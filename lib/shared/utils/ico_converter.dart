import 'dart:io';
import 'dart:typed_data';

/// 把图标字节转换成可以直接显示的 PNG。
///
/// 很多音乐站点的 favicon 是 `.ico`（内部可能是 PNG 或 BMP），而 Flutter 的
/// 图片解码器不支持 ICO，所以插件图标在缓存到本地前先转成 PNG：
///
/// * 已经是 PNG / JPEG / WebP 等格式 → 原样返回；
/// * ICO 里嵌入的是 PNG → 直接取出那段；
/// * ICO 里嵌入的是 BMP（32bpp / 24bpp） → 自己拼一个最小的 PNG。
///
/// 转换失败返回 null（调用方退回默认图标）。
class IcoConverter {
  const IcoConverter._();

  static const int _pngSignatureLength = 8;
  static final List<int> _pngSignature = [137, 80, 78, 71, 13, 10, 26, 10];

  /// 常见位图格式原样返回（Flutter 自己就能解码）。
  static bool _isKnownImage(Uint8List bytes) {
    if (bytes.length < 12) return false;
    // PNG
    if (bytes[0] == 137 && bytes[1] == 80 && bytes[2] == 78 && bytes[3] == 71) {
      return true;
    }
    // JPEG
    if (bytes[0] == 0xFF && bytes[1] == 0xD8) return true;
    // GIF
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) return true;
    // WEBP
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true;
    }
    // BMP
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) return true;
    return false;
  }

  /// 转成 PNG 字节；无法转换返回 null。
  static Uint8List? toPng(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    if (_isKnownImage(bytes)) return bytes;
    // ICO：reserved = 0, type = 1
    if (bytes.length < 22 || bytes[0] != 0 || bytes[1] != 0) return null;
    if (bytes[2] != 1 || bytes[3] != 0) return null;
    final count = _u16(bytes, 4);
    if (count <= 0) return null;

    var bestSize = -1;
    var bestOffset = 0;
    var bestLength = 0;
    for (var i = 0; i < count; i++) {
      final entry = 6 + i * 16;
      if (entry + 16 > bytes.length) break;
      final width = bytes[entry] == 0 ? 256 : bytes[entry];
      final height = bytes[entry + 1] == 0 ? 256 : bytes[entry + 1];
      final length = _u32(bytes, entry + 8);
      final offset = _u32(bytes, entry + 12);
      if (offset + length > bytes.length) continue;
      final area = width * height;
      if (area > bestSize) {
        bestSize = area;
        bestOffset = offset;
        bestLength = length;
      }
    }
    if (bestLength <= 0) return null;

    final payload = Uint8List.sublistView(
      bytes,
      bestOffset,
      bestOffset + bestLength,
    );

    // 内嵌 PNG：直接切出来。
    if (payload.length > _pngSignatureLength && _isPng(payload)) {
      return Uint8List.fromList(payload);
    }
    return _decodeDib(payload);
  }

  static bool _isPng(Uint8List bytes) {
    for (var i = 0; i < _pngSignature.length; i++) {
      if (bytes[i] != _pngSignature[i]) return false;
    }
    return true;
  }

  /// ICO 里的 BMP 部分（没有 14 字节文件头，高度是实际高度的两倍）。
  static Uint8List? _decodeDib(Uint8List dib) {
    if (dib.length < 40) return null;
    final headerSize = _u32(dib, 0);
    if (headerSize < 40 || headerSize > dib.length) return null;
    final width = _i32(dib, 4);
    final heightDouble = _i32(dib, 8);
    final bitCount = _u16(dib, 14);
    final compression = _u32(dib, 16);
    if (width <= 0 || width > 1024) return null;
    if (heightDouble <= 0) return null;
    final height = heightDouble ~/ 2;
    if (height <= 0 || height > 1024) return null;
    // 只处理未压缩的真彩色位图（绝大多数 favicon 都是这两种）。
    if (compression != 0 && compression != 3) return null;
    if (bitCount != 32 && bitCount != 24) return null;

    final bytesPerPixel = bitCount ~/ 8;
    final rowStride = ((width * bitCount + 31) ~/ 32) * 4;
    final pixelOffset = headerSize;
    final pixelBytes = rowStride * height;
    if (pixelOffset + pixelBytes > dib.length) return null;

    final maskStride = ((width + 31) ~/ 32) * 4;
    final maskOffset = pixelOffset + pixelBytes;
    final hasMask = maskOffset + maskStride * height <= dib.length;

    final rgba = Uint8List(width * height * 4);
    var anyAlpha = false;
    for (var y = 0; y < height; y++) {
      // BMP 像素自下而上
      final srcRow = pixelOffset + (height - 1 - y) * rowStride;
      final dstRow = y * width * 4;
      for (var x = 0; x < width; x++) {
        final s = srcRow + x * bytesPerPixel;
        final d = dstRow + x * 4;
        rgba[d] = dib[s + 2]; // R
        rgba[d + 1] = dib[s + 1]; // G
        rgba[d + 2] = dib[s]; // B
        final alpha = bitCount == 32 ? dib[s + 3] : 255;
        rgba[d + 3] = alpha;
        if (alpha != 0 && alpha != 255) anyAlpha = true;
        if (alpha == 255) anyAlpha = true;
      }
    }

    // 32bpp 但整张图 alpha 全是 0：说明透明信息全在 AND mask 里。
    if (!anyAlpha && hasMask) {
      for (var y = 0; y < height; y++) {
        final maskRow = maskOffset + (height - 1 - y) * maskStride;
        final dstRow = y * width * 4;
        for (var x = 0; x < width; x++) {
          final bit = (dib[maskRow + (x >> 3)] >> (7 - (x & 7))) & 1;
          rgba[dstRow + x * 4 + 3] = bit == 1 ? 0 : 255;
        }
      }
    } else if (bitCount == 24 && hasMask) {
      // 24bpp：透明度只看 mask。
      for (var y = 0; y < height; y++) {
        final maskRow = maskOffset + (height - 1 - y) * maskStride;
        final dstRow = y * width * 4;
        for (var x = 0; x < width; x++) {
          final bit = (dib[maskRow + (x >> 3)] >> (7 - (x & 7))) & 1;
          rgba[dstRow + x * 4 + 3] = bit == 1 ? 0 : 255;
        }
      }
    }

    return _encodePng(width, height, rgba);
  }

  // ---------------------------------------------------------------- PNG 编码

  static Uint8List _encodePng(int width, int height, Uint8List rgba) {
    final raw = BytesBuilder(copy: false);
    final stride = width * 4;
    for (var y = 0; y < height; y++) {
      raw.addByte(0); // filter: none
      raw.add(Uint8List.sublistView(rgba, y * stride, (y + 1) * stride));
    }
    final idat = ZLibCodec(level: 6).encode(raw.toBytes());

    final out = BytesBuilder(copy: false);
    out.add(_pngSignature);

    final ihdr = Uint8List(13);
    _writeU32Be(ihdr, 0, width);
    _writeU32Be(ihdr, 4, height);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // RGBA
    out.add(_chunk('IHDR', ihdr));
    out.add(_chunk('IDAT', Uint8List.fromList(idat)));
    out.add(_chunk('IEND', Uint8List(0)));
    return out.toBytes();
  }

  static Uint8List _chunk(String type, Uint8List data) {
    final typeBytes = Uint8List.fromList(type.codeUnits);
    final body = BytesBuilder(copy: false)
      ..add(typeBytes)
      ..add(data);
    final bodyBytes = body.toBytes();

    final chunk = BytesBuilder(copy: false);
    final length = Uint8List(4);
    _writeU32Be(length, 0, data.length);
    chunk.add(length);
    chunk.add(bodyBytes);
    final crc = Uint8List(4);
    _writeU32Be(crc, 0, _crc32(bodyBytes));
    chunk.add(crc);
    return chunk.toBytes();
  }

  static final List<int> _crcTable = List<int>.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
    }
    return c;
  });

  static int _crc32(Uint8List data) {
    var crc = 0xFFFFFFFF;
    for (final byte in data) {
      crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  // ---------------------------------------------------------------- 字节工具

  static int _u16(Uint8List bytes, int offset) =>
      bytes[offset] | (bytes[offset + 1] << 8);

  static int _u32(Uint8List bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);

  static int _i32(Uint8List bytes, int offset) {
    final value = _u32(bytes, offset);
    return value & 0x80000000 != 0 ? value - 0x100000000 : value;
  }

  /// ICO / BMP 是小端，PNG 的块长度和 CRC 是大端。
  static void _writeU32Be(Uint8List target, int offset, int value) {
    target[offset] = (value >> 24) & 0xFF;
    target[offset + 1] = (value >> 16) & 0xFF;
    target[offset + 2] = (value >> 8) & 0xFF;
    target[offset + 3] = value & 0xFF;
  }
}
