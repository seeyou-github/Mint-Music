import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../../core/l10n/l10n.dart';
import '../../domain/models/lyric_line.dart';

class LyricScrollView extends StatefulWidget {
  final List<LyricLine> lines;
  final int currentTimeMs;
  final bool isPlaying;
  final bool hasYrc;
  final Color activeColor;
  final Color inactiveColor;
  final double mainFontSize;
  final double transFontSize;
  final double romanFontSize;
  final double fontSizeRate;
  final bool enableBlur;
  final bool enableScale;
  final bool showTranslation;
  final bool showRoman;
  final bool centerAlign;
  final String fontFamily;
  final int fontWeight;
  final ValueChanged<int>? onSeek;

  const LyricScrollView({
    super.key,
    required this.lines,
    required this.currentTimeMs,
    this.isPlaying = false,
    this.hasYrc = false,
    this.activeColor = Colors.white,
    this.inactiveColor = const Color(0x40FFFFFF),
    this.mainFontSize = 30,
    this.transFontSize = 16,
    this.romanFontSize = 14,
    this.fontSizeRate = 1.0,
    this.enableBlur = true,
    this.enableScale = true,
    this.showTranslation = true,
    this.showRoman = true,
    this.centerAlign = true,
    this.fontFamily = '',
    this.fontWeight = 700,
    this.onSeek,
  });

  @override
  State<LyricScrollView> createState() => _LyricScrollViewState();
}

