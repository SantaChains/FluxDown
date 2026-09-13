# FluxDown internals · Flutter 前端 · 扩展 · 用户脚本 · Web SPA · 官网

> 本文件是 `FluxDown/AGENTS.md` 的深挖附录：只放**枚举性 / 可从源码复原**的细节，硬不变式与红线在 AGENTS.md。
> 路径以 `FluxDown/` 为根（cwd=工作区根时前置 `FluxDown/`）。事实层以源码为准，文档给坐标。

---

## GPUI PC 客户端（`crates/`，渐进迁移）

依赖方向固定为 `i18n` / `theme` → `components` → `shell` → `app`；下载领域 feature 后续各自成 crate 接进 shell，避免任一 UI crate 膨胀后拖慢增量 debug。

- `i18n`：`build.rs` 自动发现并嵌入既有 `assets/i18n/*.json`；locale 规范化、主语言匹配、英文键级回退、空值回退和 `{name}` 插值与 Flutter `I18nStore` 同契约。
- `theme`：公开 gpui-base 全量 `SemanticThemeTokens`（17 色/6 圆角/7 间距/排版/3 阴影），默认 shadcn neutral 亮暗主题；应用全局状态额外持有完整 token，因为 gpui-component legacy Theme 不保存自定义 spacing/shadow。
- `components`：以 gpui-base 无样式行为/无障碍原语为内核，从应用完整 token 装配视觉；feature 禁止绕过它散落颜色/尺寸。
- `shell`：窗口、顶层导航与 locale/theme 状态；`app` 只有进程入口。gpui-component 初始化已包含 gpui-base 初始化，主题切换后必须重新投影完整 Base token。
- 自定义标题栏入口必须用 `gpui_platform::application().with_assets(gpui_component_assets::Assets)` 注册控件图标，并以 `TitleBar::window_options()` 为基底；后者同时开启自管拖拽和 macOS 原生红绿灯 `(9,9)`，`TitleBar` 在 macOS 自动留 80px 左 inset。
- gpui-base 尚未发布，依赖暂走固定 gpui-component git commit；Zed workspace 必须在 `Cargo.lock` 统一为单一提交，否则 `gpui` 类型会分裂。

---

## Flutter 前端架构（`lib/src`）

**状态管理**：ChangeNotifier + ListenableBuilder（无 Provider/Riverpod/Bloc），`_safeNotifyListeners()` 防已释放。Provider 统一模式：订阅 rinf 信号 + 单向 `sendSignalToRust` 写（`SettingsProvider`/`PluginProvider`/`ComponentController`/`download_controller`/…）。

**两套配置平面**：引擎 config（`SettingsProvider`，~80 键，经 rinf → `db.rs config` 表）vs Dart-only 客户端偏好（主题、analytics、update——存 `KvStore`）。

### 存储：`services/kv_store.dart`
SharedPreferences 门面，**便携模式**（`portable` 标记）写 `<exe>/portable_data/settings.json`（400ms 防抖），安装模式透传。init() 全量入内存缓存，`runApp` 前必须 await。是 theme/analytics/update 的存储层。

### 主题：双层 token 系统（schema v2）
- `flux_theme_tokens.dart`：Layer0 **颜色** token（~30 字段 + 嵌套 metric），5 内置预设工厂（defaultDark/Light、midnightBlue、nord、warmLight），JSON per-field 回退，`FluxThemeScope` InheritedWidget 下发。
- `flux_metric_tokens.dart`：Layer1 **非颜色**度量 token（~60 字段：15 圆角/2 描边/5 间距/3 按钮高/~22 alpha/8 移动几何），private raw + clamped getter。
- `app_colors.dart`/`app_metrics.dart`：读门面（`.of(context)`）；`AppMetrics.soft/muted/scrim(color)` 由 base+alpha 派生半透明色，消灭魔法数。
- `theme_provider.dart`：5 内置 × 5 accent（blue/green/violet/rose/custom）+ 导入自定义主题（`imported_themes_v2`）+ uiScale；`activeTokens` 优先级 导入主题 > 内置+accent。
- `segment_palette.dart`：黄金角生成最多 256 个对比安全的 per-thread 颜色。

### 云同步（已移除）
`lib/src/services/cloud/` 全套（config_sync/cloud_auth/cloud_client/sync_catalog/cloud_models/device_identity/nickname_pool）及配套对话框（add_device/incoming_pairing）与测试已随云层整体删除；App 不再有账户/云同步/设备协同能力，daemon/agent 均为纯本地边界。

