import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:palette_generator/palette_generator.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../shared/services/app_image_cache.dart';
import '../../../shared/widgets/share_preview_dialog.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../application/playback_controller.dart';
import '../../radio/application/radio_session.dart';
import '../application/playback_ui_providers.dart';
import '../application/lyric_controller.dart';
import '../domain/models/song.dart';
import '../domain/services/cover_color_extractor.dart';
import '../../settings/application/settings_providers.dart';
import '../../library/application/playlist_providers.dart';
import '../application/root_overlay_tracker.dart';
import 'widgets/lyric_scroll_view.dart';
import 'widgets/player_controls.dart';
import '../../../shared/widgets/sleep_timer_picker.dart';

class LyricPage extends ConsumerStatefulWidget {
  const LyricPage({super.key});

  @override
  ConsumerState<LyricPage> createState() => _LyricPageState();
}

class _LyricPageState extends ConsumerState<LyricPage> {
  Color? _dominantColor;
  Song? _lastSong;
  bool _isLeaving = false;
  bool _exiting = false;
  Animation<double>? _routeAnimation;

  @override
  void initState() {
    super.initState();
    // 登记根级覆盖页状态（左侧栏封面 / 来源标签的「再点关闭」要用）。
    RootOverlayTracker.instance.retain(RootOverlayTracker.lyric);
    // 歌词页沉浸式全屏（隐藏系统栏）。
    // 退出时在 _beginExit 中先恢复 edgeToEdge 再 pop：若等到路由完全销毁
    // 才恢复，下层页面会因系统栏突然出现而重排闪烁。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadCoverColor();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (identical(animation, _routeAnimation)) return;
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
    _routeAnimation = animation;
    _routeAnimation?.addStatusListener(_onRouteAnimationStatus);
  }

