import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 「饱和度 / 明度方块 + 色相滑条」的取色区。
///
/// 与 [HsvColorPicker] 的区别：这里**没有**预览和保存 / 取消按钮，只负责
/// 「选色 → 回调」，由调用方自己的弹窗统一收尾。用于「背景渐变 → 新增颜色」
/// 这种三个色块共用一个取色区的场景：切换色块就是换 [color]。
class HsvColorArea extends StatefulWidget {
  const HsvColorArea({
    super.key,
    required this.color,
    required this.onChanged,
    this.maxSize = 260,
    this.showHue = true,
  });

  /// 当前颜色；外部换值（比如切换色块）会同步进来看不到跳变。
  final Color color;

  /// 拖动 / 点击取色区时回调新颜色。
  final ValueChanged<Color> onChanged;

  /// 方块与色相滑条的最大宽度。
  final double maxSize;

  /// 是否显示色相滑条。
  final bool showHue;

  @override
  State<HsvColorArea> createState() => _HsvColorAreaState();
}

class _HsvColorAreaState extends State<HsvColorArea> {
  double _hue = 0;
  double _saturation = 1;
  double _value = 1;

  Color get _color => HSVColor.fromAHSV(1, _hue, _saturation, _value).toColor();

  @override
  void initState() {
    super.initState();
    _syncFrom(widget.color, keepHue: false);
  }

  /// 从 [color] 同步 HSV。
  ///
  /// 纯黑 / 纯白 / 灰的色相算出来都是 0，这时保留当前色相滑条的位置，
  /// 否则一选到灰阶颜色滑条就会自己跳回红色。
  void _syncFrom(Color color, {bool keepHue = true}) {
    final hsv = HSVColor.fromColor(color);
    _saturation = hsv.saturation;
    _value = hsv.value;
    if (!keepHue || (hsv.saturation > 0 && hsv.value > 0)) {
      _hue = hsv.hue;
    }
  }

  @override
  void didUpdateWidget(covariant HsvColorArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部换了颜色（切换色块 / 回填）才同步；只是把刚报上去的值回声回来
    // 就忽略，否则拖动过程中每一帧都在重置。
    if (widget.color != oldWidget.color && widget.color != _color) {
      setState(() => _syncFrom(widget.color));
    }
  }

  void _updateSaturationValue(Offset position, double size) {
    if (size <= 0) return;
    setState(() {
      _saturation = (position.dx / size).clamp(0.0, 1.0);
      _value = 1 - (position.dy / size).clamp(0.0, 1.0);
    });
    widget.onChanged(_color);
  }

  void _updateHue(double dx, double width) {
    if (width <= 0) return;
    setState(() {
      _hue = (dx / width * 360).clamp(0.0, 360.0);
    });
    widget.onChanged(_color);
  }