### 快速下载小窗：`popup/`（第二 Flutter 引擎）
原生宿主以 `--quick-popup` 拉起 `runQuickPopupApp()`，**零插件注册 + 不初始化 Rust**，经 MethodChannel `fluxdown/popup_child` 与主引擎通信（主引擎侧 `services/popup_window_service.dart`）。payload（主题 tokens/语言/队列/目录/URL）JSON 注入；复用 `quick_download_form`/`manifest_select_view` 与同一 token→ShadTheme 管线。清单预解析命中时原窗切 ManifestSelectView。

### 其它服务/模型（新）
`analytics_service.dart`（两条匿名事件，`ANALYTICS_APP_KEY` define + `analytics_enabled` 门控）、`update_service.dart`（changelog vs `APP_VERSION`，`update_channel` stable/frontier）、`platform_utils.dart`（便携检测 + 数据目录迁移，与 `data_dir.rs` 同步）、`resolve_variant_service.dart`（rinf 信号驱动全局弹窗）；`models/`：`plugin_provider`、`components_provider`（Ffmpeg/Ytdlp 控制器）、`ua_presets`（UA 单一事实源）、`custom_category`、`manifest_breadcrumb`。

### 桌面 widgets 架构（不逐文件，按族看）
- **视图系统**：`task_list` + `task_list_item`（行）、`task_columns`（列注册表，表头/行单一事实源）、`view_options_panel`（UI，backed by `models/view_prefs`）、`task_tab_bar`、`status_bar`、`sidebar`、`header_bar`。列表/网格双形态 + 舒适/紧凑双密度 + 多维分组吸顶 + 动态列。
- **manifest 对话框族**：`manifest_select_dialog`/`manifest_select_view`（与 popup 共享）/`manifest_dialog_chrome`/`manifest_browse_list`/`manifest_advanced_panel`（backed by `models/manifest_selection`+`manifest_breadcrumb`）。
- **组件**：`task_group_card`/`group_detail_panel`（backed by `models/task_group`）。
- **详情**：`detail_panel`/`bt_file_list_widget`。
- **对话框族**：`new_download_dialog`、`quick_download_dialog`+`quick_download_form`（与 popup 共享）、`queue_manager_dialog`、`plugin_detail_dialog`/`plugin_setting_form`/`plugin_list_view`、`resolve_variant_dialog`、`hls_quality_dialog`、`bt_file_selection_dialog`、`category_edit_dialog`、`update_changelog_dialog`、`feedback_dialog`。
- **原语**：`flux_sonner`（toast）、`context_menu`、`split_action_button`、`number_selector`、`ui_scale_widget`、`dir_picker_field`。

### 移动端 `mobile/`（Android 已发布）
`mobile_app`（`Platform.isAndroid||isIOS` 路由入口）、`mobile_shell`（任务/设置双屏 + 悬浮 Dock）、`mobile_ui`、`screens/`、`pages/`、`sheets/`、`services/`（share_intent、mobile_storage）。无窗口/托盘/autostart/NMH；保留 HLS/BT/variant 全局弹窗。复用 models/i18n/theme/bindings。

### 设置项（单一事实源 = `models/settings_provider.dart` load switch + `db.rs config` 表）
~80 键，分类：**下载**（default_save_dir/segments、auto_max_connections、domain_conn_caps、max_concurrent_tasks、speed_limit_bytes、max_auto_retries、auto_retry_delay_secs、auto_resume_on_start、remember/last_save_dir、default_queue_id、global_user_agent、cdn_multi_enabled、cdn_max_nodes［0=自动］、cdn_resolver_endpoints/cdn_ecs_subnets/cdn_hints_base、cdn_node_health/cdn_pending_reports/auto_route_health［引擎学习/遥测缓存，UI 不读写］）、**App/系统**（close_to_tray、start_minimized_to_tray、auto_startup、auto_check_update、update_channel、analytics_enabled、notify_on_complete、silent_download_enabled、silent_skip_selection［免打扰子开关：跳过 BT/HLS/变体二次选择；设备本地］、use_server_time、keep_awake_while_downloading、log_max_size_mb、reveal_file_cmd）、**悬浮球/剪贴板**、**侧栏/标题栏可见性**、**自定义分类**、**代理**、**BT**（含 tracker 订阅键）、**ED2K**（server_list/订阅/kad/upnp/…

---

## 浏览器扩展（`fluxDown/`）与用户脚本（`userscript/`）

