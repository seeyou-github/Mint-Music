import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/local/data/local_metadata_reader.dart';

/// WebM / WebA（EBML 容器）时长与标题解析的回归测试。
///
/// 不依赖真实文件：手工拼最小合法的 EBML 字节流覆盖常见封装变体
/// （Segment 已知大小 / 未知大小、Duration float64 / float32、
/// 非默认 TimecodeScale、无 Info）。
void main() {
  group('LocalMetadataReader WebM', () {
    test('.webm / .weba 被识别为音频文件', () {
      expect(LocalMetadataReader.isAudioFile('a/b/c.webm'), isTrue);
      expect(LocalMetadataReader.isAudioFile('a/b/c.weba'), isTrue);
      expect(LocalMetadataReader.isAudioFile('a/b/c.WEBM'), isTrue);
      expect(LocalMetadataReader.isAudioFile('a/b/c.webp'), isFalse);
    });

    test('未知大小 Segment + float64 时长 + 标题', () async {
      final info = _known(
        const [0x15, 0x49, 0xA9, 0x66], // Info
        _known(
              const [0x2A, 0xD7, 0xB1], // TimecodeScale
              [0x00, 0x0F, 0x42, 0x40], // 1000000 ns
            ) +
            _known(
              const [0x44, 0x89], // Duration
              _float64(3125000.0),
            ) +
            _known(
              const [0x7B, 0xA9], // Title
              utf8.encode('测试标题'),
            ),
      );
      final bytes = [
        ..._known(
          const [0x1A, 0x45, 0xDF, 0xA3], // EBML header
          [0x01, 0x01, 0x00, 0x00], // 随便一点点 payload
        ),
        ..._unknown(const [0x18, 0x53, 0x80, 0x67], info), // Segment
      ];
      final result = await _readTemp('sample.webm', bytes);
      expect(result.title, '测试标题');
      expect(result.durationMs, 3125000);
      expect(result.durationSeconds, 3125);
    });

    test('float32 时长 + 非默认 TimecodeScale', () async {
      final info = _known(
        const [0x15, 0x49, 0xA9, 0x66], // Info
        _known(
              const [0x2A, 0xD7, 0xB1], // TimecodeScale
              [0x00, 0x07, 0xA1, 0x20], // 500000 ns（0.5ms）
            ) +
            _known(
              const [0x44, 0x89], // Duration
              _float32(6000.0), // 6000 × 0.5ms = 3000ms
            ),
      );
      final bytes = [
        ..._unknown(const [0x18, 0x53, 0x80, 0x67], info), // Segment
      ];
      final result = await _readTemp('sample.weba', bytes);
      expect(result.durationMs, 3000);
      expect(result.title, isNull);
    });

    test('已知大小 Segment + 已知大小 Info', () async {
      final info = _known(
        const [0x15, 0x49, 0xA9, 0x66], // Info
        _known(
          const [0x44, 0x89], // Duration
          _float64(90000.0), // scale 默认 1ms → 90s
        ),
      );
      final bytes = [
        ..._known(
          const [0x18, 0x53, 0x80, 0x67], // Segment
          info,
        ),
      ];
      final result = await _readTemp('known.webm', bytes);
      expect(result.durationMs, 90000);
    });

    test('SeekHead 排在 Info 前面（YouTube 封装）也能找到 Info', () async {
      final info = _known(
        const [0x15, 0x49, 0xA9, 0x66], // Info
        _known(
          const [0x44, 0x89], // Duration
          _float64(120000.0),
        ),
      );
      // SeekHead：ID + 大小 + 一段含「元素 ID 字样」的 payload
      //（真实 SeekHead 的 payload 里就有 Info 的 ID 字节，不能误当成元素）。
      final seekHead = _known(
        const [0x11, 0x4D, 0x9B, 0x74], // SeekHead
        [0x15, 0x49, 0xA9, 0x66, 0x53, 0xAC, 0x88, 0x00],
      );
      final bytes = [
        ..._unknown(const [0x18, 0x53, 0x80, 0x67], seekHead + info),
      ];
      final result = await _readTemp('seekhead.webm', bytes);
      expect(result.durationMs, 120000);
    });

    test('Segment 里没有 Info（只有 Tracks）→ 空结果', () async {
      final tracks = _known(const [0x16, 0x54, 0xAE, 0x6B], [0x01, 0x02, 0x03]);
      final bytes = [
        ..._unknown(const [0x18, 0x53, 0x80, 0x67], tracks),
      ];
      final result = await _readTemp('noinfo.webm', bytes);
      expect(result.durationMs, isNull);
      expect(result.title, isNull);
    });

    test('整个文件是乱字节 → 空结果不抛异常', () async {
      final result = await _readTemp(
        'junk.webm',
        List<int>.generate(64, (i) => i * 7 % 256),
      );
      expect(result.durationMs, isNull);
    });
  });
}

/// 把字节流写进临时文件并走一遍 read()。
Future<LocalAudioMetadata> _readTemp(String name, List<int> bytes) async {
  final dir = Directory.systemTemp.createTempSync('mintmusic_webm_test');
  final file = File('${dir.path}${Platform.pathSeparator}$name')
    ..writeAsBytesSync(bytes, flush: true);
  try {
    return await LocalMetadataReader.read(file.path);
  } finally {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// 已知大小的 EBML 元素：ID + 大小 VINT + payload。
List<int> _known(List<int> id, List<int> payload) => [
  ...id,
  ..._sizeVint(payload.length),
  ...payload,
];

/// 未知大小的 EBML 元素：ID + 8 字节全 1 大小 + payload。
List<int> _unknown(List<int> id, List<int> payload) => [
  ...id,
  0x01,
  0xFF,
  0xFF,
  0xFF,
  0xFF,
  0xFF,
  0xFF,
  0xFF,
  ...payload,
];

/// 大小 VINT：尽量用最短的编码。
List<int> _sizeVint(int size) {
  if (size < 0x7F) return [0x80 | size];
  if (size < 0x3FFF) {
    return [0x40 | (size >> 8), size & 0xFF];
  }
  return [0x20 | ((size >> 16) & 0x1F), (size >> 8) & 0xFF, size & 0xFF];
}

List<int> _float64(double value) {
  final data = ByteData(8)..setFloat64(0, value, Endian.big);
  return data.buffer.asUint8List().toList();
}

List<int> _float32(double value) {
  final data = ByteData(4)..setFloat32(0, value, Endian.big);
  return data.buffer.asUint8List().toList();
}
