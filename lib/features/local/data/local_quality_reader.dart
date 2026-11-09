import 'dart:io';

import 'package:flutter/foundation.dart';

import 'local_metadata_reader.dart';

/// 本地文件的真实音质标签（播放页展示用）。
///
/// 有损格式不解析帧头码率表：直接读文件属性——容器里记录的时长 + 音频
/// 字节数（m4a/aac/ogg…），或 ASF 头里声明的码率（wma）——算平均码率，
/// 如 `128K`、`221K`、`320K`。无损及以上不显示码率，只给等级
/// （`Flac` / `Flac24bit` / `HiRes`）。读不出来时返回 null，界面退回
/// 原来的音质名称。
class LocalQualityReader {
  LocalQualityReader._();

  /// 无损、不显示码率的扩展名。
  static const Set<String> _losslessExtensions = {
    '.wav',
    '.ape',
    '.dsd',
    '.dff',
    '.dsf',
  };

  static Future<String?> readLabel(String filePath) async {
    try {
      final ext = LocalMetadataReader.extensionOf(filePath);
      final file = File(filePath);
      if (!await file.exists()) return null;

      if (ext == '.flac') return await _flacLabel(file);
      if (_losslessExtensions.contains(ext)) return 'HiRes';
      if (ext == '.wma') return await _wmaLabel(file);

      final isMp4 = ext == '.m4a' || ext == '.mp4';
      var audioBytes = 0;
      if (isMp4) {
        final info = await _mp4Info(file);
        // M4A 里装 ALAC / FLAC 属于无损：只显示等级。
        if (info.isLossless) return 'HiRes';
        audioBytes = info.audioBytes;
      }
      if (audioBytes <= 0) {
        final length = await file.length();
        audioBytes = ext == '.mp3' ? await _mp3AudioBytes(file, length) : length;
      }
      if (audioBytes <= 0) return null;

      final metadata = await LocalMetadataReader.read(filePath);
      final durationMs =
          metadata.durationMs ?? (metadata.durationSeconds ?? 0) * 1000;
      if (durationMs <= 0) return null;
      // bits / ms = kbps
      return _formatKbps((audioBytes * 8 / durationMs).round());
    } catch (e) {
      debugPrint('[LocalQuality] 读取音质失败 $filePath: $e');
      return null;
    }
  }

  static String? _formatKbps(int? kbps) {
    if (kbps == null || kbps <= 0) return null;
    return '${kbps}K';
  }

  /// FLAC 按 STREAMINFO 里的位深 / 采样率分级：16bit → Flac，
  /// 24bit（≤192kHz）→ Flac24bit，再高 → HiRes。
  static Future<String?> _flacLabel(File file) async {
    final raf = await file.open(mode: FileMode.read);
    try {
      await raf.setPosition(0);
      final magic = await raf.read(4);
      if (magic.length < 4 ||
          magic[0] != 0x66 ||
          magic[1] != 0x4C ||
          magic[2] != 0x61 ||
          magic[3] != 0x43) {
        return null;
      }
      final blockHeader = await raf.read(4);
      if (blockHeader.length < 4 || (blockHeader[0] & 0x7F) != 0) return null;
      final info = await raf.read(18);
      if (info.length < 18) return null;
      final sampleRate = (info[10] << 12) | (info[11] << 4) | (info[12] >> 4);
      final bits = (((info[12] & 0x01) << 4) | ((info[13] & 0xF0) >> 4)) + 1;
      if (bits <= 16) return 'Flac';
      if (bits <= 24 && sampleRate <= 192000) return 'Flac24bit';
      return 'HiRes';
    } finally {
      await raf.close();
    }
  }

  /// MP3 音频数据字节数：去掉开头的 ID3v2 / 结尾的 ID3v1 标签，
  /// 否则内嵌封面会把平均码率算高。
  static Future<int> _mp3AudioBytes(File file, int length) async {
    final raf = await file.open(mode: FileMode.read);
    try {
      await raf.setPosition(0);
      final header = await raf.read(10);
      var start = 0;
      if (header.length == 10 &&
          header[0] == 0x49 &&
          header[1] == 0x44 &&
          header[2] == 0x33) {
        start = 10 + _synchSafe(header, 6);
        if ((header[5] & 0x10) != 0) start += 10;
      }
      var end = length;
      if (end - start >= 128) {
        await raf.setPosition(end - 128);
        final tag = await raf.read(3);
        if (tag.length == 3 &&
            tag[0] == 0x54 &&
            tag[1] == 0x41 &&
            tag[2] == 0x47) {
          end -= 128;
        }
      }
      return end > start ? end - start : 0;
    } finally {
      await raf.close();
    }
  }

