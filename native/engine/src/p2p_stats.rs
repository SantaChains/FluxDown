//! P2P / BT swarm 数据聚合：把 librqbit 内部状态投影为 FluxDown 自己
//! 拥有的、可序列化的事件载荷，供 hub/server 走信号或 WS 推到 UI。
//!
//! # 设计约束
//!
//! librqbit 的 `TorrentStateLive`、`LiveStats`、`AggregatePeerStats` 等
//! 类型定义在 crate 私有模块 `torrent_state::*` 中——它们出现在 pub 方
//! 法签名与 pub 字段类型里（"abstract return"），但 FluxDown 不能写出
//! 它们的类型名做函数签名或字段类型。因此本模块的策略是：
//!
//! - 入口只接受 librqbit **已 re-export** 的类型（`BtHandle`、`Session`）；
//! - 内部对 `stats()` 返回值做**链式字段访问**取值，最后装进 FluxDown
//!   自己定义的、纯 pub 字段的 `SwarmStats` / `SessionP2pStats`；
//! - per-peer 详情（`PeerStatsSnapshot`）因返回类型不可命名，**当前不
//!   暴露**；librqbit 后续若把 `PeerStatsSnapshot` 加入 `pub use`，本
//!   模块再补 `peers: Vec<PeerInfo>` 字段。
//!
//! 这一约束不影响面板的实用价值——聚合数据（peer 总数、活动 TCP/uTP
//! 数、下载/上传速率、剩余时间、做种比、累计上传字节）已足够支撑"任务
//! 详情 → BT 状态面板"的完整可视化。

use librqbit::Session;
use serde::Serialize;

/// 重新导出 bt_downloader 的 BtHandle 别名，避免循环 use 路径。
pub use crate::bt_downloader::BtHandle;

/// 单个 BT 任务的 swarm 概览。所有字段在 BT 任务未进入 Live 阶段时
/// 取保守零值。
#[derive(Debug, Clone, Default, Serialize)]
pub struct SwarmStats {
    /// 任务 ID（由调用方填入，本结构不持有 task_id 上下文）。
    pub task_id: String,
    /// 任务状态字符串：`"initializing"` / `"live"` / `"paused"` /
    /// `"error"`（与 librqbit `TorrentStatsState` Display 一致）。
    pub state: String,
    /// 已下载并校验字节。
    pub downloaded_bytes: u64,
    /// 累计上传字节（做种贡献）。
    pub uploaded_bytes: u64,
    /// 任务总字节。
    pub total_bytes: u64,
    /// 是否已全部下载完成（最终态，校验通过）。
    pub finished: bool,
    /// 实时下载速率（B/s）。Live 状态外为 0。
    pub download_speed_bps: u64,
    /// 实时上传速率（B/s）。Live 状态外为 0。
    pub upload_speed_bps: u64,
    /// 预计剩余时间（秒）。基于 `(total-downloaded)/dl_speed` 自算，
    /// 不依赖 librqbit 私有字段；speed=0 或已完成时为 0。
    pub eta_seconds: u64,
    /// librqbit 提供的人可读 ETA 字符串（如 `"5m 30s"`），优先 UI 直
    /// 接显示；为空表示无估算（speed=0 或元数据未解析）。
    pub eta_human: Option<String>,
    /// 已观察到（seen）的 peer 总数（去重计数）。
    pub peers_seen: u32,
    /// 当前排队中的 peer 数。
    pub peers_queued: u32,
    /// 当前正在连接握手阶段的 peer 数。
    pub peers_connecting: u32,
    /// 当前 live（已建立且可读可写）的 peer 数。
    pub peers_live: u32,
    /// live peer 中走 TCP 的数量。
    pub peers_live_tcp: u32,
    /// live peer 中走 uTP（UDP）的数量。
    pub peers_live_utp: u32,
    /// live peer 中走 SOCKS 代理的数量。
    pub peers_live_socks: u32,
    /// 已死亡（断线/超时）的 peer 累计数。
    pub peers_dead: u32,
    /// 已"不需要"（have 全 piece）的 peer 数。
    pub peers_not_needed: u32,
    /// piece 窃取事件累计（活跃 swarm 内的并发调度的旁路指标）。
    pub steals: u32,
    /// 文件级进度（每个文件的已下载字节），与 librqbit `file_progress`
    /// 字段一一对应。空 = 元数据未解析或任务非 Live。
    pub file_progress: Vec<u64>,
}

