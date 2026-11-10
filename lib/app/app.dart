import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/l10n/app_locale.dart';
import '../core/l10n/l10n.dart';
import '../core/platform/window_chrome.dart';
import '../core/services/player_notification.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/app_typography.dart';
import '../core/theme/theme_provider.dart';
import '../core/router/app_router.dart';
import '../core/theme/system_bars.dart';
import '../core/theme/system_brightness_sync.dart';
import '../core/utils/responsive_layout.dart';
import '../features/player/application/desktop_lyric_controller.dart';
import '../features/player/application/desktop_lyric_sync.dart';
import '../features/player/application/playback_controller.dart';
import '../core/theme/background_derivation.dart';
import '../features/player/domain/services/cover_color_extractor.dart';
import '../features/player/platform/desktop_lyric_overlay.dart';
import '../features/player/presentation/desktop_lyric_window.dart';
import '../features/plugin/application/plugin_providers.dart';
import '../features/settings/application/appearance_providers.dart';
import '../features/settings/application/font_providers.dart';
import '../features/settings/application/plugin_providers.dart';
import '../features/settings/application/settings_providers.dart';
import '../core/backup/playlist_sync_service.dart';
import '../core/backup/sync_timeout.dart';
import '../core/backup/webdav_service.dart';
import '../features/library/application/playlist_providers.dart';
import '../features/settings/data/plugin_repository.dart';
import '../shared/widgets/playlist_sync_indicator.dart';
import 'app_background_layer.dart';
import 'app_desktop_shell.dart';
import 'windows_title_bar.dart';

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
    // Windows：去掉系统标题栏，改由 Flutter 自绘一条（Win10 没法给系统标题栏
    // 上色，只有这么做才能和设置里的「背景颜色」完全一致）。
    WindowChrome.enableCustomTitleBar();
    WindowChrome.setDarkFrame(
      ref.read(themeColorsProvider).background.computeLuminance() < 0.5,
    );
    // 状态栏 / 系统栏样式：首帧之前就下发一次，避免启动瞬间还是系统默认的
    // 黑色（或带对比度遮罩）状态栏。之后由 build 里的 AnnotatedRegion 跟随。
    SystemBars.apply(light: ref.read(isLightThemeActiveProvider));
    // 开启「自动同步」时，进入应用先与远端同步一次歌单。
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _syncPlaylistsOnStartup(),
    );
    // Android 通知栏播放卡片上的「收藏 / 歌词」按钮。
    _initNotificationActions();
  }

  /// 通知栏卡片的按钮回调（仅 Android，其余平台直接跳过）。
  void _initNotificationActions() {
    if (!PlayerNotification.supported) return;
    PlayerNotification.attach(onAction: _handleNotificationAction);
    // 原生侧可能已经存了「Dart 还没就绪时点的按钮」，首帧后取一次；
    // 同时补一次初始状态：通知可能比 Dart 更早存在（后台恢复播放），
    // 只靠 build 里的 listen 拿不到初始值。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _syncNotificationFavorite();
      _syncNotificationLyricState();
      unawaited(_syncNotificationColor());
      final action = await PlayerNotification.consumeLaunchAction();
      if (!mounted || action == null) return;
      _handleNotificationAction(action);
    });
  }

  void _handleNotificationAction(String action) {
    switch (action) {
      case PlayerNotification.actionFavorite:
        unawaited(_toggleCurrentFavorite());
      case PlayerNotification.actionLyric:
        unawaited(_toggleDesktopLyric());
      case PlayerNotification.actionClose:
        // 通知栏 ✕：停播放并收起通知，队列保留（回到界面点播放还能接着听）。
        unawaited(ref.read(playbackControllerProvider.notifier).stopPlayback());
    }
  }

  /// 切换桌面歌词浮窗（通知栏「词」按钮）。
  Future<void> _toggleDesktopLyric() async {
    final sync = ref.read(desktopLyricSyncProvider.notifier);
    if (ref.read(desktopLyricSettingsProvider).enable) {
      await sync.disableDesktopLyric();
      return;
    }
    // 点通知栏时应用还算「前台」，原生侧会把悬浮窗设为不可见；先按后台处理，
    // 歌词窗才会立刻出现（回到应用时 lifecycle 回调会再把它隐藏）。
    await DesktopLyricOverlay.instance.setForeground(false);
    await sync.enableDesktopLyric();
  }

  /// 收藏 / 取消收藏当前播放的歌曲（与播放页、歌词页的红心同一份数据）。
  Future<void> _toggleCurrentFavorite() async {
    final song = ref.read(playbackControllerProvider).currentSong;
    if (song == null) return;
    final playlists = ref.read(playlistsProvider).valueOrNull;
    if (playlists == null) return;
    final favorites = playlists
        .where((p) => p.id == '__favorites__')
        .firstOrNull;
    final isFavorite = favorites?.songs.any((s) => s.id == song.id) ?? false;
    final notifier = ref.read(playlistsProvider.notifier);
    if (isFavorite) {
      await notifier.removeSongFromPlaylist('__favorites__', song.id);
    } else {
      await notifier.addSongToPlaylist('__favorites__', song);
    }
    _syncNotificationFavorite();
  }

  /// 把当前歌曲的收藏状态同步给通知栏（红心实心 / 空心）。
  void _syncNotificationFavorite() {
    if (!PlayerNotification.supported) return;
    final song = ref.read(playbackControllerProvider).currentSong;
    final playlists = ref.read(playlistsProvider).valueOrNull;
    final isFavorite =
        song != null &&
        (playlists
                ?.where((p) => p.id == '__favorites__')
                .firstOrNull
                ?.songs
                .any((s) => s.id == song.id) ??
            false);
    unawaited(PlayerNotification.setFavorite(isFavorite));
  }

  void _syncNotificationLyricState() {
    if (!PlayerNotification.supported) return;
    unawaited(
      PlayerNotification.setLyricState(
        enabled: ref.read(desktopLyricSettingsProvider).enable,
        primaryColor: ref.read(baseThemeColorsProvider).primary.toARGB32(),
      ),
    );
  }

  /// 把当前封面主色同步给 core 层的 [coverAccentColorProvider]。
  ///
  /// 「主界面跟随封面变色」只在这份颜色非空时生效；颜色没算好 / 没有封面时
  /// 什么都不做，背景会退回用户选的渐变。
  void _syncCoverAccent() {
    final color = ref
        .read(currentCoverColorProvider)
        .valueOrNull
        ?.dominantColor;
    if (color == null) return;
    if (ref.read(coverAccentColorProvider) == color) return;
    // build 期间不能直接改 provider，推到下一帧。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(coverAccentColorProvider.notifier).state = color;
    });
  }

  /// 把高斯模糊背景图的主色同步给 core 层：控件底色跟着照片的色调走，
  /// 中性灰压在彩色照片上会像「贴上去的」。
  void _syncBlurTint() {
    final tint = ref.read(blurBackgroundTintProvider).valueOrNull;
    if (ref.read(backgroundBlurTintProvider) == tint) return;
    // build 期间不能直接改 provider，推到下一帧。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(backgroundBlurTintProvider.notifier).state = tint;
    });
  }

  /// 让通知卡片的底色跟随当前封面（取色算法与播放页背景一致）。
  ///
  /// 直接对「这一刻的当前歌曲」取色，不走 currentCoverColorProvider：切歌瞬间
  /// provider 可能还没重建完，读 future 会拿到上一首歌的颜色。
  Future<void> _syncNotificationColor() async {
    if (!PlayerNotification.supported) return;
    final song = ref.read(playbackControllerProvider).currentSong;
    if (song == null) return;
    try {
      final result = await CoverColorExtractor.extractFromSong(song);
      // 取色期间可能已经切歌，旧结果不能覆盖新封面。
      if (ref.read(playbackControllerProvider).currentSong?.id != song.id) {
        return;
      }
      // 没有封面 / 提取失败时拿到的是默认灰，当作「没有主色」，用原生默认深色。
      final hasColor =
          result.dominantColor != CoverColorResult.defaultResult.dominantColor;
      final color = hasColor
          ? coverDarkBackgroundColor(result.dominantColor, lightness: 0.22)
          : null;
      await PlayerNotification.setAccentColor(color?.toARGB32());
    } catch (_) {
      // 取色失败就保持上一次的底色（首次为默认深色）。
    }
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
      // 启动时的一次性同步同样套 1 分钟超时，避免启动流程被卡住。
      // 启动时的一次性同步同样套 1 分钟超时，避免启动流程被卡住；
      // 超时会连带取消底层 HTTP 请求。
      final op = SyncAttempt(1);
      await op.run(
        PlaylistSyncService.pullAndMerge(
          WebDavService(config, cancelToken: op.cancelToken),
        ),
      );
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
        title: Text(tr('歌单同步失败'), style: TextStyle(color: colors.textPrimary)),
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
            child: Text(tr('重新同步'), style: TextStyle(color: colors.primary)),
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
    // 当前是否为浅色外观：状态栏图标的明暗跟着它走。
    final isLightActive = ref.watch(isLightThemeActiveProvider);
    // 「主界面跟随封面变色」要用的主色：core 层只负责存颜色，取色在
    // features 层（currentCoverColorProvider），所以在这里同步过去。
    // 监听负责切歌，[_syncCoverAccent] 负责首帧（监听不回溯已有结果）。
    ref.listen(currentCoverColorProvider, (previous, next) {
      _syncCoverAccent();
    });
    _syncCoverAccent();

    // 高斯模糊背景图的主色：同样由 features 层算好，这里转交给 core，
    // 控件底色（侧栏、卡片、按钮、搜索框…）据它派生。
    ref.listen(blurBackgroundTintProvider, (previous, next) {
      _syncBlurTint();
    });
    _syncBlurTint();

    // 同步全局语言,供非 widget 场景(如歌词控制器)使用
    currentLocale = appLocale;

    // Windows：窗口边框跟着主题背景色走（自绘标题栏本身在 builder 里，
    // 直接读 themeColorsProvider，改「背景颜色」立刻生效）。
    ref.listen(
      themeColorsProvider,
      (previous, next) =>
          WindowChrome.setDarkFrame(next.background.computeLuminance() < 0.5),
    );

    // 切歌 / 收藏变化时把红心状态同步给通知栏（仅 Android 有自定义通知卡片）；
    // 切歌同时会让通知卡片底色按新封面取色（与主界面背景无关）。
    if (PlayerNotification.supported) {
      ref.listen(currentSongIdentityProvider, (previous, next) {
        _syncNotificationFavorite();
        unawaited(_syncNotificationColor());
      });
      ref.listen(
        playlistsProvider,
        (previous, next) => _syncNotificationFavorite(),
      );
      ref.listen(
        desktopLyricSettingsProvider.select((settings) => settings.enable),
        (previous, next) => _syncNotificationLyricState(),
      );
      ref.listen(
        baseThemeColorsProvider.select((colors) => colors.primary),
        (previous, next) => _syncNotificationLyricState(),
      );
    }

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
          title: tr('Music'),
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
            final content = Listener(
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
                      data: MediaQuery.of(
                        context,
                      ).copyWith(textScaler: MediaQuery.of(context).textScaler),
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
                        (ResponsiveLayout.shouldShowSidebar(context)
                            ? 88.0
                            : 132.0) +
                        MediaQuery.paddingOf(context).bottom,
                    child: const PlaylistSyncIndicator(),
                  ),
                  const DesktopLyricLayer(),
                ],
              ),
            );
            // Windows：系统标题栏已经被去掉（见 WindowChrome），这里在路由之外
            // 顶一条自绘的标题栏，颜色跟着设置里的「背景颜色」走。
            // 放在 MaterialApp.builder 里，所有页面（含全屏播放页、弹窗之外的
            // 二级页面）都能拖窗口、点关闭。改样式失败时退回系统标题栏，
            // 不插这条，避免出现两个标题栏。
            final body = Platform.isWindows && WindowChrome.hasCustomTitleBar
                ? Column(
                    // stretch：标题栏和下面的内容都要铺满窗口宽度
                    // （Column 默认是 center，会让路由内容按自身宽度居中）。
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const WindowsTitleBar(),
                      Expanded(child: content),
                    ],
                  )
                : content;
            // 整个主界面的背景层：按「外观设置 → 背景颜色模式」画背景渐变
            // （+ 光晕）或用户选的图片的高斯模糊版本。各页面 Scaffold 都是
            // 透明的，这层才能透出来。
            final decoratedBody = Stack(
              fit: StackFit.passthrough,
              children: [
                Positioned.fill(
                  child: IgnorePointer(
                    child: const AppBackgroundLayer(),
                  ),
                ),
                body,
              ],
            );
            // 状态栏样式：透明 + 关掉系统给透明状态栏叠的半透明遮罩，
            // 让状态栏与页面背景完全同色（见 SystemBars 的说明）。
            // 用 AnnotatedRegion 而不是只调一次 SystemChrome，是为了跟随
            // 「浅色 / 深色 / 跟随系统」切换，也避免被页面自身的系统栏设置覆盖。
            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: SystemBars.overlayStyle(light: isLightActive),
              child: decoratedBody,
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
  /// 因此页面里的 `PopScope` 仍然生效（多选模式先退出多选、播放页先播放
  /// 退场动画再退出）；一级页面没有可返回内容时不做任何事。
  void _handleMouseBack(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    if ((event.buttons & kBackMouseButton) == 0) return;
    final delegate = appRouter.routerDelegate;
    if (delegate.currentConfiguration.matches.isEmpty) return;
    delegate.popRoute();
  }

  Future<void> _checkPluginsForUpdates() async {
    if (!mounted) return;
    // 插件「自动检测更新」已固定关闭（插件管理页不再提供开关），这里始终跳过；
    // 需要更新时由用户到插件管理页点右上角的「检查更新」。
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.system_update, color: Color(0xFF4CAF50), size: 24),
            const SizedBox(width: 8),
            Text(
              '插件更新',
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
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
              ...updates.map(
                (result) => Container(
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
                              result.remoteVersion != null &&
                                      result.remoteVersion != 'latest'
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
                ),
              ),
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