  /// 扫描 MP4/M4A 顶层原子：mdat 就是音频数据；moov 里出现 `alac`/`fLaC`
  /// 说明装的是 ALAC / FLAC 无损。
  static Future<({int audioBytes, bool isLossless})> _mp4Info(
    File file,
  ) async {
    final raf = await file.open(mode: FileMode.read);
    try {
      final length = await raf.length();
      var offset = 0;
      var audioBytes = 0;
      var isLossless = false;
      while (offset + 8 <= length) {
        await raf.setPosition(offset);
        final header = await raf.read(8);
        if (header.length < 8) break;
        var size = _be32(header, 0);
        final type = String.fromCharCodes(header.sublist(4, 8));
        var headerSize = 8;
        if (size == 1) {
          final ext = await raf.read(8);
          if (ext.length < 8) break;
          size = _be64(ext, 0);
          headerSize = 16;
        } else if (size == 0) {
          size = length - offset;
        }
        if (size < headerSize) break;
        if (type == 'mdat') {
          audioBytes += size - headerSize;
        } else if (type == 'moov') {
          final moov = await raf.read(size - headerSize);
          isLossless =
              _containsFourcc(moov, 'alac') || _containsFourcc(moov, 'fLaC');
        }
        offset += size;
      }
      return (audioBytes: audioBytes, isLossless: isLossless);
    } finally {
      await raf.close();
    }
  }

  /// WMA（ASF）在 File Properties 对象里直接声明了 MaxBitrate，
  /// 不需要再算时长。
  static Future<String?> _wmaLabel(File file) async {
    final raf = await file.open(mode: FileMode.read);
    try {
      final head = await raf.read(8192);
      if (head.length < 30 || !_matches(head, 0, _asfHeaderGuid)) return null;
      var pos = 30;
      while (pos + 24 <= head.length) {
        final size = _le64(head, pos + 16);
        if (size < 24) break;
        if (_matches(head, pos, _asfFilePropsGuid)) {
          final bitrateOffset = pos + 24 + 76;
          if (bitrateOffset + 4 > head.length) return null;
          return _formatKbps((_le32(head, bitrateOffset) / 1000).round());
        }
        if (size > head.length) break;
        pos += size;
      }
      return null;
    } finally {
      await raf.close();
    }
  }

  static const List<int> _asfHeaderGuid = [
    0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, //
    0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C,
  ];

  static const List<int> _asfFilePropsGuid = [
    0xA1, 0xDC, 0xAB, 0x8C, 0x47, 0xA9, 0xCF, 0x11, //
    0x8E, 0xE4, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65,
  ];

  static bool _matches(Uint8List data, int offset, List<int> pattern) {
    if (offset + pattern.length > data.length) return false;
    for (var i = 0; i < pattern.length; i++) {
      if (data[offset + i] != pattern[i]) return false;
    }
    return true;
  }

  static bool _containsFourcc(Uint8List data, String fourcc) {
    final a = fourcc.codeUnitAt(0);
    final b = fourcc.codeUnitAt(1);
    final c = fourcc.codeUnitAt(2);
    final d = fourcc.codeUnitAt(3);
    for (var i = 0; i + 4 <= data.length; i++) {
      if (data[i] == a &&
          data[i + 1] == b &&
          data[i + 2] == c &&
          data[i + 3] == d) {
        return true;
      }
    }
    return false;
  }

  static int _synchSafe(Uint8List bytes, int offset) =>
      ((bytes[offset] & 0x7F) << 21) |
      ((bytes[offset + 1] & 0x7F) << 14) |
      ((bytes[offset + 2] & 0x7F) << 7) |
      (bytes[offset + 3] & 0x7F);

  static int _be32(Uint8List bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  static int _be64(Uint8List bytes, int offset) =>
      (_be32(bytes, offset) << 32) | _be32(bytes, offset + 4);

  static int _le32(Uint8List bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);

  static int _le64(Uint8List bytes, int offset) =>
      _le32(bytes, offset) | (_le32(bytes, offset + 4) << 32);
}