class _LyricScrollViewState extends State<LyricScrollView>
    with SingleTickerProviderStateMixin {
  static const _userScrollTimeout = Duration(milliseconds: 3000);
  static const _autoScrollDuration = Duration(milliseconds: 300);
  static const _fadeTopStop = 0.15;
  static const _fadeBottomStop = 0.86;

  final _scrollController = ScrollController();
  final _lineKeys = <GlobalKey>[];
  final _clock = _LyricClock();
  late final Ticker _ticker;
  Timer? _userScrollTimer;

  bool _userScrolling = false;
  bool _autoScrolling = false;
  bool _pendingAutoScroll = false;
  bool _initialScrollQueued = false;
  int _scrollTargetIndex = -1;
  int _centerLineIndex = -1;
  int _linesSignature = 0;
  int _activeSignature = 0;
  int _anchorPositionMs = 0;
  int _anchorWallMs = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_handleTick);
    _ensureLineKeys();
    _linesSignature = _makeLinesSignature(widget.lines);
    _syncClock(widget.currentTimeMs, widget.isPlaying);
    _activeSignature = _makeActiveSignature(_activeIndicesFor(_clock.timeMs));
    _scrollController.addListener(_handleScroll);
    _queueInitialScroll();
  }

  @override
  void didUpdateWidget(covariant LyricScrollView oldWidget) {
    super.didUpdateWidget(oldWidget);

    final signature = _makeLinesSignature(widget.lines);
    if (signature != _linesSignature) {
      _linesSignature = signature;
      _ensureLineKeys();
      _scrollTargetIndex = -1;
      _centerLineIndex = -1;
      _syncClock(widget.currentTimeMs, widget.isPlaying);
      _activeSignature = _makeActiveSignature(_activeIndicesFor(_clock.timeMs));
      _queueInitialScroll();
      return;
    }

    if (oldWidget.currentTimeMs != widget.currentTimeMs ||
        oldWidget.isPlaying != widget.isPlaying) {
      _syncClock(widget.currentTimeMs, widget.isPlaying);
      _updateActiveLinesAndScroll();
    }
  }

  @override
  void dispose() {
    _userScrollTimer?.cancel();
    _ticker.dispose();
    _clock.dispose();
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _ensureLineKeys() {
    while (_lineKeys.length < widget.lines.length) {
      _lineKeys.add(GlobalKey());
    }
    if (_lineKeys.length > widget.lines.length) {
      _lineKeys.removeRange(widget.lines.length, _lineKeys.length);
    }
  }

  /// 进入页面时把正在播放的那一行滚到中间。
  ///
  /// 首帧之后歌词行可能还没排版好（拿不到 RenderBox），这时用估算位置会
  /// 偏掉，所以这里最多重试几帧，等真正拿到行位置再精确定位。
  void _queueInitialScroll() {
    if (_initialScrollQueued) return;
    _initialScrollQueued = true;
    _pendingAutoScroll = true;
    _initialScrollRetry = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _pendingAutoScroll = false;
        _initialScrollQueued = false;
        _scrollToActiveLine(force: true, preferJump: true);
      });
    });
  }

  /// 初始定位的重试次数（等歌词行排版完成）。
  int _initialScrollRetry = 0;

  int _makeLinesSignature(List<LyricLine> lines) {
    return Object.hashAll(
      lines.map(
        (line) => Object.hash(
          line.startTimeMs,
          line.endTimeMs,
          line.words.length,
          line.plainText,
          line.translatedLyric,
          line.romanLyric,
          line.adLibText,
        ),
      ),
    );
  }

  int _makeActiveSignature(List<int> indices) {
    return Object.hashAll(indices);
  }

  void _syncClock(int positionMs, bool isPlaying) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final drift = (positionMs - _clock.timeMs).abs();

    // 播放中外部 position 通常是低频回调；小漂移不重置内部逐帧时钟，避免逐字动画被反复拉扯。
    if (isPlaying && _ticker.isActive && drift <= 200) {
      final correction = ((positionMs - _clock.timeMs) * 0.50).round();
      _anchorPositionMs = _clock.timeMs + correction;
      _anchorWallMs = now;
    } else {
      _anchorPositionMs = positionMs;
      _anchorWallMs = now;
      _clock.setTime(positionMs);

      // 大幅位置跳跃（切歌、拖动进度条、后台切回等）→ 重置签名 & 用户滚动
      // 状态，并把正在播放的那一行立刻滚到中间。
      if (drift > 500) {
        _activeSignature = 0;
        _userScrolling = false;
        _userScrollTimer?.cancel();
        _scrollTargetIndex = -1;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _scrollToActiveLine(force: true);
        });
      }
    }

    if (isPlaying && !_ticker.isActive) {
      _ticker.start();
    } else if (!isPlaying && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _handleTick(Duration elapsed) {
    if (!widget.isPlaying) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final smoothTimeMs = _anchorPositionMs + now - _anchorWallMs;
    _clock.setTime(smoothTimeMs);
    _updateActiveLinesAndScroll(fromTicker: true);
  }

  void _updateActiveLinesAndScroll({bool fromTicker = false}) {
    final activeIndices = _activeIndicesFor(_clock.timeMs);
    final signature = _makeActiveSignature(activeIndices);
    if (signature == _activeSignature) return;

    _activeSignature = signature;
    if (!mounted) return;
    setState(() {});

    if (!_userScrolling) {
      _pendingAutoScroll = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _pendingAutoScroll = false;
        _scrollToActiveLine(force: true);
      });
    }
  }

  List<int> _activeIndicesFor(int timeMs) {
    if (widget.lines.isEmpty) return const [];

    if (widget.hasYrc) {
      final activeIndex = widget.lines.lastIndexWhere(
        (line) => line.startTimeMs <= timeMs,
      );
      if (activeIndex < 0) return [0];
      return [activeIndex];
    }

    final activeIndex = widget.lines.lastIndexWhere(
      (line) => line.startTimeMs <= timeMs,
    );
    if (activeIndex < 0) return [0];
    return [activeIndex];
  }

  int _activeScrollTargetIndex() {
    final indices = _activeIndicesFor(_clock.timeMs);
    if (indices.isEmpty) return -1;
    return indices.last;
  }

  void _handleScroll() {
    if (_autoScrolling || _pendingAutoScroll) return;

    if (!_userScrolling) {
      setState(() => _userScrolling = true);
    }

    _userScrollTimer?.cancel();
    _userScrollTimer = Timer(_userScrollTimeout, () {
      if (!mounted) return;
      setState(() {
        _userScrolling = false;
        _centerLineIndex = -1;
      });
      _scrollToActiveLine(force: true);
    });

    final index = _findCenterLineIndex();
    if (index != _centerLineIndex && mounted) {
      setState(() => _centerLineIndex = index);
    }
  }

  int _findCenterLineIndex() {
    final container = context.findRenderObject() as RenderBox?;
    if (container == null || widget.lines.isEmpty) return -1;

    final centerY = container.size.height / 2;
    var closestIndex = -1;
    var closestDistance = double.infinity;

    for (var i = 0; i < _lineKeys.length; i++) {
      final lineContext = _lineKeys[i].currentContext;
      if (lineContext == null) continue;
      final box = lineContext.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;

      final offset = box.localToGlobal(Offset.zero, ancestor: container);
      final lineCenterY = offset.dy + box.size.height / 2;
      final distance = (lineCenterY - centerY).abs();
      if (distance < closestDistance) {
        closestDistance = distance;
        closestIndex = i;
      }
    }

    return closestIndex;
  }

  void _scrollToActiveLine({bool force = false, bool preferJump = false}) {
    if (!mounted ||
        _userScrolling ||
        _autoScrolling ||
        !_scrollController.hasClients)
      return;

    final targetIndex = _activeScrollTargetIndex();
    if (targetIndex < 0 || targetIndex >= _lineKeys.length) return;
    if (!force && targetIndex == _scrollTargetIndex) return;

    final lineContext = _lineKeys[targetIndex].currentContext;
    if (lineContext == null) {
      // 歌词行还没排版好（拿不到 RenderBox）：稍后再试几帧，
      // 否则只能用估算位置，会偏掉，导致「正在播放的那一行」没在中间。
      if (_initialScrollRetry < 10) {
        _initialScrollRetry++;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _scrollToActiveLine(force: true, preferJump: preferJump);
        });
        return;
      }
      _estimateScrollToIndex(targetIndex);
      return;
    }
    _initialScrollRetry = 0;

    final lineBox = lineContext.findRenderObject() as RenderBox?;
    final scrollBox =
        _scrollController.position.context.storageContext.findRenderObject()
            as RenderBox?;
    if (lineBox == null ||
        scrollBox == null ||
        !lineBox.hasSize ||
        !scrollBox.hasSize) {
      return;
    }

    final lineOffset = lineBox.localToGlobal(Offset.zero, ancestor: scrollBox);
    final targetOffset =
        _scrollController.offset +
        lineOffset.dy -
        (scrollBox.size.height - lineBox.size.height) * 0.5;

    // 平滑滚动：按当前行内的播放进度，在「本行居中」与「下一行居中」之间
    // 做一点插值。这样正在播放的歌词会一直保持在接近垂直居中的位置，
    // 而不是每到下一句就「啪」地跳一下。
    final smoothOffset = _smoothedOffset(
      targetOffset: targetOffset,
      lineIndex: targetIndex,
      scrollBox: scrollBox,
    );

    _animateToOffset(smoothOffset, preferJumpIfFar: preferJump);
    _scrollTargetIndex = targetIndex;
  }

  /// 目标偏移的平滑插值。
  ///
  /// 当前行播放到一半时，滚动位置从「本行居中」向「下一行居中」移动一小段
  /// （最多 35%），让歌词始终接近垂直居中，同时滚动是连续的。
  double _smoothedOffset({
    required double targetOffset,
    required int lineIndex,
    required RenderBox scrollBox,
  }) {
    if (lineIndex + 1 >= widget.lines.length) return targetOffset;
    if (!widget.isPlaying) return targetOffset;

    final nextContext = _lineKeys[lineIndex + 1].currentContext;
    if (nextContext == null) return targetOffset;
    final nextBox = nextContext.findRenderObject() as RenderBox?;
    if (nextBox == null || !nextBox.hasSize) return targetOffset;

    final line = widget.lines[lineIndex];
    final durationMs = line.endTimeMs - line.startTimeMs;
    if (durationMs <= 0) return targetOffset;
    final progress =
        ((_clock.timeMs - line.startTimeMs) / durationMs).clamp(0.0, 1.0);

    final nextOffset = nextBox.localToGlobal(Offset.zero, ancestor: scrollBox);
    final nextCentered =
        _scrollController.offset +
        nextOffset.dy -
        (scrollBox.size.height - nextBox.size.height) * 0.5;
    return targetOffset + (nextCentered - targetOffset) * progress * 0.35;
  }

  void _estimateScrollToIndex(int index) {
    final estimatedLineHeight = max(
      48.0,
      widget.mainFontSize * widget.fontSizeRate * 2.4,
    );
    final viewportHeight = _scrollController.position.viewportDimension;
    final verticalPadding = viewportHeight * 0.45;
    final targetOffset = verticalPadding + index * estimatedLineHeight;
    _animateToOffset(targetOffset, preferJumpIfFar: true);
    _scrollTargetIndex = index;
  }

  void _animateToOffset(double offset, {bool preferJumpIfFar = false}) {
    final position = _scrollController.position;
    final clamped = offset.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    final distance = (clamped - position.pixels).abs();

    // 距离太远（切歌、拖动进度条、首次定位）直接跳过去，
    // 否则会出现很长的滚动动画，等歌词滚过去歌都唱完两句了。
    if (preferJumpIfFar || distance > position.viewportDimension * 0.85) {
      _autoScrolling = false;
      _scrollController.jumpTo(clamped);
      return;
    }

    // 跟随播放进度时一律用平滑动画：正在播放的歌词「滑」到中间，
    // 而不是每到一句就「啪」地跳一下。
    _autoScrolling = true;
    _scrollController
        .animateTo(
          clamped,
          duration: distance > position.viewportDimension * 0.5
              ? const Duration(milliseconds: 220)
              : _autoScrollDuration,
          curve: const _EaseInOutQuad(),
        )
        .whenComplete(() {
          if (!mounted) return;
          _autoScrolling = false;
          // 动画过程中可能又换行了，这里再校正一次位置。
          final target = _activeScrollTargetIndex();
          if (target >= 0 && target != _scrollTargetIndex) {
            _scrollToActiveLine(force: true);
          }
        });
  }

  @override
  Widget build(BuildContext context) {
    final rate = widget.fontSizeRate.clamp(0.5, 2.0);
    if (widget.lines.isEmpty) {
      return Center(
        child: Text(
          context.tr('暂无歌词'),
          style: TextStyle(
            fontSize: widget.mainFontSize * 0.6 * rate,
            color: widget.inactiveColor,
          ),
        ),
      );
    }

    final activeIndices = _activeIndicesFor(_clock.timeMs).toSet();
    final activeIndex = activeIndices.isEmpty ? -1 : activeIndices.last;
    return Stack(
      children: [
        ShaderMask(
          shaderCallback: (bounds) {
            return const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.white,
                Colors.white,
                Colors.transparent,
              ],
              stops: [0, _fadeTopStop, _fadeBottomStop, 1],
            ).createShader(bounds);
          },
          blendMode: BlendMode.dstIn,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final viewportHeight = constraints.maxHeight;
              final verticalPadding = viewportHeight * 0.45;

              return ListView.builder(
                controller: _scrollController,
                physics: const BouncingScrollPhysics(),
                cacheExtent: viewportHeight,
                addAutomaticKeepAlives: false,
                addRepaintBoundaries: true,
                padding: EdgeInsets.only(
                  top: verticalPadding,
                  bottom: viewportHeight - verticalPadding,
                ),
                itemCount: widget.lines.length,
                itemBuilder: (context, index) {
                  final isActive = activeIndices.contains(index);
                  return _LyricLineWidget(
                    key: _lineKeys[index],
                    line: widget.lines[index],
                    clock: _clock,
                    staticTimeMs: _clock.timeMs,
                    isActive: isActive,
                    activeIndex: activeIndex,
                    index: index,
                    activeColor: widget.activeColor,
                    inactiveColor: widget.inactiveColor,
                    mainFontSize: widget.mainFontSize * rate,
                    transFontSize: widget.transFontSize * rate,
                    romanFontSize: widget.romanFontSize * rate,
                    enableBlur: widget.enableBlur,
                    userScrolling: _userScrolling,
                    enableScale: widget.enableScale,
                    showTranslation: widget.showTranslation,
                    showRoman: widget.showRoman,
                    centerAlign: widget.centerAlign,
                    hasYrc: widget.hasYrc,
                    isPlaying: widget.isPlaying,
                    fontFamily: widget.fontFamily,
                    fontWeight: widget.fontWeight,
                  );
                },
              );
            },
          ),
        ),
        // 正在播放的歌词位置不再显示「时间 + 横线」与播放图标标志。
      ],
    );
  }
}