impl SwarmStats {
    /// 共享比（uploaded / downloaded）。`downloaded = 0` 时返回 0。
    pub fn share_ratio(&self) -> f64 {
        if self.downloaded_bytes == 0 {
            0.0
        } else {
            self.uploaded_bytes as f64 / self.downloaded_bytes as f64
        }
    }

    /// Live peer 占已见 peer 的比例（百分比，0~100）。`seen = 0` 时为 0。
    pub fn live_ratio_percent(&self) -> f64 {
        if self.peers_seen == 0 {
            0.0
        } else {
            (self.peers_live as f64 / self.peers_seen as f64) * 100.0
        }
    }
}

/// 单个 BT session（`SharedBtSession` 内的全局 session）级聚合。
///
/// 与 [`SwarmStats`] 互补：跨所有任务的全局下载/上传速率、累计字节、
/// 总 peer 状态、session uptime。
#[derive(Debug, Clone, Default, Serialize)]
pub struct SessionP2pStats {
    /// 跨任务累计下载字节。
    pub fetched_bytes: u64,
    /// 跨任务累计上传字节。
    pub uploaded_bytes: u64,
    /// 被对端拒绝（ choked）而阻塞入站的累计字节（诊断用）。
    pub blocked_incoming: u64,
    /// 本端拒绝（choked）出站的累计字节（诊断用）。
    pub blocked_outgoing: u64,
    /// 全局实时下载速率（B/s）。
    pub download_speed_bps: u64,
    /// 全局实时上传速率（B/s）。
    pub upload_speed_bps: u64,
    /// session 启动至今的秒数。
    pub uptime_seconds: u64,
    /// 全局 peer 状态聚合（跨所有任务）。
    pub peers_seen: u32,
    pub peers_queued: u32,
    pub peers_connecting: u32,
    pub peers_live: u32,
    pub peers_live_tcp: u32,
    pub peers_live_utp: u32,
    pub peers_live_socks: u32,
    pub peers_dead: u32,
    pub peers_not_needed: u32,
    pub steals: u32,
}

/// 从单个 BT 任务句柄聚合 swarm 状态。
///
/// 幂等、非阻塞、不失败：任何中间字段访问失败都退回保守零值。
/// 适合作为定时 tick（500ms~2s）的轮询入口。
pub fn collect_task_swarm_stats(task_id: &str, handle: &BtHandle) -> SwarmStats {
    let stats = handle.stats();
    let state_str = stats_state_to_string(&stats);
    let downloaded_bytes = stats.progress_bytes;
    let uploaded_bytes = stats.uploaded_bytes;
    let total_bytes = stats.total_bytes;
    let finished = stats.finished;
    let file_progress = stats.file_progress.clone();

    // `stats.live` 是 Option<LiveStats>，类型不可命名，但字段是 pub。
    // 用 `as_ref()` 拿引用，链式访问其字段，把所有需要值拷出来。
    let (dl_bps, ul_bps, eta_human, peer_fields) = stats
        .live
        .as_ref()
        .map(|live| {
            let dl_bps = live.download_speed.as_bytes();
            let ul_bps = live.upload_speed.as_bytes();
            // `time_remaining` 是 Option<DurationWithHumanReadable>，
            // 私有 tuple struct `.0` 不可访问；但其 Display impl 输出
            // "5m 30s" 字符串。优先取字符串供 UI 直接显示，ETA 秒数
            // 在下面用 `(total-downloaded)/speed` 自算。
            let eta_human = live.time_remaining.as_ref().map(|d| format!("{d}"));
            let p = &live.snapshot.peer_stats;
            let pf = PeerFields {
                seen: p.seen,
                queued: p.queued,
                connecting: p.connecting,
                live: p.live,
                live_tcp: p.live_tcp,
                live_utp: p.live_utp,
                live_socks: p.live_socks,
                dead: p.dead,
                not_needed: p.not_needed,
                steals: p.steals,
            };
            (dl_bps, ul_bps, eta_human, pf)
        })
        .unwrap_or_default();

    // ETA 秒数自算：剩余字节 / 当前下载速率。speed=0 或已完成时为 0。
    let remaining_bytes = total_bytes.saturating_sub(downloaded_bytes);
    let eta_seconds = if dl_bps == 0 || finished {
        0
    } else {
        remaining_bytes / dl_bps
    };

    SwarmStats {
        task_id: task_id.to_string(),
        state: state_str,
        downloaded_bytes,
        uploaded_bytes,
        total_bytes,
        finished,
        download_speed_bps: dl_bps,
        upload_speed_bps: ul_bps,
        eta_seconds,
        eta_human,
        peers_seen: peer_fields.seen,
        peers_queued: peer_fields.queued,
        peers_connecting: peer_fields.connecting,
        peers_live: peer_fields.live,
        peers_live_tcp: peer_fields.live_tcp,
        peers_live_utp: peer_fields.live_utp,
        peers_live_socks: peer_fields.live_socks,
        peers_dead: peer_fields.dead,
        peers_not_needed: peer_fields.not_needed,
        steals: peer_fields.steals,
        file_progress,
    }
}

