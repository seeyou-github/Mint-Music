import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../../shared/widgets/fallback_cover_image.dart';
import '../../../shared/widgets/source_name_tag.dart';
import '../../plugin/application/music_source_manager.dart';
import '../application/desktop_lyric_sync.dart';
import '../application/playback_controller.dart';
import '../application/sleep_timer_provider.dart';
import '../application/playback_ui_providers.dart';
import '../application/root_overlay_tracker.dart';
import '../application/lyric_controller.dart';
import '../../radio/application/radio_session.dart';
import '../domain/models/song.dart';
import '../domain/services/cover_color_extractor.dart';
import '../../library/application/playlist_providers.dart';
import '../../plugin/application/plugin_providers.dart';
import '../../settings/application/settings_providers.dart';
import '../../../shared/widgets/song_action_sheet.dart';
import '../../../shared/widgets/sleep_timer_picker.dart';
import 'widgets/lyric_format_tag.dart';
import 'widgets/lyric_scroll_view.dart';
import 'widgets/lyric_search_sheet.dart';
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

  bool _exiting = false;

  /// 竖屏封面页底部预留的高度（封面下方紧跟的歌名 / 歌手区 + 底部锚定的
  /// 操作按钮行）。封面先扣掉这部分再决定边长，两块信息都不会被压到。
  static const double _portraitInfoReserve = 140;

  /// 竖屏时歌名与封面底部的固定间距。
  static const double _portraitInfoGap = 10;

  @override
  void initState() {
    super.initState();
    // 登记「播放详情页已打开」，左侧栏封面按钮据此做打开 / 关闭切换。
    // StatefulShellRoute 下路由配置对根级路由的压栈反映不可靠，
    // 必须由页面自己登记（见 RootOverlayTracker 的说明）。
    RootOverlayTracker.instance.retain(RootOverlayTracker.fullPlayer);
  }

  @override
  void dispose() {
    RootOverlayTracker.instance.release(RootOverlayTracker.fullPlayer);
    _pageController.dispose();
    super.dispose();
  }

  void _beginExit() {
    if (_exiting) return;
    _exiting = true;
    FocusManager.instance.primaryFocus?.unfocus();
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
      // 拦截系统返回键，统一走 _beginExit。
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
                  final isTabletLandscape = ResponsiveLayout.isTabletLandscape(
                    context,
                  );
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
                  // Phone / tablet portrait: vertical layout with PageView.
                  final windowSize = MediaQuery.sizeOf(context);
                  final safePadding = MediaQuery.paddingOf(context);
                  final viewportWidth =
                      windowSize.width - safePadding.left - safePadding.right;
                  // 封面与歌曲信息共用同一条左右边界：封面宽度按可用宽度夹紧，
                  // 两侧留白由它反推，歌名 / 歌手才能和封面左边缘严格对齐。
                  final coverSize = math.min(
                    ResponsiveLayout.albumArtSize(context),
                    viewportWidth,
                  );
                  final coverLeft = math.max(
                    0.0,
                    (viewportWidth - coverSize) / 2,
                  );
                  // 封面顶边落在窗口高度的 15%：扣掉状态栏和顶部工具栏后，
                  // 换算成 PageView 内部需要补的间距。
                  final coverTopGap = math.max(
                    0.0,
                    windowSize.height * 0.15 -
                        safePadding.top -
                        _PlayerHeader.height,
                  );
                  // 音源标签在封面上方，封面整体下移标签占用的高度。
                  final coverTop = coverTopGap + _PlayerSourceTag.space;
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
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            // 封面还要扣掉 PageView 内部的顶部留白（含音源标签），
                            // 并给歌名 / 歌手 / 操作按钮预留空间，矮窗口下也不会被挤出。
                            final pageHeight = constraints.maxHeight;
                            final availableForCover = math.min(
                              constraints.maxWidth,
                              math.max(0.0, pageHeight - coverTop),
                            );
                            final actualCoverSize = math.min(
                              coverSize,
                              math.min(
                                availableForCover,
                                math.max(
                                  0.0,
                                  pageHeight - coverTop - _portraitInfoReserve,
                                ),
                              ),
                            );
                            return Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Positioned.fill(
                                  child: PageView.builder(
                                    controller: _pageController,
                                    physics:
                                        const NeverScrollableScrollPhysics(),
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
                                          child: Padding(
                                            padding: EdgeInsets.only(
                                              left: coverLeft,
                                              right: coverLeft,
                                              top: coverTop,
                                            ),
                                            child: _PlayerCoverPage(
                                              isPlaying: isPlaying,
                                              coverSize: actualCoverSize,
                                              alignment: Alignment.topLeft,
                                              // 缩放锚在左下角：暂停时封面的
                                              // 左边缘、底边都保持不动，
                                              // 与歌名的左对齐和间距都不变。
                                              scaleAlignment:
                                                  Alignment.bottomLeft,
                                              onTapCover: () {
                                                if (_currentPage == 0) {
                                                  _activateLyricsPage();
                                                  _pageController.jumpToPage(1);
                                                }
                                              },
                                            ),
                                          ),
                                        );
                                      }
                                      if (!_lyricsPageBuilt) {
                                        return const SizedBox.expand();
                                      }
                                      const lyricsPage = _PlayerLyricsPage();
                                      return _KeepAlivePage(
                                        // Android：点歌词区域切回封面页。
                                        child: Platform.isAndroid
                                            ? GestureDetector(
                                                behavior:
                                                    HitTestBehavior.translucent,
                                                onTap: () {
                                                  if (_currentPage == 1) {
                                                    _pageController.jumpToPage(
                                                      0,
                                                    );
                                                  }
                                                },
                                                child: lyricsPage,
                                              )
                                            : lyricsPage,
                                      );
                                    },
                                  ),
                                ),
                                // 竖屏封面页：歌名 / 歌手与操作按钮行解绑——
                                // 歌名 / 歌手跟随封面（左对齐封面左边缘、
                                // 紧贴封面底部）；操作按钮行跟随进度条
                                // （bottom 锚定在进度条正上方，左右与进度条
                                // 对齐，spaceBetween 均匀分布 5 个按钮）。
                                // 窗口高度变化时两者各自移动、互不牵连。
                                if (_currentPage == 0) ...[
                                  // 封面上方的音源标签：居中，宽度不超过封面。
                                  Positioned(
                                    left: coverLeft,
                                    right: coverLeft,
                                    top: coverTopGap,
                                    child: Center(
                                      child: _PlayerSourceTag(
                                        maxWidth: actualCoverSize,
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    left: coverLeft,
                                    right: coverLeft,
                                    top:
                                        coverTop +
                                        actualCoverSize +
                                        _portraitInfoGap,
                                    child: _PlayerSongInfo(
                                      padded: false,
                                      showInlineLyric: Platform.isAndroid,
                                      showActions: false,
                                    ),
                                  ),
                                  Positioned(
                                    left: PlayerProgressBar.horizontalPadding,
                                    right: PlayerProgressBar.horizontalPadding,
                                    bottom: 0,
                                    child: const _PlayerActions(),
                                  ),
                                ],
                              ],
                            );
                          },
                        ),
                      ),
                      if (_currentPage == 1)
                        // 与封面共用左右留白，歌名 / 歌手左对齐封面左边缘。
                        Padding(
                          padding: EdgeInsets.only(
                            left: coverLeft,
                            right: coverLeft,
                            top: 8,
                          ),
                          child: _PlayerSongInfo(
                            padded: false,
                            showInlineLyric: Platform.isAndroid,
                          ),
                        ),
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
            setState(
              () => _landscapeLyricsFullMode = !_landscapeLyricsFullMode,
            );
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
            setState(
              () => _landscapeLyricsFullMode = !_landscapeLyricsFullMode,
            );
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

  /// Split mode: cover on left (upper), controls at bottom, lyrics on right.
  ///
  /// 左栏自上而下：封面 → 歌名/歌手（紧贴封面，宽度与封面一致）→ 弹性留白
  /// → 操作按钮（进度条上方均匀铺开）→ 进度条 → 播放控制。
  Widget _buildTabletSplitMode({required bool isPlaying}) {
    return Row(
      children: [
        Expanded(
          flex: 5,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 封面缩小：宽高都收一点，并整体上移（不再垂直居中）。
              // 预留约 300px 给歌名/按钮/进度条/播放控制，再加上封面上方
              // 音源标签的高度，避免小窗口溢出。
              final coverSize = math.max(
                96.0,
                math.min(
                  math.min(constraints.maxWidth * 0.62, 315.0),
                  constraints.maxHeight - 300 - _PlayerSourceTag.space,
                ),
              );
              return Column(
                children: [
                  const SizedBox(height: 8),
                  _PlayerSourceTag(maxWidth: coverSize),
                  const SizedBox(height: _PlayerSourceTag.gap),
                  _PlayerCoverPage(
                    isPlaying: isPlaying,
                    coverSize: coverSize,
                    // 缩放锚在左下角：暂停收缩时封面左边缘不移动，
                    // 下方歌名 / 歌手始终与可见封面对齐。
                    scaleAlignment: Alignment.bottomLeft,
                    onTapCover: null,
                  ),
                  const SizedBox(height: 10),
                  // 歌名 / 歌手：宽度与封面一致，始终紧贴封面下方。
                  SizedBox(
                    width: coverSize,
                    child: const _PlayerSongInfo(
                      padded: false,
                      showActions: false,
                    ),
                  ),
                  const Spacer(),
                  // 操作按钮靠近播放条，在进度条上方均匀分布。
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 32),
                    child: _PlayerActions(),
                  ),
                  const SizedBox(height: 4),
                  _PlayerProgressBar(),
                  const SizedBox(height: 8),
                  _PlayerControls(onQueue: _openPlayQueue),
                  const SizedBox(height: 16),
                ],
              );
            },
          ),
        ),
        // Right side: lyrics (full height)
        Expanded(flex: 5, child: _buildLandscapeLyricsPanel()),
      ],
    );
  }

  /// Phone landscape split mode: same two-column structure as the tablet one
  /// (equal halves, split line aligned with the centered play-mode label in the
  /// header), with compact controls.
  ///
  /// Left column: cover with song title/artist directly underneath, then the
  /// action buttons evenly spread above the progress bar, controls at the
  /// bottom.
  Widget _buildPhoneSplitMode({required bool isPlaying}) {
    return Row(
      children: [
        Expanded(
          flex: 4,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 上半区（封面 + 歌名）吃掉底部控件之外的全部高度。
              final topArea = math.max(
                96.0,
                constraints.maxHeight - _phoneLandscapeReservedHeight,
              );
              // 封面：给下方歌名/歌手留出空间，且不超过左栏宽度的 62%。
              final coverSize =
                  math.max(
                    56.0,
                    math.min(constraints.maxWidth * 0.62, topArea - 54),
                  ) *
                  1.05;
              return Column(
                children: [
                  Expanded(
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _PlayerSourceTag(maxWidth: coverSize),
                            const SizedBox(height: 4),
                            _PlayerCoverPage(
                              isPlaying: isPlaying,
                              coverSize: coverSize,
                              // 缩放锚在左下角：暂停收缩时封面左边缘
                              // 不移动，歌名 / 歌手始终与封面对齐。
                              scaleAlignment: Alignment.bottomLeft,
                              onTapCover: null,
                            ),
                            const SizedBox(height: 8),
                            // 歌名 / 歌手紧贴封面下方，宽度与封面一致。
                            SizedBox(
                              width: coverSize,
                              child: const _PlayerSongInfo(
                                compact: true,
                                padded: false,
                                showActions: false,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: _PlayerActions(compact: true),
                  ),
                  const SizedBox(height: 2),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: _PlayerProgressBar(compact: true),
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
    if (!_lyricsPageBuilt) {
      // Defer setState to after the current build frame to avoid
      // "setState() called during build" error.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _activateLyricsPage();
      });
    }
    return const _KeepAlivePage(child: _PlayerLyricsPage(landscape: true));
  }

  /// 打开播放队列（竖屏 / 平板横屏 / 手机横屏共用）。
  void _openPlayQueue() {
    showPlayQueueSheet(
      context,
      playbackState: ref.read(playbackControllerProvider),
      controller: ref.read(playbackControllerProvider.notifier),
    );
  }

  /// 手机横屏左栏底部固定区（操作按钮 + 进度条 + 播放控制 + 间距）的高度。
  /// 上半区高度 = 左栏可用高度 - 该值；封面再由 [FittedBox] 兜底缩放，
  /// 因此任何机型都不会溢出。
  static const double _phoneLandscapeReservedHeight = 116;
}

class _PlayerHeader extends ConsumerWidget {
  /// 竖屏布局用该高度反推封面顶边位置（顶部留白 8 + 48 的 IconButton）。
  static const double height = 56;

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
    // 顶部栏只保留「收起」与「切换歌词 / 封面」两个按钮，不再显示音源名称。
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
          const Spacer(),
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

/// 封面上方的「当前播放音源」标签。
///
/// 宽度不超过封面（[maxWidth]），名称过长时省略；本地歌曲显示「本地音乐」。
class _PlayerSourceTag extends ConsumerWidget {
  const _PlayerSourceTag({required this.maxWidth});

  /// 标签的最大宽度，由封面边长决定。
  final double maxWidth;

  static const double height = 20;
  static const double gap = 6;

  /// 标签本身 + 与封面的间距，各布局按这个值给封面预留空间。
  static const double space = height + gap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(currentSongIdentityProvider);
    final song = ref.read(playbackControllerProvider).currentSong;
    final sourceId = (song?.displaySource ?? '').trim();
    // 太窄时放不下图标 + 文字，直接不显示（封面本身已经很小了）。
    if (song == null || sourceId.isEmpty || maxWidth < 56) {
      return const SizedBox.shrink();
    }
    final name = sourceId == 'local'
        ? context.tr('本地音乐')
        : ref.read(musicSourceManagerProvider).sourceDisplayName(sourceId);
    if (name.trim().isEmpty) return const SizedBox.shrink();

    // 固定高度的标签用固定字号，限制文字缩放避免撑破布局。
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.2,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(AppRadius.xs),
            border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.music_note,
                size: 12,
                color: Colors.white.withValues(alpha: 0.7),
              ),
              const SizedBox(width: 3),
              Flexible(
                child: Text(
                  SourceNameTag.shorten(name.trim()),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: Colors.white.withValues(alpha: 0.88),
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

class _PlayerCoverPage extends ConsumerWidget {
  final bool isPlaying;
  final VoidCallback? onTapCover;

  /// 显式指定封面边长；为 null 时按断点取 [ResponsiveLayout.albumArtSize]。
  /// 手机横屏用剩余高度动态计算，避免溢出。
  final double? coverSize;

  /// 封面在可用区域内的对齐方式。竖屏用 [Alignment.topLeft]，让封面顶边落在
  /// 指定高度、左边缘与歌曲信息对齐；其它布局保持居中。
  final Alignment alignment;

  /// 暂停时封面缩小动画的锚点。各布局统一用 [Alignment.bottomLeft]：
  /// 收缩时左边缘、底边都不动，歌名 / 歌手与可见封面的左对齐和间距保持不变。
  final Alignment scaleAlignment;

  const _PlayerCoverPage({
    required this.isPlaying,
    this.onTapCover,
    this.coverSize,
    this.alignment = Alignment.center,
    this.scaleAlignment = Alignment.center,
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
    final coverSize = this.coverSize ?? ResponsiveLayout.albumArtSize(context);
    final radius = ResponsiveLayout.isTablet(context) ? 28.0 : 24.0;
    final borderRadius = math.min(radius, coverSize * 0.12);

    return Align(
      alignment: alignment,
      child: GestureDetector(
        onTap: onTapCover,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 500),
          scale: isPlaying ? 1.0 : 0.95,
          alignment: scaleAlignment,
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
                      ? coverDarkBackgroundColor(
                          dominantColor,
                          lightness: 0.22,
                        ).withValues(alpha: 0.45)
                      : Colors.black.withValues(alpha: 0.5),
                  blurRadius: math.min(50, coverSize * 0.16),
                  offset: Offset(0, math.min(25, coverSize * 0.08)),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: _buildCoverImage(
              song,
              coverSize,
              ref.read(musicSourceManagerProvider),
            ),
          ),
        ),
      ),
    );
  }

  static Widget _buildCoverImage(
    Song? song,
    double artSize,
    MusicSourceManager sourceManager,
  ) {
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
    // 优先使用 coverUrl（精准匹配后的在线封面），再回退到设备本地封面。
    // 插件歌曲的 coverUrl 可能是空地址（歌单 / 榜单歌曲只有 id）或失效地址：
    // 列表有逐行 getPic 兜底能自愈，播放器这里用 FallbackCoverImage 补上同样
    // 的兜底。
    if (!song.isLocal) {
      return FallbackCoverImage(
        song: song,
        url: song.coverUrl,
        sourceManager: sourceManager,
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
  /// 是否处于横屏布局。横屏时歌词区域更宽但更矮，字号相应放大。
  final bool landscape;

  const _PlayerLyricsPage({this.landscape = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyricState = ref.watch(lyricControllerProvider);
    final position = ref.watch(
      playbackControllerProvider.select((s) => s.position),
    );
    final seekPreview = ref.watch(seekPreviewPositionProvider);
    final lyricPosition = seekPreview ?? position;
    final isPlaying = ref.watch(
      playbackControllerProvider.select((s) => s.isPlaying),
    );
    final showTranslation = ref.watch(lyricShowTranslationProvider);
    final showRoman = ref.watch(lyricShowRomanProvider);
    final enableBlur = ref.watch(lyricEnableBlurProvider);
    final enableScale = ref.watch(lyricEnableScaleProvider);
    final fontSizeScale = ref.watch(lyricFontSizeProvider);
    final themeColors = ref.watch(themeColorsProvider);

    final activeColor = themeColors.primary;
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
      return _buildEmptyState(context, ref, lyricState.error!);
    }
    if (lyricState.lines.isEmpty) {
      return _buildEmptyState(context, ref, context.tr('暂无歌词'));
    }
    return Stack(
      children: [
        Positioned.fill(
          child: LyricScrollView(
            lines: lyricState.lines,
            currentTimeMs: lyricPosition.inMilliseconds,
            isPlaying: isPlaying,
            isSeekPreview: seekPreview != null,
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
        if (lyricState.lyricFormat != null)
          Positioned(
            top: 8,
            right: 16,
            child: IgnorePointer(
              child: LyricFormatTag(
                format: lyricState.lyricFormat!,
                dark: true,
              ),
            ),
          ),
      ],
    );
  }

  /// 没有歌词 / 歌词加载失败：提示下面给一个「搜索歌词」入口。
  Widget _buildEmptyState(BuildContext context, WidgetRef ref, String message) {
    final song = ref.read(playbackControllerProvider).currentSong;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: Colors.white.withValues(alpha: 0.4),
              letterSpacing: 2,
            ),
          ),
          if (song != null) ...[
            const SizedBox(height: AppSpacing.md),
            _SearchLyricButton(song: song),
          ],
        ],
      ),
    );
  }
}

/// 歌词为空时的「搜索歌词」入口：打开搜索弹层，可换音源、改歌名 / 歌手。
class _SearchLyricButton extends StatelessWidget {
  const _SearchLyricButton({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => showLyricSearchSheet(context, song: song),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: 7,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.full),
            border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.search,
                size: 15,
                color: Colors.white.withValues(alpha: 0.75),
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                context.tr('搜索歌词'),
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withValues(alpha: 0.75),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlayerSongInfo extends ConsumerWidget {
  /// 紧凑模式：手机横屏等高度受限的场景。
  final bool compact;

  /// 是否加外层水平内边距（侧栏模式由调用方留白）。
  final bool padded;

  /// 是否在歌手名下方显示当前歌词行（Android 手机）。
  final bool showInlineLyric;

  /// 是否在歌名下方显示操作按钮。
  /// 横屏把按钮单独放在进度条上方，这里只保留歌名 / 歌手紧贴封面。
  final bool showActions;

  const _PlayerSongInfo({
    this.compact = false,
    this.padded = true,
    this.showInlineLyric = false,
    this.showActions = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(currentSongIdentityProvider);
    final song = ref.read(playbackControllerProvider).currentSong;

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

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        title,
        SizedBox(height: compact ? 1 : 4),
        artist,
        if (showInlineLyric) ...[
          const SizedBox(height: 6),
          _InlineLyricLine(fontSize: compact ? 12 : 14),
        ],
        if (showActions) ...[
          SizedBox(height: compact ? 6 : 10),
          _PlayerActions(compact: compact),
        ],
      ],
    );

    if (!padded) return content;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 12 : 32,
        vertical: compact ? 2 : 8,
      ),
      child: content,
    );
  }
}

/// 收藏 / 下载 / 定时 / 桌面歌词 / 更多。
///
/// 竖屏放在歌名下方；横屏放在进度条上方，由 [MainAxisAlignment.spaceBetween]
/// 在整栏宽度内均匀铺开。
class _PlayerActions extends ConsumerWidget {
  /// 紧凑模式：手机横屏等高度受限的场景。
  final bool compact;

  const _PlayerActions({this.compact = false});

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

    final themeColors = ref.watch(themeColorsProvider);
    final isAndroid = Platform.isAndroid;

    // Material 图标都画在 24dp 网格里、自带约 2dp 留白，实际墨迹约 17~20dp；
    // 汉字「词」的墨迹几乎占满 em 框，再加上加粗会明显比图标「重」，所以
    // 用更小的字号 + w500 让两者视觉尺寸、笔画粗细都对齐。
    final iconSize = compact ? 20.0 : 24.0;
    final wordFontSize = compact ? 15.0 : 17.0;
    final buttonConstraints = BoxConstraints.tightFor(
      width: compact ? 30 : 40,
      height: compact ? 30 : 40,
    );
    final idleColor = Colors.white.withValues(alpha: 0.7);

    IconButton iconButton({
      required IconData icon,
      required VoidCallback? onPressed,
      required String tooltip,
      Color? color,
    }) {
      return IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: iconSize, color: color ?? idleColor),
        padding: EdgeInsets.zero,
        constraints: buttonConstraints,
        tooltip: tooltip,
      );
    }

    // 收藏
    final favoriteButton = iconButton(
      icon: isFavorite ? Icons.favorite : Icons.favorite_border,
      onPressed: () => _toggleFavorite(ref, song),
      tooltip: context.tr('收藏'),
      color: isFavorite ? Colors.red : null,
    );
    // 下载：点击后选择音质
    final downloadButton = iconButton(
      icon: Icons.download_outlined,
      onPressed: song == null
          ? null
          : () => SongActionSheet.showDownloadQualityPicker(context, song),
      tooltip: context.tr('下载'),
    );
    // 定时关闭：已设定时用主题色
    final sleepActive = ref.watch(sleepTimerProvider).active;
    final sleepTimerButton = iconButton(
      icon: sleepActive ? Icons.timer : Icons.timer_outlined,
      onPressed: () => showSleepTimerPicker(context),
      tooltip: context.tr('定时关闭'),
      color: sleepActive ? themeColors.primary : null,
    );
    // 桌面歌词：图标是文字「词」，开启后文字用主题色。
    // Android 没有独立的桌面歌词窗口，这个位置换成「倍速」。
    final desktopLyricEnabled = ref.watch(
      desktopLyricSettingsProvider.select((s) => s.enable),
    );
    final desktopLyricButton = IconButton(
      onPressed: () {
        final sync = ref.read(desktopLyricSyncProvider.notifier);
        if (desktopLyricEnabled) {
          unawaited(sync.disableDesktopLyric());
        } else {
          unawaited(sync.enableDesktopLyric());
        }
      },
      // 用文字「词」当图标：不要把文字塞进和字号一样大的 SizedBox，
      // 否则中文字形的上下会超出 em 框而被裁掉（表现为图标显示不全）。
      icon: Text(
        '词',
        style: TextStyle(
          fontSize: wordFontSize,
          height: 1.2,
          fontWeight: FontWeight.w500,
          // Windows 端固定使用系统默认字体，不跟随应用自定义字体。
          fontFamily: Platform.isWindows ? 'Segoe UI' : null,
          color: desktopLyricEnabled ? themeColors.primary : idleColor,
        ),
      ),
      padding: EdgeInsets.zero,
      constraints: buttonConstraints,
      tooltip: context.tr('启用桌面歌词'),
    );
    final speedButton = iconButton(
      icon: Icons.speed,
      onPressed: () => SongActionSheet.showSpeedPicker(context, ref),
      tooltip: context.tr('播放速度'),
    );
    final moreButton = iconButton(
      icon: Icons.more_horiz,
      onPressed: song == null
          ? null
          : () => SongActionSheet.showPlayerMenu(context, song: song),
      tooltip: context.tr('更多'),
    );

    // 顺序固定为：收藏、下载、定时、桌面歌词（Android 为倍速）、更多。
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        favoriteButton,
        downloadButton,
        sleepTimerButton,
        if (isAndroid) speedButton else desktopLyricButton,
        moreButton,
      ],
    );
  }
}