### 扩展（WXT，Chrome + Firefox MV3）
- **通信**：全平台走 NMH。扩展 →（stdin/stdout）→ `fluxdown_nmh` →（Windows Named Pipe / Linux-mac UDS）→ App。消息 = 4 字节 LE 长度 + JSON。action：`ping`（只探不拉起）/`download`/`batch_download`（换行 join 单确认，按 700KB+1000 条分块防 1MB 帧上限，旧 App 回退逐条）/`warmup`（本地应答重叠冷启动）。
- **三层拦截**：`onHeadersReceived`（缓存元数据 + Firefox `webRequestBlocking` cancel）→ `onDeterminingFilename`（Chrome 主拦截 `suggest({cancel:true})`）→ `onCreated+onChanged`（兜底，Firefox 唯一路径）+ 页面态 `fetch-interceptor.ts`。
- **资源嗅探**（`media-sniff.ts`）：视频/音频/HLS/DASH/大文件，按 tabId 分组 + badge。
- Chrome ID 经 manifest key 钉住（匹配 NMH `allowed_origins`）；Alt+Shift+D 切换拦截；`Alt+Click` 15s 放行；声明零数据采集。

### 用户脚本（`userscript/fluxdown.user.js`，Tampermonkey）
页面态**扩展替代**（不能/不愿装扩展的用户）。`GM_xmlhttpRequest` POST 到本机 RPC `:17800/download`（带 `X-FluxDown-Client` 头 + 可选 token），拦截 DOM 下载 + hook fetch/XHR/MediaSource 嗅探。局限：无法拦截内核发起（Content-Disposition）下载、仅非 httpOnly cookie。

---

## Web SPA（`web/`）

React 19 + Vite 8 + TanStack（Router/Query/Table/Virtual/Form）+ Tailwind v4 + Radix + bun + oxlint + react-compiler。`bun run build` → `web/dist`，由 `fluxdown_server` **编译期内嵌**进二进制托管（SPA fallback→index.html；`FLUXDOWN_WEBROOT` 可覆盖成磁盘目录，见 hosts-and-api.md）——改了前端要重编服务器才生效。路由：`/login`、`/`（TasksScreen）、`/settings`（token 门禁，401→清凭据→/login）。`src/lib`：`api.ts`（typed REST）、`ws.ts`（可重连 WS live store）、`cloud/`（FluxCloud 客户端**残留**：Dart 侧已删、Rust agent 已纯本地化，此目录待清理）、`i18n`、`task-group`、`manifest-selection`、`view-prefs`、`theme`、`format`。

**双端信息架构对齐（硬约束）**：同一功能在 web 与桌面 App 的**归属位置必须一致，基准 = 桌面**——设置项跟随桌面 `settings_page.dart` 的分类（web 设置分区组件与桌面侧边栏分类一一对应：GeneralSettings↔通用、DownloadSettings↔下载、ProxySettings↔代理…），对话框字段的分区/排序跟随桌面对应对话框。给双端并行开发（含 subagent 派发）写任务时，**归属分类/排序必须写成一份共享契约**（明确"桌面 X 分类 + web 对应分区组件"），禁止两份各自措辞留给执行者解读。交付前自查：桌面截图里该功能在哪个菜单，web 就必须在哪个菜单。

**设置页布局**（`web/src/routes/settings.tsx` + `design.css` 的「设置」段）：左导航分类 = general/account/appearance/download/bt/**ed2k**/proxy/security/notify/extensions/about（与桌面侧边栏同序）。正文结构 `.settings-body`（滚动容器，高度确定）→ `.settings-cols`（**多列容器，高度必须自适应**——两者不能合并，否则 `column-count` 会按视口高度分列并横向溢出）。≥1200px 两列、≥1900px 三列的瀑布式排布：`.set-group` / `.set-section`（小标题+卡片+同组脚注的整体，`break-inside: avoid`）是列内元素，其余直接子元素（分区标题/说明/宽面板）`column-span: all` 整行铺满，超宽卡片显式加 `.set-wide`。异步卡片的 loading 态要与加载完成后**行数、title/desc 一致**（见 `ComponentsSettings`），否则首屏到货会重新均衡列高造成抖动。

---

## 官网（`website/`）

Astro SSR（`@astrojs/node` standalone，**自托管**非 Vercel；`deploy.sh`+Docker）。营销 + 文档 + 社区 API 站，**不属于**下载栈。
- **页面**：首页（多语言变体）、plugins、faq、themes/theme-builder、changelog、announcements、api-docs（Scalar over `public/openapi.json`）、sponsor/pay、vote、privacy/terms、feedback 等。
- **`/docs` 双语内容集**：`src/content/docs/{en,zh}/<section>/<page>.md`（纯 Markdown，禁 MDX/HTML）；section 枚举见 `content.config`；zh 带 `sourceHash`（en 正文 sha256[:12]，`npm run docs:hash`）驱动过期横幅；en-only 页回退 en + `noindex` + 排除 sitemap（`docs-fallback.ts` 单源）。
- **API 路由**（`src/pages/api/`）：feedback、changelog、release、plugins/themes/components 代理、sponsor/pay、vote、subscribe、issues、`webhooks/github`（**GitHub webhook 接收器**，HMAC——与任务事件 webhook 无关，见 `ops.md`「设计文档实现状态」）。
