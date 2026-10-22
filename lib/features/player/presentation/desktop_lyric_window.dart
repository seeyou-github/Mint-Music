import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/l10n.dart';
import '../../settings/application/settings_providers.dart';
import '../application/desktop_lyric_controller.dart';
import '../application/desktop_lyric_sync.dart';
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
    final isPlaying = ref.watch(
      playbackControllerProvider.select((s) => s.isPlaying),
    );
    // 暂停 / 停止时隐藏桌面歌词，恢复播放后再显示。
    if (!settings.enable || !hasSong || !isPlaying) {
      return const SizedBox.shrink();
    }
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

/// 负责定位与拖动的悬浮歌词窗外壳。
///
/// 歌词内容渲染在 [DesktopLyricPanel] 中,两者分离后外壳只处理交互。
class DesktopLyricWindow extends ConsumerStatefulWidget {
  const DesktopLyricWindow({super.key});

  @override
  ConsumerState<DesktopLyricWindow> createState() => _DesktopLyricWindowState();
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
    final activeIndex = ref.watch(desktopLyricActiveIndexProvider);
    final showTranslation = ref.watch(lyricShowTranslationProvider);
    final showRoman = ref.watch(lyricShowRomanProvider);
    final fontFamily = ref.watch(lyricFontFamilyProvider).trim();
    final fontSizeRate = ref.watch(lyricFontRateProvider).clamp(0.5, 2.0);
    final fontWeight = _fontWeightFromValue(ref.watch(lyricFontWeightProvider));

    final size = MediaQuery.sizeOf(context);
    final fontSize = settings.fontSize * fontSizeRate;
    final subLineCount = (showTranslation ? 1 : 0) + (showRoman ? 1 : 0);
    final slotHeight = fontSize * 1.35 * (1 + subLineCount);
    const barHeight = DesktopLyricHandle.height;
    // 宽度固定为可用宽度（100%）。
    final width = size.width;
    final contentHeight =
        slotHeight * DesktopLyricSettings.lineCount + barHeight + 8;
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
                  opacity: DesktopLyricSettings.opacity,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.22),
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: barHeight),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: DesktopLyricPanel.padding,
                              vertical: 4,
                            ),
                            child: DesktopLyricPanel(
                              settings: settings,
                              lines: lines,
                              activeIndex: activeIndex,
                              showTranslation: showTranslation,
                              showRoman: showRoman,
                              fontFamily:
                                  fontFamily.isEmpty || fontFamily == 'system'
                                  ? null
                                  : fontFamily,
                              fontWeight: fontWeight,
                              fontSizeScale: fontSizeRate,
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
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: barHeight,
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

/// 顶部拖动把手。
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
        ],
      ),
    );
  }
}

/// 桌面歌词的歌词内容(不含背景与把手)。
///
/// 固定两个槽位：当前播放行位于 `activeIndex % 2` 对应的槽位，另一个槽位
/// 预载下一行。唱到下一行时进度直接在另一个槽位显示，两个槽位的位置不变。
class DesktopLyricPanel extends StatelessWidget {
  const DesktopLyricPanel({
    super.key,
    required this.settings,
    required this.lines,
    required this.activeIndex,
    this.showTranslation = true,
    this.showRoman = true,
    this.fontFamily,
    this.fontWeight = FontWeight.w500,
    this.fontSizeScale = 1.0,
  });

  /// 歌词区域的左右内边距。
  static const double padding = 12;

  final DesktopLyricSettings settings;
  final List<LyricLine> lines;
  final int activeIndex;
  final bool showTranslation;
  final bool showRoman;
  final String? fontFamily;
  final FontWeight fontWeight;
  final double fontSizeScale;

  @override
  Widget build(BuildContext context) {
    final slots = _buildSlots(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final slot in slots) Expanded(child: _buildSlot(slot))],
    );
  }

  List<_LyricSlot> _buildSlots(BuildContext context) {
    final slots = List<_LyricSlot>.generate(
      DesktopLyricSettings.lineCount,
      (_) => const _LyricSlot.empty(),
    );
    if (lines.isEmpty) {
      slots[0] = _LyricSlot(text: context.tr('暂无歌词'));
      return slots;
    }

    final hasActive = activeIndex >= 0 && activeIndex < lines.length;
    final base = hasActive ? activeIndex : 0;
    final activeSlot = hasActive ? activeIndex % slots.length : 0;
    for (var slot = 0; slot < slots.length; slot++) {
      final offset = (slot - activeSlot + slots.length) % slots.length;
      final index = base + offset;
      if (index >= lines.length) continue;
      final line = lines[index];
      slots[slot] = _LyricSlot(
        text: line.plainText.trim(),
        translation: showTranslation ? line.translatedLyric?.trim() ?? '' : '',
        roman: showRoman ? line.romanLyric?.trim() ?? '' : '',
        active: hasActive && index == activeIndex,
      );
    }
    return slots;
  }

  Widget _buildSlot(_LyricSlot slot) {
    final text = slot.text.trim();
    final translation = slot.translation?.trim() ?? '';
    final roman = slot.roman?.trim() ?? '';
    if (text.isEmpty && translation.isEmpty && roman.isEmpty) {
      return const SizedBox.expand();
    }
    final fontSize = settings.fontSize * fontSizeScale;
    return SizedBox.expand(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (text.isNotEmpty)
            Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: _styleFor(active: slot.active, fontSize: fontSize),
            ),
          if (translation.isNotEmpty)
            Text(
              translation,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: _styleFor(
                active: slot.active,
                isSub: true,
                fontSize: fontSize,
              ),
            ),
          if (roman.isNotEmpty)
            Text(
              roman,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: _styleFor(
                active: slot.active,
                isSub: true,
                fontSize: fontSize,
              ),
            ),
        ],
      ),
    );
  }

  TextStyle _styleFor({
    required bool active,
    bool isSub = false,
    required double fontSize,
  }) {
    final color = Color(active ? settings.playedColor : settings.unplayColor);
    return TextStyle(
      color: isSub ? color.withValues(alpha: 0.85) : color,
      fontFamily: fontFamily,
      fontSize: isSub ? fontSize * 0.62 : fontSize,
      height: 1.35,
      fontWeight: fontWeight,
      shadows: [
        Shadow(
          color: Color(settings.shadowColor),
          blurRadius: 4,
          offset: const Offset(1, 1),
        ),
      ],
    );
  }
}

FontWeight _fontWeightFromValue(int value) {
  final index = (value ~/ 100).clamp(1, 9) - 1;
  return FontWeight.values[index];
}

class _LyricSlot {
  final String text;
  final String? translation;
  final String? roman;
  final bool active;

  const _LyricSlot({
    this.text = '',
    this.translation,
    this.roman,
    this.active = false,
  });

  const _LyricSlot.empty()
    : text = '',
      translation = null,
      roman = null,
      active = false;
}
