import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import '../services/file_picker_service.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/build_stats.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rinf/rinf.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import '../widgets/flux_sonner.dart';
import '../../main.dart';
import '../bindings/bindings.dart';
import '../i18n/locale_provider.dart';
import '../models/custom_category.dart';
import '../models/download_controller.dart';
import '../models/download_queue.dart';
import '../models/components_provider.dart';
import '../models/plugin_provider.dart';
import '../models/settings_provider.dart';
import '../models/site_auth_store.dart';
import '../models/ua_presets.dart';
import '../models/webhook_endpoint.dart';
import '../models/webhook_provider.dart';
import '../services/app_icon_service.dart';
import '../services/floating_ball/floating_ball_service.dart';
import '../services/link/local_pairing_service.dart';
import '../services/local_interfaces.dart';
import '../services/log_service.dart';
import '../services/update_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../theme/flux_theme_tokens.dart';
import '../theme/theme_provider.dart';
import '../widgets/category_edit_dialog.dart';
import '../widgets/dir_picker_field.dart';
import '../widgets/doctor_report_view.dart';
import '../widgets/number_selector.dart';
import '../widgets/plugin_list_view.dart';
import '../widgets/webhook_delivery_panel.dart';
import '../widgets/webhook_endpoint_dialog.dart';
import '../widgets/webhook_endpoint_list.dart';
import '../widgets/thread_selector.dart';
import '../widgets/title_drag_area.dart';

// ─────────────────────────────────────────────
// 设置分类枚举
// ─────────────────────────────────────────────

enum SettingsCategory {
  general(icon: LucideIcons.settings2),
  account(icon: LucideIcons.cloud),
  appearance(icon: LucideIcons.palette),
  download(icon: LucideIcons.download),
  bt(icon: LucideIcons.magnet),
  ed2k(icon: LucideIcons.share2),
  proxy(icon: LucideIcons.globe),
  apiService(icon: LucideIcons.server),
  notify(icon: LucideIcons.bellRing),
  extensions(icon: LucideIcons.puzzle),
  doctor(icon: LucideIcons.stethoscope),
  about(icon: LucideIcons.info),
  referral(icon: LucideIcons.gift);

  final IconData icon;

  const SettingsCategory({required this.icon});
}

extension SettingsCategoryI18n on SettingsCategory {
  String get localizedLabel {
    final s = currentS;
    return switch (this) {
      SettingsCategory.general => s.settingsCatGeneral,
      SettingsCategory.account => s.settingsCatAccount,
      SettingsCategory.referral => s.settingsCatReferral,
      SettingsCategory.appearance => s.settingsCatAppearance,
      SettingsCategory.download => s.settingsCatDownload,
      SettingsCategory.bt => s.settingsCatBt,
      SettingsCategory.ed2k => s.settingsCatEd2k,
      SettingsCategory.proxy => s.settingsCatProxy,
      SettingsCategory.apiService => s.settingsCatApiService,
      SettingsCategory.notify => s.settingsCatNotify,
      SettingsCategory.extensions => s.settingsCatExtensions,
      SettingsCategory.doctor => s.settingsCatDoctor,
      SettingsCategory.about => s.settingsCatAbout,
    };
  }

  String get localizedDesc {
    final s = currentS;
    return switch (this) {
      SettingsCategory.general => s.settingsCatGeneralDesc,
      SettingsCategory.account => s.settingsCatAccountDesc,
      SettingsCategory.referral => s.settingsCatReferralDesc,
      SettingsCategory.appearance => s.settingsCatAppearanceDesc,
      SettingsCategory.download => s.settingsCatDownloadDesc,
      SettingsCategory.bt => s.settingsCatBtDesc,
      SettingsCategory.ed2k => s.settingsCatEd2kDesc,
      SettingsCategory.proxy => s.settingsCatProxyDesc,
      SettingsCategory.apiService => s.settingsCatApiServiceDesc,
      SettingsCategory.notify => s.settingsCatNotifyDesc,
      SettingsCategory.extensions => s.settingsCatExtensionsDesc,
      SettingsCategory.doctor => s.settingsCatDoctorDesc,
      SettingsCategory.about => s.settingsCatAboutDesc,
    };
  }
}

// ─────────────────────────────────────────────
// 分类子 Tab
// ─────────────────────────────────────────────

/// 子 Tab id 常量：用于会话内选中记忆与搜索定位路由，字面量保持稳定。
const _kTabBasic = 'basic';
const _kTabTracker = 'tracker';
const _kTabSeeding = 'seeding';
const _kTabServers = 'servers';
const _kTabPlugins = 'plugins';
const _kTabComponents = 'components';
const _kTabReferralIntro = 'referralIntro';
const _kTabReferralCodes = 'referralCodes';
const _kTabReferralRecords = 'referralRecords';

/// 分类下的子 Tab 描述。
class _SettingsTabSpec {
  final String id;
  final String label;

  const _SettingsTabSpec({required this.id, required this.label});
}

/// 各分类的子 Tab 列表（空 = 该分类无 Tab，内容单页展示）。
/// 新增 Tab 时在此登记，并为 [settingsSearchItems] 中对应条目补 `tabId`，
/// 保证设置搜索能直达目标 Tab。
List<_SettingsTabSpec> _settingsTabsFor(SettingsCategory category) {
  final s = currentS;
  return switch (category) {
    SettingsCategory.bt => [
      _SettingsTabSpec(id: _kTabBasic, label: s.settingsTabGeneral),
      _SettingsTabSpec(id: _kTabTracker, label: s.settingsTabTracker),
      _SettingsTabSpec(id: _kTabSeeding, label: s.settingsTabSeeding),
    ],
    SettingsCategory.ed2k => [
      _SettingsTabSpec(id: _kTabBasic, label: s.settingsTabGeneral),
      _SettingsTabSpec(id: _kTabServers, label: s.settingsTabServers),
    ],
    SettingsCategory.extensions => [
      _SettingsTabSpec(id: _kTabPlugins, label: s.settingsCatPlugins),
      _SettingsTabSpec(id: _kTabComponents, label: s.settingsCatComponents),
    ],
    SettingsCategory.referral => [
      _SettingsTabSpec(
        id: _kTabReferralIntro,
        label: s.accountReferralTabIntro,
      ),
      _SettingsTabSpec(id: _kTabReferralCodes, label: s.accountReferralTabCode),
      _SettingsTabSpec(
        id: _kTabReferralRecords,
        label: s.accountReferralTabRecords,
      ),
    ],
    _ => const [],
  };
}

/// 设置项搜索元数据 — 每个设置项对应的分类 + 搜索关键词
class SettingsSearchItem {
  final SettingsCategory category;
  final String label;
  final String description;
  final List<String> keywords;
  final IconData icon;

  /// 目标设置项所在的子 Tab id（见 [_settingsTabsFor]）；
  /// null = 分类无 Tab 或位于默认 Tab。
  final String? tabId;

  SettingsSearchItem({
    required this.category,
    required this.label,
    required this.description,
    required this.keywords,
    required this.icon,
    this.tabId,
  });

  /// 与查询串（已 toLowerCase）匹配：标签/描述/关键词任一命中。
  bool matches(String query) =>
      label.toLowerCase().contains(query) ||
      description.toLowerCase().contains(query) ||
      keywords.any((k) => k.toLowerCase().contains(query));
}

/// 所有可搜索的设置项列表
List<SettingsSearchItem> get settingsSearchItems {
  final s = currentS;
  return [
    SettingsSearchItem(
      category: SettingsCategory.general,
      label: s.autoStartup,
      description: s.autoStartupDesc,
      keywords: s.searchKeywordsAutoStartup,
      icon: LucideIcons.power,
    ),
    SettingsSearchItem(
      category: SettingsCategory.general,
      label: s.closeToTray,
      description: s.closeToTrayDesc,
      keywords: s.searchKeywordsCloseToTray,
      icon: LucideIcons.panelBottomClose,
    ),
    SettingsSearchItem(
      category: SettingsCategory.general,
      label: s.startMinimizedToTray,
      description: s.startMinimizedToTrayDesc,
      keywords: s.searchKeywordsStartMinimizedToTray,
      icon: LucideIcons.eyeOff,
    ),
    SettingsSearchItem(
      category: SettingsCategory.general,
      label: s.floatingBall,
      description: s.floatingBallDesc,
      keywords: s.searchKeywordsFloatingBall,
      icon: LucideIcons.circleDot,
    ),
    if (Platform.isLinux)
      SettingsSearchItem(
        category: SettingsCategory.general,
        label: s.clipboardWatch,
        description: s.clipboardWatchDesc,
        keywords: s.searchKeywordsClipboardWatch,
        icon: LucideIcons.clipboard,
      ),
    SettingsSearchItem(
      category: SettingsCategory.general,
      label: s.torrentFileAssociation,
      description: s.torrentFileAssociationDesc,
      keywords: s.searchKeywordsFileAssoc,
      icon: LucideIcons.fileType,
    ),
    SettingsSearchItem(
      category: SettingsCategory.general,
      label: s.ed2kLinkAssociation,
      description: s.ed2kLinkAssociationDesc,
      keywords: s.searchKeywordsEd2kAssoc,
      icon: LucideIcons.link,
    ),
    SettingsSearchItem(
      category: SettingsCategory.general,
      label: s.magnetLinkAssociation,
      description: s.magnetLinkAssociationDesc,
      keywords: s.searchKeywordsMagnetAssoc,
      icon: LucideIcons.magnet,
    ),
    SettingsSearchItem(
      // 「下载完成通知」随分类迁移到「通知」——搜索定位不断链。
      category: SettingsCategory.notify,
      label: s.notifyOnComplete,
      description: s.notifyOnCompleteDesc,
      keywords: s.searchKeywordsNotifyOnComplete,
      icon: LucideIcons.bellRing,
    ),
    SettingsSearchItem(
      category: SettingsCategory.notify,
      label: s.notifyGroupWebhook,
      description: s.webhookEmptyDesc,
      keywords: s.searchKeywordsWebhook,
      icon: LucideIcons.webhook,
    ),
    SettingsSearchItem(
      category: SettingsCategory.notify,
      label: s.webhookDeliveryLog,
      description: s.webhookLogSubtitle,
      keywords: s.searchKeywordsWebhookLog,
      icon: LucideIcons.scrollText,
    ),
    SettingsSearchItem(
      category: SettingsCategory.general,
      label: s.keepAwakeWhileDownloading,
      description: s.keepAwakeWhileDownloadingDesc,
      keywords: s.searchKeywordsKeepAwake,
      icon: LucideIcons.coffee,
    ),
    SettingsSearchItem(
      category: SettingsCategory.general,
      label: s.sidebarVisibility,
      description: s.sidebarVisibilityDesc,
      keywords: s.searchKeywordsSidebarVisibility,
      icon: LucideIcons.panelLeft,
    ),
    SettingsSearchItem(
      category: SettingsCategory.general,
      label: s.titlebarButtons,
      description: s.titlebarButtonsDesc,
      keywords: s.searchKeywordsTitlebarButtons,
      icon: LucideIcons.panelTop,
    ),
    SettingsSearchItem(
      category: SettingsCategory.general,
      label: s.customCategories,
      description: s.customCategoriesDesc,
      keywords: s.searchKeywordsCustomCategories,
      icon: LucideIcons.layoutList,
    ),
    SettingsSearchItem(
      category: SettingsCategory.appearance,
      label: s.language,
      description: s.languageDesc,
      keywords: s.searchKeywordsLanguage,
      icon: LucideIcons.languages,
    ),
    SettingsSearchItem(
      category: SettingsCategory.appearance,
      label: s.themeMode,
      description: s.themeModeDesc,
      keywords: s.searchKeywordsThemeMode,
      icon: LucideIcons.sunMoon,
    ),
    SettingsSearchItem(
      category: SettingsCategory.appearance,
      label: s.themeColor,
      description: s.themeColorDesc,
      keywords: s.searchKeywordsThemeColor,
      icon: LucideIcons.palette,
    ),
    SettingsSearchItem(
      category: SettingsCategory.appearance,
      label: s.uiScale,
      description: s.uiScaleDesc,
      keywords: s.searchKeywordsUiScale,
      icon: LucideIcons.maximize,
    ),
    SettingsSearchItem(
      category: SettingsCategory.appearance,
      label: s.appIcon,
      description: s.appIconDesc,
      keywords: s.searchKeywordsAppIcon,
      icon: LucideIcons.image,
    ),
    SettingsSearchItem(
      category: SettingsCategory.download,
      label: s.defaultSaveDir,
      description: s.defaultSaveDirDesc,
      keywords: s.searchKeywordsSaveDir,
      icon: LucideIcons.folderOpen,
    ),
    SettingsSearchItem(
      category: SettingsCategory.download,
      label: s.rememberLastSaveDir,
      description: s.rememberLastSaveDirDesc,
      keywords: s.searchKeywordsSaveDir,
      icon: LucideIcons.history,
    ),
    SettingsSearchItem(
      category: SettingsCategory.download,
      label: s.silentDownload,
      description: s.silentDownloadDesc,
      keywords: s.searchKeywordsSilentDownload,
      icon: LucideIcons.bellOff,
    ),
    SettingsSearchItem(
      category: SettingsCategory.download,
      label: s.silentSkipSelection,
      description: s.silentSkipSelectionDesc,
      keywords: s.searchKeywordsSilentSkipSelection,
      icon: LucideIcons.listChecks,
    ),
    SettingsSearchItem(
      category: SettingsCategory.download,
      label: s.useServerTime,
      description: s.useServerTimeDesc,
      keywords: s.searchKeywordsUseServerTime,
      icon: LucideIcons.clock,
    ),
    SettingsSearchItem(
      category: SettingsCategory.download,
      label: s.fileExistsBehavior,
      description: s.fileExistsBehaviorDesc,
      keywords: s.searchKeywordsFileExists,
      icon: LucideIcons.copyX,
    ),
    SettingsSearchItem(
      category: SettingsCategory.download,
      label: s.fileMissingAction,
      description: s.fileMissingActionDesc,
      keywords: s.searchKeywordsFileMissing,
      icon: LucideIcons.fileX,
    ),
    SettingsSearchItem(
      category: SettingsCategory.download,
      label: s.defaultThreads,
      description: s.defaultThreadsDesc,
      keywords: s.searchKeywordsThreads,
      icon: LucideIcons.layers,
    ),
    SettingsSearchItem(
      category: SettingsCategory.download,
      label: s.autoMaxConnections,
      description: s.autoMaxConnectionsDesc,
      keywords: s.searchKeywordsThreads,
      icon: LucideIcons.layers,
    ),
    SettingsSearchItem(
      category: SettingsCategory.download,
      label: s.cdnMultiEnabled,
      description: s.cdnMultiEnabledDesc,
      keywords: s.searchKeywordsCdnMulti,
      icon: LucideIcons.network,
    ),
    SettingsSearchItem(
      category: SettingsCategory.download,
      label: s.connPolicyCache,
      description: s.connPolicyCacheDesc,
      keywords: s.searchKeywordsThreads,
      icon: LucideIcons.shieldOff,
    ),
    SettingsSearchItem(
      category: SettingsCategory.download,
      label: s.maxConcurrent,
      description: s.maxConcurrentDesc,
      keywords: s.searchKeywordsConcurrent,
      icon: LucideIcons.listOrdered,
    ),
    SettingsSearchItem(
      category: SettingsCategory.download,
      label: s.speedLimit,
      description: s.speedLimitDesc,
      keywords: s.searchKeywordsSpeedLimit,
      icon: LucideIcons.gauge,
    ),
    SettingsSearchItem(
      category: SettingsCategory.download,
      label: s.userAgent,
      description: s.userAgentDesc,
      keywords: s.searchKeywordsUserAgent,
      icon: LucideIcons.userCheck,
    ),
    SettingsSearchItem(
      category: SettingsCategory.about,
      label: s.softwareUpdate,
      description: s.checkUpdateDesc,
      keywords: s.searchKeywordsUpdate,
      icon: LucideIcons.refreshCw,
    ),
    SettingsSearchItem(
      category: SettingsCategory.bt,
      label: s.btSettings,
      description: s.btSettingsDesc,
      keywords: s.searchKeywordsBtSettings,
      icon: LucideIcons.magnet,
      tabId: _kTabBasic,
    ),
    SettingsSearchItem(
      category: SettingsCategory.bt,
      label: s.btTrackerList,
      description: s.btTrackerListDesc,
      keywords: s.searchKeywordsBtSettings,
      icon: LucideIcons.list,
      tabId: _kTabTracker,
    ),
    SettingsSearchItem(
      category: SettingsCategory.bt,
      label: s.btTrackerSub,
      description: s.btTrackerSubDesc,
      keywords: s.searchKeywordsBtSettings,
      icon: LucideIcons.rss,
      tabId: _kTabTracker,
    ),
    SettingsSearchItem(
      category: SettingsCategory.bt,
      label: s.btSeedingTitle,
      description: s.btSeedingTitle,
      keywords: s.searchKeywordsBtSettings,
      icon: LucideIcons.uploadCloud,
      tabId: _kTabSeeding,
    ),
    SettingsSearchItem(
      category: SettingsCategory.ed2k,
      label: s.ed2kSettings,
      description: s.ed2kSettingsDesc,
      keywords: s.searchKeywordsEd2kSettings,
      icon: LucideIcons.share2,
      tabId: _kTabBasic,
    ),
    SettingsSearchItem(
      category: SettingsCategory.ed2k,
      label: s.ed2kServerList,
      description: s.ed2kServerListDesc,
      keywords: s.searchKeywordsEd2kSettings,
      icon: LucideIcons.server,
      tabId: _kTabServers,
    ),
    SettingsSearchItem(
      category: SettingsCategory.ed2k,
      label: s.ed2kServerSub,
      description: s.ed2kServerSubDesc,
      keywords: s.searchKeywordsEd2kSettings,
      icon: LucideIcons.rss,
      tabId: _kTabServers,
    ),
    SettingsSearchItem(
      category: SettingsCategory.proxy,
      label: s.proxySettings,
      description: s.proxySettingsDesc,
      keywords: s.searchKeywordsProxy,
      icon: LucideIcons.globe,
    ),
    SettingsSearchItem(
      category: SettingsCategory.apiService,
      label: s.apiServiceEnable,
      description: s.apiServiceEnableDesc,
      keywords: s.searchKeywordsApiService,
      icon: LucideIcons.server,
    ),
    SettingsSearchItem(
      category: SettingsCategory.doctor,
      label: s.doctorTitle,
      description: s.doctorDesc,
      keywords: s.searchKeywordsDoctor,
      icon: LucideIcons.stethoscope,
    ),
    SettingsSearchItem(
      category: SettingsCategory.doctor,
      label: s.doctorRepairNmh,
      description: s.doctorCheckNmhBrowser,
      keywords: s.searchKeywordsDoctor,
      icon: LucideIcons.wrench,
    ),
    SettingsSearchItem(
      category: SettingsCategory.doctor,
      label: s.doctorCopyReport,
      description: s.doctorDesc,
      keywords: s.searchKeywordsDoctor,
      icon: LucideIcons.clipboardCopy,
    ),
    SettingsSearchItem(
      category: SettingsCategory.about,
      label: s.logExport,
      description: s.logExportDesc,
      keywords: s.searchKeywordsLogExport,
      icon: LucideIcons.fileText,
    ),
    SettingsSearchItem(
      category: SettingsCategory.about,
      label: s.donateTitle,
      description: s.donateButton,
      keywords: s.searchKeywordsDonate,
      icon: LucideIcons.heart,
    ),
  ];
}

// ─────────────────────────────────────────────
// 设置页面（带侧边栏导航）
// ─────────────────────────────────────────────

class SettingsPage extends StatefulWidget {
  final VoidCallback onBack;
  final SettingsProvider settingsProvider;
  final PluginProvider pluginProvider;
  final DownloadController? downloadController;
  final SettingsCategory? initialCategory;

  /// 从首页搜索跳转进来时携带的高亮项：切到其分类并闪烁定位对应设置卡片。
  final SettingsSearchItem? initialHighlight;

