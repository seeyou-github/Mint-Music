import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 背景抖动层：在渐变 / 光晕之上铺一层极淡的静态噪点。
///
/// 8 位色深下，大面积、低对比度的渐变叠上柔和光晕后，相邻色阶会连成一片片
/// 可见的色带（亮度越高越明显）。这层噪点把色阶边界打散，观感上恢复成平滑
/// 过渡；噪点本身太淡，正常观看看不到颗粒。
///
/// 两点决定抖动是否有效：
/// - **必须落在物理像素上**。噪点图 1 像素原本对应 1 个逻辑像素，Android 上
///   dpr 3 会把它放大成 3×3 物理像素，抖动从高频细颗粒变成低频色块，人眼低通
///   之后几乎被抹平；Windows 的 dpr 通常是 1，所以同一份代码在桌面上看起来更
///   平滑。绘制时按 dpr 反向缩放，保证 1 个噪点 = 1 个物理像素。
/// - **振幅要覆盖一个色阶**。黑白各半、各 ±4/255，亮部和暗部都能拉开 3~4 个
///   8 位色阶，才能把 1 个色阶宽的色带边界真正打散。
class BackgroundDitherLayer extends StatefulWidget {
  const BackgroundDitherLayer({super.key});

  /// 预加载噪点图。测试环境里异步解码只有在 `runAsync` 中才会真正推进，
  /// 所以测试先在这里等它完成，再挂载组件。
  @visibleForTesting
  static Future<ui.Image> loadNoise() =>
      _BackgroundDitherLayerState.loadNoise();

  @override
  State<BackgroundDitherLayer> createState() => _BackgroundDitherLayerState();
}

class _BackgroundDitherLayerState extends State<BackgroundDitherLayer> {
  /// 所有页面共用一张噪点图：只生成一次，平铺使用。
  static Future<ui.Image>? _noiseFuture;
  ui.Image? _noise;

  @override
  void initState() {
    super.initState();
    loadNoise().then((image) {
      if (mounted) setState(() => _noise = image);
    });
  }

  static Future<ui.Image> loadNoise() => _noiseFuture ??= _createNoise();

  /// 噪点强度：每个像素最多在正负方向上把亮度推 ~1.6%（4/255）。
  static const int _noiseAlpha = 4;

  static Future<ui.Image> _createNoise() {
    const size = 128;
    // 固定种子：每次启动噪点图案一致，不会闪动。
    final random = math.Random(0x5EEDBEEF);
    final pixels = Uint8List(size * size * 4);
    for (var i = 0; i < size * size; i++) {
      final offset = i * 4;
      // rgba8888 的颜色通道是预乘 alpha 的：白色噪点写 (a,a,a)，黑色写 0。
      // 黑白各半，亮部靠黑色噪点向下偏移，暗部靠白色噪点向上偏移。
      final value = random.nextBool() ? _noiseAlpha : 0;
      pixels[offset] = value;
      pixels[offset + 1] = value;
      pixels[offset + 2] = value;
      pixels[offset + 3] = _noiseAlpha;
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      size,
      size,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  @override
  Widget build(BuildContext context) {
    final noise = _noise;
    if (noise == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _DitherPainter(
            noise: noise,
            devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _DitherPainter extends CustomPainter {
  const _DitherPainter({required this.noise, required this.devicePixelRatio});

  final ui.Image noise;
  final double devicePixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    final dpr = devicePixelRatio;
    if (dpr <= 0) return;
    // 缩放后画布 1 单位 = 1 物理像素，噪点图 1 像素正好落在 1 个物理像素上。
    canvas.save();
    canvas.scale(1 / dpr);
    paintImage(
      canvas: canvas,
      rect: Rect.fromLTWH(0, 0, size.width * dpr, size.height * dpr),
      image: noise,
      repeat: ImageRepeat.repeat,
      filterQuality: FilterQuality.none,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DitherPainter oldDelegate) =>
      oldDelegate.noise != noise ||
      oldDelegate.devicePixelRatio != devicePixelRatio;
}