/// 从全局 BT session 聚合跨任务统计。
///
/// 入口接受 `&Session`（librqbit 已 re-export 的类型）。session.stats_snapshot()
/// 返回的 `SessionStatsSnapshot` 类型可命名（在 `pub mod session_stats`），
/// 但其字段 `peers` 类型不可命名——同样用链式访问取值。
pub fn collect_session_stats(session: &Session) -> SessionP2pStats {
    let snap = session.stats_snapshot();
    let counters = &snap.counters;
    let peers = &snap.peers;
    SessionP2pStats {
        fetched_bytes: counters.fetched_bytes,
        uploaded_bytes: counters.uploaded_bytes,
        blocked_incoming: counters.blocked_incoming,
        blocked_outgoing: counters.blocked_outgoing,
        download_speed_bps: snap.download_speed.as_bytes(),
        upload_speed_bps: snap.upload_speed.as_bytes(),
        uptime_seconds: snap.uptime_seconds,
        peers_seen: peers.seen,
        peers_queued: peers.queued,
        peers_connecting: peers.connecting,
        peers_live: peers.live,
        peers_live_tcp: peers.live_tcp,
        peers_live_utp: peers.live_utp,
        peers_live_socks: peers.live_socks,
        peers_dead: peers.dead,
        peers_not_needed: peers.not_needed,
        steals: peers.steals,
    }
}

/// 把 librqbit `TorrentStatsState`（不可命名）通过 Display trait 转
/// 字符串。Display impl 已在 librqbit 源码确认：返回 `"initializing"` /
/// `"live"` / `"paused"` / `"error"`。
///
/// 用 `format!("{}", &stats.state)` 触发 Display——`stats.state` 字段是
/// pub 的，但类型不可命名；通过 `&{Display}` 上下文可以触发其 Display
/// impl 而无需写出类型名。
fn stats_state_to_string<T: std::fmt::Display>(state: &T) -> String {
    format!("{state}")
}

/// 临时聚合 peer 字段的结构（不入公开 API），用于把 librqbit 的
/// `AggregatePeerStats` 字段一次性拷贝出来，避免在 ` SwarmStats`
/// 构造表达式里出现"类型不可命名的中间变量"。
#[derive(Default)]
struct PeerFields {
    seen: u32,
    queued: u32,
    connecting: u32,
    live: u32,
    live_tcp: u32,
    live_utp: u32,
    live_socks: u32,
    dead: u32,
    not_needed: u32,
    steals: u32,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn share_ratio_handles_zero_downloaded() {
        let s = SwarmStats {
            uploaded_bytes: 100,
            downloaded_bytes: 0,
            ..Default::default()
        };
        assert_eq!(s.share_ratio(), 0.0);
    }

    #[test]
    fn share_ratio_computes_correctly() {
        let s = SwarmStats {
            uploaded_bytes: 200,
            downloaded_bytes: 100,
            ..Default::default()
        };
        assert_eq!(s.share_ratio(), 2.0);
    }

    #[test]
    fn live_ratio_percent_handles_zero_seen() {
        let s = SwarmStats::default();
        assert_eq!(s.live_ratio_percent(), 0.0);
    }

    #[test]
    fn live_ratio_percent_computes() {
        let s = SwarmStats {
            peers_seen: 10,
            peers_live: 5,
            ..Default::default()
        };
        assert_eq!(s.live_ratio_percent(), 50.0);
    }

    #[test]
    fn stats_state_to_string_uses_display() {
        // 用一个 &str 验证 Display 路径不 panic。
        let s = stats_state_to_string(&"live");
        assert_eq!(s, "live");
    }
}
