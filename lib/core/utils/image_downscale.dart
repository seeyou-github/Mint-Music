import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// 把图片长边缩到 [maxSide] 并重编码成 PNG；本身已经够小则返回 null。
///
/// 高斯模糊背景最终只剩大色块，4K 原图的细节完全被抹平，却要付出每次
/// 启动几十 MB 的解码内存。导入时用 SDK 解码 / 缩放 / 重编码一次，运行期
/// 直接读几百像素的小图即可。
Future<Uint8List?> downscaleImageBytes(
  Uint8List bytes, {
  int maxSide = 384,
}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (math.max(descriptor.width, descriptor.height) <= maxSide) return null;
    final landscape = descriptor.width >= descriptor.height;
    // 只给长边，另一边由解码器按比例算，避免把竖图压扁。
    codec = await descriptor.instantiateCodec(
      targetWidth: landscape ? maxSide : null,
      targetHeight: landscape ? null : maxSide,
    );
    final frame = await codec.getNextFrame();
    image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return null;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}
