import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/l10n/app_locale.dart';
import '../core/l10n/l10n.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/app_typography.dart';
import '../core/theme/theme_provider.dart';
import '../core/router/app_router.dart';
import '../core/theme/system_brightness_sync.dart';
import '../core/utils/responsive_layout.dart';
import '../features/player/presentation/desktop_lyric_window.dart';
import '../features/plugin/application/plugin_providers.dart';
import '../features/settings/application/font_providers.dart';
import '../features/settings/application/plugin_providers.dart';
import '../features/settings/application/settings_providers.dart';
import '../core/backup/playlist_sync_service.dart';
import '../core/backup/webdav_service.dart';
import '../features/library/application/playlist_providers.dart';
import '../features/settings/data/plugin_repository.dart';
import '../shared/widgets/playlist_sync_indicator.dart';
import 'app_desktop_shell.dart';

class App extends ConsumerStatefulWidget {
  const App({super.key});

  @override
  ConsumerState<App> createState() => _AppState();
}

class _AppState extends ConsumerState<App> {
  bool _hasCheckedUpdates = false;

  @override
  void initState() {
    super.initState();
    // 开启「歌单实时同步」时，进入应用先与远端同步一次歌单。
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPlaylistsOnStartup());
  }

  /// 启动时从 WebDAV 同步歌单；失败时弹框提示原因并提供「重新同步」。
  Future<void> _syncPlaylistsOnStartup() async {
    if (!mounted) return;
    final config = ref.read(webDavConfigProvider);
    if (!config.playlistSyncEnabled) return;
    try {
      // 先确保本地歌单已加载（首次启动会创建「我的收藏」、迁移旧数据库数据），
      // 再与远端合并，避免用空数据覆盖远端。
      try {
        await ref.read(playlistsProvider.future);
      } catch (e) {
        debugPrint('[App] 本地歌单加载失败，仍尝试远端同步: $e');
      }
      await PlaylistSyncService.pullAndMerge(WebDavService(config));
      if (!mounted) return;
      ref.invalidate(playlistsProvider);
    } catch (e) {
      if (!mounted) return;
      await _showSyncFailedDialog(describeWebDavError(e));
    }
  }

  Future<void> _showSyncFailedDialog(String reason) async {
    if (!mounted) return;
    // App 位于 MaterialApp 之上，自身 context 找不到 Navigator；
    // 用路由根 Navigator 的 Overlay context 作为弹窗宿主。
    final dialogContext =
        appRouter.routerDelegate.navigatorKey.currentState?.overlay?.context;
    if (dialogContext == null) return;
    final colors = ref.read(themeColorsProvider);
    final retry = await showDialog<bool>(
      context: dialogContext,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(
          tr('歌单同步失败'),
          style: TextStyle(color: colors.textPrimary),
        ),
        content: SingleChildScrollView(
          child: Text(
            tr('同步远端歌单失败：$reason'),
            style: TextStyle(color: colors.textSecondary),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('取消'), style: TextStyle(color: colors.textHint)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              tr('重新同步'),
              style: TextStyle(color: colors.primary),
            ),
          ),
        ],
      ),
    );
    if (retry != true || !mounted) return;
    await _syncPlaylistsOnStartup();
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);
    final appLocale = ref.watch(appLocaleProvider);
    // 应用字体：设置里导入并选中的字体（为空则用默认字体）。
    final appFontFamily = ref.watch(appFontSelectedProvider);
    // 同步全局语言,供非 widget 场景(如歌词控制器)使用
    currentLocale = appLocale;

    // Listen for plugin initialization completion to trigger update check
    ref.listen(pluginInitializedProvider, (previous, next) {
      next.whenData((_) {
        if (!_hasCheckedUpdates) {
          _hasCheckedUpdates = true;
          _checkPluginsForUpdates();
        }
      });
    });

    // Also check if plugins were already initialized (e.g. on hot reload)
    final pluginState = ref.watch(pluginInitializedProvider);
    if (pluginState.hasValue && !_hasCheckedUpdates) {
      _hasCheckedUpdates = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _checkPluginsForUpdates();
      });
    }

    // 系统亮/暗变化同步进 provider，「跟随系统」主题才能实时跟随
    return SystemBrightnessSync(
      child: L10n(
        locale: appLocale,
        child: MaterialApp.router(
          title: tr('薄荷音乐'),
          debugShowCheckedModeBanner: false,
          theme: _applyAppFont(AppTheme.light, appFontFamily),
          darkTheme: _applyAppFont(AppTheme.dark, appFontFamily),
          themeMode: themeMode,
          routerConfig: appRouter,
        builder: (context, child) {
          final deviceType = ResponsiveLayout.getDeviceType(context);
          final layoutMode = ResponsiveLayout.getLayoutMode(context);
          final isLandscape = ResponsiveLayout.isLandscape(context);
          final isTablet = ResponsiveLayout.isTablet(context);
          // 桌面歌词层与路由内容同级,因此会悬浮在所有页面/弹窗之上。
          // StackFit.passthrough 保证 Navigator 依旧拿到铺满屏幕的紧约束。
          return Listener(
            // 鼠标侧键「后退」(Windows 上的 XButton1) 触发的指针事件。
            // 放在路由之上，因此所有一级/二级页面都能响应。
            behavior: HitTestBehavior.translucent,
            onPointerDown: _handleMouseBack,
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                ResponsiveWrapper(
                  deviceType: deviceType,
                  layoutMode: layoutMode,
                  isLandscape: isLandscape,
                  isTablet: isTablet,
                  child: MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      textScaler: MediaQuery.of(context).textScaler,
                    ),
                    // 宽屏下左侧导航栏渲染在路由之外，二级页面不会再遮挡它。
                    child: AppDesktopShell(
                      child: child ?? const SizedBox.shrink(),
                    ),
                  ),
                ),
                // 歌单自动同步提示：浮在窗口底部（迷你播放器 / 底部导航之上），
                // 只在收藏页增删改、开启实时同步开关触发的同步时出现。
                Positioned(
                  left: 0,
                  right: 0,
                  bottom:
                      (ResponsiveLayout.shouldShowSidebar(context) ? 88.0 : 132.0) +
                      MediaQuery.paddingOf(context).bottom,
                  child: const PlaylistSyncIndicator(),
                ),
                const DesktopLyricLayer(),
              ],
            ),
          );
        },
        ),
      ),
    );
  }

  /// 把应用字体应用到主题的文字样式上。
  ///
  /// 没有选择过字体时使用默认字体（内置的思源宋体）。
  ThemeData _applyAppFont(ThemeData theme, String? family) {
    final effective = (family == null || family.isEmpty)
        ? AppTypography.defaultFontFamily
        : family;
    return theme.copyWith(
      textTheme: theme.textTheme.apply(fontFamily: effective),
    );
  }

  /// 鼠标侧键「后退」：与系统返回键等效（关闭弹窗 / 返回上一页）。
  ///
  /// 复用 [GoRouterDelegate.popRoute]，与 Android 系统返回键同一套逻辑，
  /// 因此页面里的 `PopScope` 仍然生效（多选模式先退出多选、播放页先冻结
  /// AMLL WebView 再退出）；一级页面没有可返回内容时不做任何事。
  void _handleMouseBack(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    if ((event.buttons & kBackMouseButton) == 0) return;
    final delegate = appRouter.routerDelegate;
    if (delegate.currentConfiguration.matches.isEmpty) return;
    delegate.popRoute();
  }

  Future<void> _checkPluginsForUpdates() async {
    if (!mounted) return;
    // 插件「自动检测更新」默认关闭，只有用户主动开启后才在启动时检查。
    if (!ref.read(pluginAutoCheckUpdateProvider)) return;
    try {
      final repo = PluginRepository();
      final results = await repo.checkAllPluginUpdates();
      final available = results.where((r) => r.available).toList();

      if (available.isNotEmpty && mounted) {
        _showUpdateNotificationDialog(available);
      }
    } catch (e) {
      debugPrint('App startup plugin update check failed: $e');
    }
  }

  void _showUpdateNotificationDialog(List<PluginUpdateResult> updates) {
    if (!mounted) return;
    final colors = ref.read(themeColorsProvider);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: Row(
          children: [
            const Icon(Icons.system_update, color: Color(0xFF4CAF50), size: 24),
            const SizedBox(width: 8),
            Text(
              '插件更新',
              style: TextStyle(color: colors.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '发现 ${updates.length} 个插件可更新：',
                style: TextStyle(color: colors.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 12),
              ...updates.map((result) => Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.surfaceVariant,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(Icons.extension, color: colors.primary, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            result.plugin.name,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: colors.textPrimary,
                            ),
                          ),
                          Text(
                            result.remoteVersion != null && result.remoteVersion != 'latest'
                                ? 'v${result.plugin.version} → v${result.remoteVersion}'
                                : 'v${result.plugin.version} → 可更新',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF4CAF50),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              )),
              const SizedBox(height: 4),
              Text(
                '前往 插件管理 页面可进行更新操作。',
                style: TextStyle(fontSize: 12, color: colors.textHint),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('稍后', style: TextStyle(color: colors.textHint)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              // 跳到「我的」分支里的插件管理页。
              GoRouter.of(context).go('/plugin-management');
            },
            child: const Text(
              '去更新',
              style: TextStyle(
                color: Color(0xFF4CAF50),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
