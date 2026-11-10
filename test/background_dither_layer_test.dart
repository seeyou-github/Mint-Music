import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/shared/widgets/background_dither_layer.dart';

typedef _Rendered = ({List<int> blue, int width});

/// 渲染抖动层，返回物理像素的蓝通道值。
///
/// 逻辑尺寸要大于噪点图的 128dp，否则 `paintImage` 会把整张噪点图缩放到
/// 铺满控件，测不出平铺时每格噪点占多少物理像素。
Future<_Rendered> _renderBlue(
  WidgetTester tester, {
  required double devicePixelRatio,
  required Color background,
  double logicalSize = 200,
}) async {
  tester.view.devicePixelRatio = devicePixelRatio;
  tester.view.physicalSize = Size.square(logicalSize * devicePixelRatio);
  addTearDown(tester.view.reset);

  await tester.runAsync(BackgroundDitherLayer.loadNoise);

  final key = GlobalKey();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
        key: key,
        child: ColoredBox(
          color: background,
          child: const BackgroundDitherLayer(),
        ),
      ),
    ),
  );
  // 噪点图在真实 zone 里解码，等它的 then 回调跑完再取帧。
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pump();

  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = (await tester.runAsync(
    () => boundary.toImage(pixelRatio: devicePixelRatio),
  ))!;
  final bytes = (await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  ))!;
  final data = bytes.buffer.asUint8List();
  final width = image.width;
  final blue = <int>[];
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < width; x++) {
      blue.add(data[(y * width + x) * 4 + 2]);
    }
  }
  return (blue: blue, width: width);
}

double _transitionsPerPixel(List<int> values, int width) {
  var transitions = 0;
  for (var i = 1; i < values.length; i++) {
    if (i % width != 0 && values[i] != values[i - 1]) transitions++;
  }
  return transitions / values.length;
}

void main() {
  testWidgets('dpr 3 时噪点仍落在单个物理像素上', (tester) async {
    final rendered = await _renderBlue(
      tester,
      devicePixelRatio: 3,
      background: const Color(0xFF808080),
    );
    // 1 像素噪点：相邻像素约一半会变化；若被放大成 3×3，变化率只有约 1/3。
    expect(
      _transitionsPerPixel(rendered.blue, rendered.width),
      greaterThan(0.42),
    );
  });

  testWidgets('高亮背景上噪点仍能拉开多个色阶', (tester) async {
    final rendered = await _renderBlue(
      tester,
      devicePixelRatio: 3,
      background: const Color(0xFFF0F0F0),
    );
    final values = rendered.blue.toSet();
    // 只有白色噪点时亮背景几乎不动（240 附近只有 1 个值）；黑白各半才有多个色阶。
    expect(
      values.reduce((a, b) => a > b ? a : b) -
          values.reduce((a, b) => a < b ? a : b),
      greaterThanOrEqualTo(3),
    );
  });
}
