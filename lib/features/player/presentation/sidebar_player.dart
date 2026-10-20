import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_routes.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../shared/widgets/marquee_text.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../application/playback_controller.dart';
import '../domain/models/song.dart';
import 'widgets/play_queue_sheet.dart';

/// 桌面端左侧导航栏底部的播放器。
///
/// 布局（自上而下）：
/// 1. 大封面（点击打开全屏播放页）
/// 2. 曲名（居中显示）
/// 3. 播放进度条（可点击 / 拖动调整进度）
/// 4. 歌曲总时长
/// 5. 播放控件（上一首 / 播放暂停 / 下一首 / 播放队列）
///
/// 该组件渲染在 Router 之外（导航栏属于根布局），因此跳转与播放队列弹窗
/// 都通过全局 [appRouter] / 根 Overlay 的 context 完成。
class SidebarPlayer extends ConsumerWidget {
  const SidebarPlayer({super.key});

  /// 封面边长（固定值，避免在无界高度下计算出异常尺寸）。
  static const double _coverSize = 150;

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

    // 侧边栏宽度固定，系统大字体时容易把布局撑破，这里限制文本缩放上限。
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.2,
      // 侧边栏背景由外层 Container 绘制，这里用透明 Material 承载
      // InkWell / IconButton 的水波纹，避免水波纹被背景色盖住。
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: colors.divider.withValues(alpha: 0.3),
                width: 0.5,
              ),
            ),
          ),
          // 播放器整体高度固定：主轴使用 min，避免在无界高度下被拉伸，
          // 否则会顶掉上方的导航项。
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildCover(context, colors, song),
              const SizedBox(height: AppSpacing.sm),
              _buildSongTitle(context, colors, song),
              const SizedBox(height: AppSpacing.xs),
              _buildProgress(context, ref, colors, controller),
              const SizedBox(height: 2),
              _buildControls(ref, colors, controller,
                  isPlaying: isPlaying, isLoading: isLoading),
            ],
          ),
        ),
      ),
    );
  }

  /// 封面：点击打开全屏播放页。
  Widget _buildCover(
    BuildContext context,
    ThemeColors colors,
    Song song,
  ) {
    return Center(
      child: GestureDetector(
        onTap: () {
          // 已经在播放页时不再重复 push，避免叠加多层播放页。
          if (appRouter.routerDelegate.currentConfiguration.uri.path ==
              AppRoutes.fullPlayer) {
            return;
          }
          appRouter.push(AppRoutes.fullPlayer);
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: _coverSize,
            height: _coverSize,
            color: colors.surfaceVariant,
            child: _buildCoverImage(colors, song),
          ),
        ),
      ),
    );
  }

  Widget _buildCoverImage(ThemeColors colors, Song song) {
    // 优先使用 coverUrl（精准匹配后的在线封面），再回退到设备本地封面
    if (song.coverUrl != null && song.coverUrl!.isNotEmpty) {
      return MusicCoverImage(
        key: ValueKey('sidebar_cover_img_${song.id}'),
        url: song.coverUrl,
        fit: BoxFit.cover,
        errorWidget: Icon(Icons.music_note, size: 32, color: colors.primary),
      );
    }
    if (song.mediaStoreId != null) {
      return MusicCoverImage(
        key: ValueKey('sidebar_cover_img_${song.id}'),
        songId: song.id,
        mediaStoreId: song.mediaStoreId,
        fit: BoxFit.cover,
        errorWidget: Icon(Icons.music_note, size: 32, color: colors.primary),
      );
    }
    return Icon(Icons.music_note, size: 32, color: colors.primary);
  }

  /// 曲名：居中显示，过长时滚动。
  Widget _buildSongTitle(BuildContext context, ThemeColors colors, Song song) {
    return SizedBox(
      height: 22,
      child: Align(
        alignment: Alignment.center,
        child: MarqueeText(
          text: song.title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: colors.textPrimary,
          ),
        ),
      ),
    );
  }

  /// 播放进度条：可点击 / 拖动调整进度；下方显示歌曲总时长。
  Widget _buildProgress(
    BuildContext context,
    WidgetRef ref,
    ThemeColors colors,
    PlaybackController controller,
  ) {
    final duration = ref.watch(
      playbackControllerProvider.select((s) => s.duration),
    );
    final position = ref.watch(
      playbackControllerProvider.select((s) => s.position),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SidebarProgressBar(
          duration: duration,
          position: position,
          colors: colors,
          onSeek: (target) => controller.seek(target),
        ),
        // 歌曲总时长（不再显示剩余时间）
        Padding(
          padding: const EdgeInsets.only(right: 2, top: 2),
          child: Text(
            _formatDuration(duration),
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 11, color: colors.textHint),
          ),
        ),
      ],
    );
  }

  /// 播放控件。
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
          size: 22,
          color: colors.textSecondary,
          onPressed: () => controller.previous(),
        ),
        _buildIconButton(
          size: 26,
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
                  size: 26,
                  color: colors.textPrimary,
                ),
        ),
        _buildIconButton(
          icon: Icons.skip_next,
          size: 22,
          color: colors.textSecondary,
          onPressed: () => controller.next(),
        ),
        _buildIconButton(
          icon: Icons.queue_music,
          size: 22,
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

  /// 格式化时长：mm:ss（超过一小时显示 h:mm:ss）。
  static String _formatDuration(Duration duration) {
    if (duration <= Duration.zero) return '--:--';
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    if (hours > 0) return '$hours:$mm:$ss';
    return '$mm:$ss';
  }
}

