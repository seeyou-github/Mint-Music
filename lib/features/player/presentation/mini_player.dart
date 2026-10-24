import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../application/playback_controller.dart';
import '../application/root_overlay_tracker.dart';
import '../domain/models/song.dart';
import 'widgets/play_queue_sheet.dart';

class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 桌面/平板（侧边栏布局）下播放器固定在左侧导航栏底部（SidebarPlayer），
    // 这里返回空占位，避免页面里再出现一个重复的迷你播放器。
    if (ResponsiveLayout.shouldShowSidebar(context)) {
      return const SizedBox.shrink();
    }
    final colors = ref.watch(themeColorsProvider);
    ref.watch(currentSongIdentityProvider);
    final song = ref.read(playbackControllerProvider).currentSong;
    final isPlaying = ref.watch(
      playbackControllerProvider.select((s) => s.isPlaying),
    );
    // 与全屏播放页保持一致：加载中也显示转圈，避免「迷你=暂停、全屏=转圈」的状态不一致。
    final isLoading = ref.watch(
      playbackControllerProvider.select((s) => s.isLoading),
    );
    final controller = ref.read(playbackControllerProvider.notifier);
    if (song == null) return const SizedBox.shrink();

    // 迷你播放器是固定 56px 的紧凑布局，系统大字体/大显示设置会把两行
    // 文字撑高导致 RenderFlex 溢出（底部出现红/黄条纹与红色报错）。
    // 限制文本缩放上限，保证任意字体设置下布局都不会被撑破。
    final isTablet = ResponsiveLayout.isTablet(context);
    final height = isTablet ? 64.0 : 56.0;
    final artSize = isTablet ? 52.0 : 44.0;
    final artRadius = artSize / 2;
    final titleFontSize = isTablet ? 14.0 : 13.0;
    final subtitleFontSize = isTablet ? 12.0 : 11.0;
    final iconSize = isTablet ? 22.0 : 20.0;
    final playIconSize = isTablet ? 26.0 : 24.0;

    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.2,
      child: GestureDetector(
        onTap: () {
          // 播放详情页已打开：再点一次关闭（开关式）。状态查登记表：
          // StatefulShellRoute 下路由配置对根级路由的压栈反映不可靠。
          if (RootOverlayTracker.instance.isCovered) {
            RootOverlayTracker.instance.willPopTop();
            context.pop();
            return;
          }
          context.push('/player/full');
        },
        child: Container(
          height: height,
          margin: EdgeInsets.symmetric(horizontal: isTablet ? 12 : AppSpacing.sm),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(height / 2),
            boxShadow: [
              BoxShadow(
                color: colors.shadow,
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              const SizedBox(width: AppSpacing.xs),
              ClipRRect(
                borderRadius: BorderRadius.circular(artRadius),
                child: Container(
                  width: artSize,
                  height: artSize,
                  decoration: BoxDecoration(color: colors.surfaceVariant),
                  child: _buildCover(colors, song, artSize),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.title,
                      style: TextStyle(
                        fontSize: titleFontSize,
                        fontWeight: FontWeight.w500,
                        color: colors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 1),
                    Text(
                      song.artist,
                      style: TextStyle(fontSize: subtitleFontSize, color: colors.textHint),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              // 控制按钮紧凑靠右：间距略小于默认 IconButton 视觉边距，
              // 上一首 / 播放暂停 / 下一首 / 播放队列四个按钮排成一组。
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                constraints: const BoxConstraints(minWidth: 32),
                icon: Icon(
                  Icons.skip_previous,
                  size: iconSize,
                  color: colors.textSecondary,
                ),
                onPressed: () => controller.previous(),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                constraints: const BoxConstraints(minWidth: 32),
                icon: SizedBox(
                  // 图标与加载动画放在同样大小的方框里，避免加载动画出现 /
                  // 消失时迷你播放器高度变化。
                  width: playIconSize,
                  height: playIconSize,
                  child: isLoading
                      ? Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: colors.textPrimary,
                            ),
                          ),
                        )
                      : Icon(
                          isPlaying ? Icons.pause : Icons.play_arrow,
                          size: playIconSize,
                          color: colors.textPrimary,
                        ),
                ),
                // 遵循 CeruMusic/Sollin-Music：加载期间禁用按钮，
                // 避免用户在 URL 获取 / 换源过程中连点导致状态错乱。
                onPressed: isLoading ? null : () => controller.togglePlayPause(),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                constraints: const BoxConstraints(minWidth: 32),
                icon: Icon(
                  Icons.skip_next,
                  size: iconSize,
                  color: colors.textSecondary,
                ),
                onPressed: () => controller.next(),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.only(left: 4, right: 8),
                constraints: const BoxConstraints(minWidth: 32),
                icon: Icon(
                  Icons.queue_music,
                  size: iconSize,
                  color: colors.textSecondary,
                ),
                // 与全屏播放页相同的播放队列面板，点击直接弹出，无需跳转
                onPressed: () {
                  showPlayQueueSheet(
                    context,
                    playbackState: ref.read(playbackControllerProvider),
                    controller: controller,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCover(ThemeColors colors, Song song, double artSize) {
    // 优先使用 coverUrl（精准匹配后的在线封面），再回退到设备本地封面
    if (song.coverUrl != null && song.coverUrl!.isNotEmpty) {
      return MusicCoverImage(
        key: ValueKey('mp_cover_img_${song.id}'),
        url: song.coverUrl,
        fit: BoxFit.cover,
        errorWidget: Icon(Icons.music_note, size: 20, color: colors.primary),
      );
    }
    if (song.mediaStoreId != null || song.isLocal) {
      return MusicCoverImage(
        key: ValueKey('mp_cover_img_${song.id}'),
        songId: song.id,
        mediaStoreId: song.mediaStoreId,
        fit: BoxFit.cover,
        errorWidget: Icon(Icons.music_note, size: 20, color: colors.primary),
      );
    }
    return Icon(Icons.music_note, size: 20, color: colors.primary);
  }
}
