import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../../core/platform/app_paths.dart';
import '../../../core/storage/app_database.dart';
import '../../../shared/services/cache_paths.dart';
import '../../player/domain/models/song.dart';

/// 缓存索引的一条记录（对应 `temp\db` 里的 `audio_cache_entries`）。
class AudioCacheEntry {
  const AudioCacheEntry({
    required this.songId,
    required this.fileName,
    required this.quality,
    required this.bytes,
    required this.cachedAt,
    required this.lastUsedAt,
  });

  final String songId;
  final String fileName;
  final String quality;
  final int bytes;
  final int cachedAt;
  final int lastUsedAt;
}

/// 「我的收藏 / 自建歌单」歌曲的离线音频缓存。
///
/// 设计要点：
///
/// * **目录**：`AppData\temp\audio_cache`（Windows 与 Android 一致，见
///   [AppPaths.tempDirectory]）。缓存位置全局固定，不提供设置项；
/// * **索引**：`AppDatabase.cacheDatabase()`（`AppData\temp\db`）里的
///   `audio_cache_entries` 表，只记「哪首歌 → 哪个文件」，音频本体在目录里；
/// * **上限**：最多 [maxEntries] 首，超出后按 `last_used_at` 升序删掉最久
///   没有听过的（命中缓存播放时会刷新这个时间）；
/// * 播放页在解析在线地址之前先查这里，命中直接播本地文件，省流量也更快。
///
/// 写入是「先下到 `.part` 再改名」，中途失败不会留下半截文件被当成缓存。
class SongAudioCache {
  SongAudioCache._();

  /// 最多缓存多少首。超出后淘汰「最久没有听过」的那些。
  static const int maxEntries = 200;

  /// 缓存子目录名：固定放在数据目录的 `temp\audio_cache`
  /// （Windows / Android 都是 `AppData\temp\audio_cache`）。
  static const String directoryName = CachePaths.audioCache;

  static const String _table = 'audio_cache_entries';

  /// 下载超时：缓存是后台行为，卡住不如放弃，下次听完再试。
  static const Duration _connectTimeout = Duration(seconds: 15);
  static const Duration _receiveTimeout = Duration(seconds: 60);

  /// 同一首歌的写入去重：播完回调与手动操作可能同时触发。
  static final Map<String, Future<bool>> _pending = {};

  /// 仅测试使用：替换真实网络下载（默认用 Dio）。
  ///
  /// 返回 true 表示已经把内容写到 [savePath]。正式运行时始终为 null。
  static Future<bool> Function(
    String url,
    String savePath,
    Map<String, String>? headers,
  )?
  debugDownloader;

