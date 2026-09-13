//! `NodePool` / `NodeLease`：多 CDN 节点的 pinned client 池。
//!
//! 池内 node[0] 恒为 **SYS 节点**（无钉定、走系统 DNS 的任务级 client）——
//! 所有钉定节点被踢除后自动退到 SYS，任何情况下不比现状差（方案不变量 1）。
//!
//! 两种聚合风味共用同一套调度/踢除/EWMA 机制（设计：多镜像 metalink §4.1）：
//! - **CDN IP 聚合**（[`NodePool::multi`]）：同 host 多 IP 钉定，TLS 证书锚；
//! - **镜像聚合**（[`NodePool::mirrors`]）：同文件跨 host 多 URL，node[0] =
//!   主 URL（SYS 语义）+ 每镜像一个独立非钉定 client 槽位。两种风味互斥
//!   （分流门在 `finish_pool` 调用点，镜像优先），同一任务的分流策略只有一个。
//!
//! 调度（[`NodePool::lease`]）全部确定性、无随机：
//! - **per-节点并发上限** `cap = ceil(活跃租约数 / 存活节点数)` 强制分散，
//!   避免全部 worker 贪心涌向当前最优节点（aria2#808：per-IP 限速下分散
//!   本身就是收益）；
//! - 上限内选 `score = EWMA(吞吐) × 0.5^连续失败数` 最高者；同分取租约更少、
//!   编号更小者。无历史数据的新节点给中位初值（保证冷节点被探索）；
//! - 踢除：连续失败 ≥3 或 validator 不一致（立即）→ 本任务内不再选中；
//!   跨任务由持久化健康度 TTL 衰减自然恢复（镜像节点不持久化，仅任务内）。
//!
//! 聚合熔断（方案 §3.5）：任务内被踢节点数 > 存活钉定节点数 → 判定该 host
//! 不适合聚合，写 [`super::health`] 熔断标记（24h），本任务退 SYS 继续。
//! 镜像池不做熔断（无「host 不适合聚合」的反例语义，镜像全灭退主 URL 即兜底）。

use std::net::IpAddr;
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant};

use reqwest::Client;

use crate::db::Db;
use crate::downloader::DownloadError;
use crate::events::{EngineEvent, EventSink};
use crate::logger::log_info;
use crate::proxy_config::ProxyConfig;

/// EWMA 平滑系数（新样本权重）。
const EWMA_ALPHA: f64 = 0.3;

/// 参与 EWMA 的最小段字节数——滤除微段噪声（尾部微拆分段最低 64KB，
/// 其吞吐主要反映请求开销而非链路容量）。
const MIN_SAMPLE_BYTES: u64 = 256 * 1024;

/// 连续失败踢除阈值。
const KICK_STREAK: u32 = 3;

/// 无任何健康度先验时的初始 EWMA（4 MB/s，中位量级）：保证冷节点的初始
/// score 不为 0（可被探索），又不至于压过已被证明的快节点。
const DEFAULT_EWMA_BPS: f64 = 4.0 * 1024.0 * 1024.0;

/// `kind="leases"` 节点并发快照的最小发射间隔——租约借还极高频（每段一次），
/// 快照按"分布变化 + 节流"双门控，避免事件与日志刷屏。
const LEASES_EMIT_MIN_GAP: Duration = Duration::from_secs(2);

/// pinned client 的构建模板 = `build_client_with_tls_policy` 的参数基座。
/// `ignore_tls_errors` 恒为 false——聚合启用前置条件（方案 §3.2）保证忽略
/// TLS 错误的任务根本不会构造多节点池，故模板上不提供该自由度。
#[derive(Clone)]
pub struct ClientTemplate {
    pub proxy: ProxyConfig,
    pub user_agent: String,
}

/// 池内单节点的接入端点（CDN 钉定 IP / 镜像 URL / 系统兜底的三态泛化）。
#[derive(Clone, PartialEq)]
enum NodeEndpoint {
    /// 系统解析兜底：CDN 池的任务 client / 镜像池的主 URL client，无钉定。
    System,
    /// CDN 钉定 IP（同 host 多 IP 聚合；TLS SNI + host 钉定直连）。
    PinnedIp(IpAddr),
    /// 镜像 URL（跨 host 聚合；懒建独立非钉定 client，按 URL 自带 host 连接）。
    Mirror(String),
}

impl NodeEndpoint {
    /// 事件/诊断展示名（`CdnNodeInfo.ip` / `TaskCdnEvent.ip` 同源）。
    fn display(&self) -> String {
        match self {
            NodeEndpoint::System => "SYS".to_string(),
            NodeEndpoint::PinnedIp(ip) => ip.to_string(),
            NodeEndpoint::Mirror(url) => url.clone(),
        }
    }

    /// 是否可踢除的非兜底节点（CDN 钉定 / 镜像）。SYS 永不踢。
    fn is_failover(&self) -> bool {
        !matches!(self, NodeEndpoint::System)
    }
}

