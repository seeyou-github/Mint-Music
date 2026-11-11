import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../radio/application/radio_session.dart';
import '../application/playback_controller.dart';
import '../application/root_overlay_tracker.dart';
import '../domain/models/song.dart';
import 'widgets/play_queue_sheet.dart';

class MiniPlayer extends ConsumerStatefulWidget {
  const MiniPlayer({super.key});

  @override
  ConsumerState<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends ConsumerState<MiniPlayer>
    with SingleTickerProviderStateMixin {
  double _swipeDx = 0;
  double _titleWidth = 0;
  late final AnimationController _titleAnim = AnimationController.unbounded(
    vsync: this,
  );
  Song? _swipeSong;
  List<Song>? _swipeQueue;
  int _originIndex = -1;
  int? _previousIndex;
  int? _nextIndex;
  int? _targetIndex;
  int _swipeId = 0;
  bool _committing = false;
  bool _titleSettled = false;

  @override
  void dispose() {
    _titleAnim.dispose();
    super.dispose();
  }

  void _resetSwipe() {
    _swipeId++;
    _titleAnim.stop();
    _titleAnim.value = 0;
    _swipeDx = 0;
    _swipeSong = null;
    _swipeQueue = null;
    _previousIndex = null;
    _nextIndex = null;
    _targetIndex = null;
    _committing = false;
    _titleSettled = false;
  }

  Future<void> _animateTitleTo(double to) => _titleAnim
      .animateTo(
        to,
        duration: const Duration(milliseconds: 170),
        curve: Curves.easeOutCubic,
      )
      .orCancel;

  void _onSwipeStart(DragStartDetails details) {
    if (_committing) return;
    final state = ref.read(playbackControllerProvider);
    if (state.currentSong == null || _titleWidth <= 0) return;
    final controller = ref.read(playbackControllerProvider.notifier);
    setState(() {
      _resetSwipe();
      _swipeSong = state.currentSong;
      _swipeQueue = state.queue;
      _originIndex = state.currentIndex;
      _previousIndex = ref.read(radioModeProvider)
          ? null
          : controller.skipTargetIndex(next: false);
      _nextIndex = controller.skipTargetIndex(next: true);
    });
  }

  void _onSwipeUpdate(DragUpdateDetails details) {
    if (_swipeSong == null || _committing) return;
    _swipeDx += details.delta.dx;
    _titleAnim.value = _swipeDx.clamp(
      _nextIndex == null ? 0.0 : -_titleWidth,
      _previousIndex == null ? 0.0 : _titleWidth,
    );
  }

  Future<void> _cancelSwipe() async {
    if (_swipeSong == null || _committing) return;
    final id = _swipeId;
    try {
      await _animateTitleTo(0);
      if (mounted && id == _swipeId) setState(_resetSwipe);
    } on TickerCanceled {
      // 新手势或外部切歌已经接管标题。
    }
  }

  void _onSwipeEnd(DragEndDetails details) {
    if (_swipeSong == null || _committing) return;
    final velocity = details.primaryVelocity ?? 0;
    final dx = _swipeDx;
    final bool goNext;
    if (dx.abs() >= 64) {
      goNext = dx < 0;
    } else if (velocity.abs() >= 200) {
      goNext = velocity < 0;
    } else {
      unawaited(_cancelSwipe());
      return;
    }
    unawaited(_swipeToSong(next: goNext));
  }

  void _finishSwipeIfSelected() {
    if (!_committing || !_titleSettled) return;
    final state = ref.read(playbackControllerProvider);
    final targetSong = _swipeQueue![_targetIndex!];
    if (state.currentSong?.id == targetSong.id &&
        state.currentIndex == _targetIndex) {
      setState(_resetSwipe);
    }
  }

  Future<void> _swipeToSong({required bool next}) async {
    final target = next ? _nextIndex : _previousIndex;
    if (target == null) {
      await _cancelSwipe();
      return;
    }
    final id = _swipeId;
    _committing = true;
    _targetIndex = target;
    final controller = ref.read(playbackControllerProvider.notifier);
    final playback = next
        ? controller.next(targetIndex: target)
        : controller.previous(targetIndex: target);
    try {
      await _animateTitleTo(next ? -_titleWidth : _titleWidth);
      if (mounted && id == _swipeId) {
        _titleSettled = true;
        _finishSwipeIfSelected();
      }
      await playback;
      if (mounted && id == _swipeId) setState(_resetSwipe);
    } on TickerCanceled {
      // 已失效的动画不能重置后续手势的标题。
    }
  }

  @override
  Widget build(BuildContext context) {
    // 桌面/平板（侧边栏布局）下播放器固定在左侧导航栏底部（SidebarPlayer），
    // 这里返回空占位，避免页面里再出现一个重复的迷你播放器。
    if (ResponsiveLayout.shouldShowSidebar(context)) {
      return const SizedBox.shrink();
    }
    final colors = ref.watch(themeColorsProvider);
    ref.listen(playbackControllerProvider, (previous, next) {
      if (_swipeSong == null) return;
      final changed =
          next.currentSong?.id != _swipeSong?.id ||
          next.currentIndex != _originIndex;
      if (!_committing) {
        if (changed || !identical(next.queue, _swipeQueue)) {
          setState(_resetSwipe);
        }
      } else if (changed) {
        final targetSong = _swipeQueue![_targetIndex!];
        if (next.currentSong?.id != targetSong.id ||
            next.currentIndex != _targetIndex) {
          setState(_resetSwipe);
        } else {
          _finishSwipeIfSelected();
        }
      }
    });
    ref.listen(radioModeProvider, (previous, next) {
      if (previous != next && _swipeSong != null) setState(_resetSwipe);
    });
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
    // 电台模式：队列由电台接管，「播放列表」「上一首」不可用。
    final radioMode = ref.watch(radioModeProvider);
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    final disabledColor = colors.textSecondary.withValues(alpha: 0.3);
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
      child: Listener(
        // Flutter 会把已接受拖动的 PointerCancel 也交给 onDragEnd。
        onPointerCancel: (_) {
          if (_swipeSong != null && !_committing) setState(_resetSwipe);
        },
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
          // Android：左右滑动播放栏切歌（左滑下一首、右滑上一首）。
          // 只挂横向手势，纵向滚动不受影响，点按仍然进播放详情页。
          onHorizontalDragStart: isAndroid ? _onSwipeStart : null,
          onHorizontalDragUpdate: isAndroid ? _onSwipeUpdate : null,
          onHorizontalDragEnd: isAndroid ? _onSwipeEnd : null,
          onHorizontalDragCancel: isAndroid
              ? () => unawaited(_cancelSwipe())
              : null,
          child: Container(
            height: height,
            // 圆角裁切：歌名滑出时不会越出胶囊边缘。
            clipBehavior: Clip.antiAlias,
            margin: EdgeInsets.symmetric(
              horizontal: isTablet ? 12 : AppSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: ref.watch(miniPlayerSurfaceProvider),
              borderRadius: BorderRadius.circular(height / 2),
              boxShadow: [
                BoxShadow(
                  color: colors.shadow,
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            // 左右滑动切歌时只平移歌名这一列（拖动跟手、松手滑出/滑入），
            // 封面与按钮保持不动。
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
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      _titleWidth = constraints.maxWidth;
                      Widget title(Song value) => _buildTitle(
                        value,
                        colors,
                        titleFontSize,
                        subtitleFontSize,
                      );
                      return ClipRect(
                        child: AnimatedBuilder(
                          animation: _titleAnim,
                          builder: (context, child) => Transform.translate(
                            offset: Offset(_titleAnim.value, 0),
                            child: child,
                          ),
                          child: Stack(
                            fit: StackFit.expand,
                            clipBehavior: Clip.none,
                            children: [
                              title(_swipeSong ?? song),
                              if (_previousIndex != null)
                                Transform.translate(
                                  offset: Offset(-_titleWidth, 0),
                                  child: title(_swipeQueue![_previousIndex!]),
                                ),
                              if (_nextIndex != null)
                                Transform.translate(
                                  offset: Offset(_titleWidth, 0),
                                  child: title(_swipeQueue![_nextIndex!]),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                // 控制按钮紧凑靠右：间距略小于默认 IconButton 视觉边距。
                // Android 去掉「上一首」：切歌走左右滑动 / 下一首按钮，栏位更松快；
                // 桌面与平板保留（鼠标没有手势替代）。
                if (!isAndroid)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    constraints: const BoxConstraints(minWidth: 32),
                    icon: Icon(
                      Icons.skip_previous,
                      size: iconSize,
                      color: radioMode ? disabledColor : colors.textSecondary,
                    ),
                    onPressed: radioMode ? null : () => controller.previous(),
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
                  onPressed: isLoading
                      ? null
                      : () => controller.togglePlayPause(),
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
                    color: radioMode ? disabledColor : colors.textSecondary,
                  ),
                  // 与全屏播放页相同的播放队列面板，点击直接弹出，无需跳转
                  onPressed: radioMode
                      ? null
                      : () {
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
      ),
    );
  }

  Widget _buildTitle(
    Song song,
    ThemeColors colors,
    double titleFontSize,
    double subtitleFontSize,
  ) => Column(
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
  );

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
        filePath: song.filePath,
        mediaStoreId: song.mediaStoreId,
        fit: BoxFit.cover,
        errorWidget: Icon(Icons.music_note, size: 20, color: colors.primary),
      );
    }
    return Icon(Icons.music_note, size: 20, color: colors.primary);
  }
}