  const SettingsPage({
    super.key,
    required this.onBack,
    required this.settingsProvider,
    required this.pluginProvider,
    this.downloadController,
    this.initialCategory,
    this.initialHighlight,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

/// 一次「定位到设置项」的高亮请求。
/// [seq] 单调递增，保证连续选择同一项也能重新触发动画。
class SettingsHighlightRequest {
  final int seq;
  final String label;
  final String description;

  const SettingsHighlightRequest({
    required this.seq,
    required this.label,
    required this.description,
  });

  /// 卡片是否为本请求的目标（标签或描述与搜索元数据一致即命中）。
  bool targets(String cardLabel, String cardDescription) =>
      cardLabel == label ||
      (description.isNotEmpty && cardDescription == description);
}

/// 向下传递当前高亮请求；_SettingCard 据此自行滚动定位 + 闪烁。
/// 卡片消费（触发动画）后回调 [onConsumed]，源头清空请求，
/// 防止用户切走再切回时新建的卡片 State 重复消费同一请求（幽灵重闪）。
class _HighlightScope extends InheritedWidget {
  final SettingsHighlightRequest? request;
  final ValueChanged<int> onConsumed;

  const _HighlightScope({
    required this.request,
    required this.onConsumed,
    required super.child,
  });

  static _HighlightScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_HighlightScope>();

  @override
  bool updateShouldNotify(_HighlightScope old) => old.request != request;
}

class _SettingsPageState extends State<SettingsPage> {
  late SettingsCategory _selected;

  // 侧边栏宽度（可拖拽调整，会话级，不持久化）
  double _sidebarWidth = 180;
  static const double _sidebarMinWidth = 160;
  static const double _sidebarMaxWidth = 320;

  SettingsHighlightRequest? _highlight;
  int _highlightSeq = 0;

  @override
  void initState() {
    super.initState();
    final hl = widget.initialHighlight;
    _selected =
        hl?.category ?? widget.initialCategory ?? SettingsCategory.general;
    if (_selected == SettingsCategory.referral && !_referralAvailable) {
      _selected = SettingsCategory.account;
    }
    if (hl != null) {
      _highlight = SettingsHighlightRequest(
        seq: ++_highlightSeq,
        label: hl.label,
        description: hl.description,
      );
    }
    widget.settingsProvider.addListener(_onReferralAvailabilityChanged);
  }

  @override
  void dispose() {
    widget.settingsProvider.removeListener(_onReferralAvailabilityChanged);
    super.dispose();
  }

  bool get _referralAvailable => widget.settingsProvider.referralFeatureEnabled;

  void _onReferralAvailabilityChanged() => _ensureReferralAvailable();

  void _ensureReferralAvailable() {
    if (_selected == SettingsCategory.referral && !_referralAvailable) {
      setState(() => _selected = SettingsCategory.account);
    }
  }

  /// 切换当前选中分类：侧边栏点击、搜索跳转、页内跳转（如资料卡「推介有奖」
  /// 按钮）共用。
  void _selectCategory(SettingsCategory category) {
    if (category == SettingsCategory.referral && !_referralAvailable) return;
    setState(() => _selected = category);
  }

  /// 搜索结果选中：切换分类并下发高亮请求。
  void _onSearchSelect(SettingsSearchItem item) {
    if (item.category == SettingsCategory.referral && !_referralAvailable) {
      return;
    }
    setState(() {
      _selected = item.category;
      _highlight = SettingsHighlightRequest(
        seq: ++_highlightSeq,
        label: item.label,
        description: item.description,
      );
    });
  }

  /// 卡片已消费高亮请求 → 清空，防止重复触发。
  void _onHighlightConsumed(int seq) {
    if (_highlight?.seq != seq) return;
    // 消费回调发生在 postFrame，可以安全 setState
    setState(() => _highlight = null);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final m = AppMetrics.of(context);
    return Column(
      children: [
        // 顶部标题栏
        TitleDragArea(
          child: Container(
            height: 40,
            decoration: BoxDecoration(
              color: c.surface1,
              border: Border(bottom: BorderSide(color: c.border, width: 1)),
            ),
            child: Platform.isMacOS
                ? Stack(
                    children: [
                      // 定位到侧边栏(180px)+分隔线(1px)右边
                      Positioned(
                        left: 181,
                        top: 0,
                        bottom: 0,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            ShadButton.ghost(
                              onPressed: widget.onBack,
                              size: ShadButtonSize.sm,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    LucideIcons.arrowLeft,
                                    size: 14,
                                    color: c.textSecondary,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    LocaleScope.of(context).back,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: c.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              LocaleScope.of(context).settings,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: c.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                : Padding(
                    padding: const EdgeInsets.only(left: 12, right: 289),
                    child: Row(
                      children: [
                        ShadButton.ghost(
                          onPressed: widget.onBack,
                          size: ShadButtonSize.sm,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                LucideIcons.arrowLeft,
                                size: 14,
                                color: c.textSecondary,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                LocaleScope.of(context).back,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: c.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          LocaleScope.of(context).settings,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: c.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
        // 主体：侧边栏 + 内容区。分隔线由内容区左边框绘制（无底色差），
        // 拖拽命中区是骑在边界上的透明浮层（不占布局宽度）。
        Expanded(
          child: Stack(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 左侧导航栏
                  _SettingsSidebar(
                    width: _sidebarWidth,
                    selected: _selected,
                    onSelect: _selectCategory,
                    onSearchSelect: _onSearchSelect,
                    settingsProvider: widget.settingsProvider,
                  ),
                  // 右侧内容区
                  Expanded(
                    child: DecoratedBox(
                      position: DecorationPosition.foreground,
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(color: c.border, width: 1),
                        ),
                      ),
                      child: _HighlightScope(
                        request: _highlight,
                        onConsumed: _onHighlightConsumed,
                        child: _SettingsContent(
                          category: _selected,
                          settingsProvider: widget.settingsProvider,
                          pluginProvider: widget.pluginProvider,
                          downloadController: widget.downloadController,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              // 拖拽命中浮层（1px 分隔线居中，平时透明，悬浮/拖拽浮现主题色淡线）
              Positioned(
                top: 0,
                bottom: 0,
                left: _sidebarWidth - (_SidebarResizeHandle.hitSize - 1) / 2,
                width: _SidebarResizeHandle.hitSize,
                child: _SidebarResizeHandle(
                  color: m.selectedBorder(c.accent).withValues(alpha: 0),
                  hoverColor: m.selectedBorder(c.accent),
                  dragColor: m.focusRing(c.accent),
                  onDrag: (dx) {
                    setState(() {
                      _sidebarWidth = (_sidebarWidth + dx).clamp(
                        _sidebarMinWidth,
                        _sidebarMaxWidth,
                      );
                    });
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 可拖拽的分隔线：1px 视觉线居中 + 7px 透明命中区，便于鼠标悬浮命中；
/// 悬浮显示 hoverColor（主题强调色低透明度），拖拽中显示 dragColor（更强）。
class _SidebarResizeHandle extends StatefulWidget {
  final Color color;
  final Color? hoverColor;
  final Color? dragColor;
  final ValueChanged<double> onDrag;

  /// 命中区厚度（视觉线居中，两侧透明可命中）
  static const double hitSize = 7;

  const _SidebarResizeHandle({
    required this.color,
    required this.onDrag,
    this.hoverColor,
    this.dragColor,
  });

  @override
  State<_SidebarResizeHandle> createState() => _SidebarResizeHandleState();
}

class _SidebarResizeHandleState extends State<_SidebarResizeHandle> {
  bool _isHovered = false;
  bool _isDragging = false;

  @override
  Widget build(BuildContext context) {
    final lineColor = _isDragging
        ? (widget.dragColor ?? widget.hoverColor ?? widget.color)
        : _isHovered
        ? (widget.hoverColor ?? widget.color)
        : widget.color;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (_) => setState(() => _isDragging = true),
      onHorizontalDragEnd: (_) => setState(() => _isDragging = false),
      onHorizontalDragUpdate: (details) => widget.onDrag(details.delta.dx),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: SizedBox(
          width: _SidebarResizeHandle.hitSize,
          height: double.infinity,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 1,
              color: lineColor,
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 设置侧边栏导航
// ─────────────────────────────────────────────

class _SettingsSidebar extends StatefulWidget {
  final double width;
  final SettingsCategory selected;
  final SettingsProvider settingsProvider;
  final ValueChanged<SettingsCategory> onSelect;
  final ValueChanged<SettingsSearchItem> onSearchSelect;

  const _SettingsSidebar({
    required this.width,
    required this.settingsProvider,
    required this.selected,
    required this.onSelect,
    required this.onSearchSelect,
  });

  @override
  State<_SettingsSidebar> createState() => _SettingsSidebarState();
}

class _SettingsSidebarState extends State<_SettingsSidebar> {
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();
  final _keyboardFocusNode = FocusNode(skipTraversal: true);
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      final q = _searchController.text.trim().toLowerCase();
      if (q != _query) setState(() => _query = q);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _focusNode.dispose();
    _keyboardFocusNode.dispose();
    super.dispose();
  }

  List<SettingsSearchItem> get _results => _query.isEmpty
      ? const []
      : settingsSearchItems.where((i) => i.matches(_query)).toList();

  void _select(SettingsSearchItem item) {
    widget.onSearchSelect(item);
    _searchController.clear();
    _focusNode.unfocus();
  }

  /// Esc 清空并失焦。用 Focus.onKeyEvent 返回 handled，
  /// 阻止事件继续冒泡到外层快捷键（KeyboardListener 无拦截语义）。
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _searchController.clear();
      _focusNode.unfocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Enter 提交：选中第一条搜索结果。
  void _onSubmitted(String _) {
    final results = _results;
    if (results.isNotEmpty) _select(results.first);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final m = AppMetrics.of(context);
    final s = LocaleScope.of(context);
    final searching = _query.isNotEmpty;
    final results = _results;

    return Container(
      width: widget.width,
      color: c.surface1,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 搜索框
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: c.bg,
              borderRadius: m.brInput,
              border: Border.all(
                color: searching
                    ? m.focusRing(c.accent)
                    : m.borderFade(c.border),
                width: 1,
              ),
            ),
            child: Focus(
              focusNode: _keyboardFocusNode,
              onKeyEvent: _handleKey,
              child: ShadInput(
                controller: _searchController,
                focusNode: _focusNode,
                placeholder: Text(
                  s.settingsSearchHint,
                  style: const TextStyle(fontSize: 12),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                constraints: const BoxConstraints(minHeight: 28, maxHeight: 28),
                gap: 5,
                leading: Icon(
                  LucideIcons.search,
                  size: 13,
                  color: searching ? c.accent : c.textMuted,
                ),
                style: const TextStyle(fontSize: 12),
                decoration: const ShadDecoration(
                  // 内嵌搜索框自带容器底色，覆盖主题字段填充保持透明。
                  color: Color(0x00000000),
                  border: ShadBorder.none,
                  focusedBorder: ShadBorder.none,
                ),
                onSubmitted: _onSubmitted,
              ),
            ),
          ),
          // 搜索中 → 结果列表；否则 → 分类导航
          if (searching)
            Expanded(
              child: results.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        s.settingsSearchNoResults,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: c.textMuted),
                      ),
                    )
                  : ListView.builder(
                      itemCount: results.length,
                      itemBuilder: (context, i) => _SearchResultItem(
                        item: results[i],
                        onTap: () => _select(results[i]),
                      ),
                    ),
            )
          else
            Expanded(
              child: ListenableBuilder(
                listenable: widget.settingsProvider,
                builder: (context, _) {
                  final showReferral = false;
                  return ListView(
                      children: [
                        for (final cat in SettingsCategory.values)
                          if ((cat != SettingsCategory.referral || showReferral) &&
                              cat != SettingsCategory.account)
                            _SettingsNavItem(
                              key: ValueKey('settings-nav-${cat.name}'),
                              icon: cat.icon,
                              label: cat.localizedLabel,
                              isSelected: widget.selected == cat,
                              onTap: () => widget.onSelect(cat),
                            ),
                      ],
                    );
                  },
                ),
              ),
        ],
      ),
    );
  }
}

/// 侧边栏搜索结果项：图标 + 标签 + 所属分类
class _SearchResultItem extends StatefulWidget {
  final SettingsSearchItem item;
  final VoidCallback onTap;

  const _SearchResultItem({required this.item, required this.onTap});

  @override
  State<_SearchResultItem> createState() => _SearchResultItemState();
}

class _SearchResultItemState extends State<_SearchResultItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final m = AppMetrics.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: _isHovered ? c.hoverBg : c.hoverBg.withValues(alpha: 0),
            borderRadius: m.brMd,
          ),
          child: Row(
            children: [
              Icon(widget.item.icon, size: 14, color: c.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: c.textPrimary,
                      ),
                    ),
                    Text(
                      widget.item.category.localizedLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10.5, color: c.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsNavItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _SettingsNavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_SettingsNavItem> createState() => _SettingsNavItemState();
}

class _SettingsNavItemState extends State<_SettingsNavItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final m = AppMetrics.of(context);
    final selected = widget.isSelected;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: selected
                ? c.accentBg
                : _isHovered
                ? c.hoverBg
                : c.hoverBg.withValues(alpha: 0),
            borderRadius: m.brMd,
          ),
          child: Row(
            children: [
              Icon(
                widget.icon,
                size: 15,
                color: selected ? c.accent : c.textSecondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 13,
                    color: selected ? c.accent : c.textPrimary,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (selected)
                Container(
                  width: 3,
                  height: 14,
                  decoration: BoxDecoration(
                    color: c.accent,
                    borderRadius: m.brXs,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 设置内容区
// ─────────────────────────────────────────────

class _SettingsContent extends StatefulWidget {
  final SettingsCategory category;
  final SettingsProvider settingsProvider;
  final PluginProvider pluginProvider;
  final DownloadController? downloadController;

  const _SettingsContent({
    required this.category,
    required this.settingsProvider,
    required this.pluginProvider,
    this.downloadController,
  });

  @override
  State<_SettingsContent> createState() => _SettingsContentState();
}

class _SettingsContentState extends State<_SettingsContent> {
  final _scrollController = ScrollController();

  /// 每个分类会话内记住的子 Tab id（不持久化）。
  final Map<SettingsCategory, String> _tabByCategory = {};

  /// 已做过 Tab 路由判定的高亮请求序号，防止重复处理。
  int _routedHighlightSeq = 0;

  @override
  void didUpdateWidget(covariant _SettingsContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切换分类时回到顶部，避免沿用上一分类的滚动位置
    if (widget.category != oldWidget.category && _scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeHighlightToTab();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 当前分类应显示的子 Tab id（无 Tab 分类返回空串）。
  String _activeTabId(List<_SettingsTabSpec> tabs) {
    if (tabs.isEmpty) return '';
    final saved = _tabByCategory[widget.category];
    if (saved != null && tabs.any((t) => t.id == saved)) return saved;
    return tabs.first.id;
  }

  void _selectTab(String id) {
    if (_tabByCategory[widget.category] == id) return;
    setState(() => _tabByCategory[widget.category] = id);
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  /// 高亮请求指向其它子 Tab 上的设置项时，先切到目标 Tab，
  /// 再由卡片自身消费请求（滚动定位 + 闪烁）。「设置项 → Tab」映射
  /// 来自 [settingsSearchItems] 的 `tabId` 元数据。
  void _routeHighlightToTab() {
    final req = _HighlightScope.of(context)?.request;
    if (req == null || req.seq == _routedHighlightSeq) return;
    _routedHighlightSeq = req.seq;
    final tabs = _settingsTabsFor(widget.category);
    if (tabs.isEmpty) return;
    for (final item in settingsSearchItems) {
      if (item.category != widget.category || item.tabId == null) continue;
      if (!req.targets(item.label, item.description)) continue;
      if (tabs.any((t) => t.id == item.tabId)) {
        // didChangeDependencies 之后必然重建，直接写选中态即可
        _tabByCategory[widget.category] = item.tabId!;
      }
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final category = widget.category;
    final tabs = _settingsTabsFor(category);
    final tabId = _activeTabId(tabs);
    final c = AppColors.of(context);
    final m = AppMetrics.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // 内容锚定左侧、紧贴侧边栏，宽度完全自适应吃满可用空间；
        // 宽视口下由 _AdaptiveSections 切双列利用横向空间。
        final contentWidth = max(0.0, constraints.maxWidth - 76);
        Widget aligned(Widget child) => Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: contentWidth, child: child),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 固定头部：不透明背景 + 全宽发丝线，与滚动内容形成清晰边界，
            // 内容上滑时从线下穿过，滚动区域一目了然
            DecoratedBox(
              decoration: BoxDecoration(
                color: c.bg,
                border: Border(
                  bottom: BorderSide(color: m.borderFade(c.border), width: 1),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(40, 16, 36, 0),
                child: aligned(
                  _SectionHeader(
                    category: category,
                    tabs: tabs,
                    activeTabId: tabId,
                    onSelectTab: _selectTab,
                  ),
                ),
              ),
            ),
            Expanded(
              child: _bodyOwnsScroll(category, tabId)
                  // 内容自持滚动：固定区（如推介页统计卡）钉在头部下方，
                  // 由内容组件内部决定哪一段可滚。
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(40, 20, 36, 24),
                      child: aligned(
                        KeyedSubtree(
                          key: ValueKey('${category.name}:$tabId'),
                          child: _buildBody(category, tabId),
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(40, 20, 36, 24),
                      child: aligned(
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 120),
                          layoutBuilder: (currentChild, previousChildren) {
                            return Stack(
                              alignment: Alignment.topLeft,
                              children: [...previousChildren, ?currentChild],
                            );
                          },
                          child: KeyedSubtree(
                            key: ValueKey('${category.name}:$tabId'),
                            child: _buildBody(category, tabId),
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }

  /// 该（分类, 子 Tab）是否自持滚动区域：true 时页面不再包共享
  /// [SingleChildScrollView]，内容组件自行划分固定区与可滚区。
  bool _bodyOwnsScroll(SettingsCategory category, String tabId) {
    return false;
  }

  /// 按（分类, 子 Tab）构建内容主体；子树身份由外层 [KeyedSubtree] 承担。
  Widget _buildBody(SettingsCategory category, String tabId) {
    final settingsProvider = widget.settingsProvider;
    return switch (category) {
      SettingsCategory.general => _GeneralContent(
        settingsProvider: settingsProvider,
      ),
      SettingsCategory.account => const SizedBox.shrink(),
      SettingsCategory.referral => const SizedBox.shrink(),
      SettingsCategory.appearance => const _AppearanceContent(),
      SettingsCategory.download => _DownloadContent(
        settingsProvider: settingsProvider,
        downloadController: widget.downloadController,
      ),
      SettingsCategory.bt =>
        tabId == _kTabTracker
            ? _BtTrackerContent(settingsProvider: settingsProvider)
            : tabId == _kTabSeeding
            ? _BtSeedingContent(settingsProvider: settingsProvider)
            : _BtBasicContent(settingsProvider: settingsProvider),
      SettingsCategory.ed2k =>
        tabId == _kTabServers
            ? _Ed2kServersContent(settingsProvider: settingsProvider)
            : _Ed2kBasicContent(settingsProvider: settingsProvider),
      SettingsCategory.proxy => _ProxyContent(
        settingsProvider: settingsProvider,
      ),
      SettingsCategory.apiService => _ApiServiceContent(
        settingsProvider: settingsProvider,
      ),
      SettingsCategory.notify => _NotifyContent(
        settingsProvider: settingsProvider,
        downloadController: widget.downloadController,
      ),
      SettingsCategory.extensions =>
        tabId == _kTabComponents
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: const [
                  _ComponentsContent(
                    key: ValueKey('component-ffmpeg'),
                    kind: _ComponentKind.ffmpeg,
                  ),
                  SizedBox(height: 12),
                  _ComponentsContent(
                    key: ValueKey('component-ytdlp'),
                    kind: _ComponentKind.ytdlp,
                  ),
                ],
              )
            : PluginListView(
                provider: widget.pluginProvider,
                onNavigateToComponents: () => _selectTab(_kTabComponents),
              ),
      SettingsCategory.doctor => DoctorReportView(
        settingsProvider: settingsProvider,
      ),
      SettingsCategory.about => _AboutContent(
        settingsProvider: settingsProvider,
      ),
    };
  }
}

// ─────────────────────────────────────────────
// 分类标题头
// ─────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final SettingsCategory category;
  final List<_SettingsTabSpec> tabs;
  final String activeTabId;
  final ValueChanged<String> onSelectTab;

  const _SectionHeader({
    required this.category,
    required this.tabs,
    required this.activeTabId,
    required this.onSelectTab,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题与描述同行（基线对齐），压缩头部高度、让出纵向空间给内容
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              category.localizedLabel,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: c.textPrimary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                category.localizedDesc,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: c.textMuted),
              ),
            ),
          ],
        ),
        if (tabs.isEmpty)
          const SizedBox(height: 12)
        else ...[
          const SizedBox(height: 8),
          // Tab 栏：选中态下划线紧贴头部底边的全宽发丝线
          Row(
            children: [
              for (final tab in tabs) ...[
                _SettingsTab(
                  label: tab.label,
                  selected: tab.id == activeTabId,
                  onTap: () => onSelectTab(tab.id),
                ),
                const SizedBox(width: 18),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

/// 分类头部的子 Tab：文字 + 选中态强调色下划线（与任务列表 Tab 同视觉语言）。
class _SettingsTab extends StatefulWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SettingsTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<_SettingsTab> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final selected = widget.selected;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.only(top: 4, bottom: 8, left: 2, right: 2),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? c.accent : c.accent.withValues(alpha: 0),
                width: 2,
              ),
            ),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 13,
              color: selected
                  ? c.textPrimary
                  : _hovered
                  ? c.textSecondary
                  : c.textMuted,
              fontWeight: selected ? FontWeight.w500 : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 设置卡片：每个设置项的统一容器
// ─────────────────────────────────────────────

class _SettingCard extends StatefulWidget {
  final String label;
  final String description;
  final Widget child;
  final bool vertical;

  const _SettingCard({
    required this.label,
    required this.description,
    required this.child,
    this.vertical = false,
  });

  @override
  State<_SettingCard> createState() => _SettingCardState();
}

/// 高亮消费公共逻辑：监听 _HighlightScope，命中后滚动定位 + 闪烁。
/// 宿主 State 通过 [highlightLabel]/[highlightDescription] 声明自己的匹配键，
/// 通过 [flashing] 读取当前闪烁态渲染高亮样式。
mixin _HighlightConsumer<T extends StatefulWidget> on State<T> {
  int _consumedSeq = 0;
  bool _flashing = false;
  Timer? _flashTimer;

  String get highlightLabel;
  String get highlightDescription;

  bool get flashing => _flashing;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = _HighlightScope.of(context);
    final req = scope?.request;
    if (scope == null || req == null || req.seq == _consumedSeq) return;
    if (!req.targets(highlightLabel, highlightDescription)) return;
    _consumedSeq = req.seq;
    // 等本帧布局完成后再滚动定位（分类切换 AnimatedSwitcher 期间布局已存在）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.2,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
      _startFlash();
      // 上报消费 → 源头清空请求，防止分类切走再切回时幽灵重闪
      scope.onConsumed(req.seq);
    });
  }

  /// 闪烁 3 次：300ms 周期亮/灭交替，总时长约 1.5s
  void _startFlash() {
    _flashTimer?.cancel();
    var ticks = 0;
    setState(() => _flashing = true);
    _flashTimer = Timer.periodic(const Duration(milliseconds: 300), (t) {
      ticks++;
      if (ticks >= 5 || !mounted) {
        t.cancel();
        _flashTimer = null;
        if (mounted) setState(() => _flashing = false);
        return;
      }
      setState(() => _flashing = ticks.isEven);
    });
  }

  @override
  void dispose() {
    _flashTimer?.cancel();
    super.dispose();
  }
}

/// 无边框高亮区域：包裹非 _SettingCard 的设置小节（如「侧边栏显示」），
/// 使其同样支持搜索定位 + 闪烁高亮。
class _HighlightRegion extends StatefulWidget {
  final String label;
  final String description;
  final Widget child;

  const _HighlightRegion({
    required this.label,
    required this.description,
    required this.child,
  });

  @override
  State<_HighlightRegion> createState() => _HighlightRegionState();
}

class _HighlightRegionState extends State<_HighlightRegion>
    with _HighlightConsumer {
  @override
  String get highlightLabel => widget.label;
  @override
  String get highlightDescription => widget.description;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final m = AppMetrics.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: flashing
            ? m.subtle(c.accent)
            : m.subtle(c.accent).withValues(alpha: 0),
        borderRadius: m.brDialog,
      ),
      child: widget.child,
    );
  }
}

class _SettingCardState extends State<_SettingCard> with _HighlightConsumer {
  @override
  String get highlightLabel => widget.label;
  @override
  String get highlightDescription => widget.description;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final m = AppMetrics.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: _flashing ? m.subtle(c.accent) : c.surface1,
        borderRadius: m.brDialog,
        border: Border.all(
          color: _flashing ? m.emphasis(c.accent) : m.borderMedium(c.border),
          width: 1,
        ),
      ),
      child: widget.vertical
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: c.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  widget.description,
                  style: TextStyle(fontSize: 11.5, color: c.textMuted),
                ),
                const SizedBox(height: 12),
                widget.child,
              ],
            )
          : Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: c.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.description,
                        style: TextStyle(fontSize: 11.5, color: c.textMuted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                widget.child,
              ],
            ),
    );
  }
}

// ─────────────────────────────────────────────
// 设置分组：小节标题 + 单卡多行（发丝线分隔）
// ─────────────────────────────────────────────

/// 设置分组：可选小节标题（支持搜索定位高亮）+ 一张卡片容器，
/// 组内每行是 [_SettingRow]，行间以发丝线分隔。
/// 相比一项一卡，垂直密度显著提升，语义分组也更利于扫读。
class _SettingsGroup extends StatelessWidget {
  final String? title;
  final String? subtitle;
  final List<Widget> children;

  const _SettingsGroup({this.title, this.subtitle, required this.children});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final m = AppMetrics.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            // 标题作为搜索定位目标（如「侧边栏显示」），命中时闪烁
            child: _HighlightRegion(
              label: title!,
              description: subtitle ?? '',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title!,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: c.textSecondary,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(fontSize: 11, color: c.textMuted),
                    ),
                  ],
                ],
              ),
            ),
          ),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: c.surface1,
            borderRadius: m.brDialog,
            border: Border.all(color: m.borderMedium(c.border), width: 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  Container(
                    height: 1,
                    margin: const EdgeInsets.only(left: 16),
                    color: m.borderFade(c.border),
                  ),
                children[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 分组内的一行设置项：布局与 [_SettingCard] 一致，但无独立边框背景
/// （容器视觉由 [_SettingsGroup] 承担），行高更紧凑；
/// 支持搜索定位 + 闪烁高亮。
class _SettingRow extends StatefulWidget {
  final String label;
  final String description;
  final Widget child;
  final bool vertical;

  const _SettingRow({
    required this.label,
    required this.description,
    required this.child,
    this.vertical = false,
  });

  @override
  State<_SettingRow> createState() => _SettingRowState();
}

class _SettingRowState extends State<_SettingRow> with _HighlightConsumer {
  @override
  String get highlightLabel => widget.label;
  @override
  String get highlightDescription => widget.description;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final m = AppMetrics.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      padding: EdgeInsets.symmetric(
        horizontal: 16,
        vertical: widget.vertical ? 12 : 10,
      ),
      color: flashing
          ? m.subtle(c.accent)
          : m.subtle(c.accent).withValues(alpha: 0),
      child: widget.vertical
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: c.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  widget.description,
                  style: TextStyle(fontSize: 11.5, color: c.textMuted),
                ),
                const SizedBox(height: 10),
                widget.child,
              ],
            )
          : Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: c.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.description,
                        style: TextStyle(fontSize: 11.5, color: c.textMuted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                widget.child,
              ],
            ),
    );
  }
}

// ─────────────────────────────────────────────
// 自适应分组布局：窄视口单列，宽视口双列瀑布
// ─────────────────────────────────────────────

/// 设置分组的自适应布局：内容宽度不足 [_twoColMinWidth] 时单列排布；
/// 足够宽时按预估高度把分组贪心切成左右两列（保持整体顺序：
/// 左列在前、右列在后），利用横向空间减少滚动。
class _AdaptiveSections extends StatelessWidget {
  /// 触发双列的最小内容宽度。
  static const double _twoColMinWidth = 920;
  static const double _columnGap = 24;
  static const double _sectionGap = 16;

  final List<Widget> sections;

  const _AdaptiveSections({required this.sections});

  /// 分组高度权重估计：普通行 1、垂直行 2.4（编辑器/选择器普遍更高）、
  /// 组标题 0.6；[_WeightedSection] 用显式权重；其余富卡片按 3 估。
  static double _weightOf(Widget section) {
    if (section is _WeightedSection) return section.weight;
    if (section is _SettingsGroup) {
      var weight = section.title != null ? 0.6 : 0.0;
      for (final row in section.children) {
        weight += row is _SettingRow && row.vertical ? 2.4 : 1.0;
      }
      return weight;
    }
    return 3.0;
  }

  static Widget _buildColumn(List<Widget> sections) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < sections.length; i++) ...[
        if (i > 0) const SizedBox(height: _sectionGap),
        sections[i],
      ],
    ],
  );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (sections.length < 2 || constraints.maxWidth < _twoColMinWidth) {
          return _buildColumn(sections);
        }
        // 贪心切分：某组的重心越过总权重一半即归入右列
        final weights = [for (final s in sections) _weightOf(s)];
        final total = weights.fold(0.0, (a, b) => a + b);
        var acc = 0.0;
        var split = 0;
        while (split < sections.length - 1 &&
            acc + weights[split] / 2 < total / 2) {
          acc += weights[split];
          split++;
        }
        if (split == 0) split = 1;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _buildColumn(sections.sublist(0, split))),
            const SizedBox(width: _columnGap),
            Expanded(child: _buildColumn(sections.sublist(split))),
          ],
        );
      },
    );
  }
}

/// 为 [_AdaptiveSections] 提供显式高度权重的包装，
/// 用于无法自动估高的复杂 section（如自定义分类管理列表）。
class _WeightedSection extends StatelessWidget {
  final double weight;
  final Widget child;

  const _WeightedSection({required this.weight, required this.child});

  @override
  Widget build(BuildContext context) => child;
}

// ─────────────────────────────────────────────
// 通用设置
// ─────────────────────────────────────────────

class _GeneralContent extends StatelessWidget {
  final SettingsProvider settingsProvider;

  const _GeneralContent({required this.settingsProvider});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settingsProvider,
      builder: (context, _) {
        final s = LocaleScope.of(context);
        final ballDegraded = FloatingBallService.instance.isDegraded;
        return _AdaptiveSections(
          sections: [
            _SettingsGroup(
              title: s.settingsGroupStartupTray,
              children: [
                _SettingRow(
                  label: s.autoStartup,
                  description: s.autoStartupDesc,
                  child: ShadSwitch(
                    value: settingsProvider.autoStartup,
                    onChanged: (v) async {
                      final ok = await settingsProvider.setAutoStartup(v);
                      if (!ok && context.mounted) {
                        showShadDialog(
                          context: context,
                          barrierColor: AppColors.of(context).dialogBarrier,
                          animateIn: const [],
                          animateOut: const [],
                          builder: (ctx) => ShadDialog.alert(
                            title: Text(LocaleScope.of(ctx).settingFailed),
                            description: Text(
                              LocaleScope.of(ctx).autoStartupFailedDesc,
                            ),
                            actions: [
                              ShadButton(
                                child: Text(LocaleScope.of(ctx).confirm),
                                onPressed: () => Navigator.of(ctx).pop(),
                              ),
                            ],
                          ),
                        );
                      }
                    },
                  ),
                ),
                _SettingRow(
                  label: s.closeToTray,
                  description: s.closeToTrayDesc,
                  child: ShadSwitch(
                    value: settingsProvider.closeToTray,
                    onChanged: (v) => settingsProvider.setCloseToTray(v),
                  ),
                ),
                _SettingRow(
                  label: s.startMinimizedToTray,
                  description: s.startMinimizedToTrayDesc,
                  child: ShadSwitch(
                    value: settingsProvider.startMinimizedToTray,
                    onChanged: (v) =>
                        settingsProvider.setStartMinimizedToTray(v),
                  ),
                ),
              ],
            ),
            _SettingsGroup(
              title: s.settingsGroupSystem,
              children: [
                _SettingRow(
                  label: s.floatingBall,
                  description: ballDegraded
                      ? s.floatingBallWaylandUnsupported
                      : s.floatingBallDesc,
                  child: ShadSwitch(
                    value: settingsProvider.floatingBallEnabled,
                    enabled: !ballDegraded,
                    onChanged: (v) =>
                        FloatingBallService.instance.setEnabled(v),
                  ),
                ),
                if (settingsProvider.floatingBallEnabled && !ballDegraded)
                  _SettingRow(
                    label: s.floatingBallActiveOnly,
                    description: s.floatingBallActiveOnlyDesc,
                    child: ShadSwitch(
                      value: settingsProvider.floatingBallActiveOnly,
                      onChanged: (v) {
                        settingsProvider.setFloatingBallActiveOnly(v);
                        FloatingBallService.instance.refreshVisibility();
                      },
                    ),
                  ),
                if (Platform.isLinux && ballDegraded)
                  _SettingRow(
                    label: s.clipboardWatch,
                    description: s.clipboardWatchDesc,
                    child: ShadSwitch(
                      value: settingsProvider.clipboardWatchEnabled,
                      onChanged: (v) =>
                          settingsProvider.setClipboardWatchEnabled(v),
                    ),
                  ),
                _SettingRow(
                  label: s.torrentFileAssociation,
                  description: s.torrentFileAssociationDesc,
                  child: ShadSwitch(
                    value: settingsProvider.torrentAssociated,
                    onChanged: (v) {
                      settingsProvider.setFileAssociation(v);
                      // 用户手动操作过就标记为已提示
                      settingsProvider.markTorrentAssocPrompted();
                    },
                  ),
                ),
                _SettingRow(
                  label: s.ed2kLinkAssociation,
                  description: s.ed2kLinkAssociationDesc,
                  child: ShadSwitch(
                    value: settingsProvider.ed2kProtocolAssociated,
                    onChanged: (v) =>
                        settingsProvider.setEd2kProtocolAssociation(v),
                  ),
                ),
                _SettingRow(
                  label: s.magnetLinkAssociation,
                  description: s.magnetLinkAssociationDesc,
                  child: ShadSwitch(
                    value: settingsProvider.magnetProtocolAssociated,
                    onChanged: (v) =>
                        settingsProvider.setMagnetProtocolAssociation(v),
                  ),
                ),
                _SettingRow(
                  label: s.keepAwakeWhileDownloading,
                  description: s.keepAwakeWhileDownloadingDesc,
                  child: ShadSwitch(
                    value: settingsProvider.keepAwakeWhileDownloading,
                    onChanged: (v) =>
                        settingsProvider.setKeepAwakeWhileDownloading(v),
                  ),
                ),
                _SettingRow(
                  label: s.analyticsEnabled,
                  description: s.analyticsEnabledDesc,
                  child: ShadSwitch(
                    value: settingsProvider.analyticsEnabled,
                    onChanged: (v) => settingsProvider.setAnalyticsEnabled(v),
                  ),
                ),
              ],
            ),
            _SettingsGroup(
              title: s.sidebarVisibility,
              subtitle: s.sidebarVisibilityDesc,
              children: [
                _SettingRow(
                  label: s.showSidebarStatus,
                  description: s.showSidebarStatusDesc,
                  child: ShadSwitch(
                    value: settingsProvider.showSidebarStatus,
                    onChanged: (v) => settingsProvider.setShowSidebarStatus(v),
                  ),
                ),
                _SettingRow(
                  label: s.showSidebarQueues,
                  description: s.showSidebarQueuesDesc,
                  child: ShadSwitch(
                    value: settingsProvider.showSidebarQueues,
                    onChanged: (v) => settingsProvider.setShowSidebarQueues(v),
                  ),
                ),
                _SettingRow(
                  label: s.showSidebarRss,
                  description: s.showSidebarRssDesc,
                  child: ShadSwitch(
                    value: settingsProvider.showSidebarRss,
                    onChanged: (v) => settingsProvider.setShowSidebarRss(v),
                  ),
                ),
                _SettingRow(
                  label: s.showSidebarCategory,
                  description: s.showSidebarCategoryDesc,
                  child: ShadSwitch(
                    value: settingsProvider.showSidebarCategory,
                    onChanged: (v) =>
                        settingsProvider.setShowSidebarCategory(v),
                  ),
                ),
                _SettingRow(
                  label: s.showSidebarDevice,
                  description: s.showSidebarDeviceDesc,
                  child: ShadSwitch(
                    value: settingsProvider.showSidebarDeviceEffective(
                      LocalPairingService.instance.hasLocalDevices,
                    ),
                    onChanged: (v) => settingsProvider.setShowSidebarDevice(v),
                  ),
                ),
              ],
            ),
            _SettingsGroup(
              title: s.titlebarButtons,
              subtitle: s.titlebarButtonsDesc,
              children: [
                _SettingRow(
                  label: s.showTitlebarPauseAll,
                  description: s.showTitlebarPauseAllDesc,
                  child: ShadSwitch(
                    value: settingsProvider.showTitlebarPauseAll,
                    onChanged: (v) =>
                        settingsProvider.setShowTitlebarPauseAll(v),
                  ),
                ),
                _SettingRow(
                  label: s.showTitlebarResumeAll,
                  description: s.showTitlebarResumeAllDesc,
                  child: ShadSwitch(
                    value: settingsProvider.showTitlebarResumeAll,
                    onChanged: (v) =>
                        settingsProvider.setShowTitlebarResumeAll(v),
                  ),
                ),
                _SettingRow(
                  label: s.showTitlebarSettings,
                  description: s.showTitlebarSettingsDesc,
                  child: ShadSwitch(
                    value: settingsProvider.showTitlebarSettings,
                    onChanged: (v) =>
                        settingsProvider.setShowTitlebarSettings(v),
                  ),
                ),
                _SettingRow(
                  label: s.showTitlebarTheme,
                  description: s.showTitlebarThemeDesc,
                  child: ShadSwitch(
                    value: settingsProvider.showTitlebarTheme,
                    onChanged: (v) => settingsProvider.setShowTitlebarTheme(v),
                  ),
                ),
              ],
            ),
            // 自定义分类管理（支持搜索定位高亮）
            _WeightedSection(
              weight: 10,
              child: _HighlightRegion(
                label: s.customCategories,
                description: s.customCategoriesDesc,
                child: _CustomCategoryManager(
                  settingsProvider: settingsProvider,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────
// 分类管理（内置 + 自定义统一列表）
// ─────────────────────────────────────────────

class _CustomCategoryManager extends StatelessWidget {
  final SettingsProvider settingsProvider;

  const _CustomCategoryManager({required this.settingsProvider});

  /// 内置分类的 i18n 名称。这些文案不只是标签：「一键分类目录」拿它当目录名
  /// （`categoryDirUnder`），Web 侧 `web/src/lib/categories.ts` 的 BUILTIN_LABEL
  /// 必须逐字一致，否则两端会在同一台机器上建出两套目录。
  static String _builtinLabel(S s, String? builtinType) =>
      switch (builtinType) {
        'all' => s.categoryAll,
        'video' => s.categoryVideo,
        'audio' => s.categoryAudio,
        'document' => s.categoryDocument,
        'image' => s.categoryImage,
        'program' => s.categoryProgram,
        'archive' => s.categoryArchive,
        'other' => s.categoryOther,
        _ => '',
      };

  /// 获取分类显示名称（内置用 i18n，自定义用用户设置的名称）
  static String displayName(S s, CustomCategory cat) {
    if (cat.isBuiltin) return _builtinLabel(s, cat.builtinType);
    return cat.name;
  }

  @override
  Widget build(BuildContext context) {
    final s = LocaleScope.of(context);
    final c = AppColors.of(context);
    final categories = settingsProvider.customCategories;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题 + 操作区（按钮换行排布：三枚按钮在窄栏下不会溢出）
        Text(
          s.customCategories,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: c.textPrimary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          s.categoryPriorityNote,
          style: TextStyle(fontSize: 11.5, color: c.textMuted),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _oneClickDirsButton(context, s, c),
              ShadButton.outline(
                size: ShadButtonSize.sm,
                onPressed: () => _confirmResetAll(context, s, c),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.rotateCcw, size: 13, color: c.textMuted),
                    const SizedBox(width: 4),
                    Text(s.resetBuiltinCategories),
                  ],
                ),
              ),
              ShadButton.outline(
                size: ShadButtonSize.sm,
                onPressed: () => _showCategoryDialog(context, s, c),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.plus, size: 13, color: c.textSecondary),
                    const SizedBox(width: 4),
                    Text(s.addCategory),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        // 分类列表（Column 替代 ReorderableListView，避免 MaterialLocalizations 依赖）
        for (int i = 0; i < categories.length; i++)
          _CategoryTile(
            category: categories[i],
            index: i,
            total: categories.length,
            c: c,
            s: s,
            onEdit: () =>
                _showCategoryDialog(context, s, c, existing: categories[i]),
            onDelete: categories[i].builtinType == 'all'
                ? null
                : () => _confirmDelete(context, s, c, categories[i]),
            onReset:
                (categories[i].isBuiltin && categories[i].builtinType != 'all')
                ? () => settingsProvider.resetBuiltinCategory(
                    categories[i].builtinType!,
                  )
                : null,
            onToggleVisible: () => settingsProvider.updateCustomCategory(
              categories[i].copyWith(visible: !categories[i].visible),
            ),
            onMoveUp: i > 0
                ? () => settingsProvider.reorderCustomCategories(i, i - 1)
                : null,
            onMoveDown: i < categories.length - 1
                ? () => settingsProvider.reorderCustomCategories(i, i + 2)
                : null,
          ),
      ],
    );
  }

  /// 一键分类目录：两态按钮。尚未全部指向「默认下载目录 / 分类名」时是「应用」，
  /// 已全部指向时变成「清除」，用同一枚按钮完成开与关。
  Widget _oneClickDirsButton(BuildContext context, S s, AppColors c) {
    String labelOf(CustomCategory cat) => displayName(s, cat);
    final applied = settingsProvider.categorySaveDirsApplied(labelOf);
    final baseDir = settingsProvider.defaultSaveDir;
    // 默认下载目录为空时推导不出任何目录，按钮直接禁用。
    final enabled = baseDir.trim().isNotEmpty;
    return ShadButton.outline(
      size: ShadButtonSize.sm,
      onPressed: enabled
          ? () => _confirmCategoryDirs(context, s, c, applied: applied)
          : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            applied ? LucideIcons.folderX : LucideIcons.folderTree,
            size: 13,
            color: c.textSecondary,
          ),
          const SizedBox(width: 4),
          Text(applied ? s.clearCategoryDirs : s.autoCategoryDirs),
        ],
      ),
    );
  }

  void _confirmCategoryDirs(
    BuildContext context,
    S s,
    AppColors c, {
    required bool applied,
  }) {
    // 举例用第一个可推导出目录的分类，让用户先看清实际会建在哪。
    var sample = '';
    for (final cat in settingsProvider.customCategories) {
      if (cat.builtinType == 'all') continue;
      final dir = categoryDirUnder(
        settingsProvider.defaultSaveDir,
        displayName(s, cat),
      );
      if (dir.isNotEmpty) {
        sample = dir;
        break;
      }
    }
    showShadDialog(
      context: context,
      barrierColor: c.dialogBarrier,
      animateIn: const [],
      animateOut: const [],
      builder: (ctx) => ShadDialog(
        title: Text(applied ? s.clearCategoryDirs : s.autoCategoryDirs),
        description: Text(
          applied
              ? s.clearCategoryDirsConfirm
              : s.autoCategoryDirsConfirm(sample),
        ),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(s.cancel),
          ),
          ShadButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              if (applied) {
                settingsProvider.clearCategorySaveDirs();
              } else {
                settingsProvider.applyCategorySaveDirs(
                  (cat) => displayName(s, cat),
                );
              }
            },
            child: Text(s.confirm),
          ),
        ],
      ),
    );
  }

  void _showCategoryDialog(
    BuildContext context,
    S s,
    AppColors c, {
    CustomCategory? existing,
  }) {
    showCategoryEditDialog(
      context,
      existing: existing,
      onSave: (category) {
        if (existing != null) {
          settingsProvider.updateCustomCategory(category);
        } else {
          settingsProvider.addCustomCategory(category);
        }
      },
      onDelete: (existing != null && existing.builtinType != 'all')
          ? () => settingsProvider.removeCustomCategory(existing.id)
          : null,
    );
  }

  void _confirmDelete(
    BuildContext context,
    S s,
    AppColors c,
    CustomCategory cat,
  ) {
    showShadDialog(
      context: context,
      barrierColor: c.dialogBarrier,
      animateIn: const [],
      animateOut: const [],
      builder: (ctx) => ShadDialog(
        title: Text(s.deleteCategory),
        description: Text(s.deleteCategoryConfirm),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(s.cancel),
          ),
          ShadButton.destructive(
            onPressed: () {
              Navigator.of(ctx).pop();
              settingsProvider.removeCustomCategory(cat.id);
            },
            child: Text(s.deleteCategory),
          ),
        ],
      ),
    );
  }

  void _confirmResetAll(BuildContext context, S s, AppColors c) {
    showShadDialog(
      context: context,
      barrierColor: c.dialogBarrier,
      animateIn: const [],
      animateOut: const [],
      builder: (ctx) => ShadDialog(
        title: Text(s.resetBuiltinCategories),
        description: Text(s.resetAllCategoriesConfirm),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(s.cancel),
          ),
          ShadButton.destructive(
            onPressed: () {
              Navigator.of(ctx).pop();
              settingsProvider.resetAllCategories();
            },
            child: Text(s.confirm),
          ),
        ],
      ),
    );
  }
}

// 单个分类条目（内置 + 自定义通用）
class _CategoryTile extends StatefulWidget {
  final CustomCategory category;
  final int index;
  final int total;
  final AppColors c;
  final S s;
  final VoidCallback onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onReset;
  final VoidCallback onToggleVisible;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  const _CategoryTile({
    required this.category,
    required this.index,
    required this.total,
    required this.c,
    required this.s,
    required this.onEdit,
    this.onDelete,
    this.onReset,
    required this.onToggleVisible,
    this.onMoveUp,
    this.onMoveDown,
  });

  @override
  State<_CategoryTile> createState() => _CategoryTileState();
}

