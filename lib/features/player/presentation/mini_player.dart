import 'dart:async';
import 'dart:io';

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
  /// 横向滑动的累计位移（Android 左右滑动切歌用）。
  double _swipeDx = 0;

  /// 歌曲名（标题 + 歌手那一列）的横向位移。
  ///
  /// 左右滑动切歌时**只平移这一列文字**，封面和按钮固定不动：拖动时文字跟手，
  /// 松手后旧歌名顺着方向滑出去、新歌名从另一侧滑进来。用 [ValueNotifier]
  /// 直连一层 `Transform`，拖动过程不重建整棵子树（只有这层 transform 变）。
  final ValueNotifier<double> _titleDx = ValueNotifier<double>(0);

  /// 歌名滑出 / 滑入动画的驱动（时长每次按需设置）。
  late final AnimationController _titleAnim = AnimationController(vsync: this);

  /// 当前正在跑的位移动画；为 null 表示没有动画在跑。
  ///
  /// 只给控制器挂一个监听（[_onTitleTick]），每次动画换掉这个 tween：
  /// 中途被打断时旧 tween 直接置空，不会再有残留的监听往 [_titleDx] 里写值。
  Animation<double>? _titleTween;

  @override
  void initState() {
    super.initState();
    _titleAnim.addListener(_onTitleTick);
  }

  void _onTitleTick() {
    final animation = _titleTween;
    if (animation != null) _titleDx.value = animation.value;
  }

  @override
  void dispose() {
    _titleAnim.dispose();
    _titleDx.dispose();
    super.dispose();
  }

  /// 把歌名从当前位置动画到 [to]（像素）。
  Future<void> _animateTitleTo(double to, int milliseconds) {
    final from = _titleDx.value;
    _titleAnim.stop();
    if (from == to) {
      _titleTween = null;
      return Future<void>.value();
    }
    _titleAnim.duration = Duration(milliseconds: milliseconds);
    _titleTween = Tween<double>(
      begin: from,
      end: to,
    ).animate(CurvedAnimation(parent: _titleAnim, curve: Curves.easeOutCubic));
    return _titleAnim.forward(from: 0).then((_) {
      _titleTween = null;
      _titleDx.value = to;
    });
  }

  void _onSwipeStart(DragStartDetails details) {
    _titleAnim.stop();
    _swipeDx = 0;
    _titleDx.value = 0;
  }

  /// 拖动时歌名跟着手指走（拖动距离就是位移，不放大也不阻尼）。
  void _onSwipeUpdate(DragUpdateDetails details) {
    _swipeDx += details.delta.dx;
    _titleDx.value = _swipeDx;
  }

  /// 横向滑动结束：往左滑切下一首、往右滑切上一首。
  ///
  /// 位移不够时看甩动速度，避免轻轻一碰就误切歌；不切歌就弹回原位。
  void _onSwipeEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final dx = _swipeDx;
    _swipeDx = 0;
    final bool goNext;
    if (dx.abs() >= 64) {
      goNext = dx < 0;
    } else if (velocity.abs() >= 200) {
      goNext = velocity < 0;
    } else {
      unawaited(_animateTitleTo(0, 160));
      return;
    }
    unawaited(_swipeToSong(next: goNext));
  }

  /// 旧歌名滑出去 → 切歌 → 新歌名从另一侧滑进来。
  Future<void> _swipeToSong({required bool next}) async {
    // 电台模式下队列由电台接管，没有「上一首」。
    if (!next && ref.read(radioModeProvider)) {
      await _animateTitleTo(0, 160);
      return;
    }
    final width = MediaQuery.sizeOf(context).width;
    final sign = next ? -1.0 : 1.0;
    // 旧歌名顺着手指方向滑出可视区（文字列外面套了 ClipRect，滑出去就看不见）。
    await _animateTitleTo(sign * width, 110);
    if (!mounted) return;
    final controller = ref.read(playbackControllerProvider.notifier);
    if (next) {
      controller.next();
    } else {
      controller.previous();
    }
    // 新歌名从另一侧进场，再滑回原位。
    _titleDx.value = -sign * width;
    await _animateTitleTo(0, 170);
  }

  @override
  Widget build(BuildContext context) {
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
    // 电台模式：队列由电台接管，「播放列表」「上一首」不可用。
    final radioMode = ref.watch(radioModeProvider);
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
        onHorizontalDragStart: Platform.isAndroid ? _onSwipeStart : null,
        onHorizontalDragUpdate: Platform.isAndroid ? _onSwipeUpdate : null,
        onHorizontalDragEnd: Platform.isAndroid ? _onSwipeEnd : null,
        child: Container(
          height: height,
          // 圆角裁切：歌名滑出时不会越出胶囊边缘。
          clipBehavior: Clip.antiAlias,
          margin: EdgeInsets.symmetric(
            horizontal: isTablet ? 12 : AppSpacing.sm,
          ),
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
                // 裁掉滑出工具栏边界的部分，否则歌名会画到封面 / 按钮上面。
                child: ClipRect(
                  child: AnimatedBuilder(
                    animation: _titleDx,
                    builder: (context, child) => Transform.translate(
                      offset: Offset(_titleDx.value, 0),
                      child: child,
                    ),
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
                          style: TextStyle(
                            fontSize: subtitleFontSize,
                            color: colors.textHint,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // 控制按钮紧凑靠右：间距略小于默认 IconButton 视觉边距。
              // Android 去掉「上一首」：切歌走左右滑动 / 下一首按钮，栏位更松快；
              // 桌面与平板保留（鼠标没有手势替代）。
              if (!Platform.isAndroid)
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
        filePath: song.filePath,
        mediaStoreId: song.mediaStoreId,
        fit: BoxFit.cover,
        errorWidget: Icon(Icons.music_note, size: 20, color: colors.primary),
      );
    }
    return Icon(Icons.music_note, size: 20, color: colors.primary);
  }
}
