import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../application/desktop_lyric_sync.dart';
import '../application/playback_controller.dart';
import '../application/full_player_visibility.dart';
import '../application/lyric_controller.dart';
import '../domain/models/song.dart';
import '../domain/services/cover_color_extractor.dart';
import '../../library/application/playlist_providers.dart';
import '../../plugin/application/plugin_providers.dart';
import '../../settings/application/settings_providers.dart';
import '../../../shared/widgets/song_action_sheet.dart';
import '../../../shared/services/amll_toggle_service.dart';
import 'widgets/lyric_scroll_view.dart';
import 'widgets/amll_lyric_player.dart';
import 'widgets/play_queue_sheet.dart';
import 'widgets/player_controls.dart';
import '../platform/audio_effect_service.dart';

class FullPlayerPage extends ConsumerStatefulWidget {
  const FullPlayerPage({super.key});

  @override
  ConsumerState<FullPlayerPage> createState() => _FullPlayerPageState();
}

class _FullPlayerPageState extends ConsumerState<FullPlayerPage> {
  final _pageController = PageController(initialPage: 0);
  int _currentPage = 0;
  bool _lyricsRequested = false;
  bool _lyricsPageBuilt = false;

  /// Landscape (tablet & phone): when true, lyrics occupy the full area
  /// (cover hidden).
  bool _landscapeLyricsFullMode = false;

