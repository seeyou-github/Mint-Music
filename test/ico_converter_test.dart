import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/shared/utils/ico_converter.dart';

/// 造一个最小的 1×1 32bpp ICO：ICONDIR + 一个 entry + BITMAPINFOHEADER
/// + BGRA 像素 + AND mask（一行 4 字节对齐）。
Uint8List _buildIco(int width, int height, List<int> bgra, int maskBit) {
  final headerSize = 40;
  final pixelBytes = width * height * 4;
  final maskStride = ((width + 31) ~/ 32) * 4;
  final payload = headerSize + pixelBytes + maskStride * height;

  final bytes = BytesBuilder();
  // ICONDIR
  bytes.add([0, 0, 1, 0, 1, 0]);
  // ICONDIRENTRY
  bytes.addByte(width == 256 ? 0 : width);
  bytes.addByte(height == 256 ? 0 : height);
  bytes.addByte(0);
  bytes.addByte(0);
  bytes.add([1, 0]); // planes
  bytes.add([32, 0]); // bpp
  void u32(int value) {
    bytes.add([
      value & 0xFF,
      (value >> 8) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 24) & 0xFF,
    ]);
  }

  u32(payload);
  u32(22);
  // BITMAPINFOHEADER
  u32(headerSize);
  u32(width);
  u32(height * 2);
  bytes.add([1, 0, 32, 0]);
  u32(0); // BI_RGB
  u32(pixelBytes);
  for (var i = 0; i < 16; i++) {
    bytes.addByte(0);
  }
  bytes.add(bgra);
  for (var i = 0; i < maskStride * height; i++) {
    bytes.addByte(maskBit == 0 ? 0 : 0x80);
  }
  return bytes.toBytes();
}

void main() {
  test('PNG 原样返回', () {
    final png = Uint8List.fromList([
      137,
      80,
      78,
      71,
      13,
      10,
      26,
      10,
      1,
      2,
      3,
      4,
      5,
      6,
    ]);
    expect(IcoConverter.toPng(png), same(png));
    expect(IcoConverter.toPng(Uint8List(0)), isNull);
  });

  test('BMP 内嵌的 ICO 转成 PNG', () {
    final ico = _buildIco(1, 1, [10, 20, 30, 255], 0);
    final png = IcoConverter.toPng(ico);
    expect(png, isNotNull);
    // PNG 签名
    expect(png!.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
    // IHDR：宽高 1×1，位深 8，颜色类型 6（RGBA）
    expect(png.sublist(12, 16), [73, 72, 68, 82]); // 'IHDR'
    expect(png.sublist(16, 20), [0, 0, 0, 1]); // width
    expect(png.sublist(20, 24), [0, 0, 0, 1]); // height
    expect(png[24], 8);
    expect(png[25], 6);
  });

  test('alpha 全 0 时按 AND mask 决定透明', () {
    // 像素 alpha = 0，mask 位 = 1 → 透明；这里只验证转换不失败且输出仍是 PNG。
    final ico = _buildIco(1, 1, [1, 2, 3, 0], 1);
    final png = IcoConverter.toPng(ico);
    expect(png, isNotNull);
    expect(png!.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
  });
}