class _LyricLineWidget extends StatelessWidget {
  final LyricLine line;
  final _LyricClock clock;
  final int staticTimeMs;
  final bool isActive;
  final int activeIndex;
  final int index;
  final Color activeColor;
  final Color inactiveColor;
  final double mainFontSize;
  final double transFontSize;
  final double romanFontSize;
  final bool enableBlur;
  final bool userScrolling;
  final bool enableScale;
  final bool showTranslation;
  final bool showRoman;
  final bool centerAlign;
  final bool hasYrc;
  final bool isPlaying;
  final String fontFamily;
  final int fontWeight;

  const _LyricLineWidget({
    super.key,
    required this.line,
    required this.clock,
    required this.staticTimeMs,
    required this.isActive,
    required this.activeIndex,
    required this.index,
    required this.activeColor,
    required this.inactiveColor,
    required this.mainFontSize,
    required this.transFontSize,
    required this.romanFontSize,
    required this.enableBlur,
    required this.userScrolling,
    required this.enableScale,
    required this.showTranslation,
    required this.showRoman,
    required this.centerAlign,
    required this.hasYrc,
    required this.isPlaying,
    required this.fontFamily,
    required this.fontWeight,
  });

  /// 解析字体族字符串，返回可用于 TextStyle 的 fontFamily
  String? _resolveFontFamily() {
    if (fontFamily.isEmpty || fontFamily == 'system') return null;
    final fonts = fontFamily
        .split(',')
        .where((f) => f.isNotEmpty && f != 'system')
        .toList();
    if (fonts.isEmpty) return null;
    return fonts.first;
  }