  /// 缓存目录（自动创建）：固定为 `AppData\temp\audio_cache`。
  ///
  /// 显式取 `AppPaths.tempDirectory()`，不经过 [CachePaths]：离线音频缓存
  /// 要的是「数据目录下的 temp」，这样即使以后封面缓存换位置也不会跟着跑。
  static Future<Directory> directory() async {
    final base = await AppPaths.tempDirectory();
    final dir = Directory(p.join(base.path, directoryName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 当前缓存里的全部记录（最近使用在前）。
  static Future<List<AudioCacheEntry>> entries() async {
    try {
      final db = await AppDatabase.cacheDatabase();
      final rows = await db.query(_table, orderBy: 'last_used_at DESC');
      return [
        for (final row in rows)
          AudioCacheEntry(
            songId: (row['song_id'] as String?) ?? '',
            fileName: (row['file_name'] as String?) ?? '',
            quality: (row['quality'] as String?) ?? '',
            bytes: (row['bytes'] as int?) ?? 0,
            cachedAt: (row['cached_at'] as int?) ?? 0,
            lastUsedAt: (row['last_used_at'] as int?) ?? 0,
          ),
      ];
    } catch (e) {
      debugPrint('[SongAudioCache] 读取索引失败: $e');
      return const [];
    }
  }

  /// 查这首歌的缓存文件，命中时刷新 `last_used_at`。
  ///
  /// [quality] 非空时要求缓存音质一致：用户切换过音质（例如 128k → flac）后
  /// 不能继续拿旧档位的文件冒充，返回 null 让调用方重新解析地址，听完再写入
  /// 新档位的缓存。
  ///
  /// 索引在但文件被外部删掉时顺手清掉这条记录，返回 null。
  static Future<String?> findFile(String songId, {String quality = ''}) async {
    if (songId.isEmpty) return null;
    try {
      final db = await AppDatabase.cacheDatabase();
      final rows = await db.query(
        _table,
        where: 'song_id = ?',
        whereArgs: [songId],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final row = rows.first;
      final cachedQuality = ((row['quality'] as String?) ?? '').trim();
      if (!_qualityMatches(cachedQuality, quality)) return null;
      final fileName = ((row['file_name'] as String?) ?? '').trim();
      if (fileName.isEmpty) {
        await db.delete(_table, where: 'song_id = ?', whereArgs: [songId]);
        return null;
      }
      final file = File(p.join((await directory()).path, fileName));
      if (!await file.exists()) {
        await db.delete(_table, where: 'song_id = ?', whereArgs: [songId]);
        return null;
      }
      await db.update(
        _table,
        {'last_used_at': DateTime.now().millisecondsSinceEpoch},
        where: 'song_id = ?',
        whereArgs: [songId],
      );
      return file.path;
    } catch (e) {
      debugPrint('[SongAudioCache] 查询缓存失败: $e');
      return null;
    }
  }

  /// 下载并缓存一首歌。
  ///
  /// [url] 是播放时解析出来的地址；[headers] 用播放同一套请求头（Referer 等），
  /// 否则部分 CDN 会返回 403 / 试听片段。已经有可用缓存时只刷新使用时间，
  /// 不重复下载。
  ///
  /// 返回 true 表示「缓存可用」（新写入或已存在）。
  static Future<bool> store(
    Song song, {
    required String url,
    Map<String, String>? headers,
    String quality = '',
  }) {
    final songId = song.id;
    if (songId.isEmpty) return Future.value(false);
    if (!url.startsWith('http')) return Future.value(false);

    final running = _pending[songId];
    if (running != null) return running;

    final task = _store(
      song,
      url: url,
      headers: headers,
      quality: quality,
    ).whenComplete(() {
      // 注意回调不要返回被移除的那个 Future：`whenComplete` 会等待回调
      // 返回的 Future，而它就是这个 task 本身 → 永远完成不了。
      _pending.remove(songId);
    });
    _pending[songId] = task;
    return task;
  }

  static Future<bool> _store(
    Song song, {
    required String url,
    Map<String, String>? headers,
    required String quality,
  }) async {
    final songId = song.id;
    // 已经有同音质缓存：刷新使用时间即可（这也是「听完一首」最常见的路径：
    // 这首本来就是从缓存播的）。
    if (await findFile(songId, quality: quality) != null) return true;

    final dir = await directory();
    await _sweepStaleParts(dir);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final baseName = '${_safeId(songId)}_$stamp';
    final partPath = p.join(dir.path, '$baseName.part');
    final part = File(partPath);

    try {
      final ok = await (debugDownloader?.call(url, partPath, headers) ??
          _download(url, partPath, headers));
      if (!ok || !await part.exists() || await part.length() <= 0) {
        await _deleteQuietly(part);
        return false;
      }

      final ext = await _detectExtension(part);
      final fileName = '$baseName$ext';
      final target = File(p.join(dir.path, fileName));
      await part.rename(target.path);

      final db = await AppDatabase.cacheDatabase();
      final now = DateTime.now().millisecondsSinceEpoch;
      // 同一首歌换了音质：先把旧文件删掉，避免索引更新后留下没人认领的文件。
      final previous = await db.query(
        _table,
        where: 'song_id = ?',
        whereArgs: [songId],
        limit: 1,
      );
      if (previous.isNotEmpty) {
        final oldName =
            ((previous.first['file_name'] as String?) ?? '').trim();
        if (oldName.isNotEmpty && oldName != fileName) {
          await _deleteQuietly(File(p.join(dir.path, oldName)));
        }
      }
      await db.insert(_table, {
        'song_id': songId,
        'file_name': fileName,
        'quality': quality,
        'bytes': await target.length(),
        'cached_at': now,
        'last_used_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      debugPrint(
        '[SongAudioCache] 已缓存: ${song.title} → $fileName '
        '(${await target.length()} 字节)',
      );
      await _enforceLimit();
      return true;
    } catch (e) {
      debugPrint('[SongAudioCache] 缓存失败（${song.title}）: $e');
      await _deleteQuietly(part);
      return false;
    }
  }

  /// 删除一首歌的缓存（文件 + 索引）。
  ///
  /// 文件删不掉（正被播放器占用）时保留索引，下次淘汰再试，避免目录里留下
  /// 没人认领的碎片文件。
  static Future<void> remove(String songId) async {
    if (songId.isEmpty) return;
    try {
      final db = await AppDatabase.cacheDatabase();
      final rows = await db.query(
        _table,
        where: 'song_id = ?',
        whereArgs: [songId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final fileName = ((rows.first['file_name'] as String?) ?? '').trim();
      if (fileName.isNotEmpty) {
        final file = File(p.join((await directory()).path, fileName));
        if (await file.exists()) {
          try {
            await file.delete();
          } catch (e) {
            debugPrint('[SongAudioCache] 缓存文件删不掉（稍后再试）: $e');
            return;
          }
        }
      }
      await db.delete(_table, where: 'song_id = ?', whereArgs: [songId]);
    } catch (e) {
      debugPrint('[SongAudioCache] 删除缓存失败: $e');
    }
  }

  /// 超出 [maxEntries] 时按「最久没有听过」淘汰。
  static Future<void> _enforceLimit() async {
    try {
      final db = await AppDatabase.cacheDatabase();
      final count =
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM $_table'),
          ) ??
          0;
      if (count <= maxEntries) return;
      final overflow = count - maxEntries;
      final rows = await db.query(
        _table,
        orderBy: 'last_used_at ASC',
        limit: overflow,
      );
      final dir = await directory();
      for (final row in rows) {
        final songId = (row['song_id'] as String?) ?? '';
        final fileName = ((row['file_name'] as String?) ?? '').trim();
        if (fileName.isEmpty) {
          if (songId.isNotEmpty) {
            await db.delete(_table, where: 'song_id = ?', whereArgs: [songId]);
          }
          continue;
        }
        final file = File(p.join(dir.path, fileName));
        try {
          if (await file.exists()) await file.delete();
        } catch (e) {
          // 正被播放：这一轮先留着，下次再淘汰（不要删索引丢下孤儿文件）。
          debugPrint('[SongAudioCache] 淘汰跳过（文件被占用）: $e');
          continue;
        }
        if (songId.isNotEmpty) {
          await db.delete(_table, where: 'song_id = ?', whereArgs: [songId]);
        }
        debugPrint('[SongAudioCache] 已淘汰最久未听: $songId');
      }
    } catch (e) {
      debugPrint('[SongAudioCache] 淘汰旧缓存失败: $e');
    }
  }

  static Future<bool> _download(
    String url,
    String savePath,
    Map<String, String>? headers,
  ) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: _connectTimeout,
        receiveTimeout: _receiveTimeout,
        followRedirects: true,
        // 200 正常；206 是服务器对 Range / 分片请求的回应，同样可用。
        validateStatus: (status) =>
            status == 200 || status == 206 || (status ?? 0) < 400,
      ),
    );
    try {
      final response = await dio.download(
        url,
        savePath,
        options: Options(headers: headers),
      );
      final status = response.statusCode ?? 0;
      return status == 200 || status == 206;
    } finally {
      dio.close(force: true);
    }
  }

  /// 按文件头判断真实容器，决定缓存文件扩展名（播放器认内容，扩展名只影响
  /// 可读性；但 `.part` 直接改名成错的扩展名容易误导排查）。
  static Future<String> _detectExtension(File file) async {
    RandomAccessFile? raf;
    try {
      raf = await file.open();
      final header = await raf.read(12);
      if (header.length >= 4) {
        final magic = String.fromCharCodes(header.sublist(0, 4));
        if (magic == 'fLaC') return '.flac';
        if (magic == 'OggS') return '.ogg';
        if (magic == 'RIFF') return '.wav';
        if (magic == 'ID3') return '.mp3';
        if (header.length >= 8 &&
            String.fromCharCodes(header.sublist(4, 8)) == 'ftyp') {
          return '.m4a';
        }
        // MPEG 帧同步：0xFF Ex/Fx。
        if (header[0] == 0xFF && (header[1] & 0xE0) == 0xE0) return '.mp3';
      }
    } catch (_) {
      // 读不到文件头就按最常见的格式命名。
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
    }
    return '.mp3';
  }

  /// 文件名安全的 song id：去掉路径分隔符等非法字符，过长时截断。
  static String _safeId(String songId) {
    final cleaned = songId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    if (cleaned.isEmpty) return 'song';
    return cleaned.length <= 64 ? cleaned : cleaned.substring(0, 64);
  }

  /// 音质是否一致：任一方为空（旧记录 / 未知档位）时不拦截。
  static bool _qualityMatches(String cached, String requested) {
    final want = requested.trim().toLowerCase();
    final got = cached.trim().toLowerCase();
    if (want.isEmpty || got.isEmpty) return true;
    return want == got;
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// 清理上次异常退出（进程被杀 / 强制关机）留下的半截下载文件。
  ///
  /// 只在本进程第一次写入时跑一次，删的是「1 小时前的 `.part`」——刚开始的
  /// 下载不会被误删；目录里也不会随着每次强退越堆越多。
  static bool _partsSwept = false;

  static Future<void> _sweepStaleParts(Directory dir) async {
    if (_partsSwept) return;
    _partsSwept = true;
    try {
      final cutoff = DateTime.now().subtract(const Duration(hours: 1));
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.part')) continue;
        try {
          if ((await entity.stat()).modified.isBefore(cutoff)) {
            await entity.delete();
          }
        } catch (_) {}
      }
    } catch (_) {}
  }
}