  @override
  Widget build(BuildContext context) {
    final pureHue = HSVColor.fromAHSV(1, _hue, 1, 1).toColor();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 饱和度 / 明度方块
        LayoutBuilder(
          builder: (context, constraints) {
            final size = math.min(constraints.maxWidth, widget.maxSize);
            return GestureDetector(
              onPanDown: (details) =>
                  _updateSaturationValue(details.localPosition, size),
              onPanUpdate: (details) =>
                  _updateSaturationValue(details.localPosition, size),
              child: SizedBox(
                width: size,
                height: size,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          color: pureHue,
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          gradient: const LinearGradient(
                            colors: [Colors.white, Colors.transparent],
                          ),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          gradient: const LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, Colors.black],
                          ),
                        ),
                      ),
                    ),
                    // 一圈极细的高光边，把色板从深色弹窗底上勾出来。
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0x33FFFFFF)),
                          ),
                        ),
                      ),
                    ),
                    // 当前取色点
                    Positioned(
                      left: _saturation * size - 9,
                      top: (1 - _value) * size - 9,
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _color,
                          border: Border.all(color: Colors.white, width: 2),
                          boxShadow: const [
                            BoxShadow(color: Color(0x55000000), blurRadius: 4),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        if (widget.showHue) ...[
          const SizedBox(height: 14),
          // 色相滑条
          LayoutBuilder(
            builder: (context, constraints) {
              final width = math.min(constraints.maxWidth, widget.maxSize);
              return GestureDetector(
                onPanDown: (details) =>
                    _updateHue(details.localPosition.dx, width),
                onPanUpdate: (details) =>
                    _updateHue(details.localPosition.dx, width),
                child: SizedBox(
                  width: width,
                  height: 22,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(11),
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
                      ),
                      Positioned(
                        left: (_hue / 360 * width) - 9,
                        top: 2,
                        child: Container(
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: HSVColor.fromAHSV(1, _hue, 1, 1).toColor(),
                            border: Border.all(color: Colors.white, width: 2),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x55000000),
                                blurRadius: 4,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ],
    );
  }
}

/// HSV 取色面板：饱和度/明度方块 + 色相滑条 + 预览 + 保存 / 取消。
///
/// 用于「设置 - 外观设置 - 字体颜色 / 第二字体颜色」里新增自定义颜色。
class HsvColorPicker extends StatefulWidget {
  const HsvColorPicker({
    super.key,
    required this.initialColor,
    required this.onSave,
    required this.onCancel,
    this.showAlpha = false,
  });

  /// 打开时的初始颜色。
  final Color initialColor;

  /// 是否显示透明度滑条（桌面歌词阴影颜色需要带 alpha）。
  final bool showAlpha;

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
  late double _alpha;

  @override
  void initState() {
    super.initState();
    final hsv = HSVColor.fromColor(widget.initialColor);
    _hue = hsv.hue;
    _saturation = hsv.saturation;
    _value = hsv.value;
    _alpha = widget.showAlpha ? widget.initialColor.a : 1.0;
  }

  Color get _color =>
      HSVColor.fromAHSV(_alpha, _hue, _saturation, _value).toColor();

  Color get _opaqueColor =>
      HSVColor.fromAHSV(1, _hue, _saturation, _value).toColor();

  String get _hex => widget.showAlpha ? _toArgbHex(_color) : _toHex(_color);

  static String _toHex(Color color) {
    final r = (color.r * 255).round().toRadixString(16).padLeft(2, '0');
    final g = (color.g * 255).round().toRadixString(16).padLeft(2, '0');
    final b = (color.b * 255).round().toRadixString(16).padLeft(2, '0');
    return '#${r.toUpperCase()}${g.toUpperCase()}${b.toUpperCase()}';
  }

  static String _toArgbHex(Color color) {
    final a = (color.a * 255).round().toRadixString(16).padLeft(2, '0');
    return '#${a.toUpperCase()}${_toHex(color).substring(1)}';
  }

  void _updateHue(double dx, double width) {
    if (width <= 0) return;
    setState(() {
      _hue = (dx / width * 360).clamp(0.0, 360.0);
    });
  }

  void _updateSaturationValue(
    double dx,
    double dy,
    double width,
    double height,
  ) {
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
              onPanDown: (details) =>
                  _updateHue(details.localPosition.dx, width),
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
        if (widget.showAlpha) ...[
          Text(
            '透明度 ${(_alpha * 100).round()}%',
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 6),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = math.min(constraints.maxWidth, 260.0);
              return GestureDetector(
                onPanDown: (d) => setState(
                  () => _alpha = (d.localPosition.dx / math.max(width, 1.0))
                      .clamp(0.0, 1.0),
                ),
                onPanUpdate: (d) => setState(
                  () => _alpha = (d.localPosition.dx / math.max(width, 1.0))
                      .clamp(0.0, 1.0),
                ),
                child: SizedBox(
                  width: width,
                  height: 20,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          gradient: LinearGradient(
                            colors: [
                              _opaqueColor.withValues(alpha: 0),
                              _opaqueColor,
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        left: (_alpha * width) - 8,
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
        ],
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
            TextButton(onPressed: widget.onCancel, child: const Text('取消')),
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