  /// 获取 Flutter FontWeight 值
  FontWeight _resolveFontWeight() {
    final idx = ((fontWeight / 100).round() - 1).clamp(0, 8);
    return FontWeight.values[idx];
  }

  /// 这一句歌词在 [timeMs] 时已经唱了多少（0 ~ 1）。
  ///
  /// 普通 LRC 只有行级时间戳，这里用「行开始时间 → 下一行开始时间」这段
  /// 区间做线性插值，估算当前唱到了这一句的第几个字。
  double _lineProgress(int timeMs) {
    final start = line.startTimeMs;
    final end = line.endTimeMs;
    if (end <= start) return 0;
    if (timeMs <= start) return 0;
    if (timeMs >= end) return 1;
    return (timeMs - start) / (end - start);
  }

  @override
  Widget build(BuildContext context) {
    final distance = activeIndex < 0 ? 3 : (index - activeIndex).abs();
    final opacity = isActive ? 1.0 : 0.25;
    final scale = enableScale ? (isActive ? 1.05 : 0.9) : 1.0;
    final resolvedFontFamily = _resolveFontFamily();
    final crossAlign = centerAlign
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;

    Widget mainContent = _buildMainLyric();
    if (showRoman && (line.romanLyric?.isNotEmpty ?? false)) {
      mainContent = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: crossAlign,
        children: [
          mainContent,
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              line.romanLyric!,
              textAlign: centerAlign ? TextAlign.center : TextAlign.start,
              style: TextStyle(
                fontFamily: resolvedFontFamily,
                fontSize: romanFontSize,
                height: 1.3,
                fontWeight: FontWeight.w400,
                color: activeColor.withValues(alpha: isActive ? 0.5 : 0.3),
              ),
            ),
          ),
        ],
      );
    }

    final shouldBlur =
        enableBlur && !userScrolling && !isActive && distance > 0;

    Widget animatedLine = RepaintBoundary(
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutCubic,
        opacity: opacity,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 500),
          curve: const Cubic(0.25, 0.46, 0.45, 0.94),
          alignment: Alignment.center,
          scale: scale,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 13),
            child: mainContent,
          ),
        ),
      ),
    );

    final hasAdLib = line.adLibText != null && line.adLibText!.isNotEmpty;
    final hasTrans =
        showTranslation && (line.translatedLyric?.isNotEmpty ?? false);

    Widget? subLine;
    if (hasTrans && hasAdLib) {
      subLine = Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 8, left: 30, right: 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: crossAlign,
          children: [
            Text(
              line.translatedLyric!,
              textAlign: centerAlign ? TextAlign.center : TextAlign.start,
              style: TextStyle(
                fontFamily: resolvedFontFamily,
                fontSize: transFontSize,
                height: 1.35,
                fontWeight: FontWeight.w500,
                color: activeColor.withValues(alpha: 0.6),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                line.adLibText!,
                textAlign: centerAlign ? TextAlign.center : TextAlign.start,
                style: TextStyle(
                  fontFamily: resolvedFontFamily,
                  fontSize: transFontSize * 0.85,
                  height: 1.3,
                  fontWeight: FontWeight.w400,
                  color: activeColor.withValues(alpha: isActive ? 0.5 : 0.25),
                ),
              ),
            ),
          ],
        ),
      );
    } else if (hasTrans) {
      subLine = Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 8, left: 30, right: 30),
        child: Text(
          line.translatedLyric!,
          textAlign: centerAlign ? TextAlign.center : TextAlign.start,
          style: TextStyle(
            fontFamily: resolvedFontFamily,
            fontSize: transFontSize,
            height: 1.35,
            fontWeight: FontWeight.w500,
            color: activeColor.withValues(alpha: 0.6),
          ),
        ),
      );
    } else if (hasAdLib) {
      subLine = Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 8, left: 30, right: 30),
        child: Text(
          line.adLibText!,
          textAlign: centerAlign ? TextAlign.center : TextAlign.start,
          style: TextStyle(
            fontFamily: resolvedFontFamily,
            fontSize: transFontSize * 0.85,
            height: 1.3,
            fontWeight: FontWeight.w400,
            color: activeColor.withValues(alpha: isActive ? 0.5 : 0.25),
          ),
        ),
      );
    }

    if (subLine != null) {
      final combined = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: crossAlign,
        children: [animatedLine, subLine],
      );
      if (shouldBlur) {
        final sigma = min(1.2 + pow(distance, 0.7) * 1.5, 8).toDouble();
        return ClipRect(
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: combined,
          ),
        );
      }
      return combined;
    }

    if (shouldBlur) {
      final sigma = min(1.2 + pow(distance, 0.7) * 1.5, 8).toDouble();
      return ClipRect(
        child: ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: animatedLine,
        ),
      );
    }
    return animatedLine;
  }

  Widget _buildMainLyric() {
    final useWordLevel = hasYrc && line.words.isNotEmpty;
    final resolvedFontFamily = _resolveFontFamily();
    final resolvedFontWeight = _resolveFontWeight();
    if (!useWordLevel) {
      // 普通 LRC 只有「行级」时间戳，这里按播放时间估算这一句唱到哪里了，
      // 把已经唱过的部分显示成「已播放颜色」，唱到的部分保持高亮。
      Widget buildText(int timeMs) {
        final baseStyle = TextStyle(
          fontFamily: resolvedFontFamily,
          fontSize: mainFontSize,
          height: 1.32,
          fontWeight: resolvedFontWeight,
          letterSpacing: -0.25,
          color: isActive ? activeColor : inactiveColor,
        );

        final progress = isActive ? _lineProgress(timeMs) : 0.0;
        if (progress <= 0 || progress >= 1) {
          return Text(
            line.plainText,
            textAlign: centerAlign ? TextAlign.center : TextAlign.start,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: baseStyle,
          );
        }

        // 按字符数比例切分「已唱」与「未唱」两部分。
        final runes = line.plainText.runes.toList();
        if (runes.isEmpty) {
          return Text(
            line.plainText,
            textAlign: centerAlign ? TextAlign.center : TextAlign.start,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: baseStyle,
          );
        }
        final sungCount = (progress * runes.length).round().clamp(
          0,
          runes.length,
        );
        final sungText = String.fromCharCodes(runes.take(sungCount));
        final restText = String.fromCharCodes(runes.skip(sungCount));

        return Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: sungText,
                style: TextStyle(color: activeColor),
              ),
              TextSpan(
                text: restText,
                style: TextStyle(
                  color: activeColor.withValues(alpha: 0.45),
                ),
              ),
            ],
          ),
          textAlign: centerAlign ? TextAlign.center : TextAlign.start,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: baseStyle,
        );
      }

      if (isActive) {
        // 正在播放的这一行要逐帧刷新，才能看到进度一点点往前走。
        return AnimatedBuilder(
          animation: clock,
          builder: (context, _) => buildText(clock.timeMs),
        );
      }
      return buildText(staticTimeMs);
    }

    return _PaintedYrcLine(
      line: line,
      clock: isActive ? clock : null,
      staticTimeMs: staticTimeMs,
      activeColor: activeColor,
      inactiveColor: inactiveColor,
      fontSize: mainFontSize,
      isActive: isActive,
      centerAlign: centerAlign,
      fontFamily: resolvedFontFamily,
      fontWeight: resolvedFontWeight,
    );
  }
}