/// 池内单节点。
struct NodeSlot {
    endpoint: NodeEndpoint,
    /// 常驻 client（keep-alive 连接池挂在上面）。SYS 节点构造时注入；
    /// 钉定/镜像节点懒建（首次被选中时 `build_pinned_client` /
    /// `build_client_with_tls_policy`）。
    client: Option<Client>,
    ewma_bps: f64,
    fail_streak: u32,
    kicked: bool,
    /// 当前未归还的租约数（lease 递增，NodeLease Drop 递减）。
    outstanding: u32,
    /// 候选来源标记（`resolver::CandidateSet::origins`；镜像节点为
    /// `"mirror"`；SYS 节点为空串）。
    origin: String,
    /// 本任务经该节点累计下载的字节数（喂 `kind="summary"` 事件）。
    bytes_done: u64,
}

impl NodeSlot {
    fn score(&self) -> f64 {
        self.ewma_bps * 0.5f64.powi(self.fail_streak.min(60) as i32)
    }
}

struct PoolInner {
    slots: Vec<NodeSlot>,
    /// 聚合熔断只记一次。
    no_aggregate_recorded: bool,
    /// 上次 `kind="leases"` 快照的发射时刻（节流窗口）。
    last_leases_emit: Option<Instant>,
    /// 上次已发射快照的各槽位租约数（变化检测；与 `slots` 等长或为空）。
    last_leases_sig: Vec<u32>,
}

/// 多 CDN 节点池。见模块文档。
pub struct NodePool {
    /// 钉定目标 host（单节点池为空串）。
    host: String,
    template: Option<ClientTemplate>,
    /// 健康度/熔断持久化句柄（单节点池为 None）。
    db: Option<Db>,
    /// 所属任务（`TaskCdnEvent` 归属；单节点池为空串）。
    task_id: String,
    /// 引擎事件接收端（踢除/熔断事件；单节点池为 None，零事件）。
    sink: Option<Arc<dyn EventSink>>,
    inner: StdMutex<PoolInner>,
}

/// 一次段派工的节点租约。持有期间计入节点并发；Drop 归还。
/// [`NodePool::report`] 只负责健康度回报，不承担归还职责——两者解耦使
/// 取消/异常路径（不回报直接 drop）也绝不泄漏并发额度。
pub struct NodeLease {
    pool: Arc<NodePool>,
    node_id: usize,
    client: Client,
    endpoint: NodeEndpoint,
    /// 镜像租约的实际下载 URL（仅 [`NodeEndpoint::Mirror`] 非空；其余
    /// 风味沿用任务主 URL——CDN 钉定只改连接端点不改请求目标）。
    /// worker 侧：`lease.url.as_deref().unwrap_or(&url)`。
    pub url: Option<String>,
}

impl NodeLease {
    pub fn client(&self) -> &Client {
        &self.client
    }

    /// 是否非兜底节点（CDN 钉定 / 镜像）：段内重试预算收紧与
    /// `CdnNodeFailed` 错误翻译只对这类租约生效（快速上抛交给节点池切换）。
    /// SYS 租约保持现状语义（唯一数据流，耐心自愈）。
    pub fn is_failover(&self) -> bool {
        self.endpoint.is_failover()
    }

    /// 诊断用节点描述。
    pub fn describe(&self) -> String {
        self.endpoint.display()
    }
}

impl Drop for NodeLease {
    fn drop(&mut self) {
        let evt = {
            let Ok(mut inner) = self.pool.inner.lock() else {
                return;
            };
            if let Some(slot) = inner.slots.get_mut(self.node_id) {
                slot.outstanding = slot.outstanding.saturating_sub(1);
            }
            self.pool.leases_event_locked(&mut inner)
        };
        // 锁外发射（EventSink 契约）。
        if let Some(evt) = evt {
            self.pool.emit_all(vec![evt]);
        }
    }
}

impl NodePool {
    /// 单节点退化：包裹现有任务 client，无钉定，行为 == 现状（零事件）。
    pub fn single(client: Client) -> Arc<Self> {
        Arc::new(Self {
            host: String::new(),
            template: None,
            db: None,
            task_id: String::new(),
            sink: None,
            inner: StdMutex::new(PoolInner {
                slots: vec![NodeSlot {
                    endpoint: NodeEndpoint::System,
                    client: Some(client),
                    ewma_bps: DEFAULT_EWMA_BPS,
                    fail_streak: 0,
                    kicked: false,
                    outstanding: 0,
                    origin: String::new(),
                    bytes_done: 0,
                }],
                no_aggregate_recorded: false,
                last_leases_emit: None,
                last_leases_sig: Vec::new(),
            }),
        })
    }

