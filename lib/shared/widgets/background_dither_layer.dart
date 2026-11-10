import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 背景抖动层：在渐变 / 光晕之上铺一层极淡的静态噪点。
///
/// 8 位色深下，大面积、低对比度的渐变叠上柔和光晕后，相邻色阶会连成一片片
/// 可见的色带（亮度越高越明显）。这层 ±2 个色阶的噪点把色阶边界打散，观感上
/// 恢复成平滑过渡；噪点本身太淡，正常观看看不到颗粒。
class BackgroundDitherLayer extends StatefulWidget {
  const BackgroundDitherLayer({super.key});

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
    final future = _noiseFuture ??= _createNoise();
    future.then((image) {
      if (mounted) setState(() => _noise = image);
    });
  }

  static Future<ui.Image> _createNoise() {
    const size = 128;
    // 固定种子：每次启动噪点图案一致，不会闪动。
    final random = math.Random(0x5EEDBEEF);
    final pixels = Uint8List(size * size * 4);
    for (var i = 0; i < size * size; i++) {
      final offset = i * 4;
      // rgba8888 的颜色通道是预乘 alpha 的：白色噪点写 (a,a,a)，黑色写 0。
      final value = random.nextBool() ? 3 : 0;
      pixels[offset] = value;
      pixels[offset + 1] = value;
      pixels[offset + 2] = value;
      pixels[offset + 3] = 3;
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
          painter: _DitherPainter(noise),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _DitherPainter extends CustomPainter {
  const _DitherPainter(this.noise);

  final ui.Image noise;

  @override
  void paint(Canvas canvas, Size size) {
    paintImage(
      canvas: canvas,
      rect: Offset.zero & size,
      image: noise,
      repeat: ImageRepeat.repeat,
      filterQuality: FilterQuality.none,
    );
  }

  @override
  bool shouldRepaint(_DitherPainter oldDelegate) => oldDelegate.noise != noise;
}