/// 侧边栏播放进度条。
///
/// 自绘（不使用 Slider）：拖动时显示本地进度，松手后才真正跳转；
/// 高度固定为 16，避免在无界高度下把布局撑开。
class _SidebarProgressBar extends StatefulWidget {
  const _SidebarProgressBar({
    required this.duration,
    required this.position,
    required this.colors,
    required this.onSeek,
  });

  final Duration duration;
  final Duration position;
  final ThemeColors colors;
  final void Function(Duration target) onSeek;

  @override
  State<_SidebarProgressBar> createState() => _SidebarProgressBarState();
}

class _SidebarProgressBarState extends State<_SidebarProgressBar> {
  /// 拖动中的进度（毫秒），为空时跟随播放进度。
  double? _dragValue;

  static const double _barHeight = 16;
  static const double _trackHeight = 4;
  static const double _thumbSize = 10;

  @override
  Widget build(BuildContext context) {
    final totalMs = widget.duration.inMilliseconds;
    final maxMs = totalMs > 0 ? totalMs.toDouble() : 1.0;
    final currentMs = _dragValue ??
        widget.position.inMilliseconds.clamp(0, totalMs).toDouble();
    final ratio = (currentMs / maxMs).clamp(0.0, 1.0);
    final colors = widget.colors;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 0.0;
        final thumbLeft =
            (width * ratio - _thumbSize / 2).clamp(0.0, (width - _thumbSize).clamp(0.0, double.infinity));

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => _preview(details.localPosition.dx, width, totalMs),
          onTapUp: (_) => _commit(),
          onHorizontalDragStart: (details) =>
              _preview(details.localPosition.dx, width, totalMs),
          onHorizontalDragUpdate: (details) =>
              _preview(details.localPosition.dx, width, totalMs),
          onHorizontalDragEnd: (_) => _commit(),
          child: SizedBox(
            height: _barHeight,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // 轨道
                Positioned(
                  left: 0,
                  right: 0,
                  top: (_barHeight - _trackHeight) / 2,
                  height: _trackHeight,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.divider,
                      borderRadius: BorderRadius.circular(_trackHeight / 2),
                    ),
                  ),
                ),
                // 已播放部分
                Positioned(
                  left: 0,
                  top: (_barHeight - _trackHeight) / 2,
                  height: _trackHeight,
                  width: width * ratio,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.primary,
                      borderRadius: BorderRadius.circular(_trackHeight / 2),
                    ),
                  ),
                ),
                // 滑块
                Positioned(
                  left: thumbLeft,
                  top: (_barHeight - _thumbSize) / 2,
                  width: _thumbSize,
                  height: _thumbSize,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.primary,
                      shape: BoxShape.circle,
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

  /// 拖动 / 点击时更新本地进度（不立即跳转）。
  void _preview(double dx, double width, int totalMs) {
    if (totalMs <= 0 || width <= 0) return;
    final ratio = (dx / width).clamp(0.0, 1.0);
    setState(() => _dragValue = ratio * totalMs);
  }

  /// 松手后真正跳转。
  void _commit() {
    final value = _dragValue;
    if (value == null) return;
    setState(() => _dragValue = null);
    widget.onSeek(Duration(milliseconds: value.round()));
  }
}