    /// 多节点池：node[0] 恒为 SYS（`task_client`），`candidates` 每 IP 一个
    /// 懒建 pinned client 槽位。初始 EWMA 取持久化健康度（fresh）或冷启动
    /// 中位初值。`origins` = 每 IP 的解析来源归因（缺失 → 空串）；
    /// `task_id`/`sink` 供踢除/熔断 `TaskCdnEvent` 上报（sink=None 零事件）。
    #[allow(clippy::too_many_arguments)]
    pub fn multi(
        template: ClientTemplate,
        host: &str,
        candidates: Vec<IpAddr>,
        origins: std::collections::HashMap<IpAddr, String>,
        task_client: Client,
        db: Db,
        task_id: &str,
        sink: Option<Arc<dyn EventSink>>,
    ) -> Arc<Self> {
        let mut slots = vec![NodeSlot {
            endpoint: NodeEndpoint::System,
            client: Some(task_client),
            ewma_bps: DEFAULT_EWMA_BPS,
            fail_streak: 0,
            kicked: false,
            outstanding: 0,
            origin: String::new(),
            bytes_done: 0,
        }];
        for ip in candidates {
            let prior = super::health::lookup_ewma(host, ip);
            slots.push(NodeSlot {
                endpoint: NodeEndpoint::PinnedIp(ip),
                client: None,
                ewma_bps: prior.unwrap_or(DEFAULT_EWMA_BPS),
                fail_streak: 0,
                kicked: false,
                outstanding: 0,
                origin: origins.get(&ip).cloned().unwrap_or_default(),
                bytes_done: 0,
            });
        }
        Arc::new(Self {
            host: host.to_string(),
            template: Some(template),
            db: Some(db),
            task_id: task_id.to_string(),
            sink,
            inner: StdMutex::new(PoolInner {
                slots,
                no_aggregate_recorded: false,
                last_leases_emit: None,
                last_leases_sig: Vec::new(),
            }),
        })
    }

    /// 镜像池（与 [`Self::multi`] 对偶的另一种聚合风味）：node[0] = 主 URL
    /// （SYS 语义，任务 client；metalink 主镜像或用户原始 URL），其余每镜像
    /// 一个 Mirror 槽位（懒建独立非钉定 client，各自 DNS/连接池）。
    ///
    /// 与 CDN 池的差异：
    /// - **不持久化镜像健康度**（跨任务镜像集合不稳定，持久化会污染
    ///   `cdn_node_health` 的 `(host, ip)` 语义）→ db=None，仅任务内 EWMA；
    /// - **不做聚合熔断**（无「host 不适合聚合」的反例语义，镜像全灭退主
    ///   URL 即兜底）→ `no_aggregate_recorded` 直接置位，`check_breaker` 短路；
    /// - `host` 填主 URL 的 host（事件归属）；origin 统一 `"mirror"`
    ///   （metalink location 归因待 wire 携带后启用）。
    ///
    /// `mirror_urls` 应已排除主 URL 本身（落库语义即「不含主源」）；本构造
    /// 内部再做一次防御性去重。发一条 `kind="pool"` 就绪事件（镜像清单，
    /// UI 详情面板零改动即可显示）。
    pub fn mirrors(
        template: ClientTemplate,
        host: &str,
        mirror_urls: Vec<String>,
        task_client: Client,
        task_id: &str,
        sink: Option<Arc<dyn EventSink>>,
    ) -> Arc<Self> {
        let mut seen = std::collections::HashSet::new();
        let mut slots = vec![NodeSlot {
            endpoint: NodeEndpoint::System,
            client: Some(task_client),
            ewma_bps: DEFAULT_EWMA_BPS,
            fail_streak: 0,
            kicked: false,
            outstanding: 0,
            origin: String::new(),
            bytes_done: 0,
        }];
        for url in mirror_urls {
            if url.is_empty() || !seen.insert(url.clone()) {
                continue;
            }
            slots.push(NodeSlot {
                endpoint: NodeEndpoint::Mirror(url),
                client: None,
                ewma_bps: DEFAULT_EWMA_BPS,
                fail_streak: 0,
                kicked: false,
                outstanding: 0,
                origin: "mirror".to_string(),
                bytes_done: 0,
            });
        }
        let mirror_count = slots.len() - 1;
        let pool = Arc::new(Self {
            host: host.to_string(),
            template: Some(template),
            db: None,
            task_id: task_id.to_string(),
            sink: sink.clone(),
            inner: StdMutex::new(PoolInner {
                slots,
                no_aggregate_recorded: true,
                last_leases_emit: None,
                last_leases_sig: Vec::new(),
            }),
        });
        if let Some(sink) = sink {
            let nodes: Vec<crate::model::CdnNodeInfo> = pool
                .node_stats()
                .into_iter()
                .filter(|n| n.ip != "SYS")
                .collect();
            sink.emit(EngineEvent::TaskCdnEvent {
                task_id: task_id.to_string(),
                kind: "pool".to_string(),
                host: host.to_string(),
                nodes,
                ip: String::new(),
                reason: "mirrors".to_string(),
                candidates: mirror_count as i32,
                alive: mirror_count as i32,
                cap: mirror_count as i32,
                auto_cap: false,
            });
        }
        pool
    }

