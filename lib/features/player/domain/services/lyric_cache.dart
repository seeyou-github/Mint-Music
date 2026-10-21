import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../../shared/services/cache_paths.dart';
import '../models/song.dart';

/// 歌词磁盘缓存。
///
/// 歌词来自网络（TTML 词库 + 在线歌词），每次播放都重新请求会明显拖慢切歌，
/// 也重复消耗流量。缓存放在「缓存目录」下（Windows 即
/// `AppData\temp\lyric_cache`），跟着缓存目录的清理策略一起被清掉。
class LyricCache {
  const LyricCache._();

  /// 缓存子目录名（同时登记到缓存管理的子目录列表里）。
  static const String folderName = 'lyric_cache';

  /// 一首歌的歌词缓存内容。
  static class Entry {
    final String? lrc;
    final String? crlyric;
    final String? tlyric;
    final String? rlyric;

    /// TTML 词库原文（缓存原文，命中后本地重新解析成逐字歌词）。
    final String? ttml;

    const Entry({
      this.lrc,
      this.crlyric,
      this.tlyric,
      this.rlyric,
      this.ttml,
    });

    /// 缓存里是否什么都没有（没有就不写文件）。
    bool get isEmpty =>
        (lrc?.isEmpty ?? true) &&
        (crlyric?.isEmpty ?? true) &&
        (tlyric?.isEmpty ?? true) &&
        (rlyric?.isEmpty ?? true) &&
        (ttml?.isEmpty ?? true);

    Map<String, dynamic> toJson() => {
          if (lrc != null) 'lrc': lrc,
          if (crlyric != null) 'crlyric': crlyric,
          if (tlyric != null) 'tlyric': tlyric,
          if (rlyric != null) 'rlyric': rlyric,
          if (ttml != null) 'ttml': ttml,
        };

    factory Entry.fromJson(Map<String, dynamic> json) {
      return Entry(
        lrc: json['lrc'] as String?,
        crlyric: json['crlyric'] as String?,
        tlyric: json['tlyric'] as String?,
        rlyric: json['rlyric'] as String?,
        ttml: json['ttml'] as String?,
      );
    }
  }

  /// 缓存键：音源 + 歌曲 id。
  ///
  /// 音源 id 里可能带 `@插件id`（插件音源），这样不同插件的歌词不会串。
  static String keyFor(Song song) => '${song.source ?? ''}_${song.id}';

  static String _fileName(String key) =>
      '${md5.convert(utf8.encode(key)).toString()}.json';

  /// 读取缓存（没有缓存或读取失败返回 null）。
  static Future<Entry?> read(Song song) async {
    try {
      final dir = await CachePaths.subDirectory(folderName);
      final file = File(p.join(dir.path, _fileName(keyFor(song))));
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final entry = Entry.fromJson(decoded.map((k, v) => MapEntry('$k', v)));
      if (entry.isEmpty) return null;
      return entry;
    } catch (e) {
      debugPrint('[LyricCache] 读取缓存失败: $e');
      return null;
    }
  }

  /// 写入缓存（内容为空时忽略）。
  static Future<void> write(
    Song song, {
    String? lrc,
    String? crlyric,
    String? tlyric,
    String? rlyric,
    String? ttml,
  }) async {
    final entry = Entry(
      lrc: lrc,
      crlyric: crlyric,
      tlyric: tlyric,
      rlyric: rlyric,
      ttml: ttml,
    );
    if (entry.isEmpty) return;
    try {
      final dir = await CachePaths.subDirectory(folderName);
      final file = File(p.join(dir.path, _fileName(keyFor(song))));
      // 先写临时文件再替换，避免中途退出留下半截的缓存文件。
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonEncode(entry.toJson()), flush: true);
      if (await file.exists()) {
        await file.delete();
      }
      await temp.rename(file.path);
    } catch (e) {
      debugPrint('[LyricCache] 写入缓存失败: $e');
    }
  }
}
