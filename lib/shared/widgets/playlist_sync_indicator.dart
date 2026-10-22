import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/backup/playlist_sync_status.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/theme_provider.dart';

/// 应用窗口底部的歌单同步提示。
///
/// 自动同步（收藏页增删改触发的推送、开启「歌单实时同步」后触发的同步）
/// 进行时显示「正在同步歌单…」，结束后短暂显示成功 / 失败原因再自动隐藏。
/// 不拦截点击，浮在内容之上、迷你播放器之上。
class PlaylistSyncIndicator extends ConsumerWidget {
  const PlaylistSyncIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(playlistSyncStatusProvider);
    final colors = ref.watch(themeColorsProvider);

    return IgnorePointer(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        reverseDuration: const Duration(milliseconds: 150),
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.35),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        child: status.isVisible
            ? _buildPill(context, colors, status)
            : const SizedBox.shrink(),
      ),
    );
  }

  Widget _buildPill(
    BuildContext context,
    ThemeColors colors,
    PlaylistSyncStatus status,
  ) {
    final failed = status.phase == PlaylistSyncPhase.failed;
    final success = status.phase == PlaylistSyncPhase.success;
    final label = failed
        ? context.tr('歌单同步失败：${status.message ?? ''}')
        : success
        ? context.tr('歌单同步完成')
        : context.tr('正在同步歌单…');

    return Center(
      // Material：这个提示浮在路由之上，没有 Scaffold 提供默认文字样式，
      // 这里用透明 Material 继承主题字体。
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 460),
          margin: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: 8,
          ),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(AppRadius.full),
            border: Border.all(
              color: failed
                  ? colors.error.withValues(alpha: 0.5)
                  : colors.divider,
            ),
            boxShadow: [
              BoxShadow(
                color: colors.shadow,
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (failed)
                Icon(Icons.error_outline, size: 16, color: colors.error)
              else if (success)
                Icon(Icons.check_circle, size: 16, color: colors.success)
              else
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.primary,
                  ),
                ),
              const SizedBox(width: AppSpacing.sm),
              Flexible(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: failed ? colors.error : colors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