  /// 退出动画期间隐藏 AMLL WebView：滑动阶段平台视图不参与合成，
  /// 中低端手机上也能流畅滑动（平台视图随路由变换会导致严重掉帧/闪回）。
  bool _isLeaving = false;
  bool _exiting = false;
  final GlobalKey<AmllLyricPlayerState> _amllKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // 登记「播放详情页已打开」，左侧栏封面按钮据此做打开 / 关闭切换。
    FullPlayerVisibility.instance.setVisible(true);
  }

  @override
  void dispose() {
    FullPlayerVisibility.instance.setVisible(false);
    _pageController.dispose();
    super.dispose();
  }

  /// 退出全屏播放页：先冻结 AMLL WebView 的 JS 动画（若在歌词页），
  /// 再隐藏平台视图并 pop。滑动动画只剩纯 Flutter 图层（背景 + 控件），
  /// 与「封面页退出」一致，无闪烁、不掉帧。
  Future<void> _beginExit() async {
    if (_exiting || _isLeaving) return;
    _exiting = true;
    FocusManager.instance.primaryFocus?.unfocus();

    final amllState = _amllKey.currentState;
    final amllEnabled = AmllToggleService().isActive;
    if (amllEnabled && amllState != null) {
      // 等待 JS rAF 循环真正停止（WebView 画布稳定为静态帧）
      await amllState.freeze();
    }
    if (!mounted) return;
    setState(() => _isLeaving = true);
    context.pop();
  }

  void _ensureLyricsLoaded() {
    if (_lyricsRequested) return;
    _lyricsRequested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final song = ref.read(
        playbackControllerProvider.select((s) => s.currentSong),
      );
      if (song != null) {
        ref.read(lyricControllerProvider.notifier).loadLyrics(song);
      }
    });
  }

  void _activateLyricsPage() {
    if (mounted && !_lyricsPageBuilt) {
      setState(() => _lyricsPageBuilt = true);
    }
    _ensureLyricsLoaded();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentSongIdentityProvider);
    final song = ref.read(playbackControllerProvider).currentSong;
    final isPlaying = ref.watch(
      playbackControllerProvider.select((s) => s.isPlaying),
    );
    final bgMode = ref.watch(fullScreenBackgroundModeProvider);
    final bgAnimation = ref.watch(appearanceBgAnimationProvider);
    final audioVisualizer = ref.watch(audioVisualizerEnabledProvider);
    final coverColorAsync = ref.watch(currentCoverColorProvider);

    final Color? dominantColor = coverColorAsync.whenOrNull(
      data: (result) => result?.dominantColor,
    );

    return PopScope<void>(
      // 拦截系统返回键，统一走 _beginExit（先冻结/隐藏 AMLL WebView 再 pop，
      // 避免滑动动画卡顿/闪回）
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _beginExit();
      },
      child: Scaffold(
        body: Stack(
          children: [
            RepaintBoundary(
              child: _BackgroundLayer(
                dominantColor: dominantColor,
                coverUrl: song?.coverUrl,
                mode: bgMode,
                animate: bgAnimation,
              ),
            ),
            // 手机横屏左栏是紧凑的「封面 + 控件」，没有留给频谱条的空间，
            // 否则它会横跨两栏压在播放控制上。
            if (audioVisualizer && !ResponsiveLayout.isPhoneLandscape(context))
              const Positioned(
                left: 28,
                right: 28,
                bottom: 148,
                child: _AudioVisualizer(),
              ),
            Positioned.fill(
              child: IgnorePointer(
                child: Opacity(
                  opacity: 0.02,
                  child: Container(color: Colors.white),
                ),
              ),
            ),
            SafeArea(
              child: Builder(
                builder: (context) {
                  final isTabletLandscape = ResponsiveLayout.isTabletLandscape(context);
                  if (isTabletLandscape) {
                    // Tablet landscape: side-by-side cover + lyrics layout
                    return _buildTabletLandscapeLayout(
                      isPlaying: isPlaying,
                      audioVisualizer: audioVisualizer,
                    );
                  }
                  if (ResponsiveLayout.isPhoneLandscape(context)) {
                    // Phone landscape (system auto-rotate on): same split
                    // layout as tablet, but with compact controls.
                    return _buildPhoneLandscapeLayout(isPlaying: isPlaying);
                  }
                  // Phone / tablet portrait: vertical layout with PageView
                  return Column(
                    children: [
                      _PlayerHeader(
                        currentPage: _currentPage,
                        onBack: () => _beginExit(),
                        onTogglePage: () {
                          final next = _currentPage == 0 ? 1 : 0;
                          if (next == 1) _activateLyricsPage();
                          _pageController.jumpToPage(next);
                        },
                      ),
                      Expanded(
                        child: ListenableBuilder(
                          listenable: AmllToggleService(),
                          builder: (context, _) {
                            final amllEnabled = AmllToggleService().isActive;
                            return PageView.builder(
                              controller: _pageController,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: 2,
                              onPageChanged: (index) {
                                if (mounted) {
                                  setState(() => _currentPage = index);
                                }
                                if (index == 1) _activateLyricsPage();
                              },
                              itemBuilder: (context, index) {
                                if (index == 0) {
                                  return _KeepAlivePage(
                                    child: _PlayerCoverPage(
                                      isPlaying: isPlaying,
                                      onTapCover: () {
                                        if (_currentPage == 0) {
                                          _activateLyricsPage();
                                          _pageController.jumpToPage(1);
                                        }
                                      },
                                    ),
                                  );
                                }
                                if (!_lyricsPageBuilt)
                                  return const SizedBox.expand();
                                return _KeepAlivePage(
                                  child: _PlayerLyricsPage(
                                    amllKey: _amllKey,
                                    hideWebView: _isLeaving,
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                      _PlayerSongInfo(),
                      _PlayerProgressBar(),
                      const SizedBox(height: 12),
                      _PlayerControls(onQueue: _openPlayQueue),
                      SizedBox(height: 16),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Tablet landscape layout with two modes:
  ///
  /// Split mode (_landscapeLyricsFullMode == false):
  /// ┌─────────────────────────────────────────────┐
  /// │  ⬇ 返回          播放模式          🎵 歌词  │
  /// ├──────────────┬──────────────────────────────┤
  /// │              │                              │
  /// │   封面图片    │         歌词显示区域          │
  /// │   歌曲信息    │                              │
  /// │   进度条      │         (50% / 50%)          │
  /// │   播放控制    │                              │
  /// └──────────────┴──────────────────────────────┘
  ///
  /// Full-lyrics mode (_landscapeLyricsFullMode == true):
  /// ┌─────────────────────────────────────────────┐
  /// │  ⬇ 返回          播放模式          🖼 封面  │
  /// │                                             │
  /// │            歌词显示区域 (全屏)               │
  /// │                                             │
  /// └─────────────────────────────────────────────┘
  Widget _buildTabletLandscapeLayout({
    required bool isPlaying,
    required bool audioVisualizer,
  }) {
    return Column(
      children: [
        // Full-width header: back (left) — play mode (center) — toggle (right)
        _PlayerHeader(
          currentPage: _landscapeLyricsFullMode ? 1 : 0,
          onBack: () => _beginExit(),
          onTogglePage: () {
            setState(() => _landscapeLyricsFullMode = !_landscapeLyricsFullMode);
          },
        ),
        // Main content
        Expanded(
          child: _landscapeLyricsFullMode
              ? _buildLandscapeFullLyricsMode(isPlaying: isPlaying)
              : _buildTabletSplitMode(isPlaying: isPlaying),
        ),
      ],
    );
  }

  /// Phone landscape layout (reached when the system auto-rotate is on).
  ///
  /// Structure is identical to the tablet landscape layout — cover on top,
  /// playback controls underneath on the left, lyrics on the right — but the
  /// available height is tiny (usually 320~420dp), so:
  ///   * the header and all controls use their compact variants;
  ///   * the cover size is derived from the leftover height instead of a
  ///     fixed breakpoint value, so no device can overflow.
  Widget _buildPhoneLandscapeLayout({required bool isPlaying}) {
    return Column(
      children: [
        _PlayerHeader(
          currentPage: _landscapeLyricsFullMode ? 1 : 0,
          compact: true,
          onBack: () => _beginExit(),
          onTogglePage: () {
            setState(() => _landscapeLyricsFullMode = !_landscapeLyricsFullMode);
          },
        ),
        Expanded(
          child: _landscapeLyricsFullMode
              ? _buildLandscapeFullLyricsMode(isPlaying: isPlaying)
              : _buildPhoneSplitMode(isPlaying: isPlaying),
        ),
      ],
    );
  }

  /// Split mode: cover on left (centered/upper), controls at bottom,
  /// lyrics on right. Layout inspired by CeruMusic's side-by-side player.
  Widget _buildTabletSplitMode({required bool isPlaying}) {
    return Row(
      children: [
        // Left side: cover (centered) + controls (bottom)
        Expanded(
          flex: 5,
          child: Column(
            children: [
              const SizedBox(height: 16),
              // Cover takes up available space, centered vertically
              Expanded(
                child: _PlayerCoverPage(
                  isPlaying: isPlaying,
                  onTapCover: null,
                ),
              ),
              const SizedBox(height: 8),
              // Controls pinned to bottom
              _PlayerSongInfo(),
              _PlayerProgressBar(),
              const SizedBox(height: 8),
              _PlayerControls(onQueue: _openPlayQueue),
              const SizedBox(height: 16),
            ],
          ),
        ),
        // Right side: lyrics (full height)
        Expanded(
          flex: 5,
          child: _buildLandscapeLyricsPanel(),
        ),
      ],
    );
  }

  /// Phone landscape split mode: same two-column structure as the tablet one
  /// (equal halves, split line aligned with the centered play-mode label in the
  /// header), with compact controls.
  ///
  /// Left column: cover on the left, song title/artist + favorite/menu buttons
  /// stacked in a column on its right, then progress bar and controls below.
  Widget _buildPhoneSplitMode({required bool isPlaying}) {
    return Row(
      children: [
        Expanded(
          flex: 4,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 上半区（封面 + 信息列）吃掉底部控件之外的全部高度。
              final topArea = math.max(
                72.0,
                constraints.maxHeight - _phoneLandscapeReservedHeight,
              );
              // 封面：不超过上半区高度，也不超过左栏宽度的 46%。
              final coverSize = math.min(
                topArea - 8,
                math.max(64.0, constraints.maxWidth * 0.46),
              );
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: SizedBox(
                      height: topArea,
                      child: Row(
                        children: [
                          // scaleDown 兜底：极小屏（如分屏）时自动缩小封面而不是溢出。
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: _PlayerCoverPage(
                              isPlaying: isPlaying,
                              coverSize: coverSize,
                              onTapCover: null,
                            ),
                          ),
                          const SizedBox(width: 12),
                          // 歌名/歌手 + 收藏/功能菜单：右端与进度条右端齐平。
                          const Expanded(
                            child: _PlayerSongInfo(compact: true, side: true),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: const _PlayerProgressBar(compact: true),
                  ),
                  const SizedBox(height: 10),
                  _PlayerControls(compact: true, onQueue: _openPlayQueue),
                  const SizedBox(height: 6),
                ],
              );
            },
          ),
        ),
        const Spacer(flex: 1),
        Expanded(flex: 5, child: _buildLandscapeLyricsPanel()),
      ],
    );
  }

  /// Full-lyrics mode: lyrics occupy the entire area.
  Widget _buildLandscapeFullLyricsMode({required bool isPlaying}) {
    return _buildLandscapeLyricsPanel();
  }

  /// Shared lyrics panel builder.
  Widget _buildLandscapeLyricsPanel() {
    return ListenableBuilder(
      listenable: AmllToggleService(),
      builder: (context, _) {
        if (!_lyricsPageBuilt) {
          // Defer setState to after the current build frame to avoid
          // "setState() called during build" error.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _activateLyricsPage();
          });
        }
        return _KeepAlivePage(
          child: _PlayerLyricsPage(
            amllKey: _amllKey,
            hideWebView: _isLeaving,
            landscape: true,
          ),
        );
      },
    );
  }

  /// 打开播放队列（竖屏 / 平板横屏 / 手机横屏共用）。
  void _openPlayQueue() {
    showPlayQueueSheet(
      context,
      playbackState: ref.read(playbackControllerProvider),
      controller: ref.read(playbackControllerProvider.notifier),
    );
  }

  /// 手机横屏左栏底部固定区（进度条 + 播放控制 + 内边距）的高度。
  /// 封面 + 信息列的上半区高度 = 左栏可用高度 - 该值；封面再由
  /// [FittedBox] 兜底缩放，因此任何机型都不会溢出。
  static const double _phoneLandscapeReservedHeight = 104;
}

class _PlayerHeader extends ConsumerWidget {
  final int currentPage;
  final VoidCallback onTogglePage;
  final VoidCallback onBack;

  /// 紧凑模式：手机横屏等高度受限的场景。
  final bool compact;

  const _PlayerHeader({
    required this.currentPage,
    required this.onTogglePage,
    required this.onBack,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前实际使用的音源：内置音源本身没有地址接口，播放地址由插件解析，
    // 这里显示真正在提供地址的那个音源（内置源带「-内置」，插件源用平台名）。
    //
    // 音源标签放在顶部栏并与封面居中对齐。
    final sourceLabel = currentSourceLabel(ref) ?? '';

    return Padding(
      padding: EdgeInsets.only(
        top: compact ? 2 : 8,
        left: compact ? 4 : 8,
        right: compact ? 4 : 8,
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            icon: Icon(Icons.keyboard_arrow_down, size: compact ? 24 : 28),
            color: Colors.white.withValues(alpha: 0.6),
            padding: compact ? EdgeInsets.zero : null,
            constraints: compact
                ? const BoxConstraints.tightFor(width: 32, height: 32)
                : null,
            style: IconButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.05),
            ),
          ),
          // 顶部只显示当前使用的音源（居中，与封面居中对齐）。
          Expanded(
            child: sourceLabel.isEmpty
                ? const SizedBox.shrink()
                : Center(
                    child: Text(
                      sourceLabel,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
          ),
          // Windows 上没有「切换全屏歌词」这个形态，直接隐藏该按钮。
          if (!Platform.isWindows)
            IconButton(
              onPressed: onTogglePage,
              icon: Icon(
                currentPage == 0 ? Icons.lyrics : Icons.album,
                size: compact ? 18 : 20,
              ),
              color: Colors.white.withValues(alpha: 0.6),
              padding: compact ? EdgeInsets.zero : null,
              constraints: compact
                  ? const BoxConstraints.tightFor(width: 32, height: 32)
                  : null,
              style: IconButton.styleFrom(
                backgroundColor: Colors.white.withValues(alpha: 0.05),
              ),
            ),
        ],
      ),
    );
  }
}

class _PlayerCoverPage extends ConsumerWidget {
  final bool isPlaying;
  final VoidCallback? onTapCover;

  /// 显式指定封面边长；为 null 时按断点取 [ResponsiveLayout.albumArtSize]。
  /// 手机横屏用剩余高度动态计算，避免溢出。
  final double? coverSize;

  const _PlayerCoverPage({
    required this.isPlaying,
    this.onTapCover,
    this.coverSize,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(currentSongIdentityProvider);
    final song = ref.read(playbackControllerProvider).currentSong;
    final bgMode = ref.watch(fullScreenBackgroundModeProvider);
    final coverColorAsync = ref.watch(currentCoverColorProvider);
    final dominantColor = coverColorAsync.whenOrNull(
      data: (result) => result?.dominantColor,
    );
    final coverSize =
        this.coverSize ?? ResponsiveLayout.albumArtSize(context);
    final radius = ResponsiveLayout.isTablet(context) ? 28.0 : 24.0;
    final borderRadius = math.min(radius, coverSize * 0.12);

    // 音源名称放在顶部栏（与封面居中对齐），封面页不再重复显示。
    return Center(
      child: GestureDetector(
        onTap: onTapCover,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 500),
          scale: isPlaying ? 1.0 : 0.95,
          curve: Curves.easeOutCubic,
          child: Container(
            width: coverSize,
            height: coverSize,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(borderRadius),
              boxShadow: [
                BoxShadow(
                  color:
                      bgMode == FullScreenBackgroundMode.theme &&
                          dominantColor != null
                      ? HSLColor.fromColor(dominantColor)
                            .withLightness(
                              (HSLColor.fromColor(dominantColor).lightness - 0.2)
                                  .clamp(0.0, 0.5),
                            )
                            .toColor()
                            .withValues(alpha: 0.4)
                      : Colors.black.withValues(alpha: 0.5),
                  blurRadius: math.min(50, coverSize * 0.16),
                  offset: Offset(0, math.min(25, coverSize * 0.08)),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: _buildCoverImage(song, coverSize),
          ),
        ),
      ),
    );
  }

  static Widget _buildCoverImage(Song? song, double artSize) {
    if (song == null) {
      return Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0x4D6366F1), Color(0xFF1E1E2E)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: const Icon(Icons.music_note, size: 60, color: Colors.white24),
      );
    }
    // 优先使用 coverUrl（精准匹配后的在线封面），再回退到设备本地封面
    if (song.coverUrl != null && song.coverUrl!.isNotEmpty) {
      return MusicCoverImage(
        url: song.coverUrl,
        fit: BoxFit.cover,
        cacheWidth: 1536,
        cacheHeight: 1536,
        filterQuality: FilterQuality.high,
        errorWidget: _fallbackCover(song),
      );
    }
    if (song.mediaStoreId != null || song.isLocal) {
      return MusicCoverImage(
        key: ValueKey('fp_cover_${song.id}'),
        songId: song.id,
        mediaStoreId: song.mediaStoreId,
        fit: BoxFit.cover,
        cacheWidth: 1536,
        cacheHeight: 1536,
        filterQuality: FilterQuality.high,
        errorWidget: _fallbackCover(song),
      );
    }
    return _fallbackCover(song);
  }

  static Widget _fallbackCover(Song? song) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0x4D6366F1), Color(0xFF1E1E2E)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Icon(Icons.music_note, size: 60, color: Colors.white24),
    );
  }
}

/// 横屏（手机/平板）歌词字号放大倍数：横屏歌词区更宽更矮，
/// 竖屏的 22pt 在横屏下偏小。仅横屏生效，竖屏保持原样。
const double _landscapeLyricFontScale = 1.55;

class _PlayerLyricsPage extends ConsumerWidget {
  final GlobalKey<AmllLyricPlayerState> amllKey;

  /// 退出动画期间隐藏 AMLL WebView（平台视图不参与滑动合成）。
  final bool hideWebView;

  /// 是否处于横屏布局。横屏时歌词区域更宽但更矮，字号相应放大。
  final bool landscape;

  const _PlayerLyricsPage({
    required this.amllKey,
    required this.hideWebView,
    this.landscape = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyricState = ref.watch(lyricControllerProvider);
    final position = ref.watch(
      playbackControllerProvider.select((s) => s.position),
    );
    final isPlaying = ref.watch(
      playbackControllerProvider.select((s) => s.isPlaying),
    );
    final showTranslation = ref.watch(lyricShowTranslationProvider);
    final showRoman = ref.watch(lyricShowRomanProvider);
    final enableBlur = ref.watch(lyricEnableBlurProvider);
    final enableScale = ref.watch(lyricEnableScaleProvider);
    final enableJumpLyric = ref.watch(appearanceJumpLyricProvider);
    final immersiveColor = ref.watch(lyricImmersiveColorProvider);
    final fontSizeScale = ref.watch(lyricFontSizeProvider);
    final coverColorAsync = ref.watch(currentCoverColorProvider);
    final lightColor = coverColorAsync.whenOrNull(
      data: (result) => result?.lightColor,
    );

    final Color activeColor;
    if (immersiveColor && lightColor != null) {
      activeColor = lightColor;
    } else {
      activeColor = Colors.white;
    }
    final inactiveColor = Colors.white.withValues(alpha: 0.4);
    final hasYrc = lyricState.hasYrc;
    // 横屏（手机/平板）时歌词区更宽更矮，22pt 显得过小，统一放大。
    final layoutScale = landscape ? _landscapeLyricFontScale : 1.0;
    final baseFontSize = 22.0 * fontSizeScale * layoutScale;
    final transFontSize = 15.0 * fontSizeScale * layoutScale;
    final romanFontSize = 13.0 * fontSizeScale * layoutScale;
    final watchFontFamily = ref.watch(lyricFontFamilyProvider);
    final watchFontRate = ref.watch(lyricFontRateProvider);
    final watchFontWeight = ref.watch(lyricFontWeightProvider);
    final lyricCenterAlign = ref.watch(lyricCenterAlignProvider);
    final amllCenterAlign = ref.watch(amllCenterAlignProvider);

    return ListenableBuilder(
      listenable: AmllToggleService(),
      builder: (context, _) {
        final amll = AmllToggleService().isActive;
        if (lyricState.isLoading && lyricState.lines.isEmpty) {
          return Center(
            child: Text(
              context.tr('加载歌词中...'),
              style: TextStyle(
                fontSize: 14,
                color: Colors.white.withValues(alpha: 0.4),
                letterSpacing: 2,
              ),
            ),
          );
        }
        if (lyricState.error != null && lyricState.lines.isEmpty) {
          return Center(
            child: Text(
              lyricState.error!,
              style: TextStyle(
                fontSize: 14,
                color: Colors.white.withValues(alpha: 0.4),
                letterSpacing: 2,
              ),
            ),
          );
        }
        if (lyricState.lines.isEmpty) {
          return Center(
            child: Text(
              context.tr('暂无歌词'),
              style: TextStyle(
                fontSize: 14,
                color: Colors.white.withValues(alpha: 0.4),
                letterSpacing: 2,
              ),
            ),
          );
        }
        return Stack(
          children: [
            // Keep the native AMLL WebView mounted in a stable platform-view
            // slot. Switching only the Flutter lyric layer prevents the first
            // WebView detach/attach from flashing after a cold app start.
            //
            // Windows 端 AMLL 的 WebView 合成异常，整块都不构建，
            // 直接使用原生歌词层渲染。
            if (AmllToggleService.isPlatformSupported)
              RepaintBoundary(
                child: TickerMode(
                  enabled: !hideWebView,
                  child: Offstage(
                    offstage: hideWebView,
                    child: AmllLyricPlayer(
                      key: amllKey,
                      lines: lyricState.lines,
                      currentTimeMs: position.inMilliseconds,
                      isPlaying: isPlaying,
                      fontSizeRate: watchFontRate * layoutScale,
                      fontFamily: watchFontFamily,
                      fontWeight: watchFontWeight,
                      showTranslation: showTranslation,
                      showRoman: showRoman,
                      enableBlur: enableBlur,
                      enableScale: enableScale,
                      enableJumpLyric: enableJumpLyric,
                      centerAlign: amllCenterAlign,
                      isVisible: amll,
                      isActive: !hideWebView,
                      onLineClick: (startTimeMs) {
                        ref
                            .read(playbackControllerProvider.notifier)
                            .seek(Duration(milliseconds: startTimeMs));
                      },
                    ),
                  ),
                ),
              ),
            IgnorePointer(
              ignoring: amll,
              child: Visibility(
                visible: !amll,
                maintainState: true,
                maintainAnimation: true,
                maintainSize: true,
                maintainInteractivity: false,
                child: LyricScrollView(
                  lines: lyricState.lines,
                  currentTimeMs: position.inMilliseconds,
                  isPlaying: isPlaying,
                  hasYrc: hasYrc,
                  activeColor: activeColor,
                  inactiveColor: inactiveColor,
                  mainFontSize: baseFontSize,
                  transFontSize: transFontSize,
                  romanFontSize: romanFontSize,
                  fontSizeRate: watchFontRate,
                  showTranslation: showTranslation,
                  showRoman: showRoman,
                  enableBlur: enableBlur,
                  enableScale: enableScale,
                  enableJumpLyric: enableJumpLyric,
                  centerAlign: lyricCenterAlign,
                  fontFamily: watchFontFamily,
                  fontWeight: watchFontWeight,
                  onSeek: (startTimeMs) {
                    ref
                        .read(playbackControllerProvider.notifier)
                        .seek(Duration(milliseconds: startTimeMs));
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PlayerSongInfo extends ConsumerWidget {
  /// 紧凑模式：手机横屏等高度受限的场景。
  final bool compact;

  /// 侧栏模式：渲染为「封面右侧的信息列」——歌名/歌手 左对齐，
  /// 收藏与功能菜单另起一行；不加外层水平内边距（由调用方留白）。
  /// 手机横屏左栏使用；默认 false 时为「左对齐歌名 + 右侧图标」的横排布局。
  final bool side;

  const _PlayerSongInfo({this.compact = false, this.side = false});

  void _toggleFavorite(WidgetRef ref, Song? song) {
    if (song == null) return;
    final playlistsAsyncVal = ref.read(playlistsProvider);
    playlistsAsyncVal.whenData((playlists) {
      final fav = playlists.where((p) => p.id == '__favorites__').firstOrNull;
      final isFavorited = fav?.songs.any((s) => s.id == song.id) ?? false;
      if (isFavorited) {
        ref
            .read(playlistsProvider.notifier)
            .removeSongFromPlaylist('__favorites__', song.id);
      } else {
        ref
            .read(playlistsProvider.notifier)
            .addSongToPlaylist('__favorites__', song);
      }
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(currentSongIdentityProvider);
    final song = ref.read(playbackControllerProvider).currentSong;
    final playlistsAsync = ref.watch(playlistsProvider);

    final isFavorite =
        playlistsAsync.whenOrNull(
          data: (playlists) {
            final fav = playlists
                .where((p) => p.id == '__favorites__')
                .firstOrNull;
            return fav?.songs.any((s) => s.id == song?.id) ?? false;
          },
        ) ??
        false;

    final buttonConstraints = compact
        ? const BoxConstraints.tightFor(width: 30, height: 30)
        : null;
    final favoriteButton = IconButton(
      onPressed: () => _toggleFavorite(ref, song),
      icon: Icon(
        isFavorite ? Icons.favorite : Icons.favorite_border,
        size: compact ? 18 : 24,
        color: isFavorite ? Colors.red : Colors.white.withValues(alpha: 0.7),
      ),
      padding: compact ? EdgeInsets.zero : null,
      constraints: buttonConstraints,
    );
    // 下载：只显示图标，点击后选择音质。
    final downloadButton = IconButton(
      onPressed: song == null
          ? null
          : () => SongActionSheet.showDownloadQualityPicker(context, song!),
      icon: Icon(
        Icons.download_outlined,
        size: compact ? 18 : 22,
        color: Colors.white.withValues(alpha: 0.7),
      ),
      padding: compact ? EdgeInsets.zero : null,
      constraints: buttonConstraints,
    );
    // 桌面歌词：图标是文字「词」，开启后文字用主题色。
    final desktopLyricEnabled = ref.watch(
      desktopLyricSettingsProvider.select((s) => s.enable),
    );
    final themeColors = ref.watch(themeColorsProvider);
    final desktopLyricButton = IconButton(
      onPressed: () {
        final sync = ref.read(desktopLyricSyncProvider.notifier);
        if (desktopLyricEnabled) {
          unawaited(sync.disableDesktopLyric());
        } else {
          unawaited(sync.enableDesktopLyric());
        }
      },
      icon: Text(
        '词',
        style: TextStyle(
          fontSize: compact ? 15 : 18,
          fontWeight: FontWeight.w600,
          color: desktopLyricEnabled
              ? themeColors.primary
              : Colors.white.withValues(alpha: 0.7),
        ),
      ),
      padding: compact ? EdgeInsets.zero : null,
      constraints: buttonConstraints,
      tooltip: context.tr('启用桌面歌词'),
    );
    final moreButton = IconButton(
      onPressed: song != null
          ? () => SongActionSheet.showPlayerMenu(context, song: song)
          : null,
      icon: Icon(
        Icons.more_horiz,
        size: compact ? 18 : 24,
        color: Colors.white.withValues(alpha: 0.7),
      ),
      padding: compact ? EdgeInsets.zero : null,
      constraints: buttonConstraints,
    );

    final title = Text(
      song?.title ?? context.tr('未知歌曲'),
      style: TextStyle(
        fontSize: compact ? 18 : 20,
        fontWeight: FontWeight.w600,
        color: Colors.white,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    final artist = Text(
      song?.artist ?? context.tr('未知歌手'),
      style: TextStyle(
        fontSize: compact ? 13 : 14,
        color: Colors.white.withValues(alpha: 0.6),
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        desktopLyricButton,
        SizedBox(width: compact ? 10 : 18),
        downloadButton,
        SizedBox(width: compact ? 10 : 18),
        favoriteButton,
        SizedBox(width: compact ? 18 : 28),
        moreButton,
      ],
    );

    // 侧栏模式：封面右侧的信息列。歌名/歌手左对齐，收藏与功能菜单也左对齐，
    // 与歌名/歌手左侧齐平。
    if (side) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          title,
          SizedBox(height: compact ? 4 : 6),
          artist,
          SizedBox(height: compact ? 10 : 14),
          actions,
        ],
      );
    }

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 12 : 32,
        vertical: compact ? 2 : 8,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [title, SizedBox(height: compact ? 1 : 4), artist],
            ),
          ),
          actions,
        ],
      ),
    );
  }
}

class _PlayerProgressBar extends ConsumerWidget {
  /// 紧凑模式：手机横屏等高度受限的场景。
  final bool compact;

  const _PlayerProgressBar({this.compact = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(
      playbackControllerProvider.select((s) => s.position),
    );
    final duration = ref.watch(
      playbackControllerProvider.select((s) => s.duration),
    );
    final currentQuality = ref.watch(
      playbackControllerProvider.select((s) => s.currentQuality),
    );
    final availableQualities = ref.watch(
      playbackControllerProvider.select((s) => s.availableQualities),
    );

    return PlayerProgressBar(
      compact: compact,
      progress:
          (duration.inMilliseconds > 0
                  ? position.inMilliseconds / duration.inMilliseconds
                  : 0.0)
              .clamp(0.0, 1.0),
      position: position,
      duration: duration,
      currentQuality: currentQuality,
      availableQualities: availableQualities,
      onQualityTap: (quality) =>
          ref.read(playbackControllerProvider.notifier).setQuality(quality),
      onSeek: (value) {
        ref
            .read(playbackControllerProvider.notifier)
            .seek(
              Duration(milliseconds: (value * duration.inMilliseconds).round()),
            );
      },
    );
  }
}

class _PlayerControls extends ConsumerWidget {
  final VoidCallback onQueue;

  /// 紧凑模式：手机横屏等高度受限的场景。
  final bool compact;

  const _PlayerControls({required this.onQueue, this.compact = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPlaying = ref.watch(
      playbackControllerProvider.select((s) => s.isPlaying),
    );
    final isLoading = ref.watch(
      playbackControllerProvider.select((s) => s.isLoading),
    );
    final playMode = ref.watch(
      playbackControllerProvider.select((s) => s.playMode),
    );
    final controller = ref.read(playbackControllerProvider.notifier);

    return PlaybackControlRow(
      compact: compact,
      isPlaying: isPlaying,
      isLoading: isLoading,
      playMode: playMode,
      onPlayPause: () => controller.togglePlayPause(),
      onPrevious: () => controller.previous(),
      onNext: () => controller.next(),
      onCycleMode: () => controller.cyclePlayMode(),
      onQueue: onQueue,
    );
  }
}

class _BackgroundLayer extends StatefulWidget {
  final Color? dominantColor;
  final String? coverUrl;
  final FullScreenBackgroundMode mode;
  final bool animate;

  const _BackgroundLayer({
    required this.dominantColor,
    required this.coverUrl,
    required this.mode,
    required this.animate,
  });

  @override
  State<_BackgroundLayer> createState() => _BackgroundLayerState();
}

class _BackgroundLayerState extends State<_BackgroundLayer>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Color? _displayedDominantColor;

  @override
  void initState() {
    super.initState();
    _displayedDominantColor = widget.dominantColor;
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _BackgroundLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Color extraction is asynchronous. Keep the previous palette while the
    // next cover's FutureProvider is loading instead of briefly falling back
    // to the dark background.
    if (widget.dominantColor != null) {
      _displayedDominantColor = widget.dominantColor;
    }
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
    final mode = widget.mode;
    final dominantColor = _displayedDominantColor;
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
                  // 跟随主题的背景整体调暗 30%，避免过亮影响歌词可读性
                  HSLColor.fromColor(dominantColor!)
                      .withLightness(
                        (HSLColor.fromColor(dominantColor!).lightness * 0.7)
                            .clamp(0.10, 0.32),
                      )
                      .toColor(),
                  HSLColor.fromColor(dominantColor!)
                      .withLightness(
                        (HSLColor.fromColor(dominantColor!).lightness * 0.7 - 0.06)
                            .clamp(0.04, 0.25),
                      )
                      .toColor(),
                ],
              ),
            ),
          ),
        if (widget.coverUrl != null &&
            widget.coverUrl!.isNotEmpty &&
            mode == FullScreenBackgroundMode.cover)
          Stack(
            children: [
              Positioned.fill(
                child: widget.animate
                    ? Transform.scale(
                        scale: 1.0 + animationValue * 0.018,
                        child: MusicCoverImage(
                          url: widget.coverUrl,
                          fit: BoxFit.cover,
                          width: double.infinity,
                          height: double.infinity,
                          cacheWidth: 512,
                          cacheHeight: 512,
                          filterQuality: FilterQuality.low,
                        ),
                      )
                    : MusicCoverImage(
                        url: widget.coverUrl,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: double.infinity,
                        cacheWidth: 512,
                        cacheHeight: 512,
                        filterQuality: FilterQuality.low,
                      ),
              ),
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.7),
                        Colors.black.withValues(alpha: 0.8),
                        Colors.black.withValues(alpha: 0.9),
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

class _AudioVisualizer extends ConsumerWidget {
  const _AudioVisualizer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPlaying = ref.watch(
      playbackControllerProvider.select((state) => state.isPlaying),
    );
    return StreamBuilder<List<double>>(
      stream: audioEffectService.visualizerStream,
      builder: (context, snapshot) {
        final values = snapshot.data ?? const <double>[];
        final bars = List<double>.generate(24, (index) {
          if (!isPlaying) return 0.08;
          if (values.isEmpty) return 0.18 + (index % 5) * 0.05;
          final sourceIndex = (index * values.length / 24).floor();
          return values[sourceIndex.clamp(0, values.length - 1).toInt()];
        });
        return SizedBox(
          height: 42,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: bars
                .map(
                  (value) => AnimatedContainer(
                    duration: const Duration(milliseconds: 100),
                    width: 3,
                    height: 6 + value.clamp(0.0, 1.0).toDouble() * 32,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                )
                .toList(),
          ),
        );
      },
    );
  }
}

/// 保持 PageView 页面存活，避免页面切换时 WebView 被销毁重建
class _KeepAlivePage extends StatefulWidget {
  final Widget child;
  const _KeepAlivePage({required this.child});
  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// 当前实际使用的音源名称。
///
/// 内置音源本身没有地址接口，播放地址由插件解析，这里显示真正在提供地址的
/// 那个音源（内置源带「-内置」，插件源用平台名）。
///
/// 注意：音源标签要跟着「歌曲」一起变。只 watch source 的话，同一个平台的
/// 两首歌切换时 source 字符串没变化，组件不会重建，标签会停在上一次的
/// 结果上（看起来就是「音源显示错了」）。
String? currentSourceLabel(WidgetRef ref) {
  final songSource = ref
      .watch(
        playbackControllerProvider.select(
          (s) => (s.currentSong?.source ?? '', s.currentSong?.id ?? ''),
        ),
      )
      .$1;
  if (songSource.isEmpty) return null;
  final manager = ref.read(musicSourceManagerProvider);
  final effective = manager.resolvingSourceIdFor(songSource) ?? songSource;
  final label = manager.sourceDisplayName(effective);
  return label.isEmpty ? null : label;
}
