# FluxDown — 开发者文档（readme.dev.md）

> **改版分支说明**：本仓库为 `SantaChains` 基于 [`zerx-lab/FluxDown`](https://github.com/zerx-lab/FluxDown) 的改版分支，仓库地址 <https://github.com/SantaChains/FluxDown>。原始项目以 **GNU AGPL v3.0** 发布；本分支沿用同一许可，保留原始版权与署名，并叠加改版作者信息（详见 `NOTICE` 与 `LICENSE`）。根据 AGPL §13，通过网络交互（headless server / Web SPA）提供修改版本时，须向用户提供对应源代码——即本分支仓库本身。
>
> 本文件只覆盖**内核架构、构建/测试、硬不变式与扩展点坐标**，枚举性细节见 `.omp/knowledge/*`。

---

## 1. 一句话定位

`fluxdown_engine` 是整个产品唯一的下载逻辑载体：**零 FFI、零 rinf 依赖**的 Rust + Tokio 下载引擎。所有下载能力收敛在单一 crate 内，靠**三个引擎自有 trait** 与外界解耦，从而支撑"一个引擎、多个宿主、多个客户端"的架构。

## 2. 顶层目录地图

| 目录 | 职责 |
|---|---|
| `native/engine/` | **下载内核**：协议/分段/DB/队列/组/插件，零 FFI |
| `native/api/` | HTTP 契约（`&dyn ApiHost`）、REST/aria2/MCP/OpenAPI，零 rinf |
| `native/hub/` | **唯一**碰 rinf FFI 的 crate（App，actor=`download_actor.rs`） |
| `native/server/` | headless 服务器（**已进入废弃路径**） |
| `native/daemon/` | 迁移目标：aria2c 式纯下载核心（不含账户/云同步/UI） |
| `native/agent/` | 迁移目标：账户/云同步/设备协同 + UI Gateway（不直接执行下载） |
| `native/protocol/` | 本机 wire 层（daemon↔agent 共享的 JSON-RPC 语义） |
| `crates/*` | GPUI PC 迁移层（`crates/app` 包名 `fluxdown_ui_app`） |
| `lib/` | Flutter UI（shadcn_ui） |
| `web/` | React Web SPA（headless 管理界面） |
| `fluxDown/` | WXT 浏览器扩展 |
| `website/` | Astro 官网 |
| `userscript/` | Tampermonkey 用户脚本 |
| `.omp/knowledge/` | **随仓分发**的 AI 工具链知识文档（架构/契约/扩展点） |

## 3. 内核架构：三个解耦 trait（关键）

理解整个架构的钥匙。`fluxdown_engine` 不直接依赖任何宿主，只通过以下 trait 与外界交互：

| Trait | 方向 | 定义位置 | 契约要点 |
|---|---|---|---|
| `EventSink` | 引擎→宿主 | `engine/src/events.rs` | **同步** `fn emit(&self, EngineEvent)`、`Send+Sync`、fire-and-forget；实现**不得阻塞** |
| `HostSelection` | 引擎→宿主（请求决策） | `engine/src/selection.rs` | `async_trait`、`Arc<dyn>`；**三态** `SelectionOutcome<T>`（UserChose / TimedOutDefaulted / NoSelectorConfigured） |
| `ApiHost` | 客户端→引擎 | `fluxdown_api/src/service.rs` | 仅 `&dyn ApiHost` 依赖；同一套 HTTP 面服务任意宿主 |

`Engine` 是 facade（`engine/src/lib.rs`），直接暴露 `db` + `manager` + `selector` + `data_dir` 字段而非逐方法转发。宿主接入成本极低：注入 `EventSink`/`HostSelection` 两个 trait，`Engine::initialize` 内自举其余子系统（RSS、webhook、插件），宿主不必手动接线。

## 4. 并发模型（已落地验证）

实测 `DownloadManager`（`engine/src/download_manager.rs`）：

- **串行写**：actor 在 `current_thread` tokio 上串行化所有状态变更；每个下载 `tokio::spawn` 独立 task，配 `CancellationToken`。
- **generation 计数器**：`active_tasks: HashMap<String, ActiveTaskEntry>` + 单调 `generation: u64`。作用：防止"旧 spawn 的 `TaskDone` 误删新 spawn 的 token"；`pending_pauses` 保留已取消但仍 flush 进度的一代，避免 pause→resume 重叠写同一临时文件。
- **协议分发即容错边界**：`do_start_task`/`do_resume_task` 内为单条 `if/else` 链（`use_ftp/use_hls/use_dash/use_bt/use_ed2k`，else=HTTP 兜底），**每臂都 `AssertUnwindSafe(...).catch_unwind().await`**。panic 经 `handle_task_panic` 写 `status=4`，配合 `profile.release` **不设** `panic="abort"`——删掉即失去 task 级自愈。
- **off-actor 插件解析**：resolver 在后台 `handle.spawn` 跑，经 `resolve_tx/rx` unbounded channel 回流 actor；actor 必须 drain `resolve_rx` + `plugin_retry_rx`，否则命中 resolver 的任务永久挂起。这是 `hub::download_actor.rs` 与 `server::actor.rs` 都必须遵守的接线契约。

## 5. 六协议分发与陷阱

判定谓词：`is_ftp_url`/`is_bt_url`（`download_manager.rs`）/`hls_downloader::is_hls_url`/`dash_downloader::is_dash_url`/`ed2k::link::is_ed2k_url`。

**最易踩的坑**：`is_bt_url` 只认 `magnet:` 与 `torrent-file://` 哨兵。HTTP 的 `.torrent` **直链不会走 BT**，会被当普通文件下回来一个种子——要让直链变真下载，必须先抓字节再以 `NewTaskSpec::torrent_file_bytes` 建任务（RSS 订阅即此做法）。BT 任务绕过 pending 队列、不计入 `max_concurrent`（并发由 librqbit 共享会话自管）。

## 6. 关键子系统（一句话职责）

`segment_coordinator`（IDM 式动态分段 + per-domain 连接策略学习）、`auto_proxy`（ProxyMode::Auto 决策机：直连优先 + 并行采样 + 热切换 + 三层先验）、`cdn`（多节点聚合/健康度/云端 resolver 端点）、`plugin`（rquickjs 沙箱，Resolver+通知+门控工具三平面，feature 门控）、`rss`（三层去重 + 无人值守不变式）、`db`（sqlx Any 双后端）。细节见 `.omp/knowledge/engine.md`。

## 7. 硬不变式（维护/迁移前必读）

1. **`download_actor.rs` 主 `tokio::select!` 已占满 64 分支硬上限**——新信号/节拍/回流**不许**往主循环加分支，必须并进 `AuxSignal` 合并泵（两个后台 spawn 把消息合流进单条 `aux_tx`，主循环只有一条 `aux_rx.recv()`）。
2. **feature 门控零行为变化**：`plugins`/`components`/`link` 关闭时主链路不得有任何行为差异（注入 no-op `PluginManager`、整模块 `cfg` 门控）。
3. **`native/server` 进入废弃路径**；下一代 `native/daemon`（纯下载核心）+ `native/agent`（云/UI Gateway）+ `native/protocol`（共享 wire）基础 crate 已落盘，但**运行链路仍在迁移中**——当前生产路径仍是 `hub`/`server`，不得把目标图误报为已运行。
4. **BT DHT 持久化三级兜底** + anyhow 一律 `{e:#}` 打印（否则根因被吞）；Windows 上 `bt_sparse` 打 NTFS sparse 免簇预留。
5. **DB 双后端**：`sqlite:`/`postgres:` 按 URL 选，`$N` 占位符统一，`add_column_if_missing` 幂等迁移；`config` 表存**所有**设置键。

## 8. 构建与测试命令速查

> 命令按 cwd=`FluxDown/` 书写。Rust 按 crate 检查，不要整 workspace；测试按 crate/过滤，不要 `--workspace`。

```bash
# ── 代码生成（改 Rust 信号后必须）──
rinf gen                              # 生成 Dart 绑定（lib/src/bindings，勿手改）

# ── 构建 / 静态检查 ──
cargo check -p <crate> --lib          # 验证编译按 crate
cargo fmt --check && cargo clippy -- -D warnings   # 提交前必过
flutter analyze                       # Dart 静态分析
# flutter run -d windows              # ⚠️ 禁止运行此命令

# ── 测试 ──
cargo nextest run -p fluxdown_engine <filter>   # 引擎单测（协议/分段/DB）
cargo test -p fluxdown_api            # HTTP API 漂移守卫
cargo test -p fluxdown_server         # headless server（WS/actor/扩展路由）
cargo test -p fluxdown_cli            # CLI 退出码/尺寸解析
flutter test                          # Dart 测试
PG_TEST_URL=postgres://postgres:pw@localhost/postgres cargo test -p fluxdown_engine -- --ignored pg_smoke

# ── 运行宿主/客户端 ──
cargo run -p fluxdown_server          # headless 服务器
cargo run -p fluxdown_cli -- ping     # CLI 探活
cargo run -p fluxdown_cli -- add <url> --local   # B 模式：内嵌引擎独立下载
cd web && bun run dev                 # Web SPA localhost:5173
cd website && npm run dev             # 官网 Astro localhost:4321
cd fluxDown && npm run dev            # 扩展开发（Chrome）

# ── 图标 / 发布 ──
bun scripts/gen_icons.ts              # 改 assets/logo/*.svg 后重生成全平台图标
cargo run -p fluxdown_api --example gen_openapi > website/public/openapi.json   # 改 API 后重生成
git tag -a vX.Y.Z -m "vX.Y.Z" && git push origin vX.Y.Z   # 触发发布流水线
```

## 9. 扩展点坐标（动手前先查）

"要加 X 改哪里"全表见 `.omp/knowledge/extension-points.md`。设置键在 `lib/src/models/settings_provider.dart` 的 load switch + 引擎 `db.rs` 的 `config` 表；DB schema 在 `native/engine/src/db.rs`；HTTP 契约在 `native/api/src/types.rs`（`camelCase` wire）+ `routes.rs`；Rust↔Dart 信号在 `native/hub/src/signals/mod.rs` + 生成的 `lib/src/bindings/`。

## 10. 改版分支的本地化改动

- **Logo**：源 SVG 位于 `assets/logo/fluxdown_logo.svg`（蓝底白箭头）与 `fluxdown_bolt.svg`（白底蓝三角闪电）；`bun scripts/gen_icons.ts` 以源 SVG 重新生成全平台尺寸。
- **作者署名**：README / 官网 Footer / 关于页署名改为 `SantaChains`，保留 "Based on FluxDown by zerx-lab, AGPL-3.0" 声明；`LICENSE` 正文保持 AGPL v3 原文不变，`NOTICE` 追加改版声明。
- **账号/云功能**：本分支移除了上游 FluxCloud 账号/云同步/设备协同相关功能，定位为纯本地优先（local-first）。涉及 `lib/src/services/cloud/*`、`web/src/lib/cloud/*`、`native/agent` 账户相关路径。