/// 歌手名下方的「正在播放的歌词」（Android）：一行歌词 + 播放进度条。
class _InlineLyricLine extends ConsumerWidget {
  const _InlineLyricLine({required this.fontSize});

  /// 与歌手名同字号。
  final double fontSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines = ref.watch(lyricControllerProvider.select((s) => s.lines));
    final position = ref.watch(
      playbackControllerProvider.select((s) => s.position),
    );
    final duration = ref.watch(
      playbackControllerProvider.select((s) => s.duration),
    );
    final colors = ref.watch(themeColorsProvider);

    final positionMs = position.inMilliseconds;
    var index = lines.isEmpty
        ? -1
        : lines.lastIndexWhere((line) => line.startTimeMs <= positionMs);
    if (index < 0 && lines.isNotEmpty) index = 0;
    final text = index >= 0 ? lines[index].plainText.trim() : '';

    final progress = duration.inMilliseconds > 0
        ? (positionMs / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          text.isEmpty ? context.tr('暂无歌词') : text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: fontSize,
            color: Colors.white.withValues(alpha: text.isEmpty ? 0.35 : 0.7),
          ),
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(1),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 2,
            backgroundColor: Colors.white.withValues(alpha: 0.12),
            valueColor: AlwaysStoppedAnimation<Color>(colors.primary),
          ),
        ),
      ],
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
      onSeekPreview: (value) {
        ref
            .read(seekPreviewPositionProvider.notifier)
            .state = value == null || duration <= Duration.zero
            ? null
            : Duration(milliseconds: (value * duration.inMilliseconds).round());
      },
      onSeek: (value) {
        ref
            .read(playbackControllerProvider.notifier)
            .seek(
              Duration(milliseconds: (value * duration.inMilliseconds).round()),
            );
        ref.read(seekPreviewPositionProvider.notifier).state = null;
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
      // 电台模式：播放列表 / 上一首 / 循环模式由电台接管，按钮置灰不可点。
      radioMode: ref.watch(radioModeProvider),
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
                  // 只取封面色相，亮度固定压到暗色区间、饱和度封顶：
                  // 白色 / 浅色封面不会生成发白的背景，鲜艳封面也不会
                  // 留下亮黄 / 亮蓝 / 亮红 / 亮紫等刺眼色块。
                  coverDarkBackgroundColor(dominantColor, lightness: 0.17),
                  coverDarkBackgroundColor(dominantColor, lightness: 0.08),
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