class _PaintedYrcLine extends StatelessWidget {
  final LyricLine line;
  final _LyricClock? clock;
  final int staticTimeMs;
  final Color activeColor;
  final Color inactiveColor;
  final double fontSize;
  final bool isActive;
  final bool centerAlign;
  final String? fontFamily;
  final FontWeight fontWeight;

  const _PaintedYrcLine({
    required this.line,
    required this.clock,
    required this.staticTimeMs,
    required this.activeColor,
    required this.inactiveColor,
    required this.fontSize,
    required this.isActive,
    required this.centerAlign,
    required this.fontFamily,
    required this.fontWeight,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.of(context).size.width - 60;
        final layout = _YrcLineLayout.cached(
          line: line,
          maxWidth: maxWidth,
          fontSize: fontSize,
          activeColor: activeColor,
          inactiveColor: inactiveColor,
          isActive: isActive,
          centerAlign: centerAlign,
          fontFamily: fontFamily,
          fontWeight: fontWeight,
        );

        return RepaintBoundary(
          child: CustomPaint(
            size: Size(maxWidth, layout.height),
            painter: _YrcLinePainter(
              layout: layout,
              line: line,
              clock: clock,
              staticTimeMs: staticTimeMs,
              isActive: isActive,
              repaint: clock,
            ),
          ),
        );
      },
    );
  }
}

