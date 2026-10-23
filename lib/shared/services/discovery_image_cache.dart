import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'cache_paths.dart';

/// 歌单 / 榜单封面的磁盘缓存。
///
/// 这类封面只在发现页、搜索页、歌单详情等处出现，单独放在缓存目录下的
/// `image_discovery_cache`，和歌曲列表的 `image_cache` 分开，便于分别清理。
class DiscoveryImageCache {
  DiscoveryImageCache._();

  static const String directoryName = 'image_discovery_cache';

  /// 封面地址基本不会变化，缓存 30 天后重新下载。
  static const Duration stalePeriod = Duration(days: 30);

  /// 最多保留的封面数量，超出后淘汰最旧的文件。
  static const int maxFiles = 400;

  static const int _minBytes = 100;
  static int _writesSincePrune = 0;

  /// 按图片地址读取缓存；不存在、已过期或文件损坏时返回 null。
  static Future<Uint8List?> read(String url) async {
    try {
      final file = await _fileFor(url);
      if (!await file.exists()) return null;
      final modified = (await file.stat()).modified;
      if (DateTime.now().difference(modified) > stalePeriod) {
        unawaited(_deleteQuietly(file));
        return null;
      }
      final bytes = await file.readAsBytes();
      if (bytes.length < _minBytes || !_looksLikeImage(bytes)) {
        unawaited(_deleteQuietly(file));
        return null;
      }
      return bytes;
    } catch (e) {
      debugPrint('[DiscoveryImageCache] 读取封面失败: $e');
      return null;
    }
  }

  /// 写入封面缓存；失败只影响缓存，不影响页面显示。
  static Future<void> write(String url, Uint8List bytes) async {
    if (bytes.length < _minBytes || !_looksLikeImage(bytes)) return;
    try {
      final file = await _fileFor(url);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      if (await file.exists()) {
        await file.delete();
      }
      await tmp.rename(file.path);

      _writesSincePrune++;
      if (_writesSincePrune >= 20) {
        _writesSincePrune = 0;
        unawaited(_pruneIfNeeded(file.parent));
      }
    } catch (e) {
      debugPrint('[DiscoveryImageCache] 写入封面失败: $e');
    }
  }

  static Future<File> _fileFor(String url) async {
    final dir = await CachePaths.subDirectory(directoryName);
    final name = sha256.convert(utf8.encode(url)).toString();
    return File(p.join(dir.path, '$name.img'));
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      await file.delete();
    } catch (_) {}
  }

  /// 文件数超过上限时按写入时间淘汰旧文件，保留约 90%。
  static Future<void> _pruneIfNeeded(Directory dir) async {
    try {
      final entries = <({File file, DateTime modified})>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File || entity.path.endsWith('.tmp')) continue;
        try {
          entries.add((file: entity, modified: (await entity.stat()).modified));
        } catch (_) {}
      }
      if (entries.length <= maxFiles) return;
      entries.sort((a, b) => a.modified.compareTo(b.modified));
      final target = (maxFiles * 0.9).round();
      for (var i = 0; i < entries.length - target; i++) {
        await _deleteQuietly(entries[i].file);
      }
    } catch (_) {}
  }

  /// 校验图片头，避免把错误页 / HTML 当成封面缓存下来。
  static bool _looksLikeImage(Uint8List data) {
    if (data.length < 12) return false;
    // JPEG
    if (data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) return true;
    // PNG
    if (data[0] == 0x89 &&
        data[1] == 0x50 &&
        data[2] == 0x4E &&
        data[3] == 0x47) {
      return true;
    }
    // WEBP (RIFF....WEBP)
    if (data[0] == 0x52 &&
        data[1] == 0x49 &&
        data[2] == 0x46 &&
        data[3] == 0x46 &&
        data[8] == 0x57 &&
        data[9] == 0x45 &&
        data[10] == 0x42 &&
        data[11] == 0x50) {
      return true;
    }
    // GIF
    if (data[0] == 0x47 &&
        data[1] == 0x49 &&
        data[2] == 0x46 &&
        data[3] == 0x38) {
      return true;
    }
    // BMP
    if (data[0] == 0x42 && data[1] == 0x4D) return true;
    return false;
  }
}
