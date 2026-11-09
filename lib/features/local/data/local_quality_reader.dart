import 'dart:io';

import 'package:flutter/foundation.dart';

import 'local_metadata_reader.dart';

/// 本地文件的真实音质标签（播放页展示用）。
///
/// 有损格式读文件的真实码率（如 `54K`、`128K`、`320K`）；无损及以上不显示
/// 码率，只给等级（`Flac` / `Flac24bit` / `HiRes`）。读不出来时返回 null，
/// 界面退回原来的音质名称。
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

      if (ext == '.mp3') {
        return _formatKbps(await LocalMetadataReader.readMp3Bitrate(filePath));
      }

      // 其余有损格式（m4a/aac/ogg/wma…）没有现成的码率字段，用
      // 「文件大小 × 8 / 时长」算平均码率：标签占用相对整首可以忽略。
      final length = await file.length();
      final metadata = await LocalMetadataReader.read(filePath);
      final duration = metadata.durationSeconds ?? 0;
      if (length <= 0 || duration <= 0) return null;
      return _formatKbps((length * 8 / duration / 1000).round());
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
}