    /// 是否多节点池（含 ≥1 个钉定槽位，无论是否已被踢）。
    pub fn is_multi(&self) -> bool {
        self.inner
            .lock()
            .map(|inner| inner.slots.len() > 1)
            .unwrap_or(false)
    }

    /// 存活的非兜底节点数（CDN 钉定 / 镜像；诊断/测试用）。
    pub fn alive_failover(&self) -> usize {
        self.inner
            .lock()
            .map(|inner| {
                inner
                    .slots
                    .iter()
                    .filter(|s| s.endpoint.is_failover() && !s.kicked)
                    .count()
            })
            .unwrap_or(0)
    }

    /// `ProxyMode::Auto` 热切换：把服务节点原子替换为 `client`（代理链路）。
    ///
    /// 语义：踢除全部钉定节点（代理路由按主机名走，与钉 IP 直连互斥）并
    /// 替换 SYS 槽位的常驻 client。新租约自 [`Self::lease`] 起只会拿到代理
    /// client；在途租约在旧 client 上跑完当前段后自然收敛——分段边界即
    /// 切换边界，已下字节零丢弃。
    ///
    /// 刻意**不走**失败踢除路径：不发 `kick` 事件（这不是节点故障），并把
    /// `no_aggregate_recorded` 置位，避免聚合熔断把「主动切换」误记成
    /// 「该 host 不适合聚合」的 24h 持久化熔断标记。
    pub fn switch_to_client(&self, client: Client) {
        let mut inner = match self.inner.lock() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        };
        inner.no_aggregate_recorded = true;
        for slot in &mut inner.slots {
            if slot.endpoint.is_failover() {
                slot.kicked = true;
            }
        }
        if let Some(sys) = inner.slots.first_mut() {
            sys.client = Some(client);
        }
    }

    /// 永不阻塞、永不失败地租借一个节点。
    ///
    /// 钉定 client 懒建失败（极罕见的 builder 错误）→ 该节点按踢除处理并
    /// 继续选择；全部钉定节点不可用 → SYS 兜底。
    pub fn lease(self: &Arc<Self>) -> NodeLease {
        // 踢除/熔断事件在锁外发射（EventSink 契约不要求可重入，caller 侧
        // 也不应在持锁时调用外部代码）。
        let mut events: Vec<EngineEvent> = Vec::new();
        let lease = {
            let mut inner = match self.inner.lock() {
                Ok(g) => g,
                Err(poisoned) => poisoned.into_inner(),
            };
            let lease = loop {
                let chosen = Self::pick(&inner.slots);
                let slot = &mut inner.slots[chosen];
                // 懒建节点 client（SYS 的 client 恒存在）：CDN 钉定 →
                // host+IP 钉定；镜像 → 非钉定普通 client（按 URL 自带
                // host 连接，各自 DNS/连接池）。
                if slot.client.is_none() {
                    let built = self.template.as_ref().and_then(|t| match &slot.endpoint {
                        NodeEndpoint::System => None,
                        NodeEndpoint::PinnedIp(ip) => Some(crate::downloader::build_pinned_client(
                            &t.proxy,
                            &t.user_agent,
                            false,
                            &self.host,
                            *ip,
                        )),
                        NodeEndpoint::Mirror(_) => {
                            Some(crate::downloader::build_client_with_tls_policy(
                                &t.proxy,
                                &t.user_agent,
                                false,
                            ))
                        }
                    });
                    match built {
                        Some(Ok(client)) => slot.client = Some(client),
                        _ => {
                            log_info!(
                                "[cdn-pool] host {} 节点 {} client 构建失败，踢除",
                                self.host,
                                slot.endpoint.display()
                            );
                            slot.kicked = true;
                            if slot.endpoint.is_failover() {
                                events.push(self.kick_event(&slot.endpoint, "build", 0));
                            }
                            if let Some(evt) = self.check_breaker(&mut inner) {
                                events.push(evt);
                            }
                            continue;
                        }
                    }
                }
                let slot = &mut inner.slots[chosen];
                slot.outstanding += 1;
                let Some(client) = slot.client.clone() else {
                    // 不可达（上方已保证）；防御性回退 SYS。
                    continue;
                };
                let url = match &slot.endpoint {
                    NodeEndpoint::Mirror(url) => Some(url.clone()),
                    _ => None,
                };
                break NodeLease {
                    pool: self.clone(),
                    node_id: chosen,
                    client,
                    endpoint: slot.endpoint.clone(),
                    url,
                };
            };
            // 节点并发分布快照（节流 + 变化检测；详情面板「日志」Tab）。
            if let Some(evt) = self.leases_event_locked(&mut inner) {
                events.push(evt);
            }
            lease
        };
        self.emit_all(events);
        lease
    }

    /// `kind="leases"` 节点并发快照（持锁调用，事件由调用方在锁外发射）。
    ///
    /// 门控：多节点池且 sink 存在；各槽位未归还租约数相对上次已发射快照
    /// 发生变化；距上次发射 ≥ [`LEASES_EMIT_MIN_GAP`]。载荷 `nodes` 只含
    /// 参与中的槽位（未被踢，或虽被踢但仍有在途租约），`active` = 当前
    /// 未归还租约数，`bytes`/`ewma_bps` 为该节点截至目前的累计与实测。
    fn leases_event_locked(&self, inner: &mut PoolInner) -> Option<EngineEvent> {
        if inner.slots.len() < 2 || self.sink.is_none() {
            return None;
        }
        let sig: Vec<u32> = inner.slots.iter().map(|s| s.outstanding).collect();
        if sig == inner.last_leases_sig {
            return None;
        }
        if let Some(last) = inner.last_leases_emit
            && last.elapsed() < LEASES_EMIT_MIN_GAP
        {
            return None;
        }
        inner.last_leases_emit = Some(Instant::now());
        inner.last_leases_sig = sig;
        let nodes: Vec<crate::model::CdnNodeInfo> = inner
            .slots
            .iter()
            .filter(|s| !s.kicked || s.outstanding > 0)
            .map(|s| crate::model::CdnNodeInfo {
                ip: s.endpoint.display(),
                origin: s.origin.clone(),
                bytes: s.bytes_done.min(i64::MAX as u64) as i64,
                ewma_bps: s.ewma_bps as i64,
                active: s.outstanding.min(i32::MAX as u32) as i32,
            })
            .collect();
        log_info!(
            "[cdn-pool] task {} host {} 节点并发快照: {}",
            self.task_id,
            self.host,
            nodes
                .iter()
                .map(|n| format!("{}×{}", n.ip, n.active))
                .collect::<Vec<_>>()
                .join(" ")
        );
        Some(EngineEvent::TaskCdnEvent {
            task_id: self.task_id.clone(),
            kind: "leases".to_string(),
            host: self.host.clone(),
            nodes,
            ip: String::new(),
            reason: String::new(),
            candidates: 0,
            alive: 0,
            cap: 0,
            auto_cap: false,
        })
    }

    /// 构造一条 `kind="kick"` 事件（`count` = 连续失败次数，validator/build
    /// 路径为 0）。`ip` 字段为节点展示名（CDN 钉定 IP / 镜像 URL）。
    fn kick_event(&self, node: &NodeEndpoint, reason: &str, count: u32) -> EngineEvent {
        EngineEvent::TaskCdnEvent {
            task_id: self.task_id.clone(),
            kind: "kick".to_string(),
            host: self.host.clone(),
            nodes: Vec::new(),
            ip: node.display(),
            reason: reason.to_string(),
            candidates: count as i32,
            alive: 0,
            cap: 0,
            auto_cap: false,
        }
    }

    /// 锁外批量发射（sink=None 时静默丢弃）。
    fn emit_all(&self, events: Vec<EngineEvent>) {
        if let Some(sink) = &self.sink {
            for evt in events {
                sink.emit(evt);
            }
        }
    }

    /// 确定性选择：存活节点中，租约数低于 `cap = ceil((总租约+1)/存活数)`
    /// 者按 score 取最高（同分 → 租约更少 → 编号更小）。全部钉定被踢时
    /// 退 SYS（slot 0，永不 kicked）。
    fn pick(slots: &[NodeSlot]) -> usize {
        let alive: Vec<usize> = (0..slots.len()).filter(|&i| !slots[i].kicked).collect();
        debug_assert!(!alive.is_empty(), "SYS 节点永不被踢");
        if alive.is_empty() {
            return 0;
        }
        let total_outstanding: u32 = slots.iter().map(|s| s.outstanding).sum();
        let cap = (total_outstanding + 1).div_ceil(alive.len() as u32);
        let eligible = alive
            .iter()
            .copied()
            .filter(|&i| slots[i].outstanding < cap);
        let candidates: Vec<usize> = eligible.collect();
        let pool = if candidates.is_empty() {
            alive
        } else {
            candidates
        };
        let mut best = pool[0];
        for &i in &pool[1..] {
            let (a, b) = (&slots[i], &slots[best]);
            let better = a.score() > b.score()
                || (a.score() == b.score()
                    && (a.outstanding < b.outstanding
                        || (a.outstanding == b.outstanding && i < best)));
            if better {
                best = i;
            }
        }
        best
    }

    /// worker 段结束回报。
    ///
    /// - `Ok`：清零失败计数、累计节点字节数；段 ≥ [`MIN_SAMPLE_BYTES`] 时按
    ///   `bytes/elapsed` 喂 EWMA 并（对钉定节点）落盘健康度；
    /// - `Err`：降权（EWMA 减半 + 失败计数递增）；validator 不一致
    ///   （[`DownloadError::VersionChanged`]，多节点语境 = 节点内容不一致）
    ///   立即踢除，其余连续失败 ≥ [`KICK_STREAK`] 踢除。SYS 节点永不踢除。
    ///   踢除/熔断经 `TaskCdnEvent` 上报（锁外发射）。
    pub fn report(
        &self,
        lease: &NodeLease,
        bytes: u64,
        elapsed: Duration,
        outcome: Result<(), &DownloadError>,
    ) {
        let mut events: Vec<EngineEvent> = Vec::new();
        {
            let mut inner = match self.inner.lock() {
                Ok(g) => g,
                Err(poisoned) => poisoned.into_inner(),
            };
            let Some(slot) = inner.slots.get_mut(lease.node_id) else {
                return;
            };
            match outcome {
                Ok(()) => {
                    slot.fail_streak = 0;
                    slot.bytes_done = slot.bytes_done.saturating_add(bytes);
                    if bytes >= MIN_SAMPLE_BYTES && !elapsed.is_zero() {
                        let rate = bytes as f64 / elapsed.as_secs_f64();
                        slot.ewma_bps = (1.0 - EWMA_ALPHA) * slot.ewma_bps + EWMA_ALPHA * rate;
                        // 健康度/遥测持久化仅 CDN 钉定节点（镜像不持久化：
                        // 跨任务镜像集合不稳定，见 mirrors() 文档）。
                        if let (NodeEndpoint::PinnedIp(ip), Some(db)) =
                            (&slot.endpoint, self.db.as_ref())
                        {
                            super::health::record_ewma(&self.host, *ip, slot.ewma_bps, db);
                            // P2 遥测：段吞吐样本（仅钉定节点——SYS 无法归因 IP）。
                            super::telemetry::record_segment(
                                &self.host,
                                *ip,
                                Some(rate as u64),
                                true,
                                db,
                            );
                        }
                    }
                }
                Err(e) => {
                    slot.fail_streak += 1;
                    slot.ewma_bps *= 0.5;
                    let failover = slot.endpoint.is_failover();
                    if let (NodeEndpoint::PinnedIp(ip), Some(db)) =
                        (&slot.endpoint, self.db.as_ref())
                    {
                        super::health::record_ewma(&self.host, *ip, slot.ewma_bps, db);
                        // P2 遥测：节点失败样本。
                        super::telemetry::record_segment(&self.host, *ip, None, false, db);
                    }
                    let immediate = matches!(e, DownloadError::VersionChanged(_));
                    let should_kick = failover && (immediate || slot.fail_streak >= KICK_STREAK);
                    if should_kick {
                        slot.kicked = true;
                        let streak = slot.fail_streak;
                        log_info!(
                            "[cdn-pool] host {} 节点 {} 被踢除（{}）",
                            self.host,
                            lease.describe(),
                            if immediate {
                                "validator 不一致".to_string()
                            } else {
                                format!("连续失败 {streak}")
                            }
                        );
                        // should_kick 已蕴含 failover（SYS 永不踢），无需再判。
                        events.push(if immediate {
                            self.kick_event(&slot.endpoint, "validator", 0)
                        } else {
                            self.kick_event(&slot.endpoint, "fail", streak)
                        });
                        if let Some(evt) = self.check_breaker(&mut inner) {
                            events.push(evt);
                        }
                    }
                }
            }
        }
        self.emit_all(events);
    }

    /// 各节点的贡献统计快照（`kind="summary"` 事件载荷）：SYS 节点 ip 恒为
    /// `"SYS"`；`bytes` = 本任务经该节点实际下载字节数；`ewma_bps` = 当前
    /// EWMA 实测。含已被踢节点（其贡献仍真实存在）。
    pub fn node_stats(&self) -> Vec<crate::model::CdnNodeInfo> {
        let inner = match self.inner.lock() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        };
        inner
            .slots
            .iter()
            .map(|s| crate::model::CdnNodeInfo {
                ip: s.endpoint.display(),
                origin: s.origin.clone(),
                bytes: s.bytes_done.min(i64::MAX as u64) as i64,
                ewma_bps: s.ewma_bps as i64,
                active: s.outstanding.min(i32::MAX as u32) as i32,
            })
            .collect()
    }

    /// 池的钉定目标 host（单节点池为空串）。
    pub fn host(&self) -> &str {
        &self.host
    }

    /// 聚合熔断判定：被踢钉定节点数 > 存活钉定节点数 → 记录该 host 24h 内
    /// 不再聚合（仅记一次；本任务照常在 SYS 上继续）。触发时返回
    /// `kind="breaker"` 事件（由调用方在锁外发射）。
    fn check_breaker(&self, inner: &mut PoolInner) -> Option<EngineEvent> {
        if inner.no_aggregate_recorded {
            return None;
        }
        let kicked = inner
            .slots
            .iter()
            .filter(|s| s.endpoint.is_failover() && s.kicked)
            .count();
        let alive = inner
            .slots
            .iter()
            .filter(|s| s.endpoint.is_failover() && !s.kicked)
            .count();
        if kicked > alive {
            inner.no_aggregate_recorded = true;
            if let Some(db) = self.db.as_ref() {
                super::health::record_no_aggregate(&self.host, db);
            }
            return Some(EngineEvent::TaskCdnEvent {
                task_id: self.task_id.clone(),
                kind: "breaker".to_string(),
                host: self.host.clone(),
                nodes: Vec::new(),
                ip: String::new(),
                reason: String::new(),
                candidates: 0,
                alive: 0,
                cap: 0,
                auto_cap: false,
            });
        }
        None
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::{
        DEFAULT_EWMA_BPS, KICK_STREAK, MIN_SAMPLE_BYTES, NodeEndpoint, NodePool, NodeSlot,
    };
    use crate::downloader::DownloadError;
    use std::net::{IpAddr, Ipv4Addr};
    use std::sync::Arc;
    use std::time::Duration;

    fn ip(n: u8) -> IpAddr {
        IpAddr::V4(Ipv4Addr::new(127, 0, 0, n))
    }

    /// 直接构造带真实 client 槽位的多节点池（测试不经懒建路径，
    /// 不发任何网络请求——lease 只 clone client）。
    fn test_pool(ips: &[IpAddr]) -> Arc<NodePool> {
        let client = reqwest::Client::new();
        let pool = NodePool::single(client.clone());
        {
            let mut inner = pool.inner.lock().unwrap();
            for &ip in ips {
                inner.slots.push(NodeSlot {
                    endpoint: NodeEndpoint::PinnedIp(ip),
                    client: Some(client.clone()),
                    ewma_bps: DEFAULT_EWMA_BPS,
                    fail_streak: 0,
                    kicked: false,
                    outstanding: 0,
                    origin: String::new(),
                    bytes_done: 0,
                });
            }
        }
        pool
    }

    /// 同款直接构造镜像槽位（不经懒建，零网络）。
    fn test_mirror_pool(urls: &[&str]) -> Arc<NodePool> {
        let client = reqwest::Client::new();
        let pool = NodePool::single(client.clone());
        {
            let mut inner = pool.inner.lock().unwrap();
            for url in urls {
                inner.slots.push(NodeSlot {
                    endpoint: NodeEndpoint::Mirror(url.to_string()),
                    client: Some(client.clone()),
                    ewma_bps: DEFAULT_EWMA_BPS,
                    fail_streak: 0,
                    kicked: false,
                    outstanding: 0,
                    origin: "mirror".to_string(),
                    bytes_done: 0,
                });
            }
        }
        pool
    }

    /// 获取一个非兜底节点的租约。等分数时 tie-break 恒选低编号（SYS），
    /// 故需持有沿途的 SYS/其他租约占满其并发额度，逼出非兜底节点。
    fn failover_lease(pool: &Arc<NodePool>) -> (super::NodeLease, Vec<super::NodeLease>) {
        let mut held = Vec::new();
        loop {
            let l = pool.lease();
            if l.is_failover() {
                return (l, held);
            }
            held.push(l);
        }
    }

    #[test]
    fn single_pool_always_leases_sys() {
        let pool = NodePool::single(reqwest::Client::new());
        assert!(!pool.is_multi());
        let l1 = pool.lease();
        let l2 = pool.lease();
        assert!(!l1.is_failover());
        assert!(!l2.is_failover());
        assert_eq!(l1.describe(), "SYS");
    }

    #[test]
    fn lease_disperses_across_nodes_under_cap() {
        let pool = test_pool(&[ip(2), ip(3)]);
        assert!(pool.is_multi());
        // 3 节点（SYS + 2 钉定）等分数起步：3 个并发租约必须落在 3 个不同节点。
        let l1 = pool.lease();
        let l2 = pool.lease();
        let l3 = pool.lease();
        let mut nodes = vec![l1.node_id, l2.node_id, l3.node_id];
        nodes.sort_unstable();
        nodes.dedup();
        assert_eq!(nodes.len(), 3, "cap 约束下并发租约不得聚集单节点");
    }

    #[test]
    fn lease_release_frees_capacity() {
        let pool = test_pool(&[ip(2)]);
        let l1 = pool.lease();
        let first = l1.node_id;
        drop(l1);
        // 归还后单租约仍应落在 score 最高者上（确定性），不会因泄漏挤到他处。
        let l2 = pool.lease();
        assert_eq!(l2.node_id, first);
    }

    #[test]
    fn failed_node_gets_kicked_and_pool_falls_back_to_sys() {
        let pool = test_pool(&[ip(2)]);
        let err = DownloadError::Other("segment 0 stalled: no data".to_string());
        for _ in 0..KICK_STREAK {
            let (lease, _held) = failover_lease(&pool);
            pool.report(&lease, 0, Duration::from_secs(1), Err(&err));
        }
        // 连续失败后钉定节点被踢：此后所有租约都是 SYS。
        assert_eq!(pool.alive_failover(), 0);
        let mut held = Vec::new();
        for _ in 0..4 {
            let l = pool.lease();
            assert!(!l.is_failover());
            held.push(l);
        }
    }

    #[test]
    fn switch_to_client_retires_pinned_and_serves_new_client() {
        let pool = test_pool(&[ip(2), ip(3)]);
        assert_eq!(pool.alive_failover(), 2);
        // 在途租约不受影响地持有旧 client（切换只影响后续 lease）。
        let (old_lease, _held) = failover_lease(&pool);
        pool.switch_to_client(reqwest::Client::new());
        // 钉定节点全部退役，此后任意并发度的租约都只落 SYS（代理 client）。
        assert_eq!(pool.alive_failover(), 0);
        let mut held = Vec::new();
        for _ in 0..4 {
            let l = pool.lease();
            assert!(!l.is_failover(), "切换后新租约不得再命中钉定节点");
            held.push(l);
        }
        // 主动切换不得走熔断记录路径（kick 是节点故障语义，切换不是）。
        assert!(pool.inner.lock().unwrap().no_aggregate_recorded);
        drop(old_lease);
    }

    #[test]
    fn version_changed_kicks_immediately() {
        let pool = test_pool(&[ip(2), ip(3), ip(4)]);
        // 找到一个钉定租约并报 validator 不一致。
        let (lease, _held) = failover_lease(&pool);
        let err = DownloadError::VersionChanged("200 OK".to_string());
        let before = pool.alive_failover();
        pool.report(&lease, 0, Duration::from_secs(1), Err(&err));
        assert_eq!(
            pool.alive_failover(),
            before - 1,
            "validator 不一致立即踢除"
        );
    }

    #[test]
    fn ewma_updates_only_on_large_segments() {
        let pool = test_pool(&[ip(2)]);
        let (lease, _held) = failover_lease(&pool);
        let node_id = lease.node_id;
        // 微段：不喂 EWMA。
        pool.report(&lease, MIN_SAMPLE_BYTES - 1, Duration::from_secs(1), Ok(()));
        assert_eq!(
            pool.inner.lock().unwrap().slots[node_id].ewma_bps,
            DEFAULT_EWMA_BPS
        );
        // 大段：EWMA 移动。
        pool.report(&lease, 8 * 1024 * 1024, Duration::from_secs(1), Ok(()));
        let after = pool.inner.lock().unwrap().slots[node_id].ewma_bps;
        assert!(after > DEFAULT_EWMA_BPS, "8MB/s 样本应抬升 4MB/s 先验");
    }

    #[test]
    fn success_resets_fail_streak() {
        let pool = test_pool(&[ip(2)]);
        let (lease, _held) = failover_lease(&pool);
        let err = DownloadError::Other("segment 1 stalled: no data".to_string());
        pool.report(&lease, 0, Duration::from_secs(1), Err(&err));
        pool.report(&lease, 0, Duration::from_secs(1), Err(&err));
        pool.report(&lease, MIN_SAMPLE_BYTES, Duration::from_secs(1), Ok(()));
        assert_eq!(
            pool.inner.lock().unwrap().slots[lease.node_id].fail_streak,
            0,
            "成功必须清零失败计数（避免累积到踢除阈值）"
        );
    }

    #[test]
    fn lease_snapshot_emitted_throttled_with_active_counts() {
        use crate::events::{EngineEvent, EventSink};
        use std::sync::Mutex;

        struct CaptureSink(Mutex<Vec<EngineEvent>>);
        impl EventSink for CaptureSink {
            fn emit(&self, evt: EngineEvent) {
                self.0.lock().unwrap().push(evt);
            }
        }

        let sink = Arc::new(CaptureSink(Mutex::new(Vec::new())));
        let pool = test_pool(&[ip(2), ip(3)]);
        // test_pool 产物 sink=None；同模块直接重建带 sink 的池（槽位复用）。
        let slots = std::mem::take(&mut pool.inner.lock().unwrap().slots);
        let pool = Arc::new(NodePool {
            host: "h".to_string(),
            template: None,
            db: None,
            task_id: "t".to_string(),
            sink: Some(sink.clone()),
            inner: std::sync::Mutex::new(super::PoolInner {
                slots,
                no_aggregate_recorded: false,
                last_leases_emit: None,
                last_leases_sig: Vec::new(),
            }),
        });

        let _l1 = pool.lease();
        {
            let events = sink.0.lock().unwrap();
            let leases: Vec<_> = events
                .iter()
                .filter_map(|e| match e {
                    EngineEvent::TaskCdnEvent { kind, nodes, .. } if kind == "leases" => {
                        Some(nodes)
                    }
                    _ => None,
                })
                .collect();
            assert_eq!(leases.len(), 1, "首次租借必须发射一条 leases 快照");
            let total: i32 = leases[0].iter().map(|n| n.active).sum();
            assert_eq!(total, 1, "快照 active 总数 == 在途租约数");
        }

        // 2s 节流窗口内的后续借还不得再发射。
        let _l2 = pool.lease();
        let count = sink
            .0
            .lock()
            .unwrap()
            .iter()
            .filter(|e| matches!(e, EngineEvent::TaskCdnEvent { kind, .. } if kind == "leases"))
            .count();
        assert_eq!(count, 1, "节流窗口内不得重复发射快照");
    }
}