class _YrcLinePainter extends CustomPainter {
  static const _dimAlpha = 0.3;

  final _YrcLineLayout layout;
  final LyricLine line;
  final _LyricClock? clock;
  final int staticTimeMs;
  final bool isActive;

  _YrcLinePainter({
    required this.layout,
    required this.line,
    required this.clock,
    required this.staticTimeMs,
    required this.isActive,
    super.repaint,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final currentTimeMs = clock?.timeMs ?? staticTimeMs;

    for (final word in layout.words) {
      final duration = max(1, word.source.endTimeMs - word.source.startTimeMs);
      final progress = ((currentTimeMs - word.source.startTimeMs) / duration)
          .clamp(0.0, 1.0);
      final hasStarted = currentTimeMs >= word.source.startTimeMs;
      final isRunning =
          hasStarted && currentTimeMs < word.source.endTimeMs && isActive;
      final transform = _wordTransform(
        durationMs: duration,
        elapsedMs: currentTimeMs - word.source.startTimeMs,
        completedElapsedMs: currentTimeMs - word.source.endTimeMs,
        isRunning: isRunning,
        hasStarted: hasStarted,
      );

      canvas.save();
      canvas.translate(
        word.offset.dx + word.width / 2,
        word.offset.dy + transform.translateY + word.height / 2,
      );
      canvas.scale(transform.scale, transform.scale);
      canvas.translate(-word.width / 2, -word.height / 2);

      word.dimPainter.paint(canvas, Offset.zero);

      if (isActive) {
        final brightAlpha = hasStarted ? 1.0 : _dimAlpha;
        if (brightAlpha > _dimAlpha && progress > 0) {
          final clipWidth = word.width * progress;
          canvas.save();
          canvas.clipRect(
            Rect.fromLTWH(0, -fontPadding(word), clipWidth, word.height * 2),
          );
          word.brightPainter.paint(canvas, Offset.zero);
          canvas.restore();
        }
      } else if (currentTimeMs >= word.source.endTimeMs) {
        canvas.save();
        canvas.clipRect(Rect.fromLTWH(0, 0, word.width, word.height));
        word.finishedPainter.paint(canvas, Offset.zero);
        canvas.restore();
      }

      canvas.restore();
    }
  }

  double fontPadding(_WordPaintData word) => max(4, word.height * 0.25);

  _WordTransform _wordTransform({
    required int durationMs,
    required int elapsedMs,
    required int completedElapsedMs,
    required bool isRunning,
    required bool hasStarted,
  }) {
    if (!isActive) {
      return const _WordTransform(scale: 1, translateY: 0);
    }

    final clampedDuration = max(100, min(durationMs, 800));
    final factor = (clampedDuration - 100) / 700;
    final maxTranslateEm = factor * 0.01;
    final maxScale = 1.02 + factor * 0.13;
    final initialTranslate = layout.fontSize * 0.16;

    if (!hasStarted) {
      return _WordTransform(scale: 1, translateY: initialTranslate);
    }

    if (isRunning) {
      final riseDuration = max(durationMs * 0.8, 1100).toDouble();
      final t = Curves.easeOut.transform(
        (elapsedMs / riseDuration).clamp(0.0, 1.0),
      );
      return _WordTransform(
        scale: ui.lerpDouble(1, maxScale, t)!,
        translateY: ui.lerpDouble(
          initialTranslate,
          -layout.fontSize * maxTranslateEm,
          t,
        )!,
      );
    }

    final t = const Cubic(
      0.34,
      1.3,
      0.64,
      1,
    ).transform((completedElapsedMs / 2000).clamp(0.0, 1.0));
    return _WordTransform(
      scale: ui.lerpDouble(maxScale, 1, t)!,
      translateY: ui.lerpDouble(-layout.fontSize * maxTranslateEm, 0, t)!,
    );
  }

  @override
  bool shouldRepaint(covariant _YrcLinePainter oldDelegate) {
    return oldDelegate.layout != layout ||
        oldDelegate.line != line ||
        oldDelegate.staticTimeMs != staticTimeMs ||
        oldDelegate.isActive != isActive;
  }
}

class _YrcLineLayout {
  static final Map<int, _YrcLineLayout> _cache = {};
  static const _maxCacheEntries = 240;

