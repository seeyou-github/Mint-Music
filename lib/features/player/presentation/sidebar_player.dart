import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_routes.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../shared/widgets/marquee_text.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../application/playback_controller.dart';
import '../domain/models/song.dart';
import 'widgets/play_queue_sheet.dart';

/// 桌面端左侧导航栏底部的播放器。
///
/// 布局（三行）：
/// 1. 封面 + 歌曲名 / 歌手名（歌手名在歌曲名下方，曲名过长自动滚动，
///    点击该区域打开播放页）
/// 2. 剩余时间
/// 3. 播放控件（上一首 / 播放暂停 / 下一首 / 播放队列）
///
/// 该组件渲染在 Router 之外（导航栏属于根布局），因此跳转与播放队列弹窗
/// 都通过全局 [appRouter] / 根 Overlay 的 context 完成。
class SidebarPlayer extends ConsumerWidget {
  const SidebarPlayer({super.key});

  static const double _artSize = 44;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(themeColorsProvider);
    // 与 MiniPlayer 一致：曲目字段（封面 / 歌词等）被精准匹配更新后，
    // Song 的 == 只比较 id，因此借助 identity provider 触发重建。
    ref.watch(currentSongIdentityProvider);
    final song = ref.read(playbackControllerProvider).currentSong;
    if (song == null) return const SizedBox.shrink();

    final isPlaying = ref.watch(
      playbackControllerProvider.select((s) => s.isPlaying),
    );
    final isLoading = ref.watch(
      playbackControllerProvider.select((s) => s.isLoading),
    );
    final controller = ref.read(playbackControllerProvider.notifier);

    // 侧边栏宽度固定，系统大字体时容易把三行撑破，这里限制文本缩放上限。
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.2,
      // 侧边栏背景由外层 Container 绘制，这里用透明 Material 承载
      // InkWell / IconButton 的水波纹，避免水波纹被背景色盖住。
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: colors.divider.withValues(alpha: 0.3),
                width: 0.5,
              ),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildSongInfo(colors, song),
              const SizedBox(height: 6),
              _SidebarRemainingTime(colors: colors),
              const SizedBox(height: 2),
              _buildControls(ref, colors, controller,
                  isPlaying: isPlaying, isLoading: isLoading),
            ],
          ),
        ),
      ),
    );
  }

  /// 第一行：封面 + 曲名 / 歌手，点击打开播放页。
  Widget _buildSongInfo(ThemeColors colors, Song song) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () {
        // 已经在播放页时不再重复 push，避免叠加多层播放页。
        if (appRouter.routerDelegate.currentConfiguration.uri.path ==
            AppRoutes.fullPlayer) {
          return;
        }
        appRouter.push(AppRoutes.fullPlayer);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: _artSize,
                height: _artSize,
                color: colors.surfaceVariant,
                child: _buildCover(colors, song),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MarqueeText(
                    text: song.title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: colors.textHint),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 第三行：播放控件。
  Widget _buildControls(
    WidgetRef ref,
    ThemeColors colors,
    PlaybackController controller, {
    required bool isPlaying,
    required bool isLoading,
  }) {
    return Row(
      children: [
        _buildIconButton(
          icon: Icons.skip_previous,
          size: 20,
          color: colors.textSecondary,
          onPressed: () => controller.previous(),
        ),
        _buildIconButton(
          size: 24,
          color: colors.textPrimary,
          onPressed: isLoading ? null : () => controller.togglePlayPause(),
          iconWidget: isLoading
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.textPrimary,
                  ),
                )
              : Icon(
                  isPlaying ? Icons.pause : Icons.play_arrow,
                  size: 24,
                  color: colors.textPrimary,
                ),
        ),
        _buildIconButton(
          icon: Icons.skip_next,
          size: 20,
          color: colors.textSecondary,
          onPressed: () => controller.next(),
        ),
        _buildIconButton(
          icon: Icons.queue_music,
          size: 20,
          color: colors.textSecondary,
          onPressed: () => _showQueue(ref, controller),
        ),
      ],
    );
  }

  Widget _buildIconButton({
    IconData? icon,
    Widget? iconWidget,
    required double size,
    required Color color,
    required VoidCallback? onPressed,
  }) {
    return Expanded(
      child: IconButton(
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        icon: iconWidget ?? Icon(icon, size: size, color: color),
        onPressed: onPressed,
      ),
    );
  }

  /// 播放队列面板需要挂在根 Navigator 上；侧边栏位于 Router 之外，
  /// 取根 Navigator 的 Overlay context 作为宿主。
  void _showQueue(WidgetRef ref, PlaybackController controller) {
    final sheetContext =
        appRouter.routerDelegate.navigatorKey.currentState?.overlay?.context;
    if (sheetContext == null) return;
    showPlayQueueSheet(
      sheetContext,
      playbackState: ref.read(playbackControllerProvider),
      controller: controller,
    );
  }

  Widget _buildCover(ThemeColors colors, Song song) {
    // 优先使用 coverUrl（精准匹配后的在线封面），再回退到设备本地封面
    if (song.coverUrl != null && song.coverUrl!.isNotEmpty) {
      return MusicCoverImage(
        key: ValueKey('sidebar_cover_img_${song.id}'),
        url: song.coverUrl,
        fit: BoxFit.cover,
        errorWidget: Icon(Icons.music_note, size: 20, color: colors.primary),
      );
    }
    if (song.mediaStoreId != null) {
      return MusicCoverImage(
        key: ValueKey('sidebar_cover_img_${song.id}'),
        songId: song.id,
        mediaStoreId: song.mediaStoreId,
        fit: BoxFit.cover,
        errorWidget: Icon(Icons.music_note, size: 20, color: colors.primary),
      );
    }
    return Icon(Icons.music_note, size: 20, color: colors.primary);
  }
}

/// 第二行：剩余时间（`-mm:ss`）。
class _SidebarRemainingTime extends ConsumerWidget {
  const _SidebarRemainingTime({required this.colors});

  final ThemeColors colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final duration = ref.watch(
      playbackControllerProvider.select((s) => s.duration),
    );
    final position = ref.watch(
      playbackControllerProvider.select((s) => s.position),
    );

    final remaining = duration - position;
    final text = duration == Duration.zero || remaining.isNegative
        ? '--:--'
        : '-${_format(remaining)}';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: colors.textHint),
      ),
    );
  }

  String _format(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
