import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/theme_provider.dart';
import '../../core/utils/responsive_layout.dart';
import '../../features/player/presentation/mini_player.dart';
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(playbackControllerProvider.notifier).onMessage =
          _showPlaybackMessage;
    });
    // 启动时自动检查更新（需开启「启动时检查更新」开关）
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final info = await runStartupUpdateCheck(ref);
      if (info != null && mounted) {
        await showUpdateDialog(context, info);
      }
    });
    // Android：开始播放时检查通知权限，缺少权限则提示用户开启。
    if (Platform.isAndroid) {
      ref.listen<bool>(
        playbackControllerProvider.select((state) => state.isPlaying),
        (previous, next) {
          if (previous == true || !next) return;
          unawaited(_ensureNotificationPermission());
        },
      );
    }
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
    ref.listen<DownloadNotification?>(downloadNotificationProvider, (prev, next) {
      if (next != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next.message),
            backgroundColor: next.backgroundColor ?? Colors.grey[800],
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
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
    return Scaffold(
      backgroundColor: colors.background,
      body: Stack(
        children: [
          RepaintBoundary(
            child: widget.navigationShell,
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 5,
            child: RepaintBoundary(
              child: const MiniPlayer(),
            ),
          ),
        ],
      ),
      bottomNavigationBar: RepaintBoundary(
        child: Container(
          decoration: BoxDecoration(
            color: colors.surface,
            boxShadow: [
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
                onTap: (index) => widget.navigationShell.goBranch(index),
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
      backgroundColor: colors.background,
      body: RepaintBoundary(
        child: widget.navigationShell,
      ),
    );
  }
}
