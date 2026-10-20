import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/l10n.dart';
import '../../settings/application/settings_providers.dart';
import '../application/desktop_lyric_controller.dart';
import '../application/desktop_lyric_sync.dart';
import '../application/lyric_controller.dart';
import '../application/playback_controller.dart';
import '../domain/models/desktop_lyric_settings.dart';
import '../domain/models/lyric_line.dart';

/// 桌面歌词的顶层宿主。
///
/// 挂在 `MaterialApp.builder` 返回的内容之上(见 `app.dart`),因此会悬浮在
/// 所有路由、弹窗之上;未启用时返回空组件,不参与命中测试。
class DesktopLyricLayer extends ConsumerWidget {
  const DesktopLyricLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(desktopLyricSettingsProvider);
    // 持有同步控制器:它负责权限、歌词加载与系统悬浮窗的渲染。
    final status = ref.watch(desktopLyricSyncProvider);
    final hasSong = ref.watch(
      playbackControllerProvider.select((s) => s.currentSong != null),
    );
    if (!settings.enable || !hasSong) return const SizedBox.shrink();
    // Windows 上歌词由独立的桌面歌词窗口渲染（应用最小化后仍显示在桌面上），
    // 应用窗口内不再重复渲染一份。
    if (Platform.isWindows) return const SizedBox.shrink();
    // 歌词已由系统悬浮窗接管,应用内不再重复渲染。
    if (status.usingNativeOverlay) return const SizedBox.shrink();

    return SizedBox.expand(
      child: Stack(children: const [DesktopLyricWindow()]),
    );
  }
}

/// 负责定位、拖动与锁定的悬浮歌词窗外壳。
///
/// 歌词内容渲染在 [DesktopLyricPanel] 中,两者分离后外壳只处理交互。
class DesktopLyricWindow extends ConsumerStatefulWidget {
  const DesktopLyricWindow({super.key});

  @override
  ConsumerState<DesktopLyricWindow> createState() =>
      _DesktopLyricWindowState();
}

class _DesktopLyricWindowState extends ConsumerState<DesktopLyricWindow> {
  /// 拖动过程中的像素位置(左上角)。未拖动时为 null,使用配置里的百分比。
  Offset? _dragPos;

  /// 当前可移动空间,拖动结束换算百分比时使用。
  double _maxX = 0;
  double _maxY = 0;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(desktopLyricSettingsProvider);
    // 用过滤后的歌词行：切歌加载期间不会显示上一首的歌词
    final lines = ref.watch(desktopLyricLinesProvider);
    final songId = ref.watch(
      lyricControllerProvider.select((s) => s.currentSongId),
    );
    final activeIndex = ref.watch(desktopLyricActiveIndexProvider);
    final showTranslation = ref.watch(lyricShowTranslationProvider);
    final showRoman = ref.watch(lyricShowRomanProvider);

    final size = MediaQuery.sizeOf(context);
    final lineHeight = settings.fontSize * 1.5;
    final barHeight = settings.isLock ? 0.0 : DesktopLyricHandle.height;
    final width = (size.width * settings.widthPercent / 100)
        .clamp(140.0, size.width)
        .toDouble();
    final contentHeight =
        lineHeight * settings.visibleLineNum +
        barHeight +
        DesktopLyricPanel.padding * 2;
    final height = contentHeight
        .clamp(36.0, math.max(36.0, size.height * 0.7))
        .toDouble();

    final maxX = math.max(0.0, size.width - width);
    final maxY = math.max(0.0, size.height - height);
    _maxX = maxX;
    _maxY = maxY;