class _CategoryTileState extends State<_CategoryTile> {
  bool _isHovered = false;

  /// 描述文本：内置特殊分类显示"内置"，其余显示扩展名或正则；
  /// 设了分类保存目录的再在后面挂上目录（一键分类目录后能直接看到落点）。
  String _subtitle(CustomCategory cat, S s) {
    final rule = _matchSummary(cat, s);
    if (cat.saveDir.isEmpty) return rule;
    return rule.isEmpty ? cat.saveDir : '$rule  ·  ${cat.saveDir}';
  }

  String _matchSummary(CustomCategory cat, S s) {
    // "全部文件" 和 "其他" 不显示扩展名
    if (cat.builtinType == 'all' || cat.builtinType == 'other') {
      return s.builtinCategory;
    }
    if (cat.matchMode == MatchMode.extension && cat.extensions.isNotEmpty) {
      return cat.extensions.map((e) => '.$e').join(', ');
    }
    if (cat.matchMode == MatchMode.regex && cat.regexPattern.isNotEmpty) {
      return cat.regexPattern;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final m = AppMetrics.of(context);
    final cat = widget.category;
    final c = widget.c;
    final s = widget.s;
    final label = _CustomCategoryManager.displayName(s, cat);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: _isHovered ? c.hoverBg : c.surface1,
          borderRadius: m.brCard,
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            // 上下移动按钮
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _TileAction(
                  icon: LucideIcons.chevronUp,
                  color: widget.onMoveUp != null ? c.textMuted : c.border,
                  onTap: widget.onMoveUp ?? () {},
                ),
                _TileAction(
                  icon: LucideIcons.chevronDown,
                  color: widget.onMoveDown != null ? c.textMuted : c.border,
                  onTap: widget.onMoveDown ?? () {},
                ),
              ],
            ),
            const SizedBox(width: 6),
            // 图标
            Icon(categoryIconData(cat.icon), size: 16, color: c.accent),
            const SizedBox(width: 8),
            // 名称 + 匹配规则 + 标签
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                            color: cat.visible ? c.textPrimary : c.textMuted,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (cat.isBuiltin) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: m.soft(c.accent),
                            borderRadius: m.brSm,
                          ),
                          child: Text(
                            s.builtinCategory,
                            style: TextStyle(
                              fontSize: 9,
                              color: c.accent,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                      if (!cat.visible) ...[
                        const SizedBox(width: 6),
                        Icon(LucideIcons.eyeOff, size: 11, color: c.textMuted),
                      ],
                    ],
                  ),
                  if (_subtitle(cat, s).isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      _subtitle(cat, s),
                      style: TextStyle(
                        fontSize: 10.5,
                        color: c.textMuted,
                        fontFamily: cat.matchMode == MatchMode.regex
                            ? 'monospace'
                            : null,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            // 操作按钮
            if (_isHovered) ...[
              _TileAction(
                icon: cat.visible ? LucideIcons.eye : LucideIcons.eyeOff,
                color: c.textMuted,
                onTap: widget.onToggleVisible,
              ),
              const SizedBox(width: 2),
              // 内置分类: 非 all 可编辑（含"其他"）; 自定义分类: 总是可编辑
              if (!cat.isBuiltin || cat.builtinType != 'all') ...[
                _TileAction(
                  icon: LucideIcons.pencil,
                  color: c.textSecondary,
                  onTap: widget.onEdit,
                ),
                const SizedBox(width: 2),
              ],
              // 内置: 重置按钮（"全部文件"除外）; 自定义: 删除按钮
              if (widget.onReset != null && cat.builtinType != 'all')
                _TileAction(
                  icon: LucideIcons.rotateCcw,
                  color: c.textMuted,
                  onTap: widget.onReset!,
                ),
              if (widget.onDelete != null)
                _TileAction(
                  icon: LucideIcons.trash2,
                  color: AppColors.red,
                  onTap: widget.onDelete!,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TileAction extends StatefulWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _TileAction({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  State<_TileAction> createState() => _TileActionState();
}

class _TileActionState extends State<_TileAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final m = AppMetrics.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: _hover
                ? m.soft(widget.color)
                : m.soft(widget.color).withValues(alpha: 0),
            borderRadius: m.brSm,
          ),
          child: Icon(widget.icon, size: 12, color: widget.color),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 外观设置
// ─────────────────────────────────────────────

class _AppearanceContent extends StatelessWidget {
  const _AppearanceContent();

  @override
  Widget build(BuildContext context) {
    final s = LocaleScope.of(context);
    return _AdaptiveSections(
      sections: [
        _SettingsGroup(
          children: [
            _SettingRow(
              label: s.language,
              description: s.languageDesc,
              vertical: true,
              child: const _LanguageSelector(),
            ),
          ],
        ),
        _SettingsGroup(
          title: s.settingsGroupTheme,
          children: [
            _SettingRow(
              label: s.themeMode,
              description: s.themeModeDesc,
              vertical: true,
              child: const _ThemeModeSelector(),
            ),
            _SettingRow(
              label: s.themeSelection,
              description: s.themeSelectionDesc,
              vertical: true,
              child: const _ThemeSelector(),
            ),
            _SettingRow(
              label: s.themeColor,
              description: s.themeColorDesc,
              vertical: true,
              child: const _ColorSchemeSelector(),
            ),
          ],
        ),
        _SettingsGroup(
          title: s.settingsGroupInterface,
          children: [
            _SettingRow(
              label: s.uiScale,
              description: s.uiScaleDesc,
              vertical: true,
              child: const _UiScaleSelector(),
            ),
            _SettingRow(
              label: s.appIcon,
              description: s.appIconDesc,
              vertical: true,
              child: const _AppIconSelector(),
            ),
          ],
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
// 界面缩放选择器
// ─────────────────────────────────────────────

class _UiScaleSelector extends StatelessWidget {
  const _UiScaleSelector();

  static const _options = [0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.5];

  static String _label(double v) => '${(v * 100).round()}%';

  @override
  Widget build(BuildContext context) {
    final tp = FluxDownApp.of(context);
    final c = AppColors.of(context);
    // FluxDownApp.of 走 findAncestorStateOfType，不建立响应式依赖；
    // 本组件又以 const 挂载，父级重建会被 const 同一性跳过。
    // 必须显式监听 ThemeProvider，否则点击后高亮停留在上一次的值。
    return ListenableBuilder(
      listenable: tp,
      builder: (context, _) {
        final current = tp.uiScale;
        return Row(
          children: _options.map((v) {
            final selected = (v - current).abs() < 0.01;
            return Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _UiScaleChip(
                label: _label(v),
                selected: selected,
                isDefault: v == 1.0,
                colors: c,
                onTap: () => tp.setUiScale(v),
              ),
            );
          }).toList(),
        );
      },
    );
  }
}

class _UiScaleChip extends StatefulWidget {
  final String label;
  final bool selected;
  final bool isDefault;
  final AppColors colors;
  final VoidCallback onTap;

  const _UiScaleChip({
    required this.label,
    required this.selected,
    required this.isDefault,
    required this.colors,
    required this.onTap,
  });

  @override
  State<_UiScaleChip> createState() => _UiScaleChipState();
}

class _UiScaleChipState extends State<_UiScaleChip> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final m = AppMetrics.of(context);
    final bg = widget.selected
        ? m.active(c.accent)
        : _isHovered
        ? c.surface2
        : c.surface1;
    final border = widget.selected
        ? m.borderFade(c.accent)
        : m.borderFade(c.border);
    final textColor = widget.selected ? c.accent : c.textPrimary;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: m.brMd,
            border: Border.all(color: border, width: 1),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400,
              color: textColor,
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 应用图标选择器
// ─────────────────────────────────────────────

class _AppIconSelector extends StatefulWidget {
  const _AppIconSelector();

  @override
  State<_AppIconSelector> createState() => _AppIconSelectorState();
}

class _AppIconSelectorState extends State<_AppIconSelector> {
  bool _busy = false;

  /// 「自定义」点击 → 一律打开文件选择器（取消则保持当前图标不变）。
  /// 曾导入过也重新选图，避免「点了没反应」的切回旧图标歧义。
  Future<void> _pickImage() async {
    final s = LocaleScope.of(context);
    setState(() => _busy = true);
    try {
      final files = await FilePickerService.pickFiles(
        dialogTitle: s.appIconChooseImage,
        allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'ico'],
      );
      if (files == null || files.isEmpty) return;
      await AppIconService.instance.importAndApply(files.first.path);
    } catch (e, stack) {
      logError('AppIconSelector', 'failed to apply custom icon', e, stack);
      if (mounted) {
        FluxSonner.of(context).show(
          ShadToast.destructive(
            title: Text(LocaleScope.of(context).appIconApplyFailed),
            description: Text(e.toString()),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 弹窗放大查看图标（自定义预览源为 256px PNG；内置闪电为打包资源）
  void _showPreviewDialog(ImageProvider image, int revision) {
    final s = LocaleScope.of(context);
    final c = AppColors.of(context);
    showShadDialog(
      context: context,
      barrierColor: c.dialogBarrier,
      animateIn: const [],
      animateOut: const [],
      builder: (ctx) => ShadDialog(
        title: Text(s.appIcon),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(s.close),
          ),
        ],
        child: Padding(
          padding: const EdgeInsets.only(top: 16),
          child: _IconZoomPreview(image: image, revision: revision),
        ),
      ),
    );
  }

  /// 可点击放大的小尺寸图标缩略图。
  Widget _iconThumb(AppColors c, ImageProvider image, int revision) {
    final m = AppMetrics.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _showPreviewDialog(image, revision),
        child: Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            borderRadius: m.brCard,
            border: Border.all(color: m.borderFade(c.border)),
            color: c.surface1,
          ),
          child: ClipRRect(
            borderRadius: m.brMd,
            child: Image(
              key: ValueKey(revision),
              image: image,
              width: 34,
              height: 34,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = LocaleScope.of(context);
    final c = AppColors.of(context);
    return ListenableBuilder(
      listenable: AppIconService.instance,
      builder: (context, _) {
        final svc = AppIconService.instance;
        final previewPath = svc.previewPngPath;
        return Row(
          children: [
            _UiScaleChip(
              label: s.appIconDefault,
              selected: svc.choice == AppIconChoice.defaultIcon,
              isDefault: true,
              colors: c,
              onTap: () {
                if (!_busy) svc.useDefault();
              },
            ),
            const SizedBox(width: 6),
            _UiScaleChip(
              label: s.appIconBolt,
              selected: svc.isBolt,
              isDefault: false,
              colors: c,
              onTap: () {
                if (!_busy) svc.useBolt();
              },
            ),
            const SizedBox(width: 6),
            _UiScaleChip(
              label: s.appIconCustom,
              selected: svc.isCustom,
              isDefault: false,
              colors: c,
              onTap: () {
                if (!_busy) _pickImage();
              },
            ),
            if (svc.isBolt) ...[
              const SizedBox(width: 12),
              _iconThumb(
                c,
                const AssetImage(AppIconService.builtinBoltAsset),
                0,
              ),
            ] else if (svc.isCustom && previewPath != null) ...[
              const SizedBox(width: 12),
              _iconThumb(c, FileImage(File(previewPath)), svc.previewRevision),
            ],
          ],
        );
      },
    );
  }
}

/// 支持滚轮缩放的图标预览视口。
///
/// 悬停在视口上滚动滚轮即可放大/缩小，图标按当前尺寸自适应渲染；
/// 大倍率下切换为最近邻采样，保留像素边缘便于检查图标细节。
class _IconZoomPreview extends StatefulWidget {
  final ImageProvider image;
  final int revision;

  const _IconZoomPreview({required this.image, required this.revision});

  @override
  State<_IconZoomPreview> createState() => _IconZoomPreviewState();
}

class _IconZoomPreviewState extends State<_IconZoomPreview> {
  static const _baseSide = 160.0;
  static const _minScale = 0.25;
  static const _maxScale = 6.0;
  static const _step = 1.15;

  double _scale = 1.0;

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final factor = event.scrollDelta.dy < 0 ? _step : 1 / _step;
    setState(() {
      _scale = (_scale * factor).clamp(_minScale, _maxScale);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = LocaleScope.of(context);
    final c = AppColors.of(context);
    final m = AppMetrics.of(context);
    final side = _baseSide * _scale;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Listener(
          onPointerSignal: _onPointerSignal,
          child: Container(
            width: double.infinity,
            height: 320,
            decoration: BoxDecoration(
              color: c.surface1,
              borderRadius: m.brDialog,
              border: Border.all(color: m.borderFaint(c.border)),
            ),
            child: ClipRRect(
              borderRadius: m.brDialog,
              child: Center(
                child: Image(
                  key: ValueKey(widget.revision),
                  image: widget.image,
                  width: side,
                  height: side,
                  fit: BoxFit.contain,
                  filterQuality: _scale > 2
                      ? FilterQuality.none
                      : FilterQuality.high,
                  gaplessPlayback: true,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '${side.round()} px · ${s.appIconZoomHint}',
          style: TextStyle(fontSize: 11, color: c.textMuted),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
// 下载设置
// ─────────────────────────────────────────────

class _DownloadContent extends StatelessWidget {
  final SettingsProvider settingsProvider;
  final DownloadController? downloadController;

  const _DownloadContent({
    required this.settingsProvider,
    this.downloadController,
  });

  /// 开启多 CDN 并发前检查代理：代理启用时该功能不会生效，先让用户
  /// 选择「关闭代理并开启」或取消，避免开了却无效的误解。
  void _onCdnMultiChanged(BuildContext context, S s, bool value) {
    final mode = settingsProvider.proxyMode;
    // auto 模式下 CDN 聚合对直连任务仍可用，视同不冲突。
    if (!value || mode == 'none' || mode == 'auto') {
      settingsProvider.setCdnMultiEnabled(value);
      return;
    }
    final c = AppColors.of(context);
    showShadDialog(
      context: context,
      barrierColor: c.dialogBarrier,
      animateIn: const [],
      animateOut: const [],
      builder: (ctx) => ShadDialog(
        title: Text(s.cdnMultiProxyConfirmTitle),
        description: Text(
          mode == 'system'
              ? s.cdnMultiProxyConfirmDescSystem
              : s.cdnMultiProxyConfirmDescManual,
        ),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(s.cancel),
          ),
          ShadButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              settingsProvider.setProxyMode('none');
              settingsProvider.setCdnMultiEnabled(true);
            },
            child: Text(s.cdnMultiProxyConfirmDisable),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final listenable = downloadController != null
        ? Listenable.merge([settingsProvider, downloadController!])
        : settingsProvider;
    return ListenableBuilder(
      listenable: listenable,
      builder: (context, _) {
        final s = LocaleScope.of(context);
        final queues = downloadController?.queues ?? [];
        return _AdaptiveSections(
          sections: [
            _SettingsGroup(
              title: s.settingsGroupSaveLocation,
              children: [
                _SettingRow(
                  label: s.defaultSaveDir,
                  description: s.defaultSaveDirDesc,
                  vertical: true,
                  child: _SaveDirPicker(settingsProvider: settingsProvider),
                ),
                _SettingRow(
                  label: s.rememberLastSaveDir,
                  description: s.rememberLastSaveDirDesc,
                  child: ShadSwitch(
                    value: settingsProvider.rememberLastSaveDir,
                    onChanged: (v) =>
                        settingsProvider.setRememberLastSaveDir(v),
                  ),
                ),
              ],
            ),
            _SettingsGroup(
              title: s.settingsGroupBehavior,
              children: [
                _SettingRow(
                  label: s.silentDownload,
                  description: s.silentDownloadDesc,
                  child: ShadSwitch(
                    value: settingsProvider.silentDownloadEnabled,
                    onChanged: (v) =>
                        settingsProvider.setSilentDownloadEnabled(v),
                  ),
                ),
                // 免打扰子开关：仅父开关开启时显示（沿用页内集合 if 条件行模式）
                if (settingsProvider.silentDownloadEnabled)
                  _SettingRow(
                    label: s.silentSkipSelection,
                    description: s.silentSkipSelectionDesc,
                    child: ShadSwitch(
                      value: settingsProvider.silentSkipSelection,
                      onChanged: (v) =>
                          settingsProvider.setSilentSkipSelection(v),
                    ),
                  ),
                _SettingRow(
                  label: s.useServerTime,
                  description: s.useServerTimeDesc,
                  child: ShadSwitch(
                    value: settingsProvider.useServerTime,
                    onChanged: (v) => settingsProvider.setUseServerTime(v),
                  ),
                ),
                _SettingRow(
                  label: s.fileExistsBehavior,
                  description: s.fileExistsBehaviorDesc,
                  child: ShadSelect<String>(
                    initialValue:
                        settingsProvider.fileExistsBehavior == 'overwrite'
                        ? 'overwrite'
                        : 'rename',
                    options: [
                      ShadOption(
                        value: 'rename',
                        child: Text(s.fileExistsRename),
                      ),
                      ShadOption(
                        value: 'overwrite',
                        child: Text(s.fileExistsOverwrite),
                      ),
                    ],
                    selectedOptionBuilder: (context, value) => Text(
                      value == 'overwrite'
                          ? s.fileExistsOverwrite
                          : s.fileExistsRename,
                    ),
                    onChanged: (v) {
                      if (v != null) {
                        settingsProvider.setFileExistsBehavior(v);
                      }
                    },
                  ),
                ),
                _SettingRow(
                  label: s.fileMissingAction,
                  description: s.fileMissingActionDesc,
                  child: ShadSelect<String>(
                    initialValue: settingsProvider.fileMissingAction == 'delete'
                        ? 'delete'
                        : 'keep',
                    options: [
                      ShadOption(value: 'keep', child: Text(s.fileMissingKeep)),
                      ShadOption(
                        value: 'delete',
                        child: Text(s.fileMissingDelete),
                      ),
                    ],
                    selectedOptionBuilder: (context, value) => Text(
                      value == 'delete'
                          ? s.fileMissingDelete
                          : s.fileMissingKeep,
                    ),
                    onChanged: (v) {
                      if (v != null) {
                        settingsProvider.setFileMissingAction(v);
                      }
                    },
                  ),
                ),
                if (queues.isNotEmpty)
                  _SettingRow(
                    label: s.defaultQueueSetting,
                    description: s.defaultQueueSettingDesc,
                    child: _DefaultQueueSelector(
                      settingsProvider: settingsProvider,
                      queues: queues,
                    ),
                  ),
              ],
            ),
            _SettingsGroup(
              title: s.settingsGroupConnection,
              children: [
                _SettingRow(
                  label: s.defaultThreads,
                  description: s.defaultThreadsDesc,
                  child: _SegmentSelector(settingsProvider: settingsProvider),
                ),
                if (settingsProvider.defaultSegments == 0)
                  _SettingRow(
                    label: s.autoMaxConnections,
                    description: s.autoMaxConnectionsDesc,
                    child: _AutoMaxConnSelector(
                      settingsProvider: settingsProvider,
                    ),
                  ),
                _SettingRow(
                  label: s.cdnMultiEnabled,
                  description: s.cdnMultiEnabledDesc,
                  child: ShadSwitch(
                    value: settingsProvider.cdnMultiEnabled,
                    onChanged: (v) => _onCdnMultiChanged(context, s, v),
                  ),
                ),
                if (settingsProvider.cdnMultiEnabled)
                  _SettingRow(
                    label: s.cdnMaxNodes,
                    description: s.cdnMaxNodesDesc,
                    child: _CdnMaxNodesSelector(
                      settingsProvider: settingsProvider,
                    ),
                  ),
                _SettingRow(
                  label: s.connPolicyCache,
                  description: s.connPolicyCacheDesc,
                  child: _ConnPolicyClearButton(
                    settingsProvider: settingsProvider,
                  ),
                ),
                _SettingRow(
                  label: s.maxConcurrent,
                  description: s.maxConcurrentDesc,
                  child: _ConcurrentSelector(
                    settingsProvider: settingsProvider,
                  ),
                ),
                _SettingRow(
                  label: s.speedLimit,
                  description: s.speedLimitDesc,
                  vertical: true,
                  child: _SpeedLimitInput(settingsProvider: settingsProvider),
                ),
                _SettingRow(
                  label: s.uploadLimit,
                  description: s.uploadLimitDesc,
                  vertical: true,
                  child: _UploadLimitInput(settingsProvider: settingsProvider),
                ),
              ],
            ),
            _SettingsGroup(
              title: s.settingsGroupRetry,
              children: [
                _SettingRow(
                  label: s.autoRetryCount,
                  description: s.autoRetryCountDesc,
                  child: _AutoRetryCountSelector(
                    settingsProvider: settingsProvider,
                  ),
                ),
                _SettingRow(
                  label: s.autoRetryDelay,
                  description: s.autoRetryDelayDesc,
                  vertical: true,
                  child: _AutoRetryDelayInput(
                    settingsProvider: settingsProvider,
                  ),
                ),
              ],
            ),
            _SettingsGroup(
              title: s.settingsGroupAdvanced,
              children: [
                _SettingRow(
                  label: s.userAgent,
                  description: s.userAgentDesc,
                  vertical: true,
                  child: _UserAgentEditor(settingsProvider: settingsProvider),
                ),
                _SettingRow(
                  label: s.revealFileCmdLabel,
                  description: s.revealFileCmdDesc,
                  vertical: true,
                  child: _FileManagerCmdInput(
                    settingsProvider: settingsProvider,
                  ),
                ),
              ],
            ),
            _SettingsGroup(
              title: s.settingsSiteAuthTitle,
              subtitle: s.settingsSiteAuthDesc,
              children: [
                _SiteAuthCredentialList(settingsProvider: settingsProvider),
              ],
            ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────
// 默认队列选择器（下载设置内）
// ─────────────────────────────────────────────

class _DefaultQueueSelector extends StatelessWidget {
  final SettingsProvider settingsProvider;
  final List<DownloadQueue> queues;

  const _DefaultQueueSelector({
    required this.settingsProvider,
    required this.queues,
  });

  @override
  Widget build(BuildContext context) {
    final s = LocaleScope.of(context);
    final validIds = queues.map((q) => q.queueId).toSet();
    final currentId = settingsProvider.defaultQueueId;
    // 显示回退到主队列：不强制写回设置，仅当前值为空/失效 ID 时的展示兜底
    final effectiveId = validIds.contains(currentId)
        ? currentId
        : (validIds.contains(kMainQueueId)
              ? kMainQueueId
              : queues.first.queueId);
    return ShadSelect<String>(
      initialValue: effectiveId,
      options: queues.map((q) {
        return ShadOption(
          value: q.queueId,
          child: Text(queueDisplayName(s, q)),
        );
      }).toList(),
      selectedOptionBuilder: (context, value) {
        final q = queues.where((q) => q.queueId == value).firstOrNull;
        return Text(
          q != null ? queueDisplayName(s, q) : s.mainQueue,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        );
      },
      onChanged: (v) {
        if (v != null) settingsProvider.setDefaultQueueId(v);
      },
    );
  }
}

// ─────────────────────────────────────────────
// 已保存的网站凭据（HTTP Basic，设备本地）
// ─────────────────────────────────────────────

/// 列出引擎按站点保存的 HTTP Basic 凭据（站点 + 用户名，不显示密码），
/// 每行可编辑/删除，另提供手动新增入口；改动后整体 JSON 写回 config。
/// 空态显示提示文案（保留添加入口）。
///
/// 规模化：凭据可达数百条——顶部提供模糊搜索（站点/用户名）与计数，
/// 列表超过 [_inlineRowLimit] 行时改为定高容器内 `ListView.builder`
/// 惰性构建，既不撑高设置页也不全量 build 行 widget。
class _SiteAuthCredentialList extends StatefulWidget {
  final SettingsProvider settingsProvider;

  const _SiteAuthCredentialList({required this.settingsProvider});

  /// 超过此行数改用定高滚动容器（少量凭据时保持平铺，不占满固定高度）。
  static const int _inlineRowLimit = 8;

  /// 滚动容器高度（逻辑像素），与账号设备管理弹窗的列表高度一致。
  static const double _scrollHeight = 360;

  @override
  State<_SiteAuthCredentialList> createState() =>
      _SiteAuthCredentialListState();

  /// 站点输入归一化：含 `://` 时按 URL 解析取 host[:非默认端口]，
  /// 否则原样 trim + 小写。解析失败返回 null。
  static String? _normalizeSite(String input) {
    final raw = input.trim();
    if (raw.isEmpty) return null;
    if (raw.contains('://')) {
      final uri = Uri.tryParse(raw);
      if (uri == null || uri.host.isEmpty) return null;
      final host = uri.host.toLowerCase();
      final defaultPort = switch (uri.scheme.toLowerCase()) {
        'https' => 443,
        'http' => 80,
        _ => -1,
      };
      if (uri.hasPort && uri.port != defaultPort) return '$host:${uri.port}';
      return host;
    }
    return raw.toLowerCase();
  }
}

class _SiteAuthCredentialListState extends State<_SiteAuthCredentialList> {
  final _searchController = TextEditingController();

  SettingsProvider get settingsProvider => widget.settingsProvider;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onQueryChanged);
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_onQueryChanged)
      ..dispose();
    super.dispose();
  }

  void _onQueryChanged() => setState(() {});

  void _delete(String site) {
    try {
      final map = jsonDecode(settingsProvider.siteAuthCredentials);
      if (map is! Map<String, dynamic>) return;
      map.remove(site);
      settingsProvider.setSiteAuthCredentials(jsonEncode(map));
    } catch (_) {
      // JSON 损坏时不写回，避免把不可解析内容替换成空表
    }
  }

  /// 写回单条凭据（新增与编辑同语义：同键覆盖）。
  void _save(String site, String user, String pass) {
    final raw = settingsProvider.siteAuthCredentials;
    Map<String, dynamic> map;
    if (raw.trim().isEmpty) {
      map = <String, dynamic>{};
    } else {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) return;
        map = decoded;
      } catch (_) {
        // JSON 损坏时不写回，避免把不可解析内容替换成空表
        return;
      }
    }
    map[site] = {'user': user, 'pass': pass};
    settingsProvider.setSiteAuthCredentials(jsonEncode(map));
  }

  Future<void> _openDialog(
    BuildContext context, {
    String? site,
    String initialUser = '',
    String initialPass = '',
  }) async {
    final result = await showShadDialog<(String, String, String)>(
      context: context,
      barrierColor: AppColors.of(context).dialogBarrier,
      animateIn: const [],
      animateOut: const [],
      builder: (_) => _SiteAuthCredentialDialog(
        site: site,
        initialUser: initialUser,
        initialPass: initialPass,
      ),
    );
    if (result != null) _save(result.$1, result.$2, result.$3);
  }

  Widget _buildAddButton(BuildContext context, S s, AppColors c) {
    return Align(
      alignment: Alignment.centerLeft,
      child: ShadButton.ghost(
        size: ShadButtonSize.sm,
        onPressed: () => _openDialog(context),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.plus, size: 13, color: c.textSecondary),
            const SizedBox(width: 4),
            Text(s.settingsSiteAuthAdd),
          ],
        ),
      ),
    );
  }

  /// 单行凭据（站点 + 用户名 + 编辑/删除）。列表两种形态共用，
  /// 避免平铺分支与滚动分支各写一遍。
  Widget _buildRow(
    BuildContext context,
    S s,
    AppColors c,
    MapEntry<String, ({String user, String pass})> e,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Icon(LucideIcons.globe, size: 14, color: c.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              e.key,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: TextStyle(fontSize: 12.5, color: c.textPrimary),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              e.value.user,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: TextStyle(fontSize: 12, color: c.textMuted),
            ),
          ),
          const SizedBox(width: 8),
          ShadTooltip(
            effects: const [],
            builder: (_) => Text(s.settingsSiteAuthEdit),
            child: ShadButton.ghost(
              size: ShadButtonSize.sm,
              onPressed: () => _openDialog(
                context,
                site: e.key,
                initialUser: e.value.user,
                initialPass: e.value.pass,
              ),
              child: Icon(LucideIcons.pencil, size: 14, color: c.textSecondary),
            ),
          ),
          ShadTooltip(
            effects: const [],
            builder: (_) => Text(s.settingsSiteAuthDelete),
            child: ShadButton.ghost(
              size: ShadButtonSize.sm,
              onPressed: () => _delete(e.key),
              child: Icon(LucideIcons.trash2, size: 14, color: c.statusError),
            ),
          ),
        ],
      ),
    );
  }

  /// 搜索框 + 计数。仅在存在凭据时显示（空态只留提示与添加入口）。
  Widget _buildSearchBar(S s, AppColors c, int matched, int total) {
    final query = _searchController.text.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: ShadInput(
              controller: _searchController,
              placeholder: Text(
                s.settingsSiteAuthSearchHint,
                style: const TextStyle(fontSize: 12),
              ),
              // 与设置页顶部搜索框同款紧凑度：30px 行高 + 12px 字号。
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              constraints: const BoxConstraints(minHeight: 30, maxHeight: 30),
              gap: 6,
              style: const TextStyle(fontSize: 12),
              leading: Icon(LucideIcons.search, size: 13, color: c.textMuted),
              trailing: query.isEmpty
                  ? null
                  : MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: _searchController.clear,
                        child: Icon(
                          LucideIcons.x,
                          size: 12,
                          color: c.textMuted,
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            query.isEmpty
                ? s.settingsSiteAuthCount(total)
                : s.settingsSiteAuthCountFiltered(matched, total),
            style: TextStyle(fontSize: 11.5, color: c.textMuted),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final m = AppMetrics.of(context);
    final s = LocaleScope.of(context);
    final store = parseSiteAuthStore(settingsProvider.siteAuthCredentials);
    if (store.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                s.settingsSiteAuthEmpty,
                style: TextStyle(fontSize: 12, color: c.textMuted),
              ),
            ),
            _buildAddButton(context, s, c),
          ],
        ),
      );
    }
    final entries = filterSiteAuth(store, _searchController.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSearchBar(s, c, entries.length, store.length),
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: Text(
              s.settingsSiteAuthNoMatch,
              style: TextStyle(fontSize: 12, color: c.textMuted),
            ),
          )
        else if (entries.length <= _SiteAuthCredentialList._inlineRowLimit)
          for (final e in entries) _buildRow(context, s, c, e)
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              height: _SiteAuthCredentialList._scrollHeight,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: m.brInput,
                border: Border.all(color: m.borderFade(c.border), width: 1),
              ),
              // 惰性构建：数百条凭据只 build 视口内的行。
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: entries.length,
                itemBuilder: (context, i) =>
                    _buildRow(context, s, c, entries[i]),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
          child: _buildAddButton(context, s, c),
        ),
      ],
    );
  }
}

/// 站点凭据编辑/新增对话框。`site == null` 为新增模式（站点可输入），
/// 否则站点只读展示。保存时 pop 出 (站点, 用户名, 密码)。
class _SiteAuthCredentialDialog extends StatefulWidget {
  final String? site;
  final String initialUser;
  final String initialPass;

  const _SiteAuthCredentialDialog({
    this.site,
    this.initialUser = '',
    this.initialPass = '',
  });

  @override
  State<_SiteAuthCredentialDialog> createState() =>
      _SiteAuthCredentialDialogState();
}

class _SiteAuthCredentialDialogState extends State<_SiteAuthCredentialDialog> {
  late final TextEditingController _siteController = TextEditingController();
  late final TextEditingController _userController = TextEditingController(
    text: widget.initialUser,
  );
  late final TextEditingController _passController = TextEditingController(
    text: widget.initialPass,
  );

  /// 密码输入框明文显示切换。
  bool _showPassword = false;

  @override
  void dispose() {
    _siteController.dispose();
    _userController.dispose();
    _passController.dispose();
    super.dispose();
  }

  /// 归一化后的站点键；新增模式解析失败/为空时为 null（禁用保存）。
  String? get _resolvedSite =>
      widget.site ??
      _SiteAuthCredentialList._normalizeSite(_siteController.text);

  bool get _canSave =>
      _resolvedSite != null && _userController.text.trim().isNotEmpty;

  void _submit() {
    final site = _resolvedSite;
    final user = _userController.text.trim();
    if (site == null || user.isEmpty) return;
    Navigator.of(context).pop((site, user, _passController.text));
  }

  Widget _fieldLabel(String text, AppColors c) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: TextStyle(fontSize: 11.5, color: c.textSecondary),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = LocaleScope.of(context);
    final c = AppColors.of(context);
    final isAdd = widget.site == null;
    return ShadDialog(
      title: Text(isAdd ? s.settingsSiteAuthAdd : s.settingsSiteAuthEdit),
      constraints: const BoxConstraints(maxWidth: 380),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          _fieldLabel(s.settingsSiteAuthSite, c),
          if (isAdd)
            ShadInput(
              controller: _siteController,
              autofocus: true,
              placeholder: Text(s.settingsSiteAuthSitePlaceholder),
              onChanged: (_) => setState(() {}),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(LucideIcons.globe, size: 14, color: c.textMuted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      widget.site!,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: TextStyle(fontSize: 12.5, color: c.textPrimary),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 10),
          _fieldLabel(s.taskHttpAuthUser, c),
          ShadInput(
            controller: _userController,
            autofocus: !isAdd,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 10),
          _fieldLabel(s.taskHttpAuthPassword, c),
          ShadInput(
            controller: _passController,
            obscureText: !_showPassword,
            onSubmitted: (_) => _submit(),
            trailing: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => setState(() => _showPassword = !_showPassword),
                child: Icon(
                  _showPassword ? LucideIcons.eyeOff : LucideIcons.eye,
                  size: 14,
                  color: c.textMuted,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: ShadButton.outline(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(s.cancel),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ShadButton(
                  enabled: _canSave,
                  onPressed: _submit,
                  child: Text(s.settingsSiteAuthSave),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// BT 设置
// ─────────────────────────────────────────────

class _BtBasicContent extends StatelessWidget {
  final SettingsProvider settingsProvider;

  const _BtBasicContent({required this.settingsProvider});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settingsProvider,
      builder: (context, _) {
        return Column(
          children: [
            _SettingCard(
              label: LocaleScope.of(context).btEnableDht,
              description: LocaleScope.of(context).btEnableDhtDesc,
              child: ShadSwitch(
                value: settingsProvider.btEnableDht,
                onChanged: settingsProvider.setBtEnableDht,
              ),
            ),
            _SettingCard(
              label: LocaleScope.of(context).btEnableUpnp,
              description: LocaleScope.of(context).btEnableUpnpDesc,
              child: ShadSwitch(
                value: settingsProvider.btEnableUpnp,
                onChanged: settingsProvider.setBtEnableUpnp,
              ),
            ),
            _SettingCard(
              label: LocaleScope.of(context).btListenPort,
              description: LocaleScope.of(context).btListenPortDesc,
              vertical: true,
              child: _BtPortRangeEditor(settingsProvider: settingsProvider),
            ),
            const SizedBox(height: 6),
            // 重启提示
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  Icon(
                    LucideIcons.info,
                    size: 12,
                    color: AppColors.of(context).textMuted,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      LocaleScope.of(context).btSettingsRestartHint,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.of(context).textMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _BtTrackerContent extends StatelessWidget {
  final SettingsProvider settingsProvider;

  const _BtTrackerContent({required this.settingsProvider});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settingsProvider,
      builder: (context, _) {
        return _AdaptiveSections(
          sections: [
            _SettingCard(
              label: LocaleScope.of(context).btTrackerList,
              description: LocaleScope.of(context).btTrackerListDesc,
              vertical: true,
              child: _BtTrackerEditor(settingsProvider: settingsProvider),
            ),
            _SettingCard(
              label: LocaleScope.of(context).btTrackerSub,
              description: LocaleScope.of(context).btTrackerSubDesc,
              vertical: true,
              child: _BtTrackerSubEditor(settingsProvider: settingsProvider),
            ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────
// BT 做种设置
// ─────────────────────────────────────────────

class _BtSeedingContent extends StatelessWidget {
  final SettingsProvider settingsProvider;

  const _BtSeedingContent({required this.settingsProvider});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settingsProvider,
      builder: (context, _) {
        return _AdaptiveSections(
          sections: [
            _SettingCard(
              label: LocaleScope.of(context).btSeedEnabled,
              description: LocaleScope.of(context).btSeedEnabledDesc,
              child: ShadSwitch(
                value: settingsProvider.btSeedEnabled,
                onChanged: settingsProvider.setBtSeedEnabled,
              ),
            ),
            _SettingCard(
              label: LocaleScope.of(context).btSeedMaxActive,
              description: LocaleScope.of(context).btSeedMaxActiveDesc,
              child: _BtSeedMaxActiveSelector(
                settingsProvider: settingsProvider,
              ),
            ),
            _SettingCard(
              label: LocaleScope.of(context).btAutoReseed,
              description: LocaleScope.of(context).btAutoReseedDesc,
              child: ShadSwitch(
                value: settingsProvider.btAutoReseed,
                onChanged: settingsProvider.setBtAutoReseed,
              ),
            ),
            // 做种限制编辑器实高≈7行：显式权重让前两张小卡合入左列，
            // 避免右列一家独大、左列空置。
            _WeightedSection(
              weight: 7,
              child: _SettingCard(
                label: LocaleScope.of(context).btSeedingTitle,
                description: LocaleScope.of(context).btSeedingTitle,
                vertical: true,
                child: _BtSeedingEditor(settingsProvider: settingsProvider),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _BtSeedingEditor extends StatefulWidget {
  final SettingsProvider settingsProvider;

  const _BtSeedingEditor({required this.settingsProvider});

  @override
  State<_BtSeedingEditor> createState() => _BtSeedingEditorState();
}

class _BtSeedingEditorState extends State<_BtSeedingEditor> {
  late TextEditingController _ratioCtrl;
  late TextEditingController _postRatioCtrl;
  late TextEditingController _timeCtrl;
  late TextEditingController _inactiveCtrl;

  static int _unitFactor(String unit) {
    return switch (unit) {
      'days' => 1440,
      'hours' => 60,
      _ => 1,
    };
  }

  static int _displayValue(int minutes, String unit) {
    return minutes ~/ _unitFactor(unit);
  }

  static int _toMinutes(int displayValue, String unit) {
    return displayValue * _unitFactor(unit);
  }

  @override
  void initState() {
    super.initState();
    final sp = widget.settingsProvider;
    _ratioCtrl = TextEditingController(
      text: sp.btSeedRatioLimit.toStringAsFixed(1),
    );
    _postRatioCtrl = TextEditingController(
      text: sp.btSeedPostRatioLimit.toStringAsFixed(1),
    );
    _timeCtrl = TextEditingController(
      text:
          '${_displayValue(sp.btSeedTimeLimitMinutes, sp.btSeedTimeLimitUnit)}',
    );
    _inactiveCtrl = TextEditingController(
      text:
          '${_displayValue(sp.btSeedInactiveTimeLimitMinutes, sp.btSeedInactiveTimeLimitUnit)}',
    );
  }

  @override
  void didUpdateWidget(_BtSeedingEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sp = widget.settingsProvider;
    final ratioText = sp.btSeedRatioLimit.toStringAsFixed(1);
    if (_ratioCtrl.text != ratioText) _ratioCtrl.text = ratioText;
    final postRatioText = sp.btSeedPostRatioLimit.toStringAsFixed(1);
    if (_postRatioCtrl.text != postRatioText) {
      _postRatioCtrl.text = postRatioText;
    }
    final timeText =
        '${_displayValue(sp.btSeedTimeLimitMinutes, sp.btSeedTimeLimitUnit)}';
    if (_timeCtrl.text != timeText) _timeCtrl.text = timeText;
    final inactiveText =
        '${_displayValue(sp.btSeedInactiveTimeLimitMinutes, sp.btSeedInactiveTimeLimitUnit)}';
    if (_inactiveCtrl.text != inactiveText) _inactiveCtrl.text = inactiveText;
  }

  @override
  void dispose() {
    _ratioCtrl.dispose();
    _postRatioCtrl.dispose();
    _timeCtrl.dispose();
    _inactiveCtrl.dispose();
    super.dispose();
  }

  void _commitRatio() {
    final sp = widget.settingsProvider;
    final value = double.tryParse(_ratioCtrl.text) ?? 0.0;
    if (value >= 0.0) sp.setBtSeedRatioLimit(value);
  }

  void _commitPostRatio() {
    final sp = widget.settingsProvider;
    final value = double.tryParse(_postRatioCtrl.text) ?? 0.0;
    if (value >= 0.0) sp.setBtSeedPostRatioLimit(value);
  }

  void _commitTime() {
    final sp = widget.settingsProvider;
    final value = int.tryParse(_timeCtrl.text) ?? 0;
    if (value >= 0) {
      sp.setBtSeedTimeLimitMinutes(_toMinutes(value, sp.btSeedTimeLimitUnit));
    }
  }

  void _commitInactive() {
    final sp = widget.settingsProvider;
    final value = int.tryParse(_inactiveCtrl.text) ?? 0;
    if (value >= 0) {
      sp.setBtSeedInactiveTimeLimitMinutes(
        _toMinutes(value, sp.btSeedInactiveTimeLimitUnit),
      );
    }
  }

  Widget _buildRatioRow({
    required AppColors c,
    required bool enabled,
    required ValueChanged<bool> onChanged,
    required String label,
    required TextEditingController controller,
    required VoidCallback onSubmitted,
  }) {
    return Row(
      children: [
        ShadSwitch(value: enabled, onChanged: onChanged),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: c.textSecondary),
          ),
        ),
        SizedBox(
          width: 80,
          child: ShadInput(
            controller: controller,
            enabled: enabled,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onSubmitted: (_) => onSubmitted(),
            onChanged: (_) => onSubmitted(),
          ),
        ),
      ],
    );
  }

  Widget _buildTimeRow({
    required AppColors c,
    required S s,
    required bool enabled,
    required ValueChanged<bool> onChanged,
    required String label,
    required TextEditingController controller,
    required String unit,
    required ValueChanged<String> onUnitChanged,
    required VoidCallback onSubmitted,
  }) {
    return Row(
      children: [
        ShadSwitch(value: enabled, onChanged: onChanged),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: c.textSecondary),
          ),
        ),
        SizedBox(
          width: 72,
          child: ShadInput(
            controller: controller,
            enabled: enabled,
            keyboardType: TextInputType.number,
            onSubmitted: (_) => onSubmitted(),
            onChanged: (_) => onSubmitted(),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 80,
          child: ShadSelect<String>(
            enabled: enabled,
            initialValue: unit,
            options: [
              ShadOption(value: 'minutes', child: Text(s.timeUnitMinutes)),
              ShadOption(value: 'hours', child: Text(s.timeUnitHours)),
              ShadOption(value: 'days', child: Text(s.timeUnitDays)),
            ],
            selectedOptionBuilder: (context, value) {
              final text = switch (value) {
                'hours' => s.timeUnitHours,
                'days' => s.timeUnitDays,
                _ => s.timeUnitMinutes,
              };
              return Text(
                text,
                style: TextStyle(fontSize: 12, color: c.textPrimary),
              );
            },
            onChanged: (v) {
              if (v != null) onUnitChanged(v);
            },
          ),
        ),
      ],
    );
  }

  String _thenActionLabel(S s, String action) {
    return switch (action) {
      'delete' => s.btSeedDeleteTask,
      'delete_files' => s.btSeedDeleteTaskAndFiles,
      _ => s.btSeedStopSeeding,
    };
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final s = LocaleScope.of(context);
    final sp = widget.settingsProvider;

    return ListenableBuilder(
      listenable: sp,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildRatioRow(
              c: c,
              enabled: sp.btSeedRatioEnabled,
              onChanged: sp.setBtSeedRatioEnabled,
              label: s.btSeedRatioLimit,
              controller: _ratioCtrl,
              onSubmitted: _commitRatio,
            ),
            const SizedBox(height: 8),
            _buildRatioRow(
              c: c,
              enabled: sp.btSeedPostRatioEnabled,
              onChanged: sp.setBtSeedPostRatioEnabled,
              label: s.btSeedPostRatioLimit,
              controller: _postRatioCtrl,
              onSubmitted: _commitPostRatio,
            ),
            const SizedBox(height: 8),
            _buildTimeRow(
              c: c,
              s: s,
              enabled: sp.btSeedTimeEnabled,
              onChanged: sp.setBtSeedTimeEnabled,
              label: s.btSeedTimeLimit,
              controller: _timeCtrl,
              unit: sp.btSeedTimeLimitUnit,
              onUnitChanged: (unit) {
                sp.setBtSeedTimeLimitUnit(unit);
              },
              onSubmitted: _commitTime,
            ),
            const SizedBox(height: 8),
            _buildTimeRow(
              c: c,
              s: s,
              enabled: sp.btSeedInactiveTimeEnabled,
              onChanged: sp.setBtSeedInactiveTimeEnabled,
              label: s.btSeedInactiveTimeLimit,
              controller: _inactiveCtrl,
              unit: sp.btSeedInactiveTimeLimitUnit,
              onUnitChanged: (unit) {
                sp.setBtSeedInactiveTimeLimitUnit(unit);
              },
              onSubmitted: _commitInactive,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  s.btSeedConditionsOperator,
                  style: TextStyle(fontSize: 12, color: c.textSecondary),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 160,
                  child: ShadSelect<String>(
                    initialValue: sp.btSeedConditionsOperator,
                    options: [
                      ShadOption(value: 'or', child: Text(s.btSeedOperatorOr)),
                      ShadOption(
                        value: 'and',
                        child: Text(s.btSeedOperatorAnd),
                      ),
                    ],
                    selectedOptionBuilder: (context, value) {
                      return Text(
                        value == 'and'
                            ? s.btSeedOperatorAnd
                            : s.btSeedOperatorOr,
                        style: TextStyle(fontSize: 12, color: c.textPrimary),
                      );
                    },
                    onChanged: (v) {
                      if (v != null) sp.setBtSeedConditionsOperator(v);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  s.btSeedThenAction,
                  style: TextStyle(fontSize: 12, color: c.textSecondary),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 160,
                  child: ShadSelect<String>(
                    initialValue: sp.btSeedThenAction,
                    options: [
                      ShadOption(
                        value: 'stop',
                        child: Text(s.btSeedStopSeeding),
                      ),
                      ShadOption(
                        value: 'delete',
                        child: Text(s.btSeedDeleteTask),
                      ),
                      ShadOption(
                        value: 'delete_files',
                        child: Text(s.btSeedDeleteTaskAndFiles),
                      ),
                    ],
                    selectedOptionBuilder: (context, value) {
                      return Text(
                        _thenActionLabel(s, value),
                        style: TextStyle(fontSize: 12, color: c.textPrimary),
                      );
                    },
                    onChanged: (v) {
                      if (v != null) sp.setBtSeedThenAction(v);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              s.btSettingsRestartHint,
              style: TextStyle(fontSize: 11, color: c.textMuted),
            ),
          ],
        );
      },
    );
  }
}

class _BtSeedMaxActiveSelector extends StatelessWidget {
  final SettingsProvider settingsProvider;

  const _BtSeedMaxActiveSelector({required this.settingsProvider});

  @override
  Widget build(BuildContext context) {
    final s = LocaleScope.of(context);
    // 0 = 不限制活动做种数；超出上限的已完成任务进入排队做种，等待空闲槽位。
    String label(int v) => v == 0 ? s.btSeedMaxActiveUnlimited : '$v';
    return NumberSelector(
      value: settingsProvider.btSeedMaxActive,
      presets: const [0, 1, 3, 5, 10, 20],
      min: 0,
      max: 999,
      fallback: 0,
      selectedLabel: label,
      presetLabel: label,
      onChanged: settingsProvider.setBtSeedMaxActive,
    );
  }
}

// ─────────────────────────────────────────────
// ED2K 设置
// ─────────────────────────────────────────────

class _Ed2kBasicContent extends StatelessWidget {
  final SettingsProvider settingsProvider;

  const _Ed2kBasicContent({required this.settingsProvider});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settingsProvider,
      builder: (context, _) {
        final s = LocaleScope.of(context);
        return _AdaptiveSections(
          sections: [
            _SettingsGroup(
              children: [
                _SettingRow(
                  label: s.ed2kEnableKad,
                  description: s.ed2kEnableKadDesc,
                  child: ShadSwitch(
                    value: settingsProvider.ed2kEnableKad,
                    onChanged: (v) => settingsProvider.setEd2kEnableKad(v),
                  ),
                ),
                _SettingRow(
                  label: s.ed2kEnableUpnp,
                  description: s.ed2kEnableUpnpDesc,
                  child: ShadSwitch(
                    value: settingsProvider.ed2kEnableUpnp,
                    onChanged: (v) => settingsProvider.setEd2kEnableUpnp(v),
                  ),
                ),
                _SettingRow(
                  label: s.ed2kListenPort,
                  description: s.ed2kListenPortDesc,
                  child: _Ed2kListenPortEditor(
                    settingsProvider: settingsProvider,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _Ed2kServersContent extends StatelessWidget {
  final SettingsProvider settingsProvider;

  const _Ed2kServersContent({required this.settingsProvider});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settingsProvider,
      builder: (context, _) {
        return _AdaptiveSections(
          sections: [
            _SettingCard(
              label: LocaleScope.of(context).ed2kServerList,
              description: LocaleScope.of(context).ed2kServerListDesc,
              vertical: true,
              child: _Ed2kServerEditor(settingsProvider: settingsProvider),
            ),
            _SettingCard(
              label: LocaleScope.of(context).ed2kServerSub,
              description: LocaleScope.of(context).ed2kServerSubDesc,
              vertical: true,
              child: _Ed2kServerSubEditor(settingsProvider: settingsProvider),
            ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────
// 代理设置
// ─────────────────────────────────────────────

class _ProxyContent extends StatelessWidget {
  final SettingsProvider settingsProvider;

  const _ProxyContent({required this.settingsProvider});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settingsProvider,
      builder: (context, _) {
        return Column(
          children: [_ProxySettingsCard(settingsProvider: settingsProvider)],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────
// 下载设置子组件
// ─────────────────────────────────────────────

class _SaveDirPicker extends StatefulWidget {
  final SettingsProvider settingsProvider;

  const _SaveDirPicker({required this.settingsProvider});

  @override
  State<_SaveDirPicker> createState() => _SaveDirPickerState();
}

class _SaveDirPickerState extends State<_SaveDirPicker> {
  bool _isPicking = false;

  Future<void> _pickDir() async {
    if (_isPicking) return;
    setState(() => _isPicking = true);
    try {
      final result = await FilePickerService.pickDirectory(
        dialogTitle: currentS.selectDefaultSaveDir,
        initialDirectory: widget.settingsProvider.defaultSaveDir.isNotEmpty
            ? widget.settingsProvider.defaultSaveDir
            : null,
      );
      if (result != null && mounted) {
        widget.settingsProvider.setDefaultSaveDir(result);
      }
    } on FilePickerException catch (e) {
      if (mounted) _showPickerError(e);
    } finally {
      if (mounted) setState(() => _isPicking = false);
    }
  }

  void _showPickerError(FilePickerException e) {
    final s = currentS;
    final message = switch (e.reason) {
      FilePickerFailReason.timeout => s.filePickerErrorTimeout,
      FilePickerFailReason.noDialogTool => s.filePickerErrorNoTool,
      FilePickerFailReason.comInitFailed => s.filePickerErrorNative,
      FilePickerFailReason.nativeDialogFailed => s.filePickerErrorNative,
      FilePickerFailReason.unknown => s.filePickerErrorGeneric,
    };
    FluxSonner.of(context).show(ShadToast.destructive(title: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return DirPickerField(
      path: widget.settingsProvider.defaultSaveDir,
      placeholder: currentS.selectDefaultSaveDir,
      enabled: !_isPicking,
      onTap: _pickDir,
    );
  }
}

class _SegmentSelector extends StatelessWidget {
  final SettingsProvider settingsProvider;

  const _SegmentSelector({required this.settingsProvider});

  @override
  Widget build(BuildContext context) {
    final current = settingsProvider.defaultSegments;
    // SettingsProvider: 0 = 自动; ThreadSelector: null = 自动
    final value = current > 0 ? current.toString() : null;

    return ThreadSelector(
      value: value,
      onChanged: (v) {
        final n = int.tryParse(v ?? '') ?? 0;
        settingsProvider.setDefaultSegments(n.clamp(0, 256));
      },
    );
  }
}

class _AutoMaxConnSelector extends StatelessWidget {
  final SettingsProvider settingsProvider;

  const _AutoMaxConnSelector({required this.settingsProvider});

  @override
  Widget build(BuildContext context) {
    return NumberSelector(
      value: settingsProvider.autoMaxConnections,
      presets: const [4, 8, 16, 32, 64],
      min: 1,
      max: 64,
      fallback: 16,
      onChanged: settingsProvider.setAutoMaxConnections,
    );
  }
}

class _CdnMaxNodesSelector extends StatelessWidget {
  final SettingsProvider settingsProvider;

  const _CdnMaxNodesSelector({required this.settingsProvider});

  @override
  Widget build(BuildContext context) {
    final s = LocaleScope.of(context);
    // 0 = 自动档（按文件大小/并发连接数推导），与 [SettingsProvider] 语义一致。
    String label(int v) => v == 0 ? s.auto : '$v';
    return NumberSelector(
      value: settingsProvider.cdnMaxNodes,
      presets: const [0, 2, 3, 4, 6, 8],
      min: 0,
      max: 8,
      fallback: 0,
      selectedLabel: label,
      presetLabel: label,
      onChanged: settingsProvider.setCdnMaxNodes,
    );
  }
}

class _ConnPolicyClearButton extends StatefulWidget {
  final SettingsProvider settingsProvider;

  const _ConnPolicyClearButton({required this.settingsProvider});

  @override
  State<_ConnPolicyClearButton> createState() => _ConnPolicyClearButtonState();
}

class _ConnPolicyClearButtonState extends State<_ConnPolicyClearButton> {
  @override
  void initState() {
    super.initState();
    // 记录由引擎在下载过程中随时写入，进入设置页时拉取最新 config 刷新条数。
    widget.settingsProvider.requestConfig();
  }

  @override
  Widget build(BuildContext context) {
    final s = LocaleScope.of(context);
    final c = AppColors.of(context);
    final count = widget.settingsProvider.connPolicyCount;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          count > 0 ? s.nRecords(count) : s.connPolicyCacheEmpty,
          style: TextStyle(fontSize: 12, color: c.textMuted),
        ),
        const SizedBox(width: 8),
        ShadButton.outline(
          size: ShadButtonSize.sm,
          enabled: count > 0,
          onPressed: () {
            widget.settingsProvider.clearDomainConnCaps();
            FluxSonner.of(
              context,
            ).show(ShadToast(title: Text(s.connPolicyCacheCleared)));
          },
          child: Text(s.connPolicyCacheClear),
        ),
      ],
    );
  }
}

class _ConcurrentSelector extends StatelessWidget {
  final SettingsProvider settingsProvider;

  const _ConcurrentSelector({required this.settingsProvider});

  @override
  Widget build(BuildContext context) {
    return NumberSelector(
      value: settingsProvider.maxConcurrentTasks,
      presets: const [1, 2, 3, 5, 8, 10],
      min: 1,
      max: 50,
      fallback: 5,
      selectedLabel: (v) => currentS.nTasks(v),
      onChanged: settingsProvider.setMaxConcurrentTasks,
    );
  }
}

class _SpeedLimitInput extends StatefulWidget {
  final SettingsProvider settingsProvider;

  const _SpeedLimitInput({required this.settingsProvider});

  @override
  State<_SpeedLimitInput> createState() => _SpeedLimitInputState();
}

class _SpeedLimitInputState extends State<_SpeedLimitInput> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    final kbps = widget.settingsProvider.speedLimitBytes ~/ 1024;
    _controller = TextEditingController(text: kbps == 0 ? '0' : '$kbps');
  }

  @override
  void didUpdateWidget(_SpeedLimitInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    final kbps = widget.settingsProvider.speedLimitBytes ~/ 1024;
    final current = int.tryParse(_controller.text) ?? 0;
    if (kbps != current) {
      _controller.text = kbps == 0 ? '0' : '$kbps';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onSubmit(String value) {
    final kbps = int.tryParse(value) ?? 0;
    widget.settingsProvider.setSpeedLimitBytes(kbps * 1024);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Row(
      children: [
        SizedBox(
          width: 120,
          child: ShadInput(
            controller: _controller,
            placeholder: const Text('0'),
            onSubmitted: _onSubmit,
            onChanged: _onSubmit,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          currentS.speedLimitUnit,
          style: TextStyle(fontSize: 12, color: c.textMuted),
        ),
      ],
    );
  }
}

/// 全局上传限速输入（仅作用于 BT 上传，含做种；KB/s 输入，0 = 不限）。
class _UploadLimitInput extends StatefulWidget {
  final SettingsProvider settingsProvider;

  const _UploadLimitInput({required this.settingsProvider});

  @override
  State<_UploadLimitInput> createState() => _UploadLimitInputState();
}

class _UploadLimitInputState extends State<_UploadLimitInput> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    final kbps = widget.settingsProvider.uploadLimitBytes ~/ 1024;
    _controller = TextEditingController(text: kbps == 0 ? '0' : '$kbps');
  }

  @override
  void didUpdateWidget(_UploadLimitInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    final kbps = widget.settingsProvider.uploadLimitBytes ~/ 1024;
    final current = int.tryParse(_controller.text) ?? 0;
    if (kbps != current) {
      _controller.text = kbps == 0 ? '0' : '$kbps';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onSubmit(String value) {
    final kbps = int.tryParse(value) ?? 0;
    widget.settingsProvider.setUploadLimitBytes(kbps * 1024);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Row(
      children: [
        SizedBox(
          width: 120,
          child: ShadInput(
            controller: _controller,
            placeholder: const Text('0'),
            onSubmitted: _onSubmit,
            onChanged: _onSubmit,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          currentS.speedLimitUnit,
          style: TextStyle(fontSize: 12, color: c.textMuted),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
// 失败自动重试
// ─────────────────────────────────────────────

/// 重试次数下拉：关闭(0) / 1 / 2 / 3 / 5 / 10 / 无限(-1)。
class _AutoRetryCountSelector extends StatelessWidget {
  final SettingsProvider settingsProvider;

  const _AutoRetryCountSelector({required this.settingsProvider});

  static const _options = [0, 1, 2, 3, 5, 10, -1];

  String _label(BuildContext context, int v) {
    final s = LocaleScope.of(context);
    if (v == 0) return s.autoRetryOff;
    if (v == -1) return s.autoRetryUnlimited;
    return s.nRetries(v);
  }

  @override
  Widget build(BuildContext context) {
    final current = settingsProvider.maxAutoRetries;
    return ShadSelect<int>(
      placeholder: Text(_label(context, current)),
      initialValue: current,
      options: _options
          .map((v) => ShadOption(value: v, child: Text(_label(context, v))))
          .toList(),
      selectedOptionBuilder: (context, value) => Text(_label(context, value)),
      onChanged: (v) {
        if (v != null) settingsProvider.setMaxAutoRetries(v);
      },
    );
  }
}

/// 重试间隔数字输入（秒，0 = 立即重试）。
class _AutoRetryDelayInput extends StatefulWidget {
  final SettingsProvider settingsProvider;

  const _AutoRetryDelayInput({required this.settingsProvider});

  @override
  State<_AutoRetryDelayInput> createState() => _AutoRetryDelayInputState();
}

class _AutoRetryDelayInputState extends State<_AutoRetryDelayInput> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: '${widget.settingsProvider.autoRetryDelaySecs}',
    );
  }

  @override
  void didUpdateWidget(_AutoRetryDelayInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    final secs = widget.settingsProvider.autoRetryDelaySecs;
    final current = int.tryParse(_controller.text) ?? 0;
    if (secs != current) {
      _controller.text = '$secs';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onSubmit(String value) {
    final secs = (int.tryParse(value) ?? 0).clamp(0, 3600);
    widget.settingsProvider.setAutoRetryDelaySecs(secs);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final s = LocaleScope.of(context);
    return Row(
      children: [
        SizedBox(
          width: 120,
          child: ShadInput(
            controller: _controller,
            placeholder: const Text('0'),
            onSubmitted: _onSubmit,
            onChanged: _onSubmit,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          s.autoRetryDelayUnit,
          style: TextStyle(fontSize: 12, color: c.textMuted),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
// 失焦提交型输入的卸载兜底
// ─────────────────────────────────────────────

/// 输入框带着未提交的编辑被销毁时的兜底提交。
///
/// 失焦提交依赖 [FocusNode] 的 listener，而组件被程序性卸载时（浏览器扩展
/// 推来新下载导致设置页自动切回首页等）全程没有指针事件，不会触发失焦；
/// 卸载时输入框内层的 `Focus` 又先于外层 `State.dispose` 摘掉焦点，
/// [FocusNode.dispose] 时节点已脱离焦点树、其 `_notify` 提前返回——两条路
/// 都通知不到 listener，未提交的编辑就此静默丢失（#266 的残留面）。
///
/// 所以调用方**不能**用 `hasFocus` 判断「用户是否正在编辑」（dispose 时它
/// 恒为 false），只能比对输入框文本与已生效值：不等即说明有未提交的编辑。
///
/// 提交推迟到下一帧：卸载发生在 build/unmount 阶段，此时直接调用 provider
/// 的 setter 会经 `notifyListeners` 触发别处 `setState`，命中
/// 「setState() called during build」断言。
///
/// 待提交的值必须在 dispose 里**先取出**再传入闭包——回调执行时 controller
/// 已经 dispose，闭包内不可再读它。
void _commitOnUnmount(VoidCallback commit) {
  WidgetsBinding.instance.addPostFrameCallback((_) => commit());
}

// ─────────────────────────────────────────────
// UA 编辑器
// ─────────────────────────────────────────────

class _UserAgentEditor extends StatefulWidget {
  final SettingsProvider settingsProvider;

  const _UserAgentEditor({required this.settingsProvider});

  @override
  State<_UserAgentEditor> createState() => _UserAgentEditorState();
}

class _UserAgentEditorState extends State<_UserAgentEditor> {
  late TextEditingController _controller;
  late FocusNode _focusNode;
  late String _selectedPreset;

  @override
  void initState() {
    super.initState();
    final ua = widget.settingsProvider.globalUserAgent;
    _controller = TextEditingController(text: ua);
    _selectedPreset = detectUaPreset(ua);
    _focusNode = FocusNode();
    _focusNode.addListener(() {
      // 失焦时持久化（与 _FileManagerCmdInput 一致），避免未回车直接离开
      // 设置页导致刚输入的自定义 UA 被丢弃（#266）
      if (!_focusNode.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_UserAgentEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ua = widget.settingsProvider.globalUserAgent;
    // 仅在未聚焦（用户未编辑）时才用外部值回填，避免编辑过程中被外部
    // rebuild 回灌旧值
    if (!_focusNode.hasFocus && ua != _controller.text) {
      _controller.text = ua;
      _selectedPreset = detectUaPreset(ua);
    }
  }

  @override
  void dispose() {
    // 失焦提交在程序性卸载时不会触发（见 _commitOnUnmount），文本与已生效
    // 值不等即说明有未提交的编辑，按值兜底一次。
    final ua = _controller.text;
    final sp = widget.settingsProvider;
    if (ua != sp.globalUserAgent) {
      _commitOnUnmount(() => sp.setGlobalUserAgent(ua));
    }
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onPresetChanged(String? preset) {
    if (preset == null) return;
    setState(() => _selectedPreset = preset);
    if (preset != 'custom') {
      // 'default' 不在 kUaPresets 中，映射为空字符串（引擎内置 UA）
      final ua = kUaPresets[preset] ?? '';
      _controller.text = ua;
      widget.settingsProvider.setGlobalUserAgent(ua);
    }
  }

  void _onTextChanged(String value) {
    // 手动编辑时切换到 custom
    final detected = detectUaPreset(value);
    if (detected != _selectedPreset) {
      setState(() => _selectedPreset = detected);
    }
  }

  void _commit() {
    widget.settingsProvider.setGlobalUserAgent(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final s = LocaleScope.of(context);
    return Row(
      children: [
        SizedBox(
          width: 150,
          child: ShadSelect<String>(
            initialValue: _selectedPreset,
            options: [
              ShadOption(
                value: 'default',
                child: Text(s.userAgentPresetDefault),
              ),
              ShadOption(value: 'chrome', child: Text(s.userAgentPresetChrome)),
              ShadOption(
                value: 'firefox',
                child: Text(s.userAgentPresetFirefox),
              ),
              ShadOption(value: 'edge', child: Text(s.userAgentPresetEdge)),
              ShadOption(value: 'safari', child: Text(s.userAgentPresetSafari)),
              ShadOption(value: 'custom', child: Text(s.userAgentPresetCustom)),
            ],
            selectedOptionBuilder: (context, value) {
              final label = switch (value) {
                'default' => s.userAgentPresetDefault,
                'chrome' => 'Chrome',
                'firefox' => 'Firefox',
                'edge' => 'Edge',
                'safari' => 'Safari',
                _ => s.userAgentPresetCustom,
              };
              return Text(label, overflow: TextOverflow.ellipsis, maxLines: 1);
            },
            onChanged: _onPresetChanged,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: ShadInput(
            controller: _controller,
            focusNode: _focusNode,
            placeholder: Text(s.userAgentPlaceholder),
            onChanged: _onTextChanged,
            onSubmitted: (_) => _commit(),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
// 文件管理器自定义命令输入
// ─────────────────────────────────────────────

/// 让用户填写第三方文件管理器的命令模板。
/// 提交时机：失焦或回车（与 UA 编辑器一致），避免每次按键写盘。
class _FileManagerCmdInput extends StatefulWidget {
  final SettingsProvider settingsProvider;

  const _FileManagerCmdInput({required this.settingsProvider});

  @override
  State<_FileManagerCmdInput> createState() => _FileManagerCmdInputState();
}

class _FileManagerCmdInputState extends State<_FileManagerCmdInput> {
  late TextEditingController _controller;
  late FocusNode _focusNode;

  String get _currentValue => widget.settingsProvider.revealFileCmd;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _currentValue);
    _focusNode = FocusNode();
    _focusNode.addListener(() {
      // 失焦时持久化（与 UA 编辑器交互一致）
      if (!_focusNode.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_FileManagerCmdInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 仅在未聚焦（用户未编辑）时才用外部值回填，避免用户清空/编辑过程中被
    // 外部 rebuild 回灌旧值，导致无法清空、无法重置为默认（留空=平台默认）。
    if (!_focusNode.hasFocus && _currentValue != _controller.text) {
      _controller.text = _currentValue;
    }
  }

  @override
  void dispose() {
    // 失焦提交在程序性卸载时不会触发（见 _commitOnUnmount），按值兜底一次。
    final cmd = _controller.text;
    final sp = widget.settingsProvider;
    if (cmd != sp.revealFileCmd) {
      _commitOnUnmount(() => sp.setRevealFileCmd(cmd));
    }
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _commit() {
    widget.settingsProvider.setRevealFileCmd(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final s = LocaleScope.of(context);
    final placeholder = s.revealFileCmdPlaceholder;
    return ShadInput(
      controller: _controller,
      focusNode: _focusNode,
      placeholder: Text(placeholder),
      onSubmitted: (_) => _commit(),
    );
  }
}

// ─────────────────────────────────────────────
// 代理设置子组件
// ─────────────────────────────────────────────

/// 代理设置卡片（模式选择 + 手动配置表单）
class _ProxySettingsCard extends StatefulWidget {
  final SettingsProvider settingsProvider;

  const _ProxySettingsCard({required this.settingsProvider});

  @override
  State<_ProxySettingsCard> createState() => _ProxySettingsCardState();
}

class _ProxySettingsCardState extends State<_ProxySettingsCard> {
  late TextEditingController _hostController;
  late TextEditingController _portController;
  late TextEditingController _usernameController;
  late TextEditingController _passwordController;
  late TextEditingController _noListController;

  // 代理测试状态: null=未测试, true=成功, false=失败
  bool? _testResult;
  bool _isTesting = false;
  int _testLatencyMs = 0;
  String _testError = '';
  StreamSubscription<RustSignalPack<ProxyTestResult>>? _testSub;

  // 系统代理检测状态
  bool _sysProxyDetecting = false;
  bool _sysProxyDetected = false;
  String _sysProxyType = '';
  String _sysProxyHost = '';
  String _sysProxyPort = '';
  String _sysProxyNoList = '';
  StreamSubscription<RustSignalPack<SystemProxyInfo>>? _sysProxySub;

  @override
  void initState() {
    super.initState();
    final sp = widget.settingsProvider;
    _hostController = TextEditingController(text: sp.proxyHost);
    _portController = TextEditingController(text: sp.proxyPort);
    _usernameController = TextEditingController(text: sp.proxyUsername);
    _passwordController = TextEditingController(text: sp.proxyPassword);
    _noListController = TextEditingController(text: sp.proxyNoList);
    _testSub = ProxyTestResult.rustSignalStream.listen(_onTestResult);
    _sysProxySub = SystemProxyInfo.rustSignalStream.listen(_onSysProxyResult);
    // 如果当前就是系统代理模式，立即请求检测
    if (sp.proxyMode == 'system') {
      _requestDetectSystemProxy();
    }
  }

  @override
  void didUpdateWidget(_ProxySettingsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sp = widget.settingsProvider;
    // 仅在外部值变化时同步（例如从 Rust 端加载初始值）
    if (sp.proxyHost != _hostController.text) {
      _hostController.text = sp.proxyHost;
    }
    if (sp.proxyPort != _portController.text) {
      _portController.text = sp.proxyPort;
    }
    if (sp.proxyUsername != _usernameController.text) {
      _usernameController.text = sp.proxyUsername;
    }
    if (sp.proxyPassword != _passwordController.text) {
      _passwordController.text = sp.proxyPassword;
    }
    if (sp.proxyNoList != _noListController.text) {
      _noListController.text = sp.proxyNoList;
    }
  }

  void _onTestResult(RustSignalPack<ProxyTestResult> pack) {
    if (!mounted) return;
    final msg = pack.message;
    setState(() {
      _isTesting = false;
      _testResult = msg.success;
      _testLatencyMs = msg.latencyMs.toInt();
      _testError = msg.errorMessage;
    });
  }

  void _testProxy() {
    final sp = widget.settingsProvider;
    if (sp.proxyHost.isEmpty || sp.proxyPort.isEmpty) return;
    setState(() {
      _isTesting = true;
      _testResult = null;
    });
    TestProxyConnection(
      proxyType: sp.proxyType,
      proxyHost: sp.proxyHost,
      proxyPort: sp.proxyPort,
      proxyUsername: sp.proxyUsername,
      proxyPassword: sp.proxyPassword,
    ).sendSignalToRust();
  }

  void _requestDetectSystemProxy() {
    setState(() {
      _sysProxyDetecting = true;
      _sysProxyDetected = false;
    });
    DetectSystemProxy().sendSignalToRust();
  }

  void _onSysProxyResult(RustSignalPack<SystemProxyInfo> pack) {
    if (!mounted) return;
    final msg = pack.message;
    setState(() {
      _sysProxyDetecting = false;
      _sysProxyDetected = msg.detected;
      _sysProxyType = msg.proxyType;
      _sysProxyHost = msg.host;
      _sysProxyPort = msg.port;
      _sysProxyNoList = msg.noProxyList;
    });
  }

  @override
  void dispose() {
    _testSub?.cancel();
    _sysProxySub?.cancel();
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _noListController.dispose();
    super.dispose();
  }

  /// 开启代理前检查多 CDN 并发下载：该功能在代理启用时不生效，若已开启
  /// 则先提醒用户「开启代理将同时关闭该功能」，确认后关闭功能再切代理。
  void _selectProxyMode(BuildContext context, S s, String mode) {
    final sp = widget.settingsProvider;
    if (sp.proxyMode == mode) return;
    // auto 模式下直连任务仍保留多 CDN 加速，与 CDN 聚合不互斥，直接应用。
    if (!sp.cdnMultiEnabled || mode == 'auto') {
      _applyProxyMode(mode);
      return;
    }
    final c = AppColors.of(context);
    showShadDialog(
      context: context,
      barrierColor: c.dialogBarrier,
      animateIn: const [],
      animateOut: const [],
      builder: (ctx) => ShadDialog(
        title: Text(s.proxyCdnMultiConfirmTitle),
        description: Text(s.proxyCdnMultiConfirmDesc),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(s.cancel),
          ),
          ShadButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              widget.settingsProvider.setCdnMultiEnabled(false);
              _applyProxyMode(mode);
            },
            child: Text(s.proxyCdnMultiConfirmEnable),
          ),
        ],
      ),
    );
  }

  void _applyProxyMode(String mode) {
    widget.settingsProvider.setProxyMode(mode);
    if (mode == 'system') _requestDetectSystemProxy();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final m = AppMetrics.of(context);
    final s = LocaleScope.of(context);
    final sp = widget.settingsProvider;
    final isManual = sp.proxyMode == 'manual';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: m.brDialog,
        border: Border.all(color: m.borderMedium(c.border), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 代理模式选择
          Text(
            s.proxySettings,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: c.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            s.proxyBtNote,
            style: TextStyle(fontSize: 11.5, color: c.textMuted),
          ),
          const SizedBox(height: 12),
          Row(
            spacing: 8,
            children: [
              Expanded(
                child: _ProxyModeOption(
                  icon: LucideIcons.unplug,
                  label: s.proxyModeNone,
                  selected: sp.proxyMode == 'none',
                  colors: c,
                  onTap: () => sp.setProxyMode('none'),
                ),
              ),
              Expanded(
                child: _ProxyModeOption(
                  icon: LucideIcons.monitor,
                  label: s.proxyModeSystem,
                  selected: sp.proxyMode == 'system',
                  colors: c,
                  onTap: () => _selectProxyMode(context, s, 'system'),
                ),
              ),
              Expanded(
                child: _ProxyModeOption(
                  icon: LucideIcons.settings2,
                  label: s.proxyModeManual,
                  selected: sp.proxyMode == 'manual',
                  colors: c,
                  onTap: () => _selectProxyMode(context, s, 'manual'),
                ),
              ),
              Expanded(
                child: _ProxyModeOption(
                  icon: LucideIcons.sparkles,
                  label: s.proxyModeAuto,
                  selected: sp.proxyMode == 'auto',
                  colors: c,
                  onTap: () => _selectProxyMode(context, s, 'auto'),
                ),
              ),
            ],
          ),
          // 自动模式说明（默认直连零额外流量；直连慢且代理明显更快时按站点切换；
          // 直连任务保留多 CDN 加速）
          if (sp.proxyMode == 'auto') ...[
            const SizedBox(height: 16),
            Divider(height: 1, color: m.borderFaint(c.border)),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(LucideIcons.info, size: 14, color: c.textMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    s.proxyModeAutoDesc,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: c.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ],
          // 系统代理只读展示
          if (sp.proxyMode == 'system') ...[
            const SizedBox(height: 16),
            Divider(height: 1, color: m.borderFaint(c.border)),
            const SizedBox(height: 14),
            if (_sysProxyDetecting)
              Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: c.textMuted,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    s.proxySystemDetecting,
                    style: TextStyle(fontSize: 12, color: c.textMuted),
                  ),
                ],
              )
            else if (!_sysProxyDetected)
              Row(
                children: [
                  Icon(LucideIcons.info, size: 14, color: c.textMuted),
                  const SizedBox(width: 8),
                  Text(
                    s.proxySystemNotConfigured,
                    style: TextStyle(fontSize: 12, color: c.textMuted),
                  ),
                ],
              )
            else ...[
              Text(
                s.proxySystemDetected,
                style: TextStyle(fontSize: 11.5, color: c.textMuted),
              ),
              const SizedBox(height: 10),
              // 代理类型
              _ReadOnlyProxyField(
                label: s.proxyType,
                value: _sysProxyType.toUpperCase(),
                colors: c,
              ),
              const SizedBox(height: 8),
              // 地址 + 端口（与手动配置表单布局一致）
              Row(
                children: [
                  SizedBox(
                    width: 80,
                    child: Text(
                      s.proxyHost,
                      style: TextStyle(fontSize: 12, color: c.textSecondary),
                    ),
                  ),
                  Expanded(
                    child: _ReadOnlyValueBox(value: _sysProxyHost, colors: c),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 48,
                    child: Text(
                      s.proxyPort,
                      style: TextStyle(fontSize: 12, color: c.textSecondary),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  SizedBox(
                    width: 90,
                    child: _ReadOnlyValueBox(value: _sysProxyPort, colors: c),
                  ),
                ],
              ),
              if (_sysProxyNoList.isNotEmpty) ...[
                const SizedBox(height: 8),
                _ReadOnlyProxyField(
                  label: s.proxyNoList,
                  value: _sysProxyNoList,
                  colors: c,
                ),
              ],
            ],
          ],
          // 手动配置表单
          if (isManual) ...[
            const SizedBox(height: 16),
            Divider(height: 1, color: m.borderFaint(c.border)),
            const SizedBox(height: 14),
            // 代理类型
            Row(
              children: [
                SizedBox(
                  width: 80,
                  child: Text(
                    s.proxyType,
                    style: TextStyle(fontSize: 12, color: c.textSecondary),
                  ),
                ),
                Expanded(
                  child: ShadSelect<String>(
                    initialValue: sp.proxyType,
                    options: const [
                      ShadOption(value: 'http', child: Text('HTTP')),
                      ShadOption(value: 'https', child: Text('HTTPS')),
                      ShadOption(value: 'socks4', child: Text('SOCKS4')),
                      ShadOption(value: 'socks5', child: Text('SOCKS5')),
                    ],
                    selectedOptionBuilder: (context, value) =>
                        Text(value.toUpperCase()),
                    onChanged: (v) {
                      if (v != null) sp.setProxyType(v);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // 地址 + 端口
            Row(
              children: [
                SizedBox(
                  width: 80,
                  child: Text(
                    s.proxyHost,
                    style: TextStyle(fontSize: 12, color: c.textSecondary),
                  ),
                ),
                Expanded(
                  child: ShadInput(
                    controller: _hostController,
                    placeholder: Text(s.proxyHostPlaceholder),
                    onChanged: (v) => sp.setProxyHost(v),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 48,
                  child: Text(
                    s.proxyPort,
                    style: TextStyle(fontSize: 12, color: c.textSecondary),
                    textAlign: TextAlign.center,
                  ),
                ),
                SizedBox(
                  width: 90,
                  child: ShadInput(
                    controller: _portController,
                    placeholder: Text(s.proxyPortPlaceholder),
                    onChanged: (v) => sp.setProxyPort(v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // 用户名 + 密码
            Row(
              children: [
                SizedBox(
                  width: 80,
                  child: Text(
                    s.proxyUsername,
                    style: TextStyle(fontSize: 12, color: c.textSecondary),
                  ),
                ),
                Expanded(
                  child: ShadInput(
                    controller: _usernameController,
                    placeholder: Text(s.proxyUsernamePlaceholder),
                    onChanged: (v) => sp.setProxyUsername(v),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 70,
                  child: Text(
                    s.proxyPassword,
                    style: TextStyle(fontSize: 12, color: c.textSecondary),
                    textAlign: TextAlign.center,
                  ),
                ),
                Expanded(
                  child: ShadInput(
                    controller: _passwordController,
                    placeholder: Text(s.proxyPasswordPlaceholder),
                    obscureText: true,
                    onChanged: (v) => sp.setProxyPassword(v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // 排除列表
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 80,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      s.proxyNoList,
                      style: TextStyle(fontSize: 12, color: c.textSecondary),
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ShadInput(
                        controller: _noListController,
                        placeholder: Text(s.proxyNoListPlaceholder),
                        onChanged: (v) => sp.setProxyNoList(v),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        s.proxyNoListDesc,
                        style: TextStyle(fontSize: 10.5, color: c.textMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // 测试连接按钮 + 结果
            Row(
              children: [
                ShadButton.outline(
                  size: ShadButtonSize.sm,
                  enabled:
                      !_isTesting &&
                      sp.proxyHost.isNotEmpty &&
                      sp.proxyPort.isNotEmpty,
                  onPressed: _testProxy,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_isTesting)
                        SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: c.textSecondary,
                          ),
                        )
                      else
                        Icon(
                          LucideIcons.plugZap,
                          size: 13,
                          color: c.textSecondary,
                        ),
                      const SizedBox(width: 6),
                      Text(
                        _isTesting ? s.proxyTesting : s.proxyTestConnection,
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (_testResult != null)
                  Expanded(
                    child: Text(
                      _testResult!
                          ? s.proxyTestSuccess(_testLatencyMs)
                          : s.proxyTestFailed(
                              s.translateProxyTestError(_testError),
                            ),
                      style: TextStyle(
                        fontSize: 11.5,
                        color: _testResult!
                            ? const Color(0xFF22C55E)
                            : const Color(0xFFEF4444),
                      ),
                      // 失败提示可能是多句可执行建议（如 issue #183 的类型选错），
                      // 单行省略会把关键的「改选 HTTP」截掉。
                      maxLines: _testResult! ? 1 : 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 代理模式选项卡片（复用 _ThemeModeCard 的视觉风格）
class _ProxyModeOption extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final AppColors colors;
  final VoidCallback onTap;

  const _ProxyModeOption({
    required this.icon,
    required this.label,
    required this.selected,
    required this.colors,
    required this.onTap,
  });

  @override
  State<_ProxyModeOption> createState() => _ProxyModeOptionState();
}

class _ProxyModeOptionState extends State<_ProxyModeOption> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final c = widget.colors;
    final m = AppMetrics.of(context);
    final selected = widget.selected;
    final borderColor = selected ? theme.colorScheme.primary : c.border;
    final bgColor = selected
        ? m.subtle(theme.colorScheme.primary)
        : _isHovered
        ? c.hoverBg
        : c.bg;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: m.brCard,
            border: Border.all(color: borderColor, width: selected ? 1.5 : 1),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                widget.icon,
                size: 14,
                color: selected ? theme.colorScheme.primary : c.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? theme.colorScheme.primary : c.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 只读代理信息展示字段
class _ReadOnlyProxyField extends StatelessWidget {
  final String label;
  final String value;
  final AppColors colors;

  const _ReadOnlyProxyField({
    required this.label,
    required this.value,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final m = AppMetrics.of(context);
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
        ),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: colors.surface1,
              borderRadius: m.brMd,
              border: Border.all(
                color: colors.border.withValues(alpha: 0.4),
                width: 1,
              ),
            ),
            child: Text(
              value.isEmpty ? '—' : value,
              style: TextStyle(
                fontSize: 12,
                color: value.isEmpty ? colors.textMuted : colors.textPrimary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 只读代理值展示框（不带 label，用于 Row 内嵌布局）
class _ReadOnlyValueBox extends StatelessWidget {
  final String value;
  final AppColors colors;

  const _ReadOnlyValueBox({required this.value, required this.colors});

  @override
  Widget build(BuildContext context) {
    final m = AppMetrics.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: colors.surface1,
        borderRadius: m.brMd,
        border: Border.all(
          color: colors.border.withValues(alpha: 0.4),
          width: 1,
        ),
      ),
      child: Text(
        value.isEmpty ? '—' : value,
        style: TextStyle(
          fontSize: 12,
          color: value.isEmpty ? colors.textMuted : colors.textPrimary,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// API 服务子组件
// ─────────────────────────────────────────────

class _ApiServiceContent extends StatefulWidget {
  final SettingsProvider settingsProvider;

  const _ApiServiceContent({required this.settingsProvider});

  @override
  State<_ApiServiceContent> createState() => _ApiServiceContentState();
}

class _ApiServiceContentState extends State<_ApiServiceContent> {
  late TextEditingController _portController;
  late FocusNode _portFocusNode;
  late TextEditingController _tokenController;
  late FocusNode _tokenFocusNode;

  /// 本机非回环 IPv4 网卡快照，供开启局域网 / 组网访问后在地址预览里下拉切换。
  /// 网卡会随插拔 / 切网 / VPN 上下线变化，所以不是一次性探测：[_ifaceTicker]
  /// 每 5s 重采一次，列表未变时不 setState。
  List<LocalInterface> _localIps = const [];

  /// 用户在下拉里选中的展示主机；null = 未选过（跟随首个可用网卡）。
  String? _selectedHost;

  Timer? _ifaceTicker;

  static const String _loopback = LocalInterfaces.loopback;

  @override
  void initState() {
    super.initState();
    _portController = TextEditingController(
      text: widget.settingsProvider.localServerPort.toString(),
    );
    _portFocusNode = FocusNode()..addListener(_onPortFocusChange);
    _tokenController = TextEditingController(
      text: widget.settingsProvider.localServerToken,
    );
    _tokenFocusNode = FocusNode()..addListener(_onTokenFocusChange);
    unawaited(_loadLocalIps());
    _ifaceTicker = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_loadLocalIps()),
    );
  }

  @override
  void dispose() {
    // 失焦提交在程序性卸载时不会触发（见 _commitOnUnmount），按值兜底一次。
    // 非法端口直接丢弃——组件已经不在，既回退不了输入框也弹不出提示。
    final sp = widget.settingsProvider;
    final port = _parsePort(_portController.text);
    if (port != null && port != sp.localServerPort) {
      _commitOnUnmount(() => sp.setLocalServerPort(port));
    }
    final token = _tokenController.text.trim();
    if (token != sp.localServerToken) {
      _commitOnUnmount(() => sp.setLocalServerToken(token));
    }
    _ifaceTicker?.cancel();
    _portFocusNode.removeListener(_onPortFocusChange);
    _portFocusNode.dispose();
    _portController.dispose();
    _tokenFocusNode.removeListener(_onTokenFocusChange);
    _tokenFocusNode.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  void _onPortFocusChange() {
    if (!_portFocusNode.hasFocus) _commitPort();
  }

  /// 端口区间校验（1024-65535）；非法返回 null。
  static int? _parsePort(String raw) {
    final value = int.tryParse(raw.trim());
    if (value == null || value < 1024 || value > 65535) return null;
    return value;
  }

  /// 端口失焦/提交时校验 1024-65535；非法则回退为当前生效值
  void _commitPort() {
    final sp = widget.settingsProvider;
    final value = _parsePort(_portController.text);
    if (value == null) {
      setState(() => _portController.text = sp.localServerPort.toString());
      FluxSonner.of(context).show(
        ShadToast.destructive(
          title: Text(LocaleScope.of(context).apiServicePortInvalid),
        ),
      );
      return;
    }
    sp.setLocalServerPort(value);
  }

  /// 重采本机非回环 IPv4 网卡（枚举与排序见 [LocalInterfaces]）。列表未变且选
  /// 中项仍有效时直接返回，不触发重建；选中的网卡消失（拔网线 / 切 Wi-Fi /
  /// VPN 断开）时回落到「跟随首个网卡」。
  Future<void> _loadLocalIps() async {
    final ips = await LocalInterfaces.list();
    if (!mounted) return;
    final staleSelection =
        _selectedHost != null &&
        _selectedHost != _loopback &&
        !ips.any((e) => e.ip == _selectedHost);
    final unchanged =
        ips.length == _localIps.length &&
        Iterable<int>.generate(ips.length).every((i) => ips[i] == _localIps[i]);
    if (unchanged && !staleSelection) return;
    setState(() {
      _localIps = ips;
      if (staleSelection) _selectedHost = null;
    });
  }

  /// 下拉项文案：`IP · 网卡名`（回环为 `127.0.0.1 · 本机`）。同一 IP 出现在
  /// 多张网卡上时取首个匹配，够用且不至于让选项文案变成一串网卡名。
  String _hostLabel(S s, String host) {
    if (host == _loopback) return '$_loopback · ${s.apiServiceHostLoopback}';
    for (final e in _localIps) {
      if (e.ip == host) return '${e.ip} · ${e.name}';
    }
    return host;
  }

  void _onTokenFocusChange() {
    if (!_tokenFocusNode.hasFocus) _commitToken();
  }

  /// token 失焦提交：允许自定义任意值（含清空），去除首尾空白后持久化。
  void _commitToken() {
    final sp = widget.settingsProvider;
    final value = _tokenController.text.trim();
    if (value != _tokenController.text) _tokenController.text = value;
    if (value != sp.localServerToken) sp.setLocalServerToken(value);
  }

  /// 生成 32 位随机 hex token
  String _generateHexToken() {
    final r = Random.secure();
    return List<int>.generate(
      16,
      (_) => r.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> _copyToken() async {
    await Clipboard.setData(
      ClipboardData(text: widget.settingsProvider.localServerToken),
    );
    if (!mounted) return;
    FluxSonner.of(context).show(
      ShadToast(
        title: Text(LocaleScope.of(context).apiServiceCopied),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _clearToken() {
    widget.settingsProvider.clearLocalServerToken();
    if (!mounted) return;
    FluxSonner.of(context).show(
      ShadToast(
        title: Text(LocaleScope.of(context).apiServiceTokenCleared),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _confirmClearToken() {
    final sp = widget.settingsProvider;
    // token 已空且管理 API 未启用：无需确认，直接返回（按钮通常已禁用）。
    if (sp.localServerToken.isEmpty && !sp.localServerApiEnabled) return;
    // 管理 API 未依赖此令牌：直接清空，无需二次确认。
    if (!sp.localServerApiEnabled) {
      _clearToken();
      return;
    }
    final c = AppColors.of(context);
    final s = LocaleScope.of(context);
    showShadDialog(
      context: context,
      barrierColor: c.dialogBarrier,
      animateIn: const [],
      animateOut: const [],
      builder: (ctx) => ShadDialog(
        title: Text(s.apiServiceTokenClearConfirmTitle),
        description: Text(s.apiServiceTokenClearConfirmDesc),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(s.cancel),
          ),
          ShadButton.destructive(
            onPressed: () {
              Navigator.of(ctx).pop();
              _clearToken();
            },
            child: Text(s.apiServiceTokenClear),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.settingsProvider,
      builder: (context, _) {
        final c = AppColors.of(context);
        final m = AppMetrics.of(context);
        final s = LocaleScope.of(context);
        final sp = widget.settingsProvider;
        final enabled = sp.localServerEnabled;
        final committedPortText = sp.localServerPort.toString();
        // 未获焦时随外部配置变化同步（如首次加载配置完成）
        if (!_portFocusNode.hasFocus &&
            _portController.text != committedPortText) {
          _portController.text = committedPortText;
        }
        // token 未获焦时随外部配置变化同步（生成/清空/首次加载配置）
        if (!_tokenFocusNode.hasFocus &&
            _tokenController.text != sp.localServerToken) {
          _tokenController.text = sp.localServerToken;
        }
        // 地址预览随端口输入框实时更新，不等待失焦提交
        final typedPort = _portController.text.trim();
        final livePort = typedPort.isEmpty ? committedPortText : typedPort;
        // 关闭局域网访问时服务只绑回环，地址预览必须固定回环；开启后默认展示
        // 首个可用网卡，用户可在下拉里改（仅影响展示，实际监听恒为 0.0.0.0）。
        final lanOn = enabled && sp.localServerLanEnabled;
        final hostOptions = lanOn
            ? [_loopback, ..._localIps.map((e) => e.ip)]
            : const [_loopback];
        final liveHost = lanOn && hostOptions.contains(_selectedHost)
            ? _selectedHost!
            : (lanOn && _localIps.isNotEmpty ? _localIps.first.ip : _loopback);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: c.surface1,
                borderRadius: m.brDialog,
                border: Border.all(color: m.borderMedium(c.border), width: 1),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 标题 + 描述
                  Text(
                    s.apiServiceEnable,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: c.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    s.apiServiceEnableDesc,
                    style: TextStyle(fontSize: 11.5, color: c.textMuted),
                  ),
                  const SizedBox(height: 12),
                  // 总开关
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          s.apiServiceEnable,
                          style: TextStyle(fontSize: 13, color: c.textPrimary),
                        ),
                      ),
                      ShadSwitch(
                        value: enabled,
                        onChanged: (v) => sp.setLocalServerEnabled(v),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Divider(height: 1, color: m.borderFaint(c.border)),
                  const SizedBox(height: 14),
                  // 端口行
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s.apiServicePort,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: enabled ? c.textPrimary : c.textDisabled,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              s.apiServicePortDesc,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: enabled ? c.textMuted : c.textDisabled,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 120,
                        child: ShadInput(
                          controller: _portController,
                          focusNode: _portFocusNode,
                          enabled: enabled,
                          keyboardType: TextInputType.number,
                          onChanged: (_) => setState(() {}),
                          onSubmitted: (_) => _commitPort(),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // Token 行
                  Text(
                    s.apiServiceToken,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: enabled ? c.textPrimary : c.textDisabled,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    s.apiServiceTokenDesc,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: enabled ? c.textMuted : c.textDisabled,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    spacing: 8,
                    children: [
                      Expanded(
                        child: ShadInput(
                          controller: _tokenController,
                          focusNode: _tokenFocusNode,
                          enabled: enabled,
                          onSubmitted: (_) => _commitToken(),
                        ),
                      ),
                      ShadButton.outline(
                        size: ShadButtonSize.sm,
                        enabled: enabled,
                        onPressed: () {
                          final t = _generateHexToken();
                          _tokenController.text = t;
                          sp.setLocalServerToken(t);
                        },
                        child: Text(s.apiServiceTokenGenerate),
                      ),
                      ShadButton.outline(
                        size: ShadButtonSize.sm,
                        enabled: enabled && sp.localServerToken.isNotEmpty,
                        onPressed: _copyToken,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(LucideIcons.copy, size: 13),
                            const SizedBox(width: 4),
                            Text(s.apiServiceCopy),
                          ],
                        ),
                      ),
                      ShadButton.outline(
                        size: ShadButtonSize.sm,
                        enabled:
                            enabled &&
                            (sp.localServerToken.isNotEmpty ||
                                sp.localServerApiEnabled),
                        onPressed: _confirmClearToken,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(LucideIcons.eraser, size: 13),
                            const SizedBox(width: 4),
                            Text(s.apiServiceTokenClear),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Divider(height: 1, color: m.borderFaint(c.border)),
                  const SizedBox(height: 14),
                  // 允许局域网 / 组网访问：免账号本地配对的响应方需被对端访问，
                  // 跨网络（VPN/组网）时须绑 0.0.0.0；内网穿透至回环则无需开启。
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s.apiServiceLanEnable,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: enabled ? c.textPrimary : c.textDisabled,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              s.apiServiceLanEnableDesc,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: c.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      ShadSwitch(
                        value: sp.localServerLanEnabled,
                        enabled: enabled,
                        onChanged: enabled
                            ? (v) {
                                sp.setLocalServerLanEnabled(v);
                                // 刚开启时立刻补一次网卡快照，不等 5s ticker。
                                if (v) unawaited(_loadLocalIps());
                              }
                            : null,
                      ),
                    ],
                  ),
                  if (lanOn) ...[
                    const SizedBox(height: 12),
                    // 网卡选择：下方各功能地址跟随此处选中的 IP。实际监听恒为
                    // 0.0.0.0，这里只决定「拿哪个地址给对端用」。
                    Row(
                      children: [
                        SizedBox(
                          width: 56,
                          child: Text(
                            s.apiServiceHost,
                            style: TextStyle(
                              fontSize: 12,
                              color: c.textSecondary,
                            ),
                          ),
                        ),
                        Expanded(
                          child: ShadSelect<String>(
                            // 网卡列表变化时重建，避免内部选中态残留已消失的 IP。
                            key: ValueKey('api-host-${hostOptions.join(',')}'),
                            initialValue: liveHost,
                            options: [
                              for (final host in hostOptions)
                                ShadOption(
                                  value: host,
                                  child: Text(_hostLabel(s, host)),
                                ),
                            ],
                            selectedOptionBuilder: (context, value) =>
                                Text(_hostLabel(s, value)),
                            onChanged: (v) {
                              if (v != null) setState(() => _selectedHost = v);
                            },
                          ),
                        ),
                      ],
                    ),
                    if (_localIps.isEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        s.apiServiceHostNone,
                        style: TextStyle(fontSize: 11.5, color: c.textMuted),
                      ),
                    ],
                  ],
                  const SizedBox(height: 14),
                  Divider(height: 1, color: m.borderFaint(c.border)),
                  const SizedBox(height: 14),
                  // 允许任意来源跨域：默认关闭时本服务不回任何 Access-Control-*
                  // 头，网页的跨域 fetch 在预检就被浏览器拦下（这正是挡住恶意
                  // 网页的那道门）。部分网站把「aria2 探活」写死成浏览器
                  // fetch，必须开这个开关才能识别到本机服务。
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  s.apiServiceCorsAllowAll,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    color: enabled
                                        ? c.textPrimary
                                        : c.textDisabled,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                ShadTooltip(
                                  waitDuration: const Duration(
                                    milliseconds: 200,
                                  ),
                                  effects: const [],
                                  builder: (_) => ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 360,
                                    ),
                                    child: Text(
                                      s.apiServiceCorsAllowAllHelp,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        height: 1.6,
                                      ),
                                    ),
                                  ),
                                  child: ShadGestureDetector(
                                    cursor: SystemMouseCursors.help,
                                    onTap: () {},
                                    child: Icon(
                                      LucideIcons.circleHelp,
                                      size: 13,
                                      color: c.textMuted,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              s.apiServiceCorsAllowAllDesc,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: c.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      ShadSwitch(
                        value: sp.localServerCorsAllowAll,
                        enabled: enabled,
                        onChanged: enabled
                            ? (v) => sp.setLocalServerCorsAllowAll(v)
                            : null,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _HighlightRegion(
              label: s.apiServiceFeaturesTitle,
              description: s.apiServiceFeaturesDesc,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      s.apiServiceFeaturesTitle,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: c.textPrimary,
                      ),
                    ),
                  ),
                  Text(
                    s.apiServiceFeaturesDesc,
                    style: TextStyle(fontSize: 11.5, color: c.textMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            _ApiSubFeatureCard(
              masterEnabled: enabled,
              label: s.apiServiceTakeover,
              description: s.apiServiceTakeoverDesc,
              value: sp.localServerTakeoverEnabled,
              onChanged: (v) => sp.setLocalServerTakeoverEnabled(v),
              address: 'http://$liveHost:$livePort',
              extra: _CopyUserscriptButton(enabled: enabled),
            ),
            const SizedBox(height: 10),
            _ApiSubFeatureCard(
              masterEnabled: enabled,
              label: s.apiServiceJsonrpc,
              description: s.apiServiceJsonrpcDesc,
              value: sp.localServerJsonrpcEnabled,
              onChanged: (v) => sp.setLocalServerJsonrpcEnabled(v),
              address: 'http://$liveHost:$livePort/jsonrpc',
            ),
            const SizedBox(height: 10),
            _ApiSubFeatureCard(
              masterEnabled: enabled,
              label: s.apiServiceApi,
              description: s.apiServiceApiDesc,
              value: sp.localServerApiEnabled,
              onChanged: (v) => sp.setLocalServerApiEnabled(v),
              address: 'http://$liveHost:$livePort/api/v1',
            ),
            const SizedBox(height: 10),
            _ApiSubFeatureCard(
              masterEnabled: enabled,
              label: s.apiServiceMcp,
              description: s.apiServiceMcpDesc,
              value: sp.localServerMcpEnabled,
              onChanged: (v) => sp.setLocalServerMcpEnabled(v),
              address: 'http://$liveHost:$livePort/mcp',
            ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────
// 通知（系统通知 + Webhook 推送）
// ─────────────────────────────────────────────

class _NotifyContent extends StatefulWidget {
  final SettingsProvider settingsProvider;
  final DownloadController? downloadController;

  const _NotifyContent({
    required this.settingsProvider,
    this.downloadController,
  });

  @override
  State<_NotifyContent> createState() => _NotifyContentState();
}

class _NotifyContentState extends State<_NotifyContent> {
  /// 页面局部 Provider：投递日志/预设目录只在这一页用得到，没必要挂到 App 根。
  late final WebhookProvider _webhook = WebhookProvider();

  /// 处于「再点一次就删」窗口的端点 id；[_confirmTimer] 到点自动还原。
  String _pendingDeleteId = '';
  Timer? _confirmTimer;

  @override
  void initState() {
    super.initState();
    _webhook.refresh();
  }

  @override
  void dispose() {
    _confirmTimer?.cancel();
    _webhook.dispose();
    super.dispose();
  }

  /// 打开推送记录抽屉；先拉一次最新快照（引擎内存态，UI 无法自己推断）。
  /// 端点表一并传进去：记录里只有 ID，展示名和筛选下拉都要靠它。
  void _openLog(String endpointId) {
    _webhook.refresh();
    showWebhookDeliveryPanel(
      context: context,
      webhook: _webhook,
      endpoints: widget.settingsProvider.webhookEndpoints,
      endpointId: endpointId,
    );
  }

  Future<void> _openDialog({WebhookEndpoint? initial}) async {
    final saved = await showWebhookEndpointDialog(
      context: context,
      webhook: _webhook,
      queues: widget.downloadController?.queues ?? const [],
      initial: initial,
    );
    if (saved == null || !mounted) return;
    widget.settingsProvider.upsertWebhookEndpoint(saved);
  }

  /// 原地二次确认：首次点击进入 2s 确认窗口，超时自动还原——低成本防错，
  /// 不弹对话框打断心流。
  void _armOrDelete(WebhookEndpoint endpoint) {
    if (_pendingDeleteId == endpoint.id) {
      _confirmTimer?.cancel();
      setState(() => _pendingDeleteId = '');
      widget.settingsProvider.removeWebhookEndpoint(endpoint.id);
      return;
    }
    _confirmTimer?.cancel();
    setState(() => _pendingDeleteId = endpoint.id);
    _confirmTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _pendingDeleteId = '');
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.settingsProvider, _webhook]),
      builder: (context, _) {
        final s = LocaleScope.of(context);
        final c = AppColors.of(context);
        final sp = widget.settingsProvider;
        final endpoints = sp.webhookEndpoints;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SettingsGroup(
              title: s.notifyGroupSystem,
              children: [
                _SettingRow(
                  label: s.notifyOnComplete,
                  description: s.notifyOnCompleteDesc,
                  child: ShadSwitch(
                    value: sp.notifyOnComplete,
                    onChanged: (v) => sp.setNotifyOnComplete(v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _buildWebhookHeader(s, c),
            const SizedBox(height: 8),
            if (endpoints.isEmpty)
              _buildEmptyCard(s, c)
            else
              WebhookEndpointList(
                endpoints: endpoints,
                webhook: _webhook,
                pendingDeleteId: _pendingDeleteId,
                onToggle: (e, v) =>
                    sp.upsertWebhookEndpoint(e.copyWith(enabled: v)),
                onTest: (e) {
                  // 行内「测试」直接打日志抽屉：结果一条条落在日志里，
                  // 比一个转瞬即逝的 toast 有用得多。
                  _webhook.testEndpoint(e);
                  _openLog(e.id);
                },
                onLogs: (e) => _openLog(e.id),
                onEdit: (e) => _openDialog(initial: e),
                onDelete: _armOrDelete,
              ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                s.webhookSemantics,
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.6,
                  color: c.textMuted,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildWebhookHeader(S s, AppColors c) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Row(
        children: [
          Expanded(
            child: _HighlightRegion(
              label: s.notifyGroupWebhook,
              description: s.webhookEmptyDesc,
              child: Text(
                s.notifyGroupWebhook,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: c.textSecondary,
                ),
              ),
            ),
          ),
          ShadButton.ghost(
            size: ShadButtonSize.sm,
            onPressed: () => _openLog(''),
            child: Text(s.webhookDeliveryLog),
          ),
          const SizedBox(width: 6),
          ShadButton(
            size: ShadButtonSize.sm,
            onPressed: () => _openDialog(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(LucideIcons.plus, size: 13),
                const SizedBox(width: 4),
                Text(s.webhookAddEndpoint),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 空态不是空白：说明 + 主按钮，identity 建立在第一次接触时。
  Widget _buildEmptyCard(S s, AppColors c) {
    final m = AppMetrics.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: m.brDialog,
        border: Border.all(color: m.borderMedium(c.border), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.webhookEmptyTitle,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: c.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            s.webhookEmptyDesc,
            style: TextStyle(fontSize: 11.5, height: 1.6, color: c.textMuted),
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: ShadButton(
              size: ShadButtonSize.sm,
              onPressed: () => _openDialog(),
              child: Text(s.webhookAddEndpoint),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「功能开关」分组下的单个子功能卡片：标题+描述+开关 与 只读地址+复制 两行。
/// [masterEnabled] 为 false 时整卡禁用置灰（跟随总开关，无需重启提示）。
class _ApiSubFeatureCard extends StatelessWidget {
  final bool masterEnabled;
  final String label;
  final String description;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String address;
  final Widget? extra;

  const _ApiSubFeatureCard({
    required this.masterEnabled,
    required this.label,
    required this.description,
    required this.value,
    required this.onChanged,
    required this.address,
    this.extra,
  });

  Future<void> _copyAddress(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: address));
    if (!context.mounted) return;
    FluxSonner.of(context).show(
      ShadToast(
        title: Text(LocaleScope.of(context).apiServiceCopied),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final m = AppMetrics.of(context);
    final s = LocaleScope.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: m.brDialog,
        border: Border.all(color: m.borderMedium(c.border), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: masterEnabled ? c.textPrimary : c.textDisabled,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: masterEnabled ? c.textMuted : c.textDisabled,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              ShadSwitch(
                value: value,
                enabled: masterEnabled,
                onChanged: onChanged,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              SizedBox(
                width: 56,
                child: Text(
                  s.apiServiceAddress,
                  style: TextStyle(
                    fontSize: 12,
                    color: masterEnabled ? c.textSecondary : c.textDisabled,
                  ),
                ),
              ),
              Expanded(
                child: _ReadOnlyValueBox(value: address, colors: c),
              ),
              const SizedBox(width: 8),
              ShadButton.outline(
                size: ShadButtonSize.sm,
                enabled: masterEnabled,
                onPressed: () => _copyAddress(context),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.copy, size: 13),
                    const SizedBox(width: 4),
                    Text(s.apiServiceCopy),
                  ],
                ),
              ),
            ],
          ),
          if (extra != null) ...[const SizedBox(height: 10), extra!],
        ],
      ),
    );
  }
}

/// 复制内置油猴脚本到剪贴板（浏览器脚本接管子功能的便捷入口）
class _CopyUserscriptButton extends StatelessWidget {
  final bool enabled;

  const _CopyUserscriptButton({required this.enabled});

  Future<void> _copy(BuildContext context) async {
    final s = LocaleScope.of(context);
    try {
      final script = await rootBundle.loadString('userscript/fluxdown.user.js');
      await Clipboard.setData(ClipboardData(text: script));
      if (!context.mounted) return;
      FluxSonner.of(context).show(
        ShadToast(
          title: Text(s.apiServiceScriptCopied),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      FluxSonner.of(
        context,
      ).show(ShadToast.destructive(title: Text('Error: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ShadButton.outline(
      size: ShadButtonSize.sm,
      enabled: enabled,
      onPressed: () => _copy(context),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.code, size: 13),
          const SizedBox(width: 4),
          Text(LocaleScope.of(context).apiServiceCopyScript),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 组件管理（v1 仅 ffmpeg）
// ─────────────────────────────────────────────

/// 组件设置分类 body：ffmpeg 状态展示 + 手动路径 + 托管安装/卸载。
///
/// ffmpeg 是可选的外部工具，由官方源按需下载，不随安装包分发；用于合并
/// 音视频轨（DASH/轨对任务）。内部持有独立的 [FfmpegController] 实例
/// （随本 widget 生命周期创建/销毁），进入本分类时自动请求一次状态 +
/// 版本列表（懒加载，无需额外按钮）。
/// 组件卡片类型：决定使用哪个 [ComponentController] 与标题/描述文案。
enum _ComponentKind { ffmpeg, ytdlp }

class _ComponentsContent extends StatefulWidget {
  final _ComponentKind kind;
  const _ComponentsContent({super.key, required this.kind});

  @override
  State<_ComponentsContent> createState() => _ComponentsContentState();
}

class _ComponentsContentState extends State<_ComponentsContent> {
  late final ComponentController _provider;
  late final TextEditingController _pathController;
  late final FocusNode _pathFocusNode;
  String? _selectedVersion;
  int _lastInstallResultSeq = -1;
  String _pendingOp = '';
  bool _versionsRequested = false;

  @override
  void initState() {
    super.initState();
    _provider = widget.kind == _ComponentKind.ffmpeg
        ? FfmpegController()
        : YtdlpController();
    _lastInstallResultSeq = _provider.installResultSeq;
    _pathController = TextEditingController(text: _provider.manualPath);
    _pathFocusNode = FocusNode();
    _provider.addListener(_onProviderChanged);
    _provider.requestStatus();
    // 版本列表懒加载：仅在状态回流确认本平台支持托管安装后再拉取，
    // 避免 macOS 等不支持平台每次进页都发起注定失败的请求并弹错。
    if (_provider.hasStatus && _provider.managedSupported) {
      _versionsRequested = true;
      _provider.requestVersions();
    }
  }

  @override
  void dispose() {
    _provider.removeListener(_onProviderChanged);
    _provider.dispose();
    _pathController.dispose();
    _pathFocusNode.dispose();
    super.dispose();
  }

  void _onProviderChanged() {
    if (!mounted) return;
    // 手动路径框跟随 provider（ConfigLoaded 回流）刷新，但用户正在编辑
    // 时不打断（与 UA/端口编辑器一致的失焦提交护栏）。
    if (!_pathFocusNode.hasFocus &&
        _pathController.text != _provider.manualPath) {
      _pathController.text = _provider.manualPath;
    }
    if (_selectedVersion == null && _provider.latestStable.isNotEmpty) {
      _selectedVersion = _provider.latestStable;
    }
    // 状态回流后若确认平台支持托管安装且尚未拉过版本列表，懒拉一次。
    if (!_versionsRequested &&
        _provider.hasStatus &&
        _provider.managedSupported) {
      _versionsRequested = true;
      _provider.requestVersions();
    }
    final seq = _provider.installResultSeq;
    if (seq != _lastInstallResultSeq) {
      _lastInstallResultSeq = seq;
      if (_provider.lastResultOk != null) {
        _showInstallResultToast(
          _provider.lastResultOk!,
          _provider.lastResultMessage,
        );
      }
      _pendingOp = '';
    }
    setState(() {});
  }

  void _showInstallResultToast(bool ok, String message) {
    final s = LocaleScope.of(context);
    final isUninstall = _pendingOp == 'uninstall';
    final name = _title(s);
    if (ok) {
      FluxSonner.of(context).show(
        ShadToast(
          title: Text(
            isUninstall
                ? s.componentsUninstallSuccess(name)
                : s.componentsInstallSuccess(name),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    FluxSonner.of(context).show(
      ShadToast.destructive(
        title: Text(
          isUninstall
              ? s.componentsUninstallFailed(message)
              : s.componentsInstallFailed(message),
        ),
      ),
    );
  }

  void _saveManualPath() =>
      _provider.saveManualPath(_pathController.text.trim());

  void _clearManualPath() {
    _pathController.clear();
    _provider.saveManualPath('');
  }

  void _install() {
    _pendingOp = 'install';
    _provider.install(_selectedVersion ?? '');
  }

  void _confirmUninstall() {
    final s = LocaleScope.of(context);
    final name = _title(s);
    final c = AppColors.of(context);
    showShadDialog(
      context: context,
      barrierColor: c.dialogBarrier,
      animateIn: const [],
      animateOut: const [],
      builder: (ctx) => ShadDialog(
        title: Text(s.componentsUninstallConfirmTitle(name)),
        description: Text(s.componentsUninstallConfirmMsg(name)),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(s.cancel),
          ),
          ShadButton.destructive(
            onPressed: () {
              Navigator.of(ctx).pop();
              _pendingOp = 'uninstall';
              _provider.uninstall();
            },
            child: Text(s.componentsUninstallButton),
          ),
        ],
      ),
    );
  }

  String _sourceLabel(S s, String source) => switch (source) {
    'manual' => s.componentsSourceManual,
    'managed' => s.componentsSourceManaged,
    _ => s.componentsSourceSystem,
  };

  String _title(S s) => widget.kind == _ComponentKind.ffmpeg
      ? s.componentsFfmpegTitle
      : s.componentsYtdlpTitle;
  String _desc(S s) => widget.kind == _ComponentKind.ffmpeg
      ? s.componentsFfmpegDesc
      : s.componentsYtdlpDesc;

  @override
  Widget build(BuildContext context) {
    final s = LocaleScope.of(context);
    final c = AppColors.of(context);
    final m = AppMetrics.of(context);
    final hasManaged =
        _provider.hasStatus && _provider.managedVersion.isNotEmpty;

    return _ComponentAccordionCard(
      label: _title(s),
      description: _desc(s),
      summary: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildStatusRow(c, s),
          const SizedBox(height: 8),
          _buildSystemPathRow(c, s),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          Divider(height: 1, color: m.borderFaint(c.border)),
          const SizedBox(height: 16),
          _buildManualPathSection(c, s),
          const SizedBox(height: 16),
          Divider(height: 1, color: m.borderFaint(c.border)),
          const SizedBox(height: 16),
          _buildInstallSection(context, c, s, hasManaged),
        ],
      ),
    );
  }

  Widget _buildStatusRow(AppColors c, S s) {
    if (!_provider.hasStatus) {
      return Row(
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: c.textSecondary,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            s.componentsStatusLoading,
            style: TextStyle(fontSize: 12, color: c.textMuted),
          ),
        ],
      );
    }
    if (_provider.source == 'none') {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.circleAlert, size: 14, color: AppColors.amber),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _provider.managedSupported
                  ? s.componentsStatusNotFound(_title(s))
                  : s.componentsStatusNotFoundUnsupported(_title(s)),
              style: TextStyle(fontSize: 12, color: c.textPrimary),
            ),
          ),
        ],
      );
    }
    final m = AppMetrics.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(LucideIcons.circleCheck, size: 14, color: AppColors.green),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  _ComponentBadge(
                    text: _sourceLabel(s, _provider.source),
                    color: c.accent,
                    bg: m.subtle(c.accent),
                  ),
                  if (_provider.version.isNotEmpty)
                    Text(
                      'v${_provider.version}',
                      style: TextStyle(fontSize: 11, color: c.textMuted),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                _provider.path,
                style: TextStyle(fontSize: 11.5, color: c.textSecondary),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSystemPathRow(AppColors c, S s) {
    if (!_provider.hasStatus) return const SizedBox.shrink();
    final found = _provider.systemPath.isNotEmpty;
    return Row(
      children: [
        Icon(LucideIcons.terminal, size: 12, color: c.textMuted),
        const SizedBox(width: 6),
        Text(
          s.componentsSystemPathLabel,
          style: TextStyle(fontSize: 11, color: c.textMuted),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            found ? _provider.systemPath : s.componentsSystemPathNotFound,
            style: TextStyle(
              fontSize: 11,
              color: found ? c.textSecondary : c.textMuted,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildManualPathSection(AppColors c, S s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          s.componentsManualPathLabel,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: c.textPrimary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          s.componentsManualPathDesc(_title(s)),
          style: TextStyle(fontSize: 11, color: c.textMuted),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: ShadInput(
                controller: _pathController,
                focusNode: _pathFocusNode,
                placeholder: Text(
                  widget.kind == _ComponentKind.ffmpeg
                      ? s.componentsManualPathHintFfmpeg
                      : s.componentsManualPathHintYtdlp,
                ),
                onSubmitted: (_) => _saveManualPath(),
              ),
            ),
            const SizedBox(width: 8),
            ShadButton.outline(
              size: ShadButtonSize.sm,
              onPressed: _saveManualPath,
              child: Text(s.componentsManualPathSave),
            ),
            const SizedBox(width: 4),
            ShadTooltip(
              builder: (_) => Text(s.componentsManualPathClear),
              child: ShadIconButton.ghost(
                icon: Icon(LucideIcons.x, size: 15, color: c.textSecondary),
                onPressed: _clearManualPath,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildInstallSection(
    BuildContext context,
    AppColors c,
    S s,
    bool hasManaged,
  ) {
    final p = _provider;
    // 平台不支持托管安装（macOS 等）：不展示版本选择/安装按钮，只给一条
    // 静态引导，避免反复弹「不支持安装」。手动指定路径区块仍在上方可用。
    if (!p.managedSupported) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.info, size: 13, color: c.textMuted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              s.componentsManagedUnsupported(_title(s)),
              style: TextStyle(fontSize: 11.5, color: c.textSecondary),
            ),
          ),
        ],
      );
    }
    final m = AppMetrics.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                s.componentsInstallSectionTitle,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: c.textPrimary,
                ),
              ),
            ),
            ShadTooltip(
              builder: (_) => Text(s.componentsFetchVersionsButton),
              child: ShadIconButton.ghost(
                icon: p.versionsLoading
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: c.textSecondary,
                        ),
                      )
                    : Icon(
                        LucideIcons.refreshCw,
                        size: 14,
                        color: c.textSecondary,
                      ),
                onPressed: p.versionsLoading ? null : p.requestVersions,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          widget.kind == _ComponentKind.ffmpeg
              ? s.componentsInstallSectionDescFfmpeg
              : s.componentsInstallSectionDescYtdlp,
          style: TextStyle(fontSize: 11, color: c.textMuted),
        ),
        const SizedBox(height: 8),
        if (hasManaged) ...[
          Text(
            s.componentsManagedVersionLabel(p.managedVersion),
            style: TextStyle(fontSize: 11, color: c.textMuted),
          ),
          const SizedBox(height: 8),
        ],
        if (p.versionsError.isNotEmpty) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(LucideIcons.circleAlert, size: 13, color: AppColors.amber),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  s.componentsVersionsLoadFailed(p.versionsError),
                  style: TextStyle(fontSize: 11.5, color: c.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ShadButton.outline(
            size: ShadButtonSize.sm,
            enabled: !p.versionsLoading,
            onPressed: p.requestVersions,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (p.versionsLoading)
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: c.textSecondary,
                    ),
                  )
                else
                  Icon(LucideIcons.refreshCw, size: 13, color: c.textSecondary),
                const SizedBox(width: 6),
                Text(s.componentsRetryVersions),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        ShadSelect<String>(
          enabled: p.versions.isNotEmpty && !p.installing,
          initialValue: _selectedVersion,
          placeholder: Text(
            p.versionsLoading
                ? s.componentsVersionsLoading
                : s.componentsVersionSelectPlaceholder,
          ),
          options: p.versions
              .map((v) => ShadOption(value: v, child: Text(v)))
              .toList(),
          selectedOptionBuilder: (context, value) => Text(value),
          onChanged: (v) {
            if (v != null) setState(() => _selectedVersion = v);
          },
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            ShadButton(
              size: ShadButtonSize.sm,
              enabled: !p.installing,
              onPressed: _install,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (p.installing) ...[
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(s.componentsInstalling),
                  ] else ...[
                    const Icon(
                      LucideIcons.download,
                      size: 13,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      hasManaged
                          ? s.componentsReinstallButton
                          : s.componentsInstallButton,
                    ),
                  ],
                ],
              ),
            ),
            if (hasManaged) ...[
              const SizedBox(width: 8),
              ShadButton.outline(
                size: ShadButtonSize.sm,
                enabled: !p.installing,
                onPressed: _confirmUninstall,
                child: Text(s.componentsUninstallButton),
              ),
            ],
          ],
        ),
        if (p.installing) ...[
          const SizedBox(height: 10),
          _buildProgress(c, m, s, p),
        ],
      ],
    );
  }

  Widget _buildProgress(AppColors c, AppMetrics m, S s, ComponentController p) {
    final total = p.totalBytes;
    final downloaded = p.downloadedBytes;
    final fraction = total > 0 ? (downloaded / total).clamp(0.0, 1.0) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: m.brXs,
          child: LinearProgressIndicator(
            value: fraction,
            backgroundColor: c.surface2,
            valueColor: AlwaysStoppedAnimation<Color>(c.accent),
            minHeight: 6,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          total > 0
              ? '${(fraction! * 100).toStringAsFixed(1)}%  '
                    '${UpdateService.formatBytes(downloaded)} / ${UpdateService.formatBytes(total)}'
              : '${UpdateService.formatBytes(downloaded)} · ${s.componentsInstallUnknownSize}',
          style: TextStyle(fontSize: 11, color: c.textMuted),
        ),
      ],
    );
  }
}

/// 组件手风琴卡片：视觉复刻 [_SettingCard]（surface1 圆角卡 + 高亮闪烁），
/// 头部（组件名 + 描述 + 基础状态摘要）常显且整体可点击，展开后显示
/// 安装与配置操作区（[child]）。经 [_HighlightConsumer] 继续支持设置搜索
/// 定位 + 闪烁高亮。
class _ComponentAccordionCard extends StatefulWidget {
  final String label;
  final String description;

  /// 折叠态也常显的基础信息（当前来源/版本/系统 PATH）。
  final Widget summary;

  /// 展开后才显示的操作区（手动路径 + 托管安装/卸载）。
  final Widget child;

  const _ComponentAccordionCard({
    required this.label,
    required this.description,
    required this.summary,
    required this.child,
  });

  @override
  State<_ComponentAccordionCard> createState() =>
      _ComponentAccordionCardState();
}

class _ComponentAccordionCardState extends State<_ComponentAccordionCard>
    with _HighlightConsumer {
  bool _expanded = false;

  @override
  String get highlightLabel => widget.label;
  @override
  String get highlightDescription => widget.description;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final m = AppMetrics.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: flashing ? m.subtle(c.accent) : c.surface1,
        borderRadius: m.brDialog,
        border: Border.all(
          color: flashing ? m.emphasis(c.accent) : m.borderMedium(c.border),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _expanded = !_expanded),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.label,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: c.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.description,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: c.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeInOut,
                        child: Icon(
                          LucideIcons.chevronDown,
                          size: 16,
                          color: c.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  widget.summary,
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: _expanded
                ? SizedBox(width: double.infinity, child: widget.child)
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

/// ffmpeg 来源标签（手动指定/组件安装/系统 PATH），复刻插件卡片的
/// `_Badge`（`plugin_list_view.dart`，私有类型无法跨文件复用）。
class _ComponentBadge extends StatelessWidget {
  final String text;
  final Color color;
  final Color bg;

  const _ComponentBadge({
    required this.text,
    required this.color,
    required this.bg,
  });

  @override
  Widget build(BuildContext context) {
    final m = AppMetrics.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: m.brPill),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w500,
          color: color,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// BT 设置子组件
// ─────────────────────────────────────────────

/// BT 监听端口范围编辑器（起始端口 / 结束端口）
class _BtPortRangeEditor extends StatefulWidget {
  final SettingsProvider settingsProvider;

  const _BtPortRangeEditor({required this.settingsProvider});

  @override
  State<_BtPortRangeEditor> createState() => _BtPortRangeEditorState();
}

class _BtPortRangeEditorState extends State<_BtPortRangeEditor> {
  late TextEditingController _startController;
  late TextEditingController _endController;
  String? _error;

  @override
  void initState() {
    super.initState();
    final sp = widget.settingsProvider;
    _startController = TextEditingController(text: '${sp.btPortStart}');
    _endController = TextEditingController(text: '${sp.btPortEnd}');
  }

  @override
  void didUpdateWidget(_BtPortRangeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sp = widget.settingsProvider;
    final start = int.tryParse(_startController.text);
    final end = int.tryParse(_endController.text);
    if (sp.btPortStart != start) {
      _startController.text = '${sp.btPortStart}';
    }
    if (sp.btPortEnd != end) {
      _endController.text = '${sp.btPortEnd}';
    }
  }

  @override
  void dispose() {
    _startController.dispose();
    _endController.dispose();
    super.dispose();
  }

  bool _isValid(int start, int end) {
    return start >= 1024 &&
        start <= 65535 &&
        end >= 1024 &&
        end <= 65535 &&
        start <= end;
  }

  void _tryCommit() {
    final start = int.tryParse(_startController.text);
    final end = int.tryParse(_endController.text);
    if (start == null || end == null || !_isValid(start, end)) {
      setState(() => _error = LocaleScope.of(context).btPortInvalid);
      return;
    }
    setState(() => _error = null);
    widget.settingsProvider.setBtPortStart(start);
    widget.settingsProvider.setBtPortEnd(end);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final s = LocaleScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 110,
              child: ShadInput(
                controller: _startController,
                placeholder: Text(s.btListenPortStart),
                keyboardType: TextInputType.number,
                onSubmitted: (_) => _tryCommit(),
                onChanged: (_) => _tryCommit(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                '–',
                style: TextStyle(fontSize: 14, color: c.textMuted),
              ),
            ),
            SizedBox(
              width: 110,
              child: ShadInput(
                controller: _endController,
                placeholder: Text(s.btListenPortEnd),
                keyboardType: TextInputType.number,
                onSubmitted: (_) => _tryCommit(),
                onChanged: (_) => _tryCommit(),
              ),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 6),
          Text(_error!, style: TextStyle(fontSize: 11.5, color: c.statusError)),
        ],
      ],
    );
  }
}

/// ED2K 监听端口编辑器（单端口；0 或空 = OS 自动选择）。
class _Ed2kListenPortEditor extends StatefulWidget {
  final SettingsProvider settingsProvider;

  const _Ed2kListenPortEditor({required this.settingsProvider});

  @override
  State<_Ed2kListenPortEditor> createState() => _Ed2kListenPortEditorState();
}

class _Ed2kListenPortEditorState extends State<_Ed2kListenPortEditor> {
  late TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: '${widget.settingsProvider.ed2kListenPort}',
    );
  }

  @override
  void didUpdateWidget(_Ed2kListenPortEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final port = int.tryParse(_controller.text);
    if (widget.settingsProvider.ed2kListenPort != port) {
      _controller.text = '${widget.settingsProvider.ed2kListenPort}';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _tryCommit() {
    final raw = _controller.text.trim();
    // 空或 0 = OS 自动选择端口。
    final port = raw.isEmpty ? 0 : int.tryParse(raw);
    if (port == null || port < 0 || port > 65535) {
      setState(() => _error = LocaleScope.of(context).btPortInvalid);
      return;
    }
    setState(() => _error = null);
    widget.settingsProvider.setEd2kListenPort(port);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        SizedBox(
          width: 130,
          child: ShadInput(
            controller: _controller,
            placeholder: const Text('0'),
            keyboardType: TextInputType.number,
            onSubmitted: (_) => _tryCommit(),
            onChanged: (_) => _tryCommit(),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 6),
          Text(_error!, style: TextStyle(fontSize: 11.5, color: c.statusError)),
        ],
      ],
    );
  }
}

/// BT Tracker 列表编辑器
///
/// 使用与 [new_download_dialog] 相同的 Localizations + Material + TextField
/// 方案，确保鼠标选择、复制粘贴等功能正常。
class _BtTrackerEditor extends StatefulWidget {
  final SettingsProvider settingsProvider;

  const _BtTrackerEditor({required this.settingsProvider});

  @override
  State<_BtTrackerEditor> createState() => _BtTrackerEditorState();
}

/// 内置默认 Tracker 列表（与 Rust 端 PUBLIC_TRACKERS 保持同步）。
/// "重置为默认"时用此列表恢复。
const _kDefaultTrackers = [
  // CN / Asia
  'udp://tracker.dler.com:6969/announce',
  'udp://admin.52ywp.com:6969/announce',
  'udp://tracker.dler.org:6969/announce',
  'https://tracker.moeblog.cn:443/announce',
  'http://nyaa.tracker.wf:7777/announce',
  'https://tr.zukizuki.org:443/announce',
  // International
  'udp://tracker.opentrackr.org:1337/announce',
  'udp://open.dstud.io:6969/announce',
  'udp://tracker-udp.gbitt.info:80/announce',
  'udp://open.stealth.si:80/announce',
  'udp://tracker.torrent.eu.org:451/announce',
  'udp://exodus.desync.com:6969/announce',
  'udp://explodie.org:6969/announce',
  'udp://tracker.srv00.com:6969/announce',
  'udp://tracker.qu.ax:6969/announce',
  'udp://opentracker.io:6969/announce',
  'udp://tracker.bittor.pw:1337/announce',
  'udp://tracker.theoks.net:6969/announce',
  'udp://tracker.opentorrent.top:6969/announce',
  'udp://open.demonoid.ch:6969/announce',
  'udp://tracker.t-1.org:6969/announce',
  // HTTPS fallbacks
  'https://tracker.ghostchu-services.top:443/announce',
  'https://tracker.bt4g.com:443/announce',
  'https://1337.abcvg.info:443/announce',
  'http://tracker.bt4g.com:2095/announce',
];

class _BtTrackerEditorState extends State<_BtTrackerEditor> {
  late TextEditingController _controller;
  bool _isExpanded = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.settingsProvider.btCustomTrackers,
    );
  }

  @override
  void didUpdateWidget(_BtTrackerEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 仅在外部值变化时同步（例如从 Rust 端加载初始值）
    if (widget.settingsProvider.btCustomTrackers != _controller.text &&
        !_isExpanded) {
      _controller.text = widget.settingsProvider.btCustomTrackers;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    // 清洗 + 去重：按 trim 后小写、去尾部斜杠的形式判重，保留首次出现的原始行
    // （Rust 端合并订阅时还会按 URL 规范化形式再去重一次）
    final seen = <String>{};
    final lines = <String>[];
    for (final raw in _controller.text.split('\n')) {
      final l = raw.trim();
      if (l.isEmpty) continue;
      final key = l.toLowerCase().replaceAll(RegExp(r'/+$'), '');
      if (seen.add(key)) lines.add(l);
    }
    final cleaned = lines.join('\n');
    _controller.text = cleaned;
    widget.settingsProvider.setBtCustomTrackers(cleaned);
  }

  int get _trackerCount {
    final text = _controller.text.trim();
    if (text.isEmpty) return 0;
    return text.split('\n').where((l) => l.trim().isNotEmpty).length;
  }

  void _resetToDefault() {
    showShadDialog(
      context: context,
      barrierColor: AppColors.of(context).dialogBarrier,
      animateIn: const [],
      animateOut: const [],
      builder: (ctx) => ShadDialog.alert(
        title: Text(LocaleScope.of(ctx).btResetTrackers),
        description: Text(LocaleScope.of(ctx).btResetTrackersConfirm),
        actions: [
          ShadButton.outline(
            child: Text(LocaleScope.of(ctx).cancel),
            onPressed: () => Navigator.of(ctx).pop(),
          ),
          ShadButton(
            child: Text(LocaleScope.of(ctx).confirm),
            onPressed: () {
              Navigator.of(ctx).pop();
              final defaults = _kDefaultTrackers.join('\n');
              _controller.text = defaults;
              widget.settingsProvider.setBtCustomTrackers(defaults);
              setState(() {});
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final m = AppMetrics.of(context);
    final s = LocaleScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 统计行 + 按钮
        Row(
          children: [
            Text(
              s.btTrackerCount(_trackerCount),
              style: TextStyle(fontSize: 12, color: c.textMuted),
            ),
            const Spacer(),
            ShadButton.ghost(
              size: ShadButtonSize.sm,
              onPressed: _resetToDefault,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.rotateCcw, size: 12, color: c.textSecondary),
                  const SizedBox(width: 4),
                  Text(
                    s.btResetTrackers,
                    style: TextStyle(fontSize: 11, color: c.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            ShadButton.ghost(
              size: ShadButtonSize.sm,
              onPressed: () => setState(() => _isExpanded = !_isExpanded),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _isExpanded
                        ? LucideIcons.chevronUp
                        : LucideIcons.chevronDown,
                    size: 14,
                    color: c.textSecondary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _isExpanded ? s.cancel : s.manage,
                    style: TextStyle(fontSize: 11, color: c.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
        // 展开时显示多行编辑区（与 new_download_dialog 一致的实现）
        if (_isExpanded) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 240,
            child: Localizations(
              locale: const Locale('en'),
              delegates: const [
                DefaultWidgetsLocalizations.delegate,
                DefaultMaterialLocalizations.delegate,
              ],
              child: Material(
                type: MaterialType.transparency,
                child: TextSelectionTheme(
                  data: TextSelectionThemeData(
                    selectionColor: m.textSelection(c.accent),
                    cursorColor: c.accent,
                    selectionHandleColor: c.accent,
                  ),
                  child: TextField(
                    controller: _controller,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    cursorColor: c.accent,
                    style: TextStyle(
                      fontSize: 12,
                      color: c.textPrimary,
                      fontFamily: 'monospace',
                      height: 1.5,
                    ),
                    decoration: InputDecoration(
                      hintText: s.btTrackerPlaceholder,
                      hintStyle: TextStyle(fontSize: 12, color: c.textMuted),
                      hintMaxLines: 5,
                      contentPadding: const EdgeInsets.all(10),
                      filled: true,
                      fillColor: c.inputBg,
                      hoverColor: Colors.transparent,
                      border: OutlineInputBorder(
                        borderRadius: m.brInput,
                        borderSide: BorderSide(color: c.inputBorder),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: m.brInput,
                        borderSide: BorderSide(color: c.inputBorder),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: m.brInput,
                        borderSide: BorderSide(color: c.inputFocusBorder),
                      ),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: ShadButton(
              size: ShadButtonSize.sm,
              onPressed: () {
                _save();
                setState(() => _isExpanded = false);
              },
              child: Text(s.confirm),
            ),
          ),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────
// BT Tracker 订阅编辑器
// ─────────────────────────────────────────────

/// 默认订阅地址（与 Rust 端 tracker_subscription::DEFAULT_SUBSCRIPTION_URLS 保持同步）：
/// - trackerslist.com — XIU2/TrackersListCollection 官方 CDN（中文社区最流行，国内可达）
/// - ngosang.github.io — ngosang/trackerslist（每日自动更新，按延迟排序）
const _kDefaultTrackerSubUrls = [
  'https://trackerslist.com/best.txt',
  'https://ngosang.github.io/trackerslist/trackers_best.txt',
];

/// BT Tracker 订阅编辑器：启用开关 + 订阅状态 + 立即更新 + 订阅地址管理。
class _BtTrackerSubEditor extends StatefulWidget {
  final SettingsProvider settingsProvider;

  const _BtTrackerSubEditor({required this.settingsProvider});

  @override
  State<_BtTrackerSubEditor> createState() => _BtTrackerSubEditorState();
}

class _BtTrackerSubEditorState extends State<_BtTrackerSubEditor> {
  late TextEditingController _controller;
  bool _isExpanded = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.settingsProvider.btTrackerSubUrls,
    );
  }

  @override
  void didUpdateWidget(_BtTrackerSubEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 仅在外部值变化时同步（例如从 Rust 端加载初始值）
    if (widget.settingsProvider.btTrackerSubUrls != _controller.text &&
        !_isExpanded) {
      _controller.text = widget.settingsProvider.btTrackerSubUrls;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    // 清洗 + 去重（忽略大小写与尾部斜杠差异）
    final seen = <String>{};
    final lines = <String>[];
    for (final raw in _controller.text.split('\n')) {
      final l = raw.trim();
      if (l.isEmpty) continue;
      final key = l.toLowerCase().replaceAll(RegExp(r'/+$'), '');
      if (seen.add(key)) lines.add(l);
    }
    final cleaned = lines.join('\n');
    _controller.text = cleaned;
    widget.settingsProvider.setBtTrackerSubUrls(cleaned);
  }

  void _resetToDefault() {
    showShadDialog(
      context: context,
      barrierColor: AppColors.of(context).dialogBarrier,
      animateIn: const [],
      animateOut: const [],
      builder: (ctx) => ShadDialog.alert(
        title: Text(LocaleScope.of(ctx).btResetTrackers),
        description: Text(LocaleScope.of(ctx).btTrackerSubResetConfirm),
        actions: [
          ShadButton.outline(
            child: Text(LocaleScope.of(ctx).cancel),
            onPressed: () => Navigator.of(ctx).pop(),
          ),
          ShadButton(
            child: Text(LocaleScope.of(ctx).confirm),
            onPressed: () {
              Navigator.of(ctx).pop();
              final defaults = _kDefaultTrackerSubUrls.join('\n');
              _controller.text = defaults;
              widget.settingsProvider.setBtTrackerSubUrls(defaults);
              setState(() {});
            },
          ),
        ],
      ),
    );
  }

  String _formatUpdatedAt(int unixSecs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(unixSecs * 1000);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final m = AppMetrics.of(context);
    final s = LocaleScope.of(context);
    final sp = widget.settingsProvider;

    // 状态文本：已订阅 N 个 Tracker · 更新于… / 尚未更新 / 更新中
    final String statusText;
    if (sp.btTrackerSubRefreshing) {
      statusText = s.btTrackerSubUpdating;
    } else if (sp.btTrackerSubUpdatedAt > 0) {
      statusText =
          '${s.btTrackerSubStatus(sp.btTrackerSubCount)} · '
          '${s.btTrackerSubUpdatedAt(_formatUpdatedAt(sp.btTrackerSubUpdatedAt))}';
    } else {
      statusText = s.btTrackerSubNeverUpdated;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 状态行 + 启用开关
        Row(
          children: [
            Expanded(
              child: Text(
                statusText,
                style: TextStyle(fontSize: 12, color: c.textMuted),
              ),
            ),
            ShadSwitch(
              value: sp.btTrackerSubEnabled,
              onChanged: (v) => sp.setBtTrackerSubEnabled(v),
            ),
          ],
        ),
        if (sp.btTrackerSubEnabled) ...[
          // 错误提示
          if (sp.btTrackerSubLastError.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '${s.btTrackerSubUpdateFailed}: ${sp.btTrackerSubLastError}',
              style: TextStyle(fontSize: 11, color: c.statusError),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 4),
          // 操作行：立即更新 / 管理订阅地址
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              ShadButton.ghost(
                size: ShadButtonSize.sm,
                onPressed: sp.btTrackerSubRefreshing
                    ? null
                    : () => sp.refreshTrackerSubscription(),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (sp.btTrackerSubRefreshing)
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: c.textSecondary,
                        ),
                      )
                    else
                      Icon(
                        LucideIcons.refreshCw,
                        size: 12,
                        color: c.textSecondary,
                      ),
                    const SizedBox(width: 4),
                    Text(
                      sp.btTrackerSubRefreshing
                          ? s.btTrackerSubUpdating
                          : s.btTrackerSubUpdateNow,
                      style: TextStyle(fontSize: 11, color: c.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              ShadButton.ghost(
                size: ShadButtonSize.sm,
                onPressed: () => setState(() => _isExpanded = !_isExpanded),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _isExpanded
                          ? LucideIcons.chevronUp
                          : LucideIcons.chevronDown,
                      size: 14,
                      color: c.textSecondary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _isExpanded ? s.cancel : s.manage,
                      style: TextStyle(fontSize: 11, color: c.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // 展开时显示订阅地址编辑区（与 Tracker 编辑器一致的实现）
          if (_isExpanded) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 100,
              child: Localizations(
                locale: const Locale('en'),
                delegates: const [
                  DefaultWidgetsLocalizations.delegate,
                  DefaultMaterialLocalizations.delegate,
                ],
                child: Material(
                  type: MaterialType.transparency,
                  child: TextSelectionTheme(
                    data: TextSelectionThemeData(
                      selectionColor: m.textSelection(c.accent),
                      cursorColor: c.accent,
                      selectionHandleColor: c.accent,
                    ),
                    child: TextField(
                      controller: _controller,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      cursorColor: c.accent,
                      style: TextStyle(
                        fontSize: 12,
                        color: c.textPrimary,
                        fontFamily: 'monospace',
                        height: 1.5,
                      ),
                      decoration: InputDecoration(
                        hintText: s.btTrackerSubPlaceholder,
                        hintStyle: TextStyle(fontSize: 12, color: c.textMuted),
                        hintMaxLines: 3,
                        contentPadding: const EdgeInsets.all(10),
                        filled: true,
                        fillColor: c.inputBg,
                        hoverColor: Colors.transparent,
                        border: OutlineInputBorder(
                          borderRadius: m.brInput,
                          borderSide: BorderSide(color: c.inputBorder),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: m.brInput,
                          borderSide: BorderSide(color: c.inputBorder),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: m.brInput,
                          borderSide: BorderSide(color: c.inputFocusBorder),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                ShadButton.ghost(
                  size: ShadButtonSize.sm,
                  onPressed: _resetToDefault,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        LucideIcons.rotateCcw,
                        size: 12,
                        color: c.textSecondary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        s.btResetTrackers,
                        style: TextStyle(fontSize: 11, color: c.textSecondary),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                ShadButton(
                  size: ShadButtonSize.sm,
                  onPressed: () {
                    _save();
                    setState(() => _isExpanded = false);
                  },
                  child: Text(s.confirm),
                ),
              ],
            ),
          ],
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────
// ED2K 服务器编辑器
// ─────────────────────────────────────────────

/// 内置默认 ED2K 服务器列表（与 Rust 端 db.rs 的 ed2k_server_list 默认值同步）。
/// "重置为默认"时用此列表恢复。
const _kDefaultEd2kServers = [
  '176.123.5.89:4725',
  '45.82.80.155:5687',
  '85.121.5.137:4232',
  '176.123.2.239:4232',
  '145.239.2.134:4661',
  '91.208.162.87:4232',
  '37.15.61.236:4232',
];

/// 默认 server.met 订阅地址（与 Rust 端 server_subscription::DEFAULT_SERVER_MET_URLS 同步）。
const _kDefaultEd2kMetUrls = [
  'http://upd.emule-security.org/server.met',
  'https://www.shortypower.org/server.met',
];

/// ED2K 手填服务器编辑器：统计 + 重置默认 + 可展开多行编辑（每行一个 host:port）。
/// 存储为逗号分隔（与 Rust `parse_server_list` 一致），编辑区按行展示。
class _Ed2kServerEditor extends StatefulWidget {
  final SettingsProvider settingsProvider;

  const _Ed2kServerEditor({required this.settingsProvider});

  @override
  State<_Ed2kServerEditor> createState() => _Ed2kServerEditorState();
}

class _Ed2kServerEditorState extends State<_Ed2kServerEditor> {
  late TextEditingController _controller;
  bool _isExpanded = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: _toLines(widget.settingsProvider.ed2kServerList),
    );
  }

  @override
  void didUpdateWidget(_Ed2kServerEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final asLines = _toLines(widget.settingsProvider.ed2kServerList);
    if (asLines != _controller.text && !_isExpanded) {
      _controller.text = asLines;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 逗号分隔 → 每行一个（编辑展示）。
  static String _toLines(String csv) =>
      csv.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).join('\n');

  void _save() {
    // 清洗 + 去重（按 trim 后的小写形式判重），存储为逗号分隔。
    final seen = <String>{};
    final items = <String>[];
    for (final raw in _controller.text.split(RegExp(r'[\n,]'))) {
      final l = raw.trim();
      if (l.isEmpty) continue;
      if (seen.add(l.toLowerCase())) items.add(l);
    }
    _controller.text = items.join('\n');
    widget.settingsProvider.setEd2kServerList(items.join(','));
  }

  int get _serverCount {
    final text = _controller.text.trim();
    if (text.isEmpty) return 0;
    return text
        .split(RegExp(r'[\n,]'))
        .where((l) => l.trim().isNotEmpty)
        .length;
  }

  void _resetToDefault() {
    showShadDialog(
      context: context,
      barrierColor: AppColors.of(context).dialogBarrier,
      animateIn: const [],
      animateOut: const [],
      builder: (ctx) => ShadDialog.alert(
        title: Text(LocaleScope.of(ctx).ed2kResetServers),
        description: Text(LocaleScope.of(ctx).ed2kResetServersConfirm),
        actions: [
          ShadButton.outline(
            child: Text(LocaleScope.of(ctx).cancel),
            onPressed: () => Navigator.of(ctx).pop(),
          ),
          ShadButton(
            child: Text(LocaleScope.of(ctx).confirm),
            onPressed: () {
              Navigator.of(ctx).pop();
              _controller.text = _kDefaultEd2kServers.join('\n');
              widget.settingsProvider.setEd2kServerList(
                _kDefaultEd2kServers.join(','),
              );
              setState(() {});
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final m = AppMetrics.of(context);
    final s = LocaleScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              s.ed2kServerCount(_serverCount),
              style: TextStyle(fontSize: 12, color: c.textMuted),
            ),
            const Spacer(),
            ShadButton.ghost(
              size: ShadButtonSize.sm,
              onPressed: _resetToDefault,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.rotateCcw, size: 12, color: c.textSecondary),
                  const SizedBox(width: 4),
                  Text(
                    s.ed2kResetServers,
                    style: TextStyle(fontSize: 11, color: c.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            ShadButton.ghost(
              size: ShadButtonSize.sm,
              onPressed: () => setState(() => _isExpanded = !_isExpanded),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _isExpanded
                        ? LucideIcons.chevronUp
                        : LucideIcons.chevronDown,
                    size: 14,
                    color: c.textSecondary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _isExpanded ? s.cancel : s.manage,
                    style: TextStyle(fontSize: 11, color: c.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (_isExpanded) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 200,
            child: Localizations(
              locale: const Locale('en'),
              delegates: const [
                DefaultWidgetsLocalizations.delegate,
                DefaultMaterialLocalizations.delegate,
              ],
              child: Material(
                type: MaterialType.transparency,
                child: TextSelectionTheme(
                  data: TextSelectionThemeData(
                    selectionColor: m.textSelection(c.accent),
                    cursorColor: c.accent,
                    selectionHandleColor: c.accent,
                  ),
                  child: TextField(
                    controller: _controller,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    cursorColor: c.accent,
                    style: TextStyle(
                      fontSize: 12,
                      color: c.textPrimary,
                      fontFamily: 'monospace',
                      height: 1.5,
                    ),
                    decoration: InputDecoration(
                      hintText: s.ed2kServerPlaceholder,
                      hintStyle: TextStyle(fontSize: 12, color: c.textMuted),
                      hintMaxLines: 3,
                      contentPadding: const EdgeInsets.all(10),
                      filled: true,
                      fillColor: c.inputBg,
                      hoverColor: Colors.transparent,
                      border: OutlineInputBorder(
                        borderRadius: m.brInput,
                        borderSide: BorderSide(color: c.inputBorder),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: m.brInput,
                        borderSide: BorderSide(color: c.inputBorder),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: m.brInput,
                        borderSide: BorderSide(color: c.inputFocusBorder),
                      ),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: ShadButton(
              size: ShadButtonSize.sm,
              onPressed: () {
                _save();
                setState(() => _isExpanded = false);
              },
              child: Text(s.confirm),
            ),
          ),
        ],
      ],
    );
  }
}

/// ED2K 服务器订阅编辑器：启用开关 + 订阅状态 + 立即更新 + 订阅地址管理。
class _Ed2kServerSubEditor extends StatefulWidget {
  final SettingsProvider settingsProvider;

  const _Ed2kServerSubEditor({required this.settingsProvider});

  @override
  State<_Ed2kServerSubEditor> createState() => _Ed2kServerSubEditorState();
}

class _Ed2kServerSubEditorState extends State<_Ed2kServerSubEditor> {
  late TextEditingController _controller;
  bool _isExpanded = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.settingsProvider.ed2kServerSubUrls,
    );
  }

  @override
  void didUpdateWidget(_Ed2kServerSubEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.settingsProvider.ed2kServerSubUrls != _controller.text &&
        !_isExpanded) {
      _controller.text = widget.settingsProvider.ed2kServerSubUrls;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final seen = <String>{};
    final lines = <String>[];
    for (final raw in _controller.text.split('\n')) {
      final l = raw.trim();
      if (l.isEmpty) continue;
      final key = l.toLowerCase().replaceAll(RegExp(r'/+$'), '');
      if (seen.add(key)) lines.add(l);
    }
    final cleaned = lines.join('\n');
    _controller.text = cleaned;
    widget.settingsProvider.setEd2kServerSubUrls(cleaned);
  }

  void _resetToDefault() {
    showShadDialog(
      context: context,
      barrierColor: AppColors.of(context).dialogBarrier,
      animateIn: const [],
      animateOut: const [],
      builder: (ctx) => ShadDialog.alert(
        title: Text(LocaleScope.of(ctx).ed2kResetServers),
        description: Text(LocaleScope.of(ctx).ed2kServerSubResetConfirm),
        actions: [
          ShadButton.outline(
            child: Text(LocaleScope.of(ctx).cancel),
            onPressed: () => Navigator.of(ctx).pop(),
          ),
          ShadButton(
            child: Text(LocaleScope.of(ctx).confirm),
            onPressed: () {
              Navigator.of(ctx).pop();
              final defaults = _kDefaultEd2kMetUrls.join('\n');
              _controller.text = defaults;
              widget.settingsProvider.setEd2kServerSubUrls(defaults);
              setState(() {});
            },
          ),
        ],
      ),
    );
  }

  String _formatUpdatedAt(int unixSecs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(unixSecs * 1000);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final m = AppMetrics.of(context);
    final s = LocaleScope.of(context);
    final sp = widget.settingsProvider;

    final String statusText;
    if (sp.ed2kServerSubRefreshing) {
      statusText = s.ed2kServerSubUpdating;
    } else if (sp.ed2kServerSubUpdatedAt > 0) {
      statusText =
          '${s.ed2kServerSubStatus(sp.ed2kServerSubCount)} · '
          '${s.ed2kServerSubUpdatedAt(_formatUpdatedAt(sp.ed2kServerSubUpdatedAt))}';
    } else {
      statusText = s.ed2kServerSubNeverUpdated;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                statusText,
                style: TextStyle(fontSize: 12, color: c.textMuted),
              ),
            ),
            ShadSwitch(
              value: sp.ed2kServerSubEnabled,
              onChanged: (v) => sp.setEd2kServerSubEnabled(v),
            ),
          ],
        ),
        if (sp.ed2kServerSubEnabled) ...[
          if (sp.ed2kServerSubLastError.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '${s.ed2kServerSubUpdateFailed}: ${sp.ed2kServerSubLastError}',
              style: TextStyle(fontSize: 11, color: c.statusError),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              ShadButton.ghost(
                size: ShadButtonSize.sm,
                onPressed: sp.ed2kServerSubRefreshing
                    ? null
                    : () => sp.refreshEd2kServerSubscription(),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (sp.ed2kServerSubRefreshing)
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: c.textSecondary,
                        ),
                      )
                    else
                      Icon(
                        LucideIcons.refreshCw,
                        size: 12,
                        color: c.textSecondary,
                      ),
                    const SizedBox(width: 4),
                    Text(
                      sp.ed2kServerSubRefreshing
                          ? s.ed2kServerSubUpdating
                          : s.ed2kServerSubUpdateNow,
                      style: TextStyle(fontSize: 11, color: c.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              ShadButton.ghost(
                size: ShadButtonSize.sm,
                onPressed: () => setState(() => _isExpanded = !_isExpanded),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _isExpanded
                          ? LucideIcons.chevronUp
                          : LucideIcons.chevronDown,
                      size: 14,
                      color: c.textSecondary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _isExpanded ? s.cancel : s.manage,
                      style: TextStyle(fontSize: 11, color: c.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_isExpanded) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 100,
              child: Localizations(
                locale: const Locale('en'),
                delegates: const [
                  DefaultWidgetsLocalizations.delegate,
                  DefaultMaterialLocalizations.delegate,
                ],
                child: Material(
                  type: MaterialType.transparency,
                  child: TextSelectionTheme(
                    data: TextSelectionThemeData(
                      selectionColor: m.textSelection(c.accent),
                      cursorColor: c.accent,
                      selectionHandleColor: c.accent,
                    ),
                    child: TextField(
                      controller: _controller,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      cursorColor: c.accent,
                      style: TextStyle(
                        fontSize: 12,
                        color: c.textPrimary,
                        fontFamily: 'monospace',
                        height: 1.5,
                      ),
                      decoration: InputDecoration(
                        hintText: s.ed2kServerSubPlaceholder,
                        hintStyle: TextStyle(fontSize: 12, color: c.textMuted),
                        hintMaxLines: 3,
                        contentPadding: const EdgeInsets.all(10),
                        filled: true,
                        fillColor: c.inputBg,
                        hoverColor: Colors.transparent,
                        border: OutlineInputBorder(
                          borderRadius: m.brInput,
                          borderSide: BorderSide(color: c.inputBorder),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: m.brInput,
                          borderSide: BorderSide(color: c.inputBorder),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: m.brInput,
                          borderSide: BorderSide(color: c.inputFocusBorder),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                ShadButton.ghost(
                  size: ShadButtonSize.sm,
                  onPressed: _resetToDefault,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        LucideIcons.rotateCcw,
                        size: 12,
                        color: c.textSecondary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        s.ed2kResetServers,
                        style: TextStyle(fontSize: 11, color: c.textSecondary),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                ShadButton(
                  size: ShadButtonSize.sm,
                  onPressed: () {
                    _save();
                    setState(() => _isExpanded = false);
                  },
                  child: Text(s.confirm),
                ),
              ],
            ),
          ],
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────
// 语言选择器（跟随系统 + I18nStore 自动发现的全部语言）
//
// 用 ShadSelect 下拉而非卡片 Wrap：语言由社区经 Weblate 持续贡献，
// 数量可达几十种，下拉在弹层内滚动，任意数量都不会挤乱设置页布局。
// ─────────────────────────────────────────────

class _LanguageSelector extends StatelessWidget {
  const _LanguageSelector();

  String _label(S s, String pref) =>
      pref == kLocaleSystem ? s.languageSystem : I18nStore.nativeName(pref);

  @override
  Widget build(BuildContext context) {
    final current = localeNotifier.preference;
    final s = LocaleScope.of(context);

    final prefs = [kLocaleSystem, ...I18nStore.available];

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260),
      child: ShadSelect<String>(
        initialValue: current,
        placeholder: Text(_label(s, current)),
        options: [
          for (final pref in prefs)
            ShadOption(
              value: pref,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    pref == kLocaleSystem
                        ? LucideIcons.monitor
                        : LucideIcons.languages,
                    size: 14,
                  ),
                  const SizedBox(width: 8),
                  Text(_label(s, pref)),
                ],
              ),
            ),
        ],
        selectedOptionBuilder: (context, value) => Text(
          _label(s, value),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onChanged: (v) {
          if (v != null) localeNotifier.setLocale(v);
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 主题选择器（内置主题卡片 + 导入导出）
// ─────────────────────────────────────────────

class _ThemeSelector extends StatelessWidget {
  const _ThemeSelector();

  @override
  Widget build(BuildContext context) {
    final provider = FluxDownApp.of(context);
    // ListenableBuilder 监听 ThemeProvider，确保导入/删除主题后立即 rebuild
    return ListenableBuilder(
      listenable: provider,
      builder: (context, _) {
        final c = AppColors.of(context);
        final s = LocaleScope.of(context);
        final dark = provider.isDark(context);

        final darkThemes = builtinThemes
            .where((e) => e.appearance == Brightness.dark)
            .toList();
        final lightThemes = builtinThemes
            .where((e) => e.appearance == Brightness.light)
            .toList();

        final appearance = dark ? Brightness.dark : Brightness.light;
        final importedForMode = provider.importedThemesFor(appearance);
        final selectedCustomId = dark
            ? provider.selectedCustomDarkId
            : provider.selectedCustomLightId;
        final isCustomActive = dark
            ? provider.isCustomDarkActive
            : provider.isCustomLightActive;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ThemeGroupLabel(
              label: dark ? s.themeDarkTheme : s.themeLightTheme,
              colors: c,
            ),
            const SizedBox(height: 6),
            _ThemeCardRow(
              themes: dark ? darkThemes : lightThemes,
              selectedId: dark
                  ? provider.selectedDarkTheme
                  : provider.selectedLightTheme,
              colors: c,
              isCustomActive: isCustomActive,
              onSelect: (id) =>
                  dark ? provider.setDarkTheme(id) : provider.setLightTheme(id),
              importedThemes: importedForMode,
              selectedCustomId: selectedCustomId,
              onSelectImported: (id) => provider.selectImportedTheme(id),
              onRemoveImported: (id) => provider.removeImportedTheme(id),
            ),
            const SizedBox(height: 14),
            _ThemeActions(colors: c),
          ],
        );
      },
    );
  }
}

/// 导入 / 导出操作行
class _ThemeActions extends StatelessWidget {
  final AppColors colors;

  const _ThemeActions({required this.colors});

  Future<void> _importTheme(BuildContext context) async {
    final provider = FluxDownApp.of(context);
    final s = LocaleScope.of(context);

    List<XFile>? result;
    try {
      result = await FilePickerService.pickFiles(
        dialogTitle: s.themeImport,
        allowedExtensions: ['json'],
        allowMultiple: true,
      );
    } on FilePickerException catch (e) {
      if (!context.mounted) return;
      final msg = switch (e.reason) {
        FilePickerFailReason.timeout => s.filePickerErrorTimeout,
        FilePickerFailReason.noDialogTool => s.filePickerErrorNoTool,
        FilePickerFailReason.comInitFailed => s.filePickerErrorNative,
        FilePickerFailReason.nativeDialogFailed => s.filePickerErrorNative,
        FilePickerFailReason.unknown => s.filePickerErrorGeneric,
      };
      FluxSonner.of(context).show(ShadToast.destructive(title: Text(msg)));
      return;
    }
    if (result == null || result.isEmpty) return;

    int successCount = 0;
    final errors = <String>[];

    for (final picked in result) {
      final path = picked.path;

      try {
        final file = File(path);
        final content = await file.readAsString();
        final tokens = provider.importThemeJson(content);
        provider.addImportedTheme(tokens);
        successCount++;
      } catch (e) {
        errors.add('${picked.name}: $e');
      }
    }

    if (!context.mounted) return;

    if (successCount > 0) {
      FluxSonner.of(context).show(
        ShadToast(
          title: Text('${s.themeImportSuccess} ($successCount)'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
    if (errors.isNotEmpty) {
      FluxSonner.of(context).show(
        ShadToast.destructive(
          title: Text(s.themeImportError),
          description: Text(errors.join('\n')),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _exportTheme(BuildContext context) async {
    final provider = FluxDownApp.of(context);
    final s = LocaleScope.of(context);
    final dark = provider.isDark(context);
    final tokens = provider.getExportableTokens(dark);
    final json = provider.exportThemeJson(tokens);

    final safeName = tokens.name
        .replaceAll(RegExp(r'[^\w\-]'), '_')
        .toLowerCase();
    String? result;
    try {
      result = await FilePickerService.saveFile(
        dialogTitle: s.themeExport,
        fileName: '$safeName.json',
        allowedExtensions: ['json'],
      );
    } on FilePickerException catch (e) {
      if (!context.mounted) return;
      final msg = switch (e.reason) {
        FilePickerFailReason.timeout => s.filePickerErrorTimeout,
        FilePickerFailReason.noDialogTool => s.filePickerErrorNoTool,
        FilePickerFailReason.comInitFailed => s.filePickerErrorNative,
        FilePickerFailReason.nativeDialogFailed => s.filePickerErrorNative,
        FilePickerFailReason.unknown => s.filePickerErrorGeneric,
      };
      FluxSonner.of(context).show(ShadToast.destructive(title: Text(msg)));
      return;
    }
    if (result == null) return;

    try {
      await File(result).writeAsString(json);
      if (!context.mounted) return;
      FluxSonner.of(context).show(
        ShadToast(
          title: Text(s.themeExportSuccess),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      FluxSonner.of(context).show(
        ShadToast.destructive(
          title: Text(s.themeImportError),
          description: Text(e.toString()),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = LocaleScope.of(context);
    final c = colors;
    return Row(
      children: [
        _SmallActionButton(
          icon: LucideIcons.fileUp,
          label: s.themeImport,
          colors: c,
          onTap: () => _importTheme(context),
        ),
        const SizedBox(width: 8),
        _SmallActionButton(
          icon: LucideIcons.fileDown,
          label: s.themeExport,
          colors: c,
          onTap: () => _exportTheme(context),
        ),
        const SizedBox(width: 8),
        _SmallActionButton(
          icon: LucideIcons.globe,
          label: s.themeMore,
          colors: c,
          onTap: () => launchUrl(Uri.parse('https://fluxdown.zerx.dev/themes')),
        ),
      ],
    );
  }
}

class _SmallActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final AppColors colors;
  final VoidCallback onTap;

  const _SmallActionButton({
    required this.icon,
    required this.label,
    required this.colors,
    required this.onTap,
  });

  @override
  State<_SmallActionButton> createState() => _SmallActionButtonState();
}

class _SmallActionButtonState extends State<_SmallActionButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final m = AppMetrics.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: _isHovered ? c.hoverBg : c.hoverBg.withValues(alpha: 0),
            borderRadius: m.brMd,
            border: Border.all(color: c.border, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 12, color: c.textSecondary),
              const SizedBox(width: 5),
              Text(
                widget.label,
                style: TextStyle(fontSize: 11, color: c.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThemeGroupLabel extends StatelessWidget {
  final String label;
  final AppColors colors;

  const _ThemeGroupLabel({required this.label, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        color: colors.textMuted,
      ),
    );
  }
}

class _ThemeCardRow extends StatelessWidget {
  final List<BuiltinThemeEntry> themes;
  final BuiltinThemeId selectedId;
  final AppColors colors;
  final bool isCustomActive;
  final ValueChanged<BuiltinThemeId> onSelect;
  final List<ImportedThemeEntry> importedThemes;
  final String? selectedCustomId;
  final ValueChanged<String> onSelectImported;
  final ValueChanged<String> onRemoveImported;

  const _ThemeCardRow({
    required this.themes,
    required this.selectedId,
    required this.colors,
    required this.isCustomActive,
    required this.onSelect,
    required this.importedThemes,
    required this.selectedCustomId,
    required this.onSelectImported,
    required this.onRemoveImported,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final entry in themes)
          _ThemePreviewCard(
            entry: entry,
            selected: selectedId == entry.id && !isCustomActive,
            colors: colors,
            onTap: () => onSelect(entry.id),
          ),
        for (final imported in importedThemes)
          _CustomThemeCard(
            tokens: imported.tokens,
            selected: selectedCustomId == imported.id,
            colors: colors,
            onTap: () => onSelectImported(imported.id),
            onClear: () => onRemoveImported(imported.id),
          ),
      ],
    );
  }
}

/// 自定义主题卡片（导入的自定义主题）
class _CustomThemeCard extends StatefulWidget {
  final FluxThemeTokens tokens;
  final bool selected;
  final AppColors colors;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  const _CustomThemeCard({
    required this.tokens,
    required this.selected,
    required this.colors,
    required this.onTap,
    this.onClear,
  });

  @override
  State<_CustomThemeCard> createState() => _CustomThemeCardState();
}

class _CustomThemeCardState extends State<_CustomThemeCard> {
  bool _isHovered = false;
  bool _deleteRequested = false;

  void _handleTap() {
    if (_deleteRequested) {
      _deleteRequested = false;
      return;
    }
    widget.onTap();
  }

  void _handleDelete() {
    _deleteRequested = true;
    widget.onClear?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final c = widget.colors;
    final m = AppMetrics.of(context);
    final tokens = widget.tokens;
    // 迷你预览内部用「被预览主题自身」的 metric（圆角/透明度随被预览主题变化），
    // 而非当前生效 App 的 m（那是外层卡片 chrome 用的）。
    final tm = AppMetrics.fromTokens(tokens);
    final selected = widget.selected;
    final borderColor = selected ? theme.colorScheme.primary : c.border;

    return ShadTooltip(
      builder: (_) => Text(tokens.name),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: _handleTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 120,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _isHovered && !selected ? c.hoverBg : c.bg,
              borderRadius: m.brDialog,
              border: Border.all(color: borderColor, width: selected ? 1.5 : 1),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.15,
                        ),
                        blurRadius: 8,
                      ),
                    ]
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── 迷你预览（与内置主题卡片相同逻辑）──
                Container(
                  height: 52,
                  decoration: BoxDecoration(
                    color: tokens.background,
                    borderRadius: tm.brMd,
                    border: Border.all(color: tm.borderFade(tokens.border)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 28,
                        decoration: BoxDecoration(
                          color: tokens.surface1,
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(5.5),
                            bottomLeft: Radius.circular(5.5),
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 16,
                              height: 3,
                              margin: const EdgeInsets.only(bottom: 3),
                              decoration: BoxDecoration(
                                color: tokens.accent,
                                borderRadius: tm.brProgress,
                              ),
                            ),
                            Container(
                              width: 16,
                              height: 3,
                              margin: const EdgeInsets.only(bottom: 3),
                              decoration: BoxDecoration(
                                color: tm.borderSubtle(tokens.textMuted),
                                borderRadius: tm.brProgress,
                              ),
                            ),
                            Container(
                              width: 16,
                              height: 3,
                              decoration: BoxDecoration(
                                color: tm.borderSubtle(tokens.textMuted),
                                borderRadius: tm.brProgress,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                height: 3,
                                margin: const EdgeInsets.only(bottom: 3),
                                decoration: BoxDecoration(
                                  color: tm.borderFaint(tokens.textPrimary),
                                  borderRadius: tm.brProgress,
                                ),
                              ),
                              Container(
                                height: 3,
                                margin: const EdgeInsets.only(bottom: 3),
                                decoration: BoxDecoration(
                                  // 刻意保留：迷你预览次级文本条示意，固定装饰透明度。
                                  color: tokens.textMuted.withValues(
                                    alpha: 0.2,
                                  ),
                                  borderRadius: tm.brProgress,
                                ),
                              ),
                              Container(
                                height: 4,
                                decoration: BoxDecoration(
                                  color: tokens.surface3,
                                  borderRadius: tm.brXs,
                                ),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: FractionallySizedBox(
                                    widthFactor: 0.6,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: tokens.accent,
                                        borderRadius: tm.brXs,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                // ── 名称 + 删除/勾选 ──
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        tokens.name,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: selected
                              ? theme.colorScheme.primary
                              : c.textSecondary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (selected)
                      Icon(
                        LucideIcons.check,
                        size: 12,
                        color: theme.colorScheme.primary,
                      ),
                    if (_isHovered && widget.onClear != null)
                      Padding(
                        padding: EdgeInsets.only(left: selected ? 4 : 0),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: Listener(
                            behavior: HitTestBehavior.opaque,
                            onPointerDown: (_) => _handleDelete(),
                            child: Padding(
                              padding: const EdgeInsets.all(2),
                              child: Icon(
                                LucideIcons.x,
                                size: 12,
                                color: c.textMuted,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ThemePreviewCard extends StatefulWidget {
  final BuiltinThemeEntry entry;
  final bool selected;
  final AppColors colors;
  final VoidCallback onTap;

  const _ThemePreviewCard({
    required this.entry,
    required this.selected,
    required this.colors,
    required this.onTap,
  });

  @override
  State<_ThemePreviewCard> createState() => _ThemePreviewCardState();
}

class _ThemePreviewCardState extends State<_ThemePreviewCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final m = AppMetrics.of(context);
    final theme = ShadTheme.of(context);
    final c = widget.colors;
    final entry = widget.entry;
    final selected = widget.selected;

    // 预览主题的色值
    final tokens = entry.build();
    // 迷你预览内部用被预览主题自身的 metric（见 _CustomThemeCard 注释）。
    final tm = AppMetrics.fromTokens(tokens);
    final borderColor = selected ? theme.colorScheme.primary : c.border;

    return ShadTooltip(
      builder: (_) => Text(entry.id.label),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 120,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _isHovered && !selected ? c.hoverBg : c.bg,
              borderRadius: m.brDialog,
              border: Border.all(color: borderColor, width: selected ? 1.5 : 1),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.15,
                        ),
                        blurRadius: 8,
                      ),
                    ]
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── 迷你预览 ──
                Container(
                  height: 52,
                  decoration: BoxDecoration(
                    color: tokens.background,
                    borderRadius: tm.brMd,
                    border: Border.all(color: tm.borderFade(tokens.border)),
                  ),
                  child: Row(
                    children: [
                      // 侧边栏预览
                      Container(
                        width: 28,
                        decoration: BoxDecoration(
                          color: tokens.surface1,
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(5.5),
                            bottomLeft: Radius.circular(5.5),
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 16,
                              height: 3,
                              margin: const EdgeInsets.only(bottom: 3),
                              decoration: BoxDecoration(
                                color: tokens.accent,
                                borderRadius: tm.brProgress,
                              ),
                            ),
                            Container(
                              width: 16,
                              height: 3,
                              margin: const EdgeInsets.only(bottom: 3),
                              decoration: BoxDecoration(
                                color: tm.borderSubtle(tokens.textMuted),
                                borderRadius: tm.brProgress,
                              ),
                            ),
                            Container(
                              width: 16,
                              height: 3,
                              decoration: BoxDecoration(
                                color: tm.borderSubtle(tokens.textMuted),
                                borderRadius: tm.brProgress,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // 内容区预览
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                height: 3,
                                margin: const EdgeInsets.only(bottom: 3),
                                decoration: BoxDecoration(
                                  color: tm.borderFaint(tokens.textPrimary),
                                  borderRadius: tm.brProgress,
                                ),
                              ),
                              Container(
                                height: 3,
                                margin: const EdgeInsets.only(bottom: 3),
                                decoration: BoxDecoration(
                                  // 刻意保留：迷你预览次级文本条示意，固定装饰透明度。
                                  color: tokens.textMuted.withValues(
                                    alpha: 0.2,
                                  ),
                                  borderRadius: tm.brProgress,
                                ),
                              ),
                              // 进度条预览
                              Container(
                                height: 4,
                                decoration: BoxDecoration(
                                  color: tokens.surface3,
                                  borderRadius: tm.brXs,
                                ),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: FractionallySizedBox(
                                    widthFactor: 0.6,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: tokens.accent,
                                        borderRadius: tm.brXs,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                // ── 主题名 + 选中勾 ──
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        entry.id.label,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: selected
                              ? theme.colorScheme.primary
                              : c.textSecondary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (selected)
                      Icon(
                        LucideIcons.check,
                        size: 12,
                        color: theme.colorScheme.primary,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 主题模式选择器（亮色 / 暗色 / 跟随系统）
// ─────────────────────────────────────────────

class _ThemeModeSelector extends StatelessWidget {
  const _ThemeModeSelector();

  @override
  Widget build(BuildContext context) {
    final provider = FluxDownApp.of(context);
    // FluxDownApp.of 走 findAncestorStateOfType，不建立响应式依赖；
    // 本组件又以 const 挂载，父级重建会被 const 同一性跳过。当主题模式在
    // 视觉等价的档位间切换（如系统为亮色时 跟随系统 ↔ 亮色）时，AppColors/
    // ShadTheme 均无变化，没有任何 inherited 依赖会触发重建，高亮就停留在
    // 上一次的值。必须显式监听 ThemeProvider。
    return ListenableBuilder(
      listenable: provider,
      builder: (context, _) {
        final current = provider.themeMode;
        final c = AppColors.of(context);
        final s = LocaleScope.of(context);

        final modes = [
          (
            mode: ThemeMode.system,
            label: s.themeModeSystem,
            icon: LucideIcons.monitor,
          ),
          (
            mode: ThemeMode.light,
            label: s.themeModeLight,
            icon: LucideIcons.sun,
          ),
          (
            mode: ThemeMode.dark,
            label: s.themeModeDark,
            icon: LucideIcons.moon,
          ),
        ];

        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final item in modes)
              _ThemeModeCard(
                icon: item.icon,
                label: item.label,
                selected: current == item.mode,
                colors: c,
                onTap: () => provider.setThemeMode(item.mode),
              ),
          ],
        );
      },
    );
  }
}

class _ThemeModeCard extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final AppColors colors;
  final VoidCallback onTap;

  const _ThemeModeCard({
    required this.icon,
    required this.label,
    required this.selected,
    required this.colors,
    required this.onTap,
  });

  @override
  State<_ThemeModeCard> createState() => _ThemeModeCardState();
}

class _ThemeModeCardState extends State<_ThemeModeCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final m = AppMetrics.of(context);
    final theme = ShadTheme.of(context);
    final c = widget.colors;
    final selected = widget.selected;
    final borderColor = selected ? theme.colorScheme.primary : c.border;
    final bgColor = selected
        ? m.subtle(theme.colorScheme.primary)
        : _isHovered
        ? c.hoverBg
        : c.bg;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: m.brCard,
            border: Border.all(color: borderColor, width: selected ? 1.5 : 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.icon,
                size: 14,
                color: selected ? theme.colorScheme.primary : c.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? theme.colorScheme.primary : c.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 主题色选择器（4 预设 + 自定义色盘）
// ─────────────────────────────────────────────

/// 预设色列表（排除 custom）
const _presetSchemes = [
  AppColorScheme.blue,
  AppColorScheme.green,
  AppColorScheme.violet,
  AppColorScheme.rose,
];

class _ColorSchemeSelector extends StatelessWidget {
  const _ColorSchemeSelector();

  @override
  Widget build(BuildContext context) {
    final provider = FluxDownApp.of(context);
    final current = provider.colorScheme;
    final c = AppColors.of(context);
    final isCustom = current == AppColorScheme.custom;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 色点行：4 预设 + 1 自定义 ──
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final scheme in _presetSchemes)
              _ColorDot(
                color: scheme.previewColor,
                label: scheme.label,
                selected: current == scheme,
                colors: c,
                onTap: () => provider.setColorScheme(scheme),
              ),
            _ColorDot(
              color: provider.customColor,
              label: AppColorScheme.custom.label,
              selected: isCustom,
              colors: c,
              icon: isCustom ? LucideIcons.check : LucideIcons.palette,
              onTap: () => provider.setColorScheme(AppColorScheme.custom),
            ),
          ],
        ),
        // ── 自定义色盘（仅在选中 custom 时展开） ──
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: isCustom
              ? Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: _CustomColorPicker(
                    color: provider.customColor,
                    onChanged: provider.setCustomColor,
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

class _ColorDot extends StatefulWidget {
  final Color color;
  final String label;
  final bool selected;
  final AppColors colors;
  final IconData? icon;
  final VoidCallback onTap;

  const _ColorDot({
    required this.color,
    required this.label,
    required this.selected,
    required this.colors,
    this.icon,
    required this.onTap,
  });

  @override
  State<_ColorDot> createState() => _ColorDotState();
}

class _ColorDotState extends State<_ColorDot> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final m = AppMetrics.of(context);
    final selected = widget.selected;
    final showIcon = selected || widget.icon != null;
    return ShadTooltip(
      builder: (_) => Text(widget.label),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: widget.color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected
                    ? widget.colors.textPrimary
                    : _isHovered
                    ? m.borderMedium(widget.colors.textSecondary)
                    : widget.color,
                width: selected
                    ? 2.5
                    : _isHovered
                    ? 1.5
                    : 0,
              ),
              boxShadow: _isHovered || selected
                  ? [
                      BoxShadow(
                        color: m.shadowStrong(widget.color),
                        blurRadius: 6,
                        spreadRadius: 0,
                      ),
                    ]
                  : null,
            ),
            child: showIcon
                ? Icon(
                    selected
                        ? LucideIcons.check
                        : (widget.icon ?? LucideIcons.check),
                    size: selected ? 13 : 12,
                    color: Colors.white,
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 自定义色盘（色相滑块 + Hex 输入）
// ─────────────────────────────────────────────

class _CustomColorPicker extends StatefulWidget {
  final Color color;
  final ValueChanged<Color> onChanged;

  const _CustomColorPicker({required this.color, required this.onChanged});

  @override
  State<_CustomColorPicker> createState() => _CustomColorPickerState();
}

class _CustomColorPickerState extends State<_CustomColorPicker> {
  late TextEditingController _hexController;
  late FocusNode _hexFocusNode;
  late double _hue;
  late double _saturation;
  late double _lightness;

  @override
  void initState() {
    super.initState();
    final hsl = HSLColor.fromColor(widget.color);
    _hue = hsl.hue;
    _saturation = hsl.saturation;
    _lightness = hsl.lightness;
    _hexController = TextEditingController(text: _colorToHex(widget.color));
    _hexFocusNode = FocusNode()..addListener(_onHexFocusChange);
  }

  @override
  void didUpdateWidget(_CustomColorPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.color != widget.color) {
      final hsl = HSLColor.fromColor(widget.color);
      _hue = hsl.hue;
      _saturation = hsl.saturation;
      _lightness = hsl.lightness;
      final hex = _colorToHex(widget.color);
      if (_hexController.text != hex) {
        _hexController.text = hex;
      }
    }
  }

  @override
  void dispose() {
    // 手输 hex 未回车就被程序性卸载时的兜底（滑块是即时提交，只有手输
    // 这一条路径需要补）；见 _commitOnUnmount。
    final color = _parseHex(_hexController.text);
    if (color != null && color != widget.color) {
      final onChanged = widget.onChanged;
      _commitOnUnmount(() => onChanged(color));
    }
    _hexFocusNode.removeListener(_onHexFocusChange);
    _hexFocusNode.dispose();
    _hexController.dispose();
    super.dispose();
  }

  static String _colorToHex(Color c) {
    final r = (c.r * 255).round();
    final g = (c.g * 255).round();
    final b = (c.b * 255).round();
    return '${r.toRadixString(16).padLeft(2, '0')}'
            '${g.toRadixString(16).padLeft(2, '0')}'
            '${b.toRadixString(16).padLeft(2, '0')}'
        .toUpperCase();
  }

  void _onHueChanged(double hue) {
    setState(() => _hue = hue);
    final color = HSLColor.fromAHSL(1, hue, _saturation, _lightness).toColor();
    _hexController.text = _colorToHex(color);
    widget.onChanged(color);
  }

  void _onSaturationChanged(double sat) {
    setState(() => _saturation = sat);
    final color = HSLColor.fromAHSL(1, _hue, sat, _lightness).toColor();
    _hexController.text = _colorToHex(color);
    widget.onChanged(color);
  }

  void _onLightnessChanged(double lit) {
    setState(() => _lightness = lit);
    final color = HSLColor.fromAHSL(1, _hue, _saturation, lit).toColor();
    _hexController.text = _colorToHex(color);
    widget.onChanged(color);
  }

  void _onHexFocusChange() {
    if (!_hexFocusNode.hasFocus) _commitHex(_hexController.text);
  }

  /// 解析 6 位 hex 文本（可带 `#`）；非法返回 null。
  static Color? _parseHex(String value) {
    final hex = value.replaceAll('#', '').trim();
    if (hex.length != 6) return null;
    final parsed = int.tryParse(hex, radix: 16);
    if (parsed == null) return null;
    return Color(0xFF000000 | parsed);
  }

  /// 提交 hex 输入（失焦或回车）。非法输入回退为当前生效颜色的文本，
  /// 避免输入框停在一个永远不会生效的半成品值上。
  void _commitHex(String value) {
    final color = _parseHex(value);
    if (color == null) {
      _hexController.text = _colorToHex(widget.color);
      return;
    }
    final hsl = HSLColor.fromColor(color);
    setState(() {
      _hue = hsl.hue;
      _saturation = hsl.saturation;
      _lightness = hsl.lightness;
    });
    widget.onChanged(color);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final currentColor = HSLColor.fromAHSL(
      1,
      _hue,
      _saturation,
      _lightness,
    ).toColor();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 色相滑块
        _HueSlider(hue: _hue, onChanged: _onHueChanged),
        const SizedBox(height: 10),
        // 饱和度滑块
        _GradientSlider(
          value: _saturation,
          onChanged: _onSaturationChanged,
          leftColor: HSLColor.fromAHSL(1, _hue, 0, _lightness).toColor(),
          rightColor: HSLColor.fromAHSL(1, _hue, 1, _lightness).toColor(),
        ),
        const SizedBox(height: 10),
        // 明度滑块
        _GradientSlider(
          value: _lightness,
          onChanged: _onLightnessChanged,
          leftColor: HSLColor.fromAHSL(1, _hue, _saturation, 0.05).toColor(),
          rightColor: HSLColor.fromAHSL(1, _hue, _saturation, 0.95).toColor(),
        ),
        const SizedBox(height: 12),
        // Hex 输入 + 预览
        Row(
          children: [
            // 颜色预览圆点
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: currentColor,
                shape: BoxShape.circle,
                border: Border.all(color: c.border, width: 1),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '#',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: c.textSecondary,
              ),
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 90,
              child: ShadInput(
                controller: _hexController,
                focusNode: _hexFocusNode,
                placeholder: const Text('3B82F6'),
                onSubmitted: _commitHex,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
// 色相滑块（彩虹渐变条）
// ─────────────────────────────────────────────

class _HueSlider extends StatelessWidget {
  final double hue; // 0..360
  final ValueChanged<double> onChanged;

  const _HueSlider({required this.hue, required this.onChanged});

  void _handleInteraction(Offset localPosition, double width) {
    final fraction = (localPosition.dx / width).clamp(0.0, 1.0);
    onChanged(fraction * 360);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final m = AppMetrics.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final thumbX = (hue / 360) * width;
        return GestureDetector(
          onTapDown: (d) => _handleInteraction(d.localPosition, width),
          onPanUpdate: (d) => _handleInteraction(d.localPosition, width),
          child: SizedBox(
            height: 22,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                // 彩虹渐变条
                Container(
                  height: 14,
                  decoration: BoxDecoration(
                    borderRadius: m.brMd,
                    gradient: const LinearGradient(
                      colors: [
                        Color(0xFFFF0000), // 0°   Red
                        Color(0xFFFFFF00), // 60°  Yellow
                        Color(0xFF00FF00), // 120° Green
                        Color(0xFF00FFFF), // 180° Cyan
                        Color(0xFF0000FF), // 240° Blue
                        Color(0xFFFF00FF), // 300° Magenta
                        Color(0xFFFF0000), // 360° Red
                      ],
                    ),
                    border: Border.all(
                      color: m.borderSubtle(c.border),
                      width: 0.5,
                    ),
                  ),
                ),
                // 拖动指示器
                Positioned(
                  left: (thumbX - 8).clamp(0, width - 16),
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: HSLColor.fromAHSL(1, hue, 0.8, 0.5).toColor(),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x40000000),
                          blurRadius: 3,
                          spreadRadius: 0,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────
// 通用双色渐变滑块（饱和度 / 明度）
// ─────────────────────────────────────────────

class _GradientSlider extends StatelessWidget {
  final double value; // 0..1
  final ValueChanged<double> onChanged;
  final Color leftColor;
  final Color rightColor;

  const _GradientSlider({
    required this.value,
    required this.onChanged,
    required this.leftColor,
    required this.rightColor,
  });

  void _handleInteraction(Offset localPosition, double width) {
    final fraction = (localPosition.dx / width).clamp(0.0, 1.0);
    onChanged(fraction);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final m = AppMetrics.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final thumbX = value * width;
        final thumbColor = Color.lerp(leftColor, rightColor, value)!;
        return GestureDetector(
          onTapDown: (d) => _handleInteraction(d.localPosition, width),
          onPanUpdate: (d) => _handleInteraction(d.localPosition, width),
          child: SizedBox(
            height: 22,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: 14,
                  decoration: BoxDecoration(
                    borderRadius: m.brMd,
                    gradient: LinearGradient(colors: [leftColor, rightColor]),
                    border: Border.all(
                      color: m.borderSubtle(c.border),
                      width: 0.5,
                    ),
                  ),
                ),
                Positioned(
                  left: (thumbX - 8).clamp(0, width - 16),
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: thumbColor,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x40000000),
                          blurRadius: 3,
                          spreadRadius: 0,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────
// 关于页面
// ─────────────────────────────────────────────

class _AboutContent extends StatelessWidget {
  const _AboutContent({required this.settingsProvider});

  final SettingsProvider settingsProvider;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([UpdateService.instance, settingsProvider]),
      builder: (context, _) {
        final svc = UpdateService.instance;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // App info card
            _SettingCard(
              label: 'FluxDown',
              description: LocaleScope.of(context).appDescription,
              vertical: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _infoRow(
                    c,
                    LocaleScope.of(context).currentVersion,
                    svc.currentVersion == 'dev'
                        ? 'dev'
                        : 'v${svc.currentVersion}',
                  ),
                  if (svc.checkResult != null && svc.checkResult!.hasUpdate)
                    _infoRow(
                      c,
                      LocaleScope.of(context).latestVersion,
                      'v${svc.checkResult!.latestVersion}',
                    ),
                  if (svc.checkResult != null && svc.checkResult!.hasUpdate)
                    _infoRow(
                      c,
                      LocaleScope.of(context).publishDate,
                      _formatDate(svc.checkResult!.publishedAt),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            // Update card
            _SettingCard(
              label: LocaleScope.of(context).softwareUpdate,
              description: LocaleScope.of(context).checkUpdateDesc,
              vertical: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              LocaleScope.of(context).autoCheckUpdate,
                              style: TextStyle(
                                fontSize: 12,
                                color: c.textPrimary,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              LocaleScope.of(context).autoCheckUpdateDesc,
                              style: TextStyle(
                                fontSize: 11,
                                color: c.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      ShadSwitch(
                        value: settingsProvider.autoCheckUpdate,
                        onChanged: (v) =>
                            settingsProvider.setAutoCheckUpdate(v),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              LocaleScope.of(context).updateChannel,
                              style: TextStyle(
                                fontSize: 12,
                                color: c.textPrimary,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              LocaleScope.of(context).updateChannelDesc,
                              style: TextStyle(
                                fontSize: 11,
                                color: c.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      ShadSelect<String>(
                        initialValue: settingsProvider.updateChannel,
                        options: [
                          ShadOption(
                            value: 'stable',
                            child: Text(
                              LocaleScope.of(context).updateChannelStable,
                            ),
                          ),
                          ShadOption(
                            value: 'frontier',
                            child: Text(
                              LocaleScope.of(context).updateChannelFrontier,
                            ),
                          ),
                        ],
                        selectedOptionBuilder: (context, value) => Text(
                          value == 'frontier'
                              ? LocaleScope.of(context).updateChannelFrontier
                              : LocaleScope.of(context).updateChannelStable,
                        ),
                        onChanged: (v) {
                          if (v != null) settingsProvider.setUpdateChannel(v);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildUpdateSection(context, svc, c),
                ],
              ),
            ),
            const SizedBox(height: 10),
            // Browser extension card
            _ExtensionCard(colors: c),
            const SizedBox(height: 10),
            // Log export card
            _LogExportCard(colors: c, settingsProvider: settingsProvider),
            const SizedBox(height: 10),
            // Donate card
            _DonateCard(colors: c),
          ],
        );
      },
    );
  }

  Widget _infoRow(AppColors c, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: c.textMuted),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              color: c.textPrimary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUpdateSection(
    BuildContext context,
    UpdateService svc,
    AppColors c,
  ) {
    final status = svc.status;
    final s = LocaleScope.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Status message
        if (status == UpdateStatus.upToDate)
          _statusRow(c, LucideIcons.circleCheck, AppColors.green, s.upToDate),
        if (status == UpdateStatus.error)
          _statusRow(
            c,
            LucideIcons.circleAlert,
            AppColors.red,
            svc.errorMessage,
          ),
        if (status == UpdateStatus.available)
          _statusRow(
            c,
            LucideIcons.circleArrowDown,
            AppColors.amber,
            s.newVersionFound(svc.checkResult?.latestVersion ?? ''),
          ),
        if (status == UpdateStatus.readyToInstall)
          _statusRow(
            c,
            LucideIcons.circleCheck,
            AppColors.green,
            s.downloadComplete,
          ),

        // Download progress
        if (status == UpdateStatus.downloading) ...[
          _statusRow(c, LucideIcons.download, c.accent, s.downloadingUpdate),
          const SizedBox(height: 10),
          _buildProgressSection(context, svc, c),
        ],

        const SizedBox(height: 14),

        // Action buttons
        Row(
          children: [
            if (status == UpdateStatus.idle ||
                status == UpdateStatus.upToDate ||
                status == UpdateStatus.error)
              ShadButton.outline(
                size: ShadButtonSize.sm,
                enabled: status != UpdateStatus.checking,
                onPressed: svc.checkForUpdate,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (status == UpdateStatus.checking) ...[
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: c.textSecondary,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(s.checking),
                    ] else ...[
                      Icon(
                        LucideIcons.refreshCw,
                        size: 13,
                        color: c.textSecondary,
                      ),
                      const SizedBox(width: 6),
                      Text(s.checkUpdate),
                    ],
                  ],
                ),
              ),
            if (status == UpdateStatus.error && svc.canFallbackToTask) ...[
              const SizedBox(width: 8),
              ShadButton.outline(
                size: ShadButtonSize.sm,
                onPressed: () {
                  if (svc.downloadUpdateViaTask()) {
                    FluxSonner.of(context).show(
                      ShadToast(
                        title: Text(s.updateFallbackTaskCreated),
                        duration: const Duration(seconds: 3),
                      ),
                    );
                  }
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      LucideIcons.circlePlus,
                      size: 13,
                      color: c.textSecondary,
                    ),
                    const SizedBox(width: 6),
                    Text(s.updateFallbackToTask),
                  ],
                ),
              ),
            ],
            if (status == UpdateStatus.checking)
              ShadButton.outline(
                size: ShadButtonSize.sm,
                enabled: false,
                onPressed: () {},
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: c.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(s.checking),
                  ],
                ),
              ),
            if (status == UpdateStatus.available) ...[
              ShadButton(
                size: ShadButtonSize.sm,
                onPressed: svc.downloadUpdate,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      LucideIcons.download,
                      size: 13,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      s.downloadUpdate(
                        UpdateService.formatBytes(
                          svc.checkResult?.fileSize ?? 0,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ShadButton.outline(
                size: ShadButtonSize.sm,
                onPressed: svc.checkForUpdate,
                child: Text(s.recheck),
              ),
            ],
            if (status == UpdateStatus.readyToInstall) ...[
              ShadButton(
                size: ShadButtonSize.sm,
                onPressed: svc.installUpdate,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      LucideIcons.rotateCcw,
                      size: 13,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 6),
                    Text(s.installAndRestart),
                  ],
                ),
              ),
            ],
            const Spacer(),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => launchUrl(Uri.parse('https://fluxdown.zerx.dev')),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.globe, size: 12, color: c.accent),
                    const SizedBox(width: 5),
                    Text(
                      s.officialWebsite,
                      style: TextStyle(
                        fontSize: 11,
                        color: c.accent,
                        decoration: TextDecoration.underline,
                        decorationColor: c.accent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _statusRow(AppColors c, IconData icon, Color color, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: c.textPrimary),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressSection(
    BuildContext context,
    UpdateService svc,
    AppColors c,
  ) {
    final p = svc.progress;
    if (p == null) return const SizedBox.shrink();

    final m = AppMetrics.of(context);
    final s = LocaleScope.of(context);
    final fraction = p.totalBytes > 0
        ? (p.downloadedBytes / p.totalBytes).clamp(0.0, 1.0)
        : 0.0;
    final pctText = '${(fraction * 100).toStringAsFixed(1)}%';
    final sizeText =
        '${UpdateService.formatBytes(p.downloadedBytes)} / ${UpdateService.formatBytes(p.totalBytes)}';
    final speedText = UpdateService.formatSpeed(p.speed);
    final segments = p.segments;
    final activeSegments = p.activeSegments;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: m.brXs,
          child: LinearProgressIndicator(
            value: fraction,
            backgroundColor: c.surface2,
            valueColor: AlwaysStoppedAnimation<Color>(c.accent),
            minHeight: 6,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(
              '$pctText  $sizeText',
              style: TextStyle(fontSize: 11, color: c.textMuted),
            ),
            const Spacer(),
            if (segments > 1) ...[
              Icon(LucideIcons.layers, size: 11, color: m.emphasis(c.accent)),
              const SizedBox(width: 3),
              Text(
                s.segmentsDownloading(activeSegments, segments),
                style: TextStyle(fontSize: 11, color: m.emphasis(c.accent)),
              ),
              const SizedBox(width: 10),
            ],
            Text(speedText, style: TextStyle(fontSize: 11, color: c.textMuted)),
          ],
        ),
      ],
    );
  }

  String _formatDate(String isoDate) {
    if (isoDate.isEmpty) return '';
    final dt = DateTime.tryParse(isoDate);
    if (dt == null) return isoDate;
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}

// ─────────────────────────────────────────────
// 浏览器扩展卡片
// ─────────────────────────────────────────────

class _ExtensionCard extends StatelessWidget {
  final AppColors colors;
  const _ExtensionCard({required this.colors});

  static const _chromeStoreUrl =
      'https://chromewebstore.google.com/detail/fluxdown/meleenglfggcmcajknpeeeiobnpfmahc';
  static const _firefoxStoreUrl =
      'https://addons.mozilla.org/firefox/addon/fluxdown/';
  static const _edgeStoreUrl =
      'https://microsoftedge.microsoft.com/addons/detail/fluxdown/nglkkjbogjghekbhhcnccnpfedjbdhhd';
  static const _offlinePackagesUrl = 'https://fluxdown.zerx.dev/#download';

  @override
  Widget build(BuildContext context) {
    final c = colors;
    final s = LocaleScope.of(context);
    return _SettingCard(
      label: s.extensionCardTitle,
      description: s.extensionCardDesc,
      vertical: true,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _linkButton(
            label: s.extensionChromeStore,
            url: _chromeStoreUrl,
            colors: c,
          ),
          _linkButton(
            label: s.extensionFirefoxStore,
            url: _firefoxStoreUrl,
            colors: c,
          ),
          _linkButton(
            label: s.extensionEdgeStore,
            url: _edgeStoreUrl,
            colors: c,
          ),
          _linkButton(
            label: s.extensionOfflinePackages,
            url: _offlinePackagesUrl,
            colors: c,
            icon: LucideIcons.download,
          ),
        ],
      ),
    );
  }

  Widget _linkButton({
    required String label,
    required String url,
    required AppColors colors,
    IconData icon = LucideIcons.puzzle,
  }) {
    return ShadButton.outline(
      size: ShadButtonSize.sm,
      onPressed: () => launchUrl(Uri.parse(url)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: colors.textSecondary),
          const SizedBox(width: 6),
          Text(label),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 捐赠卡片
// ─────────────────────────────────────────────

class _DonateCard extends StatelessWidget {
  final AppColors colors;
  const _DonateCard({required this.colors});

  /// 构建期注入的首次 commit 日期，按当前语言格式化。
  String _firstDateText(S s) {
    final dt = DateTime.tryParse(statsFirstCommitDate);
    if (dt == null) return statsFirstCommitDate;
    return s.donateDate(dt.year, dt.month, dt.day);
  }

  @override
  Widget build(BuildContext context) {
    final c = colors;
    final s = LocaleScope.of(context);
    return _SettingCard(
      label: s.donateTitle,
      description: s.donateThanks,
      vertical: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.donateBody(
              _firstDateText(s),
              statsReleaseCount,
              statsCommitCount,
            ),
            style: TextStyle(fontSize: 12, height: 1.6, color: c.textSecondary),
          ),
          const SizedBox(height: 12),
          ShadButton(
            size: ShadButtonSize.sm,
            onPressed: () =>
                launchUrl(Uri.parse('https://fluxdown.zerx.dev/sponsor')),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(LucideIcons.heart, size: 13, color: Colors.white),
                const SizedBox(width: 6),
                Text(s.donateButton),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 日志导出卡片
// ─────────────────────────────────────────────

class _LogExportCard extends StatefulWidget {
  final AppColors colors;
  final SettingsProvider settingsProvider;
  const _LogExportCard({required this.colors, required this.settingsProvider});

  @override
  State<_LogExportCard> createState() => _LogExportCardState();
}

class _LogExportCardState extends State<_LogExportCard> {
  bool _exporting = false;

  /// 日志总大小上限可选项（MB）
  static const _maxSizeOptions = [5, 10, 20, 50, 100];

  Future<void> _exportLogs() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final s = LocaleScope.of(context);
      final now = DateTime.now();
      final datePart =
          '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
      final result = await FilePickerService.saveFile(
        dialogTitle: s.logSelectExportDir,
        fileName: 'fluxdown_logs_$datePart.zip',
        allowedExtensions: ['zip'],
      );
      if (result == null || !mounted) {
        if (mounted) setState(() => _exporting = false);
        return;
      }
      final savePath = result.endsWith('.zip') ? result : '$result.zip';
      final count = await LogService.instance.exportLogs(savePath);
      if (!mounted) return;
      if (count > 0) {
        FluxSonner.of(context).show(
          ShadToast(
            title: Text(s.logExportSuccess(count)),
            duration: const Duration(seconds: 3),
          ),
        );
      } else {
        FluxSonner.of(context).show(
          ShadToast(
            title: Text(s.logExportEmpty),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        FluxSonner.of(context).show(
          ShadToast.destructive(
            title: Text(LocaleScope.of(context).logExportFailed),
            description: Text(e.toString()),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _openLogDir() {
    final path = LogService.instance.logDir.path;
    if (Platform.isWindows) {
      Process.run('explorer', [path]);
    } else if (Platform.isMacOS) {
      Process.run('open', [path]);
    } else {
      Process.run('xdg-open', [path]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final s = LocaleScope.of(context);
    final fileCount = LogService.instance.logFileCount;
    final sizeBytes = LogService.instance.logDirSizeBytes;
    final sizeText = UpdateService.formatBytes(sizeBytes);
    final logger = LogService.instance;
    final logStatusText = logger.initialized && !logger.degraded
        ? s.logStatusHealthy
        : s.logStatusDegraded(logger.failureCount, logger.lastError ?? '—');

    return _SettingCard(
      label: s.logExport,
      description: s.logExportDesc,
      vertical: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.logExportInfo(fileCount, sizeText),
            style: TextStyle(fontSize: 12, color: c.textMuted),
          ),
          const SizedBox(height: 4),
          Text(
            logStatusText,
            style: TextStyle(
              fontSize: 11,
              color: logger.initialized && !logger.degraded
                  ? c.textMuted
                  : AppColors.red,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.logMaxSize,
                      style: TextStyle(
                        fontSize: 12,
                        color: c.textPrimary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      s.logMaxSizeDesc,
                      style: TextStyle(fontSize: 11, color: c.textMuted),
                    ),
                  ],
                ),
              ),
              ShadSelect<int>(
                initialValue: widget.settingsProvider.logMaxSizeMb,
                placeholder: Text('${widget.settingsProvider.logMaxSizeMb} MB'),
                options: _maxSizeOptions
                    .map((mb) => ShadOption(value: mb, child: Text('$mb MB')))
                    .toList(),
                selectedOptionBuilder: (context, value) => Text('$value MB'),
                onChanged: (v) {
                  if (v != null) {
                    widget.settingsProvider.setLogMaxSizeMb(v);
                    setState(() {});
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              ShadButton.outline(
                size: ShadButtonSize.sm,
                enabled: !_exporting,
                onPressed: _exportLogs,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_exporting) ...[
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: c.textSecondary,
                        ),
                      ),
                    ] else ...[
                      Icon(
                        LucideIcons.fileDown,
                        size: 13,
                        color: c.textSecondary,
                      ),
                    ],
                    const SizedBox(width: 6),
                    Text(s.logExportButton),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ShadButton.outline(
                size: ShadButtonSize.sm,
                onPressed: _openLogDir,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      LucideIcons.folderOpen,
                      size: 13,
                      color: c.textSecondary,
                    ),
                    const SizedBox(width: 6),
                    Text(s.logOpenDirButton),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

