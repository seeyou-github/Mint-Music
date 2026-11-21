import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/utils/image_downscale.dart';

Future<Uint8List> _solidPng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF336699),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('横图按长边缩到 384 并保持比例', () async {
    final source = await _solidPng(800, 450);
    final result = await downscaleImageBytes(source);
    expect(result, isNotNull);
    final image = await _decode(result!);
    expect(image.width, 384);
    expect(image.height, 216);
    image.dispose();
  });

  test('竖图同样按长边缩小', () async {
    final source = await _solidPng(400, 800);
    final result = await downscaleImageBytes(source);
    expect(result, isNotNull);
    final image = await _decode(result!);
    expect(image.width, 192);
    expect(image.height, 384);
    image.dispose();
  });

  test('本身不超过上限时返回 null，调用方保留原图', () async {
    final source = await _solidPng(320, 200);
    expect(await downscaleImageBytes(source), isNull);
  });
}