  void _onRouteAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.reverse) {
      _isLeaving = true;
      return;
    }
    if (!_isLeaving || status != AnimationStatus.dismissed) return;
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
      overlays: SystemUiOverlay.values,
    );
  }

  /// 退出歌词页。
  ///
  /// 1. 先恢复系统 UI（immersiveSticky → edgeToEdge）：让系统栏在歌词页
  ///    仍覆盖屏幕时就出现、窗口布局先稳定。若等到路由完全销毁才恢复，
  ///    下层页面（如全屏播放页）会突然重排，表现为退出末尾的一次闪烁
  ///    （且因 immersiveSticky 当前是否已呼出系统栏而时有时无）。
  /// 2. 把 _isLeaving 置位：外层 TickerMode 随之停掉歌词动画，退出滑动
  ///    期间不再重绘。
  void _beginExit() {
    if (_exiting || _isLeaving) return;
    _exiting = true;
    FocusManager.instance.primaryFocus?.unfocus();

    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
      overlays: SystemUiOverlay.values,
    );

    setState(() => _isLeaving = true);
    context.pop();
  }

  @override
  void dispose() {
    RootOverlayTracker.instance.release(RootOverlayTracker.lyric);
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
    super.dispose();
  }

  Future<void> _loadCoverColor() async {
    if (_isLeaving) return;
    final playbackState = ref.read(playbackControllerProvider);
    final song = playbackState.currentSong;
    if (song?.coverUrl == null || song!.coverUrl!.isEmpty) {
      // A source may fill in its cover asynchronously after the song changes.
      // Keep the previous palette during that short gap so next/previous does
      // not flash to a black background.
      return;
    }
    try {
      ImageProvider imageProvider;
      if (song.coverUrl!.startsWith('http')) {
        imageProvider = CachedNetworkImageProvider(
          song.coverUrl!,
          cacheManager: AppImageCache.manager,
        );
      } else {
        imageProvider = AssetImage(song.coverUrl!);
      }
      final paletteGenerator = await PaletteGenerator.fromImageProvider(
        imageProvider,
        maximumColorCount: 8,
        region: Rect.fromCenter(
          center: const Offset(150, 150),
          width: 200,
          height: 200,
        ),
      );
      if (!mounted || _isLeaving) return;
      final dominant = paletteGenerator.dominantColor;
      if (dominant != null) {
        setState(() {
          _dominantColor = dominant.color;
        });
      }
    } catch (_) {
      // Keep the previous successful palette if the next cover fails to
      // decode. The next valid cover update will replace it.
    }
  }

  @override
  Widget build(BuildContext context) {
    // The page shell must not subscribe to the 200ms position stream. The
    // high-frequency parts below subscribe in their own small subtrees.
    ref.watch(currentSongIdentityProvider);
    final song = ref.read(playbackControllerProvider).currentSong;
    final controller = ref.read(playbackControllerProvider.notifier);
    final lyricState = ref.watch(lyricControllerProvider);
    final bgMode = ref.watch(fullScreenBackgroundModeProvider);
    final bgAnimation = ref.watch(appearanceBgAnimationProvider);

    final showTranslation = ref.watch(lyricShowTranslationProvider);
    final showRoman = ref.watch(lyricShowRomanProvider);
    final enableBlur = ref.watch(lyricEnableBlurProvider);
    final enableScale = ref.watch(lyricEnableScaleProvider);
    final fontSizeScale = ref.watch(lyricFontSizeProvider);
    final themeColors = ref.watch(themeColorsProvider);
    if (song != null && !identical(song, _lastSong)) {
      _lastSong = song;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _isLeaving) return;
        ref.read(lyricControllerProvider.notifier).loadLyrics(song);
        _loadCoverColor();
      });
    }

    final activeColor = themeColors.primary;
    final inactiveColor = Colors.white.withValues(alpha: 0.4);
    final hasYrc = lyricState.hasYrc;
    final baseFontSize = 35.0 * fontSizeScale;
    final transFontSize = 18.0 * fontSizeScale;
    final romanFontSize = 14.0 * fontSizeScale;
    final watchFontFamily = ref.watch(lyricFontFamilyProvider);
    final watchFontRate = ref.watch(lyricFontRateProvider);
    final watchFontWeight = ref.watch(lyricFontWeightProvider);
    final lyricCenterAlign = ref.watch(lyricCenterAlignProvider);

    return PopScope<void>(
      // canPop:false 拦截系统返回键，统一走 _beginExit（先恢复系统 UI 再 pop）。
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _beginExit();
      },
      child: TickerMode(
        enabled: !_isLeaving,
        child: Scaffold(
          body: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragEnd: (details) {
              if (details.primaryVelocity != null &&
                  details.primaryVelocity! > 100) {
                _beginExit();
              }
            },
            child: Stack(
              children: [
                // 用 RepaintBoundary 缓存整层背景（含全屏 80px BackdropFilter）。
                // 路由滑动切换时合成器只需平移缓存的纹理，避免每一帧都重新执行
                // 全屏高斯模糊导致掉帧/闪烁（全屏播放页无此模糊所以流畅）。
                RepaintBoundary(
                  child: _LyricBackgroundLayer(
                    dominantColor: _dominantColor,
                    coverUrl: song?.coverUrl,
                    mode: bgMode,
                    animate: bgAnimation,
                  ),
                ),
                SafeArea(
                  child: Column(
                    children: [
                      Expanded(
                        child: Builder(
                          builder: (context) {
                            return Stack(
                              children: [
                                if (lyricState.isLoading &&
                                    lyricState.lines.isEmpty)
                                  Center(
                                    child: Text(
                                      context.tr('加载歌词中...'),
                                      style: TextStyle(
                                        fontSize: 18,
                                        color: activeColor.withValues(
                                          alpha: 0.5,
                                        ),
                                        letterSpacing: 2,
                                      ),
                                    ),
                                  )
                                else if (lyricState.error != null &&
                                    lyricState.lines.isEmpty)
                                  Center(
                                    child: Text(
                                      lyricState.error!,
                                      style: TextStyle(
                                        fontSize: 18,
                                        color: activeColor.withValues(
                                          alpha: 0.5,
                                        ),
                                        letterSpacing: 2,
                                      ),
                                    ),
                                  )
                                else if (lyricState.lines.isEmpty)
                                  Center(
                                    child: Text(
                                      context.tr('暂无歌词'),
                                      style: TextStyle(
                                        fontSize: 18,
                                        color: activeColor.withValues(
                                          alpha: 0.5,
                                        ),
                                        letterSpacing: 2,
                                      ),
                                    ),
                                  )
                                else
                                  Consumer(
                                    builder: (context, ref, _) {
                                      final playback = ref.watch(
                                        playbackControllerProvider.select(
                                          (state) => (
                                            position: state.position,
                                            isPlaying: state.isPlaying,
                                          ),
                                        ),
                                      );
                                      final seekPreview = ref.watch(
                                        seekPreviewPositionProvider,
                                      );
                                      final lyricPosition =
                                          seekPreview ?? playback.position;
                                      return LyricScrollView(
                                        lines: lyricState.lines,
                                        currentTimeMs:
                                            lyricPosition.inMilliseconds,
                                        isPlaying: playback.isPlaying,
                                        isSeekPreview: seekPreview != null,
                                        hasYrc: hasYrc,
                                        activeColor: activeColor,
                                        inactiveColor: inactiveColor,
                                        mainFontSize: baseFontSize,
                                        transFontSize: transFontSize,
                                        romanFontSize: romanFontSize,
                                        fontSizeRate: watchFontRate,
                                        enableBlur: enableBlur,
                                        enableScale: enableScale,
                                        showTranslation: showTranslation,
                                        showRoman: showRoman,
                                        centerAlign: lyricCenterAlign,
                                        fontFamily: watchFontFamily,
                                        fontWeight: watchFontWeight,
                                        onSeek: (startTimeMs) {
                                          controller.seek(
                                            Duration(milliseconds: startTimeMs),
                                          );
                                        },
                                      );
                                    },
                                  ),
                                // Close button
                                Positioned(
                                  top: 8,
                                  left: 16,
                                  child: GestureDetector(
                                    onTap: _beginExit,
                                    behavior: HitTestBehavior.opaque,
                                    child: Container(
                                      width: 36,
                                      height: 36,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Colors.white.withValues(
                                          alpha: 0.1,
                                        ),
                                      ),
                                      child: const Icon(
                                        Icons.keyboard_arrow_down,
                                        size: 20,
                                        color: Colors.white70,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                      _buildLyricSongInfo(song),
                      const _LyricProgressBar(),
                      const SizedBox(height: 12),
                      const _LyricControls(),
                      const SizedBox(height: 50),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLyricSongInfo(Song? song) {
    final isFavorite = _isSongFavorite(song);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  song?.title ?? context.tr('未知歌曲'),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  song?.artist ?? context.tr('未知歌手'),
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => _toggleFavorite(song),
            icon: Icon(
              isFavorite ? Icons.favorite : Icons.favorite_border,
              size: 24,
              color: isFavorite
                  ? AppColors.primary
                  : Colors.white.withValues(alpha: 0.7),
            ),
          ),
          IconButton(
            onPressed: () => _showMoreMenu(song),
            icon: Icon(
              Icons.more_horiz,
              size: 24,
              color: Colors.white.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  bool _isSongFavorite(Song? song) {
    if (song == null) return false;
    final playlistsAsync = ref.read(playlistsProvider);
    return playlistsAsync.whenOrNull(
          data: (playlists) {
            final fav = playlists
                .where((p) => p.id == '__favorites__')
                .firstOrNull;
            return fav?.songs.any((s) => s.id == song.id) ?? false;
          },
        ) ??
        false;
  }

  void _toggleFavorite(Song? song) {
    if (song == null) return;
    final playlistsAsync = ref.read(playlistsProvider);
    playlistsAsync.whenData((playlists) {
      final fav = playlists.where((p) => p.id == '__favorites__').firstOrNull;
      final isFavorited = fav?.songs.any((s) => s.id == song.id) ?? false;
      if (isFavorited) {
        ref
            .read(playlistsProvider.notifier)
            .removeSongFromPlaylist('__favorites__', song.id);
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(context.tr('已取消收藏')),
              duration: const Duration(seconds: 1),
            ),
          );
      } else {
        ref
            .read(playlistsProvider.notifier)
            .addSongToPlaylist('__favorites__', song);
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(context.tr('已添加到我的收藏')),
              duration: const Duration(seconds: 1),
            ),
          );
      }
    });
  }

  void _showMoreMenu(Song? song) {
    if (song == null) return;
    showModalBottomSheet(
      context: context,
      sheetAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 220),
        reverseDuration: Duration(milliseconds: 180),
      ),
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: const Icon(
                  Icons.playlist_add,
                  color: AppColors.textSecondary,
                ),
                title: Text(
                  context.tr('添加到歌单'),
                  style: const TextStyle(color: AppColors.textPrimary),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _showAddToPlaylist(song);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.speed,
                  color: AppColors.textSecondary,
                ),
                title: Text(
                  context.tr('播放速度'),
                  style: const TextStyle(color: AppColors.textPrimary),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _showSpeedPicker();
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.share,
                  color: AppColors.textSecondary,
                ),
                title: Text(
                  context.tr('分享'),
                  style: const TextStyle(color: AppColors.textPrimary),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _shareSong(song);
                },
              ),
              const SleepTimerMenuTile(),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  void _showSpeedPicker() {
    final currentSpeed = ref.read(playbackSpeedProvider);
    const speeds = ['0.5x', '0.75x', '1.0x', '1.25x', '1.5x', '2.0x'];
    showModalBottomSheet(
      context: context,
      sheetAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 220),
        reverseDuration: Duration(milliseconds: 180),
      ),
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                context.tr('播放速度'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              ...speeds.map((label) {
                final speed = double.parse(label.replaceAll('x', ''));
                final isSelected = currentSpeed == speed;
                return ListTile(
                  leading: Icon(
                    isSelected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: isSelected
                        ? AppColors.primary
                        : AppColors.textSecondary,
                  ),
                  title: Text(
                    label,
                    style: TextStyle(
                      color: isSelected
                          ? AppColors.primary
                          : AppColors.textPrimary,
                    ),
                  ),
                  onTap: () {
                    ref.read(playbackSpeedProvider.notifier).state = speed;
                    unawaited(_doPersistSpeed(speed));
                    ref.read(audioHandlerProvider).setSpeed(speed);
                    Navigator.pop(ctx);
                  },
                );
              }),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _doPersistSpeed(double speed) async {
    final svc = await ref.read(settingsServiceProvider.future);
    await svc.setPlaybackSpeed(speed);
  }

  void _showAddToPlaylist(Song song) {
    final playlistsAsync = ref.read(playlistsProvider);
    playlistsAsync.whenData((playlists) {
      final availablePlaylists = playlists
          .where((p) => p.id != '__favorites__')
          .toList();
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (ctx) => Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  context.tr('添加到歌单'),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                ...availablePlaylists.map(
                  (playlist) => ListTile(
                    title: Text(
                      playlist.name,
                      style: const TextStyle(color: AppColors.textPrimary),
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      ref
                          .read(playlistsProvider.notifier)
                          .addSongToPlaylist(playlist.id, song);
                      if (mounted)
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(context.tr('已添加到「${playlist.name}」')),
                            duration: const Duration(seconds: 1),
                          ),
                        );
                    },
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      );
    });
  }

  void _shareSong(Song song) {
    SharePreviewDialog.show(context, song: song);
  }
}

class _LyricProgressBar extends ConsumerWidget {
  const _LyricProgressBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(
      playbackControllerProvider.select(
        (state) => (
          position: state.position,
          duration: state.duration,
          currentQuality: state.currentQuality,
          availableQualities: state.availableQualities,
        ),
      ),
    );
    final durationMs = playback.duration.inMilliseconds;
    final progress = durationMs == 0
        ? 0.0
        : (playback.position.inMilliseconds / durationMs).clamp(0.0, 1.0);
    final controller = ref.read(playbackControllerProvider.notifier);

    return PlayerProgressBar(
      progress: progress,
      position: playback.position,
      duration: playback.duration,
      currentQuality: playback.currentQuality,
      availableQualities: playback.availableQualities,
      onQualityTap: controller.setQuality,
      onSeekPreview: (value) {
        ref
            .read(seekPreviewPositionProvider.notifier)
            .state = value == null || durationMs <= 0
            ? null
            : Duration(milliseconds: (value * durationMs).round());
      },
      onSeek: (value) {
        controller.seek(Duration(milliseconds: (value * durationMs).round()));
        ref.read(seekPreviewPositionProvider.notifier).state = null;
      },
    );
  }
}

class _LyricControls extends ConsumerWidget {
  const _LyricControls();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(
      playbackControllerProvider.select(
        (state) => (
          isPlaying: state.isPlaying,
          isLoading: state.isLoading,
          playMode: state.playMode,
        ),
      ),
    );
    final controller = ref.read(playbackControllerProvider.notifier);

    return PlaybackControlRow(
      isPlaying: playback.isPlaying,
      isLoading: playback.isLoading,
      playMode: playback.playMode,
      // 电台模式：播放列表 / 上一首 / 循环模式由电台接管。
      radioMode: ref.watch(radioModeProvider),
      onPlayPause: controller.togglePlayPause,
      onPrevious: controller.previous,
      onNext: controller.next,
      onCycleMode: controller.cyclePlayMode,
      onQueue: () {},
    );
  }
}

class _LyricBackgroundLayer extends StatefulWidget {
  final Color? dominantColor;
  final String? coverUrl;
  final FullScreenBackgroundMode mode;
  final bool animate;

  const _LyricBackgroundLayer({
    required this.dominantColor,
    required this.coverUrl,
    required this.mode,
    required this.animate,
  });

  @override
  State<_LyricBackgroundLayer> createState() => _LyricBackgroundLayerState();
}

class _LyricBackgroundLayerState extends State<_LyricBackgroundLayer>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void initState() {
    super.initState();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _LyricBackgroundLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animate != widget.animate ||
        oldWidget.mode != widget.mode ||
        oldWidget.coverUrl != widget.coverUrl) {
      _syncAnimation();
    }
  }

  void _syncAnimation() {
    final shouldAnimate =
        widget.animate &&
        widget.mode == FullScreenBackgroundMode.cover &&
        widget.coverUrl != null &&
        widget.coverUrl!.isNotEmpty;
    if (shouldAnimate) {
      _controller ??= AnimationController(
        vsync: this,
        duration: const Duration(seconds: 16),
      )..repeat(reverse: true);
    } else {
      _controller?.dispose();
      _controller = null;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return _buildLayer(context, 0);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => _buildLayer(context, controller.value),
    );
  }

  Widget _buildLayer(BuildContext context, double animationValue) {
    final dominantColor = widget.dominantColor;
    final coverUrl = widget.coverUrl;
    final mode = widget.mode;
    return Stack(
      children: [
        Container(color: const Color(0xFF09090B)),
        if (dominantColor != null && mode == FullScreenBackgroundMode.theme)
          AnimatedContainer(
            duration: widget.animate
                ? const Duration(seconds: 1)
                : Duration.zero,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  // 与播放详情页一致：只取封面色相，亮度压进暗色区间、
                  // 饱和度封顶，白色 / 鲜艳封面都不会生成浅色或刺眼背景。
                  coverDarkBackgroundColor(dominantColor, lightness: 0.17),
                  coverDarkBackgroundColor(dominantColor, lightness: 0.08),
                ],
              ),
            ),
          ),
        if (coverUrl != null &&
            coverUrl!.isNotEmpty &&
            mode == FullScreenBackgroundMode.cover)
          Stack(
            children: [
              Positioned.fill(
                // 使用带内存缓存的 MusicCoverImage（与全屏播放页一致），
                // 避免每次进入歌词页重复下载/解码封面导致首帧卡顿。
                child: widget.animate
                    ? Transform.scale(
                        scale: 1.0 + animationValue * 0.018,
                        child: ImageFiltered(
                          imageFilter: ui.ImageFilter.blur(
                            sigmaX: 40,
                            sigmaY: 40,
                          ),
                          child: MusicCoverImage(
                            url: coverUrl,
                            fit: BoxFit.cover,
                            width: double.infinity,
                            height: double.infinity,
                            cacheWidth: 512,
                            cacheHeight: 512,
                            filterQuality: FilterQuality.low,
                            errorWidget: const SizedBox(),
                          ),
                        ),
                      )
                    : ImageFiltered(
                        imageFilter: ui.ImageFilter.blur(
                          sigmaX: 40,
                          sigmaY: 40,
                        ),
                        child: MusicCoverImage(
                          url: coverUrl,
                          fit: BoxFit.cover,
                          width: double.infinity,
                          height: double.infinity,
                          cacheWidth: 512,
                          cacheHeight: 512,
                          filterQuality: FilterQuality.low,
                          errorWidget: const SizedBox(),
                        ),
                      ),
              ),
              Positioned.fill(
                child: Container(color: Colors.black.withValues(alpha: 0.6)),
              ),
              Positioned.fill(
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x1A000000),
                        Color(0x33000000),
                        Color(0x99000000),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        if (mode == FullScreenBackgroundMode.dark ||
            (dominantColor == null && mode == FullScreenBackgroundMode.theme))
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFF18181B),
                  Color(0xFF09090B),
                  Color(0xFF000000),
                ],
              ),
            ),
          ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            height: MediaQuery.of(context).size.height * 0.6,
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.topCenter,
                radius: 0.8,
                colors: [
                  Colors.white.withValues(alpha: 0.06),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