    final baseX = (settings.positionX / 100 * maxX).clamp(0.0, maxX);
    final baseY = (settings.positionY / 100 * maxY).clamp(0.0, maxY);
    final left = (_dragPos?.dx ?? baseX).clamp(0.0, maxX);
    final top = (_dragPos?.dy ?? baseY).clamp(0.0, maxY);

    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      // 背景与歌词整体不参与命中测试,只有顶部把手可交互。
      // 否则整块面板会吞掉下层页面的点击(悬浮窗覆盖区域内页面完全点不动)。
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: Material(
                type: MaterialType.transparency,
                child: Opacity(
                  opacity: settings.opacity,
                  child: Container(
                    decoration: BoxDecoration(
                      color: settings.isLock
                          ? Colors.transparent
                          : Colors.black.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(10),
                      border: settings.isLock
                          ? null
                          : Border.all(
                              color: Colors.white.withValues(alpha: 0.22),
                            ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (!settings.isLock)
                          const SizedBox(height: DesktopLyricHandle.height),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: DesktopLyricPanel.padding,
                              vertical: 4,
                            ),
                            child: DesktopLyricPanel(
                              settings: settings,
                              lines: lines,
                              songId: songId,
                              activeIndex: activeIndex,
                              showTranslation: showTranslation,
                              showRoman: showRoman,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (!settings.isLock)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: DesktopLyricHandle.height,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (details) {
                  final current = _dragPos ?? Offset(baseX, baseY);
                  setState(() {
                    _dragPos = Offset(
                      (current.dx + details.delta.dx).clamp(0.0, _maxX),
                      (current.dy + details.delta.dy).clamp(0.0, _maxY),
                    );
                  });
                },
                onPanEnd: (_) => _commitPosition(),
                onPanCancel: _commitPosition,
                onDoubleTap: () => updateDesktopLyricSettings(
                  ref.read,
                  (s) => s.copyWith(isLock: !s.isLock),
                ),
                child: const DesktopLyricHandle(),
              ),
            ),
        ],
      ),
    );
  }

  /// 拖动结束:把像素位置换算回百分比并落盘,这样屏幕尺寸变化后位置依旧相对一致。
  void _commitPosition() {
    final pos = _dragPos;
    if (pos == null) return;
    setState(() => _dragPos = null);
    final px = _maxX <= 0 ? 0.0 : (pos.dx / _maxX * 100).clamp(0.0, 100.0);
    final py = _maxY <= 0 ? 0.0 : (pos.dy / _maxY * 100).clamp(0.0, 100.0);
    updateDesktopLyricSettings(
      ref.read,
      (s) => s.copyWith(positionX: px, positionY: py),
    );
  }
}

/// 未锁定时的顶部拖动把手。
///
/// 应用内回退方案里,只有这一条参与命中测试(歌词区保持穿透),
/// 否则整块面板会吞掉下层页面的点击。
class DesktopLyricHandle extends StatelessWidget {
  const DesktopLyricHandle({super.key});

