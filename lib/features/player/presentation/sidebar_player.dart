import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_routes.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../shared/widgets/marquee_text.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../../shared/widgets/source_badge.dart';
import '../../discover/domain/models/search_collection.dart';
import '../../library/application/playlist_providers.dart';
import '../../library/domain/models/recently_played.dart';
import '../application/playback_context.dart';
import '../application/playback_controller.dart';
import '../application/full_player_visibility.dart';
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
          // 底部留白加倍，让播放器与窗口底边保持更舒适的距离。
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
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
              _buildCover(context, ref, colors, song),
              const SizedBox(height: AppSpacing.sm),
              _buildSongTitle(context, colors, song),
              const SizedBox(height: AppSpacing.xs),
              _buildProgress(context, ref, colors, controller),
              const SizedBox(height: 2),
              _buildControls(
                ref,
                colors,
                controller,
                isPlaying: isPlaying,
                isLoading: isLoading,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 封面：点击打开 / 关闭全屏播放页；右上角显示本次播放的来源标签。
  Widget _buildCover(
    BuildContext context,
    WidgetRef ref,
    ThemeColors colors,
    Song song,
  ) {
    return Center(
      child: GestureDetector(
        onTap: () {
          // 播放详情页已经打开：再次点击封面直接关闭；否则打开。
          final path = appRouter.routerDelegate.currentConfiguration.uri.path;
          final isOpen =
              FullPlayerVisibility.instance.visible ||
              path == AppRoutes.fullPlayer;
          if (isOpen) {
            appRouter.pop();
            return;
          }
          appRouter.push(AppRoutes.fullPlayer);
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: _coverSize,
            height: _coverSize,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Container(
                    color: colors.surfaceVariant,
                    child: _buildCoverImage(colors, song),
                  ),
                ),
                Positioned(
                  top: 6,
                  right: 6,
                  // 来源变化时就地刷新标签（例如从另一个歌单重播同一首歌）。
                  child: ListenableBuilder(
                    listenable: PlaybackContext.instance,
                    builder: (context, _) =>
                        _buildSourceBadge(context, ref, colors, song),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 当前播放来源标签；未知来源不显示。
  Widget _buildSourceBadge(
    BuildContext context,
    WidgetRef ref,
    ThemeColors colors,
    Song song,
  ) {
    final ctx = PlaybackContext.instance;
    if (ctx.type == PlaybackSourceType.unknown) {
      return const SizedBox.shrink();
    }
    final clickable = switch (ctx.type) {
      PlaybackSourceType.playlist ||
      PlaybackSourceType.rank ||
      PlaybackSourceType.album ||
      PlaybackSourceType.artist => true,
      _ => false,
    };
    return SourceBadge(
      type: ctx.type,
      colors: colors,
      onTap: clickable ? () => _openSource(ref, song) : null,
    );
  }

  /// 打开当前歌曲的来源页：歌单（含我的收藏）/ 榜单 / 专辑 / 作者。
  Future<void> _openSource(WidgetRef ref, Song song) async {
    // 点击后可能马上切歌，先把来源快照下来。
    final ctx = PlaybackContext.instance;
    final type = ctx.type;
    final id = ctx.id;
    final name = ctx.name;
    final meta = ctx.sourceMeta;
    if (id == null || id.isEmpty) return;
    final encodedId = Uri.encodeComponent(id);
    switch (type) {
      case PlaybackSourceType.playlist:
        // 本地歌单（含「我的收藏」）和远端歌单是不同的路由。
        var local = false;
        try {
          final playlists = await ref.read(playlistsProvider.future);
          local = playlists.any((p) => p.id == id);
        } catch (_) {
          // 本地歌单读取失败就按远端歌单打开。
        }
        appRouter.push(
          local ? '/library/playlist/$encodedId' : '/playlist/$encodedId',
        );
      case PlaybackSourceType.rank:
        appRouter.push('/playlist/$encodedId?type=rank');
      case PlaybackSourceType.album:
      case PlaybackSourceType.artist:
        appRouter.push(
          AppRoutes.collectionDetail,
          extra: _collectionOf(
            type == PlaybackSourceType.artist
                ? CollectionType.artist
                : CollectionType.album,
            song: song,
            id: id,
            name: name,
            meta: meta,
          ),
        );
      case PlaybackSourceType.search:
      case PlaybackSourceType.local:
      case PlaybackSourceType.unknown:
        break;
    }
  }

  /// 打开专辑 / 作者主页用的信息。
  ///
  /// 播放时记录里有完整主页信息（[PlaybackContext.sourceMeta]）就直接用；
  /// 没有时按歌曲字段拼一个。
  SearchCollection _collectionOf(
    CollectionType type, {
    required Song song,
    required String id,
    required String? name,
    required Map<String, dynamic>? meta,
  }) {
    if (meta != null) return SearchCollection.fromJson(meta, type: type);

    final isArtist = type == CollectionType.artist;
    final title = name ?? (isArtist ? song.artist : song.album);
    return SearchCollection(
      id: id,
      title: title,
      type: type,
      source: song.source ?? '',
      coverUrl: song.coverUrl,
      artist: isArtist ? null : song.artist,
      raw: {
        'id': id,
        'name': title,
        if (isArtist) 'avatar': song.coverUrl ?? '',
        if (!isArtist) 'artist': song.artist,
        if (!isArtist) 'picUrl': song.coverUrl ?? '',
      },
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
    if (song.mediaStoreId != null || song.isLocal) {
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
          // 切换歌曲时显示加载动画；图标与动画都放在同样大小的方框里，
          // 避免加载动画出现 / 消失时按钮高度变化、整个播放控件上下跳动。
          iconWidget: SizedBox(
            width: 26,
            height: 26,
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
                    size: 26,
                    color: colors.textPrimary,
                  ),
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
    final currentMs =
        _dragValue ??
        widget.position.inMilliseconds.clamp(0, totalMs).toDouble();
    final ratio = (currentMs / maxMs).clamp(0.0, 1.0);
    final colors = widget.colors;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 0.0;
        final thumbLeft = (width * ratio - _thumbSize / 2).clamp(
          0.0,
          (width - _thumbSize).clamp(0.0, double.infinity),
        );

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) =>
              _preview(details.localPosition.dx, width, totalMs),
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