  final double width;
  final double height;
  final double fontSize;
  final List<_WordPaintData> words;

  const _YrcLineLayout({
    required this.width,
    required this.height,
    required this.fontSize,
    required this.words,
  });

  static _YrcLineLayout cached({
    required LyricLine line,
    required double maxWidth,
    required double fontSize,
    required Color activeColor,
    required Color inactiveColor,
    required bool isActive,
    required bool centerAlign,
    required String? fontFamily,
    required FontWeight fontWeight,
  }) {
    final key = Object.hash(
      line.startTimeMs,
      line.endTimeMs,
      line.plainText,
      Object.hashAll(
        line.words.map(
          (word) => Object.hash(word.word, word.startTimeMs, word.endTimeMs),
        ),
      ),
      maxWidth.round(),
      (fontSize * 100).round(),
      activeColor.toARGB32(),
      inactiveColor.toARGB32(),
      isActive,
      centerAlign,
      fontFamily ?? '',
      fontWeight.value,
    );
    final cached = _cache[key];
    if (cached != null) return cached;

    final layout = build(
      line: line,
      maxWidth: maxWidth,
      fontSize: fontSize,
      activeColor: activeColor,
      inactiveColor: inactiveColor,
      isActive: isActive,
      centerAlign: centerAlign,
      fontFamily: fontFamily,
      fontWeight: fontWeight,
    );
    if (_cache.length >= _maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = layout;
    return layout;
  }

  static _YrcLineLayout build({
    required LyricLine line,
    required double maxWidth,
    required double fontSize,
    required Color activeColor,
    required Color inactiveColor,
    required bool isActive,
    required bool centerAlign,
    required String? fontFamily,
    required FontWeight fontWeight,
  }) {
    final textStyle = TextStyle(
      fontFamily: fontFamily,
      fontSize: fontSize,
      height: 1.32,
      fontWeight: fontWeight,
      letterSpacing: -0.25,
    );
    final dimColor = isActive
        ? activeColor.withValues(alpha: 0.3)
        : inactiveColor.withValues(alpha: 0.85);
    final finishedColor = activeColor.withValues(alpha: isActive ? 1 : 0.5);

    final spaceFull = _spacePainter(textStyle).width;

    // build paint data & gap widths
    final paintWords = <_WordPaintData>[];
    final gaps = <double>[]; // gaps[i] = gap before paintWords[i+1]
    for (int si = 0; si < line.words.length; si++) {
      final source = line.words[si];
      if (source.word.isEmpty) continue;
      final raw = source.word;
      final hasTrail = raw.endsWith(' ');
      final displayText = hasTrail ? raw.substring(0, raw.length - 1) : raw;
      paintWords.add(
        _WordPaintData(
          source: source,
          dimPainter: _buildPainter(displayText, textStyle, dimColor),
          brightPainter: _buildPainter(displayText, textStyle, activeColor),
          finishedPainter: _buildPainter(displayText, textStyle, finishedColor),
          activeColor: activeColor,
        ),
      );
      if (si < line.words.length - 1) {
        final nextRaw = line.words[si + 1].word;
        final nextClean = nextRaw.endsWith(' ')
            ? nextRaw.substring(0, nextRaw.length - 1)
            : nextRaw;

        final hasCjk =
            displayText.codeUnits.any((cu) => cu >= 0x4E00 && cu <= 0x9FFF) &&
            nextClean.codeUnits.any((cu) => cu >= 0x4E00 && cu <= 0x9FFF);

        if (hasCjk) {
          gaps.add(0);
        } else if (hasTrail) {
          gaps.add(spaceFull * 0.75);
        } else {
          gaps.add(0);
        }
      }
    }

    final rows = <List<_WordPaintData>>[];
    var currentRow = <_WordPaintData>[];
    var currentRowWidth = 0.0;

    for (int wi = 0; wi < paintWords.length; wi++) {
      final word = paintWords[wi];
      final gap = (currentRow.isNotEmpty && wi - 1 < gaps.length)
          ? gaps[wi - 1]
          : 0;
      final nextWidth = currentRowWidth + gap + word.width;

      if (currentRow.isNotEmpty && nextWidth > maxWidth) {
        rows.add(currentRow);
        currentRow = <_WordPaintData>[];
        currentRowWidth = 0;
      }

      if (currentRow.isNotEmpty && wi - 1 < gaps.length)
        currentRowWidth += gaps[wi - 1];
      currentRow.add(word);
      currentRowWidth += word.width;
    }
    if (currentRow.isNotEmpty) rows.add(currentRow);

    final positioned = <_WordPaintData>[];
    var y = 0.0;
    for (final row in rows) {
      final rowGaps = <double>[];
      for (int ri = 0; ri + 1 < row.length; ri++) {
        final gi = paintWords.indexOf(row[ri]);
        if (gi >= 0 && gi < gaps.length) rowGaps.add(gaps[gi]);
      }
      final totalSpace = rowGaps.fold<double>(0, (s, g) => s + g);
      final rowWidth = row.fold<double>(0, (s, w) => s + w.width) + totalSpace;
      final rowHeight = row.fold<double>(0, (h, w) => max(h, w.height));
      var x = centerAlign ? max(0.0, (maxWidth - rowWidth) / 2) : 0.0;
      for (int ri = 0; ri < row.length; ri++) {
        positioned.add(row[ri].copyWith(offset: Offset(x, y)));
        x += row[ri].width;
        if (ri < rowGaps.length) x += rowGaps[ri];
      }
      y += rowHeight;
    }

    return _YrcLineLayout(
      width: maxWidth,
      height: max(y, fontSize * 1.32),
      fontSize: fontSize,
      words: positioned,
    );
  }

  static TextPainter _spacePainter(TextStyle baseStyle) {
    final painter = TextPainter(
      text: TextSpan(text: ' ', style: baseStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    return painter;
  }

  static TextPainter _buildPainter(
    String text,
    TextStyle baseStyle,
    Color color,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: baseStyle.copyWith(color: color),
      ),
      textAlign: TextAlign.left,
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return painter;
  }
}

class _WordPaintData {
  final LyricWord source;
  final TextPainter dimPainter;
  final TextPainter brightPainter;
  final TextPainter finishedPainter;
  final Color activeColor;
  final Offset offset;

  const _WordPaintData({
    required this.source,
    required this.dimPainter,
    required this.brightPainter,
    required this.finishedPainter,
    required this.activeColor,
    this.offset = Offset.zero,
  });

  double get width => dimPainter.width;

  double get height => dimPainter.height;

  _WordPaintData copyWith({Offset? offset}) {
    return _WordPaintData(
      source: source,
      dimPainter: dimPainter,
      brightPainter: brightPainter,
      finishedPainter: finishedPainter,
      activeColor: activeColor,
      offset: offset ?? this.offset,
    );
  }
}

class _WordTransform {
  final double scale;
  final double translateY;

  const _WordTransform({required this.scale, required this.translateY});
}

class _LyricClock extends ChangeNotifier {
  int _timeMs = 0;

  int get timeMs => _timeMs;

  void setTime(int value) {
    if (value == _timeMs) return;
    _timeMs = value;
    notifyListeners();
  }
}

class _EaseInOutQuad extends Curve {
  const _EaseInOutQuad();

  @override
  double transformInternal(double t) {
    return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2;
  }
}