  static const double height = 22;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Row(
        children: [
          const SizedBox(width: 8),
          Icon(
            Icons.drag_indicator,
            size: 14,
            color: Colors.white.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              context.tr('桌面歌词'),
              style: TextStyle(
                fontSize: 10,
                color: Colors.white.withValues(alpha: 0.55),
              ),
            ),
          ),
          Icon(
            Icons.lock_open,
            size: 12,
            color: Colors.white.withValues(alpha: 0.55),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

/// 桌面歌词的歌词内容(不含背景与把手)。
///
/// 纯展示组件,便于单独渲染测试。
class DesktopLyricPanel extends StatelessWidget {
  const DesktopLyricPanel({
    super.key,
    required this.settings,
    required this.lines,
    required this.activeIndex,
    this.songId,
    this.showTranslation = true,
    this.showRoman = true,
  });

  /// 歌词区域的左右内边距。
  static const double padding = 12;

  final DesktopLyricSettings settings;
  final List<LyricLine> lines;
  final int activeIndex;
  final String? songId;
  final bool showTranslation;
  final bool showRoman;

  @override
  Widget build(BuildContext context) => _buildLyricBody(context);

  Widget _buildLyricBody(BuildContext context) {
    final body = lines.isEmpty
        ? Align(
            alignment: _alignFor(settings),
            child: Text(
              context.tr('暂无歌词'),
              style: _styleFor(settings, active: false).copyWith(
                fontSize: settings.fontSize * 0.8,
              ),
            ),
          )
        : Column(
            mainAxisAlignment: settings.verticalAlignment,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.max,
            children: _buildRows(context)
                .map((row) => _buildRow(settings, row))
                .toList(),
          );

    if (!settings.showToggleAnima) return body;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.28),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: KeyedSubtree(
        key: ValueKey<String>('${songId ?? ''}#$activeIndex'),
        child: body,
      ),
    );
  }

  List<_LyricRow> _buildRows(BuildContext context) {
    var index = activeIndex < 0 ? 0 : activeIndex;
    if (index >= lines.length) index = lines.length - 1;

    final currentText = lines[index].plainText.trim();

    // 单行模式:只显示当前行。
    if (settings.isSingleLine) {
      return [
        _LyricRow(currentText.isEmpty ? context.tr('暂无歌词') : currentText),
      ];
    }

    final max = settings.visibleLineNum;
    final rows = <_LyricRow>[];

    for (var i = index; i < lines.length && rows.length < max; i++) {
      final text = lines[i].plainText.trim();
      if (text.isNotEmpty) {
        rows.add(_LyricRow(text, active: i == index));
      }
      if (i != index) continue;
      // 当前行的翻译/罗马音紧跟其后。
      if (showTranslation) {
        final translated = lines[i].translatedLyric?.trim() ?? '';
        if (translated.isNotEmpty && rows.length < max) {
          rows.add(_LyricRow(translated, active: true, isSub: true));
        }
      }
      if (showRoman) {
        final roman = lines[i].romanLyric?.trim() ?? '';
        if (roman.isNotEmpty && rows.length < max) {
          rows.add(_LyricRow(roman, active: true, isSub: true));
        }
      }
    }

    if (rows.isEmpty) rows.add(_LyricRow(context.tr('暂无歌词')));
    return rows;
  }
}

Alignment _alignFor(DesktopLyricSettings settings) {
  final x = switch (settings.textAlignX) {
    DesktopLyricTextAlignX.left => -1.0,
    DesktopLyricTextAlignX.center => 0.0,
    DesktopLyricTextAlignX.right => 1.0,
  };
  final y = switch (settings.textAlignY) {
    DesktopLyricTextAlignY.top => -1.0,
    DesktopLyricTextAlignY.center => 0.0,
    DesktopLyricTextAlignY.bottom => 1.0,
  };
  return Alignment(x, y);
}

Widget _buildRow(DesktopLyricSettings settings, _LyricRow row) {
  final style = _styleFor(settings, active: row.active, isSub: row.isSub);
  if (settings.isSingleLine) {
    return _MarqueeText(
      text: row.text,
      style: style,
      textAlign: settings.textAlign,
    );
  }
  return Text(
    row.text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    textAlign: settings.textAlign,
    style: style,
  );
}

TextStyle _styleFor(
  DesktopLyricSettings settings, {
  required bool active,
  bool isSub = false,
}) {
  final color = Color(active ? settings.playedColor : settings.unplayColor);
  return TextStyle(
    color: isSub ? color.withValues(alpha: 0.85) : color,
    fontSize: isSub ? settings.fontSize * 0.62 : settings.fontSize,
    height: 1.35,
    fontWeight: active && !isSub ? FontWeight.w700 : FontWeight.w500,
    shadows: [
      Shadow(
        color: Color(settings.shadowColor),
        blurRadius: 4,
        offset: const Offset(1, 1),
      ),
    ],
  );
}

class _LyricRow {
  final String text;
  final bool active;
  final bool isSub;

  const _LyricRow(this.text, {this.active = false, this.isSub = false});
}

/// 单行模式下文字超出宽度时横向来回滚动(对应 lx-music 的 LyricTextView)。
class _MarqueeText extends StatefulWidget {
  const _MarqueeText({
    required this.text,
    required this.style,
    required this.textAlign,
  });

  final String text;
  final TextStyle style;
  final TextAlign textAlign;

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  double _overflow = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 7),
    );
  }

  @override
  void didUpdateWidget(covariant _MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text && _controller.isAnimating) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _measure(double maxWidth) {
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: double.infinity);
    return painter.width - maxWidth;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final overflow = _measure(constraints.maxWidth);
        _overflow = overflow > 0 ? overflow : 0;
        final shouldAnimate = _overflow > 0;
        if (shouldAnimate != _controller.isAnimating) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (shouldAnimate) {
              _controller.repeat(reverse: true);
            } else {
              _controller.stop();
              _controller.value = 0;
            }
          });
        }
        return ClipRect(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) => Transform.translate(
              offset: Offset(-_controller.value * _overflow, 0),
              child: child,
            ),
            child: Text(
              widget.text,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.visible,
              textAlign: shouldAnimate ? TextAlign.left : widget.textAlign,
              style: widget.style,
            ),
          ),
        );
      },
    );
  }
}
