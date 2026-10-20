import 'dart:math' as math;

import 'package:flutter/material.dart';

/// HSV 取色面板：饱和度/明度方块 + 色相滑条 + 预览 + 保存 / 取消。
///
/// 用于「设置 - 外观设置 - 字体颜色 / 第二字体颜色」里新增自定义颜色。
class HsvColorPicker extends StatefulWidget {
  const HsvColorPicker({
    super.key,
    required this.initialColor,
    required this.onSave,
    required this.onCancel,
  });

  /// 打开时的初始颜色。
  final Color initialColor;

  /// 点击「保存」时回调选中的颜色。
  final ValueChanged<Color> onSave;

  /// 点击「取消」时回调。
  final VoidCallback onCancel;

  @override
  State<HsvColorPicker> createState() => _HsvColorPickerState();
}

class _HsvColorPickerState extends State<HsvColorPicker> {
  late double _hue;
  late double _saturation;
  late double _value;

  @override
  void initState() {
    super.initState();
    final hsv = HSVColor.fromColor(widget.initialColor);
    _hue = hsv.hue;
    _saturation = hsv.saturation;
    _value = hsv.value;
  }

  Color get _color =>
      HSVColor.fromAHSV(1, _hue, _saturation, _value).toColor();

  String get _hex => _toHex(_color);

  static String _toHex(Color color) {
    final r = (color.r * 255).round().toRadixString(16).padLeft(2, '0');
    final g = (color.g * 255).round().toRadixString(16).padLeft(2, '0');
    final b = (color.b * 255).round().toRadixString(16).padLeft(2, '0');
    return '#${r.toUpperCase()}${g.toUpperCase()}${b.toUpperCase()}';
  }

  void _updateHue(double dx, double width) {
    if (width <= 0) return;
    setState(() {
      _hue = (dx / width * 360).clamp(0.0, 360.0);
    });
  }

  void _updateSaturationValue(double dx, double dy, double width, double height) {
    if (width <= 0 || height <= 0) return;
    setState(() {
      _saturation = (dx / width).clamp(0.0, 1.0);
      _value = 1 - (dy / height).clamp(0.0, 1.0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pureHue = HSVColor.fromAHSV(1, _hue, 1, 1).toColor();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 饱和度 / 明度方块
        LayoutBuilder(
          builder: (context, constraints) {
            final size = math.min(constraints.maxWidth, 260.0);
            return GestureDetector(
              onPanDown: (details) => _updateSaturationValue(
                details.localPosition.dx,
                details.localPosition.dy,
                size,
                size,
              ),
              onPanUpdate: (details) => _updateSaturationValue(
                details.localPosition.dx,
                details.localPosition.dy,
                size,
                size,
              ),
              child: SizedBox(
                width: size,
                height: size,
                child: Stack(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: pureHue,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        gradient: const LinearGradient(
                          colors: [Colors.white, Colors.transparent],
                        ),
                      ),
                    ),
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        gradient: const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black],
                        ),
                      ),
                    ),
                    // 当前取色点
                    Positioned(
                      left: _saturation * size - 8,
                      top: (1 - _value) * size - 8,
                      child: Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                          color: _color,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 16),
        // 色相滑条
        LayoutBuilder(
          builder: (context, constraints) {
            final width = math.min(constraints.maxWidth, 260.0);
            return GestureDetector(
              onPanDown: (details) => _updateHue(details.localPosition.dx, width),
              onPanUpdate: (details) =>
                  _updateHue(details.localPosition.dx, width),
              child: SizedBox(
                width: width,
                height: 20,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        gradient: const LinearGradient(
                          colors: [
                            Colors.red,
                            Colors.yellow,
                            Colors.green,
                            Colors.cyan,
                            Colors.blue,
                            Colors.purple,
                            Colors.red,
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      left: (_hue / 360 * width) - 8,
                      top: -2,
                      child: Container(
                        width: 16,
                        height: 24,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _color,
                          border: Border.all(
                            color: theme.colorScheme.onSurface,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 16),
        // 预览 + 色值
        Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: _color,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.dividerColor, width: 1),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _hex,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: widget.onCancel,
              child: const Text('取消'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => widget.onSave(_color),
              child: const Text('保存'),
            ),
          ],
        ),
      ],
    );
  }
}
