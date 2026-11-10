import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../core/l10n/l10n.dart';
import '../../core/router/current_route_provider.dart';
import '../../core/router/navigation_shell_provider.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/theme_provider.dart';
import '../../core/utils/responsive_layout.dart';
import '../../features/player/presentation/mini_player.dart';
import '../../features/player/application/mini_player_visibility.dart';
import '../../features/player/application/playback_controller.dart';
import '../../features/player/domain/services/cover_color_extractor.dart';
import '../../features/download/application/download_providers.dart';
import '../../features/settings/application/update_providers.dart';
import '../../features/settings/presentation/update_dialog.dart';
import 'app_sidebar.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  /// 通知权限提示每个会话只弹一次。
  bool _notificationPromptShown = false;

  /// 当前挂着的路由器，用来监听「页面切换」以决定是否显示迷你播放器。
  GoRouter? _router;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(playbackControllerProvider.notifier).onMessage =
          _showPlaybackMessage;
      // 把导航壳暴露给路由之外的左侧导航栏：切换一级分类时用它切换分支，
      // 这样各分类自己的页面栈（已打开的二级页面）才能被保留。
      if (!mounted) return;
      ref.read(navigationShellProvider.notifier).state = widget.navigationShell;
      // 首帧也要记一次当前页面：直接从「最近播放」等页面冷启动时，
      // 路由不会再发通知，迷你播放器得按当前页隐藏。
      _syncRoutePath();
    });
    // 启动时自动检查更新（需开启「启动时检查更新」开关）
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // 首帧回调可能在部件已经销毁后才跑到（例如 initState 里抛错、
      // 或者路由被替换），此时 ref 已经失效，再 read 会抛
      // 「Looking up a deactivated widget's ancestor is unsafe」。
      if (!mounted) return;
      final info = await runStartupUpdateCheck(ref);
      if (info != null && mounted) {
        await showUpdateDialog(context, info);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final router = GoRouter.of(context);
    if (identical(router, _router)) return;
    _router?.routerDelegate.removeListener(_handleRouteChanged);
    _router = router;
    router.routerDelegate.addListener(_handleRouteChanged);
    // didChangeDependencies 仍在 build 阶段，写 provider 会撞上
    // 「不能在建树期间修改 provider」的断言，推迟到帧结束。
    _handleRouteChanged();
  }

  @override
  void dispose() {
    _router?.routerDelegate.removeListener(_handleRouteChanged);
    super.dispose();
  }

  /// 页面切换：把当前路径写进 [currentRoutePathProvider]。
  ///
  /// 路由解析（含首帧）会在这个部件的 build 期间发通知，直接改 provider 会
  /// 落在 build 阶段，所以统一推迟到帧结束再写。
  void _handleRouteChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncRoutePath();
    });
  }

  void _syncRoutePath() {
    final router = _router;
    if (router == null || !mounted) return;
    final path = currentPageUri(router).path;
    if (path.isEmpty || path == ref.read(currentRoutePathProvider)) return;
    ref.read(currentRoutePathProvider.notifier).state = path;
  }

  /// Android 播放通知依赖通知权限，缺少时弹框提醒用户开启。
  Future<void> _ensureNotificationPermission() async {
    if (_notificationPromptShown) return;
    try {
      final status = await Permission.notification.status;
      if (status.isGranted) return;
      if (!mounted) return;
      _notificationPromptShown = true;
      final colors = ref.read(themeColorsProvider);
      final openSettings = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: colors.surface,
          title: Text(
            context.tr('开启通知权限'),
            style: TextStyle(color: colors.textPrimary),
          ),
          content: Text(
            context.tr('播放通知需要通知权限，开启后可以在通知栏看到播放状态。'),
            style: TextStyle(color: colors.textSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(
                context.tr('暂不开启'),
                style: TextStyle(color: colors.textHint),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                context.tr('去开启'),
                style: TextStyle(color: colors.primary),
              ),
            ),
          ],
        ),
      );
      if (openSettings == true) {
        await openAppSettings();
      }
    } catch (_) {}
  }

  void _showPlaybackMessage(String message, {Color? backgroundColor}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: backgroundColor ?? Colors.grey[800],
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Android：开始播放时检查通知权限，缺少权限则提示用户开启。
    //
    // 必须写在 build 里：Riverpod 的 ref.listen 只允许在 ConsumerWidget /
    // ConsumerState.build 期间注册，放到 initState 会直接断言失败
    // （'ref.listen can only be used within the build method'），表现为红屏。
    // Riverpod 会按 build 周期自动维护订阅，重复注册是安全的。
    if (Platform.isAndroid) {
      ref.listen<bool>(
        playbackControllerProvider.select((state) => state.isPlaying),
        (previous, next) {
          if (previous == true || !next) return;
          unawaited(_ensureNotificationPermission());
        },
      );
    }
    ref.listen<DownloadNotification?>(downloadNotificationProvider, (
      prev,
      next,
    ) {
      if (next != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next.message),
            backgroundColor: next.backgroundColor ?? Colors.grey[800],
            behavior: SnackBarBehavior.floating,
            duration: next.duration,
          ),
        );
      }
    });
    final colors = ref.watch(themeColorsProvider);
    // 预热封面主色调：歌曲切换时就在后台 isolate 计算并缓存，
    // 用户再打开全屏播放页/歌词页时颜色已就绪，冷启动不出现
    // 「先默认色再换主题色」的跳变。
    ref.watch(currentCoverColorProvider);
    final showSidebar = ResponsiveLayout.shouldShowSidebar(context);

    if (showSidebar) {
      return _buildWideLayout(colors);
    }
    return _buildPhoneLayout(colors);
  }

  /// Phone layout: bottom navigation bar (current behavior).
  Widget _buildPhoneLayout(ThemeColors colors) {
    // 「我的」里的设置 / 插件管理 / 下载 / 听歌识曲 / 最近播放这些页面底部
    // 有自己的内容（列表、分页条），进去时把迷你播放器收起来，页面才能铺到底。
    final showMiniPlayer = ref.watch(miniPlayerVisibleProvider);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          RepaintBoundary(child: widget.navigationShell),
          if (showMiniPlayer)
            Positioned(
              left: 0,
              right: 0,
              bottom: 5,
              child: RepaintBoundary(child: const MiniPlayer()),
            ),
        ],
      ),
      bottomNavigationBar: RepaintBoundary(
        child: Container(
          decoration: BoxDecoration(
            // Android：底栏不铺自己的色块、也不投影，直接透出主界面的封面
            // 渐变，看起来与页面是一整块。其它平台保留 surface 色块。
            color: Platform.isAndroid ? Colors.transparent : colors.surface,
            boxShadow: Platform.isAndroid
                ? null
                : [
                    BoxShadow(
                      color: colors.shadow,
                      blurRadius: 8,
                      offset: const Offset(0, -2),
                    ),
                  ],
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: BottomNavigationBar(
                currentIndex: widget.navigationShell.currentIndex,
                onTap: (index) => switchMainTab(widget.navigationShell, index),
                type: BottomNavigationBarType.fixed,
                backgroundColor: Colors.transparent,
                elevation: 0,
                selectedItemColor: colors.primary,
                unselectedItemColor: colors.textHint,
                selectedFontSize: 11,
                unselectedFontSize: 11,
                items: [
                  for (final item in appNavItems)
                    BottomNavigationBarItem(
                      icon: Icon(item.icon),
                      activeIcon: Icon(item.activeIcon),
                      label: context.tr(item.label),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 宽屏内容区：左侧导航栏（含底部播放器）由 `AppDesktopShell` 统一渲染在
  /// 路由之外，这里只负责当前分支内容，保证二级页面不会盖住导航栏。
  Widget _buildWideLayout(ThemeColors colors) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: RepaintBoundary(child: widget.navigationShell),
    );
  }
}
