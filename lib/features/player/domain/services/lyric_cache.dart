import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../../../core/storage/app_database.dart';
import '../../../../shared/services/cache_paths.dart';
import '../models/song.dart';

/// 一首歌的歌词缓存内容。
///
/// 注意：Dart 不支持嵌套类（`class` 声明在另一个 `class` 里是语法错误），
/// 所以这个类必须放在顶层。
class LyricCacheEntry {
  final String? lrc;
  final String? crlyric;
  final String? tlyric;
  final String? rlyric;

  /// TTML 词库原文（缓存原文，命中后本地重新解析成逐字歌词）。
  final String? ttml;

  const LyricCacheEntry({
    this.lrc,
    this.crlyric,
    this.tlyric,
    this.rlyric,
    this.ttml,
  });

  /// 缓存里是否什么都没有（没有就不写）。
  bool get isEmpty =>
      (lrc?.isEmpty ?? true) &&
      (crlyric?.isEmpty ?? true) &&
      (tlyric?.isEmpty ?? true) &&
      (rlyric?.isEmpty ?? true) &&
      (ttml?.isEmpty ?? true);

  factory LyricCacheEntry.fromRow(Map<String, Object?> row) {
    return LyricCacheEntry(
      lrc: row['lrc'] as String?,
      crlyric: row['crlyric'] as String?,
      tlyric: row['tlyric'] as String?,
      rlyric: row['rlyric'] as String?,
      ttml: row['ttml'] as String?,
    );
  }
}

/// 歌词磁盘缓存。
///
/// 歌词来自网络（TTML 词库 + 在线歌词），每次播放都重新请求会明显拖慢切歌，
/// 也重复消耗流量。
///
/// 缓存放在**临时库**（Windows：`AppData\temp\db\mintmusic_cache.db` 的
/// `lyrics` 表）里：
///
/// * 一首歌一行，读写都是行级操作，不用开文件、少一次文件 IO；
/// * 不用再产生「一首歌一个小文件」，几千首歌也就多几千行数据，
///   不会在缓存目录里堆几千个碎片文件；
/// * 跟其它高频数据一样属于「丢了可以重新取回」的缓存。
class LyricCache {
  const LyricCache._();

  /// 旧版把歌词缓存成「一首歌一个 JSON 文件」的目录名（首次启动时迁移）。
  static const String folderName = 'lyric_cache';

  /// 迁移标记用的模块名。
  static const String _migrationModule = 'lyric_cache';

  /// 缓存键：平台 + 歌曲 id 的 md5。
  ///
  /// 音源 id 里可能带 `@插件id`（插件音源；或者内置源的地址被插件解析后，
  /// 队列里歌曲的 source 被标记成了插件变体 id）。这里只取平台部分：
  /// 同一首歌在「内置源」和「插件源」下的歌词缓存要能对上，否则歌曲在
  /// 两种来源之间切换时缓存全部失效（每次都要重新联网取词）。
  static String keyFor(Song song) {
    final source = (song.source ?? '').split('@').first;
    final raw = '${source}_${song.id}';
    return md5.convert(utf8.encode(raw)).toString();
  }

  /// 读取缓存（没有缓存或读取失败返回 null）。
  static Future<LyricCacheEntry?> read(Song song) async {
    try {
      await _ensureMigrated();
      final db = await AppDatabase.cacheDatabase();
      final rows = await db.query(
        'lyrics',
        where: 'cache_key = ?',
        whereArgs: [keyFor(song)],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final entry = LyricCacheEntry.fromRow(rows.first);
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
    final entry = LyricCacheEntry(
      lrc: lrc,
      crlyric: crlyric,
      tlyric: tlyric,
      rlyric: rlyric,
      ttml: ttml,
    );
    if (entry.isEmpty) return;
    try {
      await _ensureMigrated();
      final db = await AppDatabase.cacheDatabase();
      await db.insert(
        'lyrics',
        {
          'cache_key': keyFor(song),
          'lrc': entry.lrc,
          'crlyric': entry.crlyric,
          'tlyric': entry.tlyric,
          'rlyric': entry.rlyric,
          'ttml': entry.ttml,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await _trimIfNeeded(db);
    } catch (e) {
      debugPrint('[LyricCache] 写入缓存失败: $e');
    }
  }

  // ---------------------------------------------------------------- 容量控制

  /// 歌词缓存最多保留多少条。
  ///
  /// 逐字歌词（TTML）一条能有几十 KB，不限制的话临时库会一直涨。
  /// 旧版歌词缓存放在缓存目录里，受「缓存大小上限」约束，现在放进数据库
  /// 就得自己控制条数。
  static const int _maxEntries = 2000;

  /// 每写多少条检查一次容量（避免每次写入都 COUNT 一遍）。
  static const int _trimInterval = 32;

  static int _writeCount = 0;

  static Future<void> _trimIfNeeded(Database db) async {
    _writeCount++;
    if (_writeCount % _trimInterval != 0) return;
    try {
      final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM lyrics');
      final count = (rows.first['c'] as int?) ?? 0;
      if (count <= _maxEntries) return;
      final excess = count - _maxEntries;
      await db.rawDelete(
        'DELETE FROM lyrics WHERE cache_key IN ('
        'SELECT cache_key FROM lyrics ORDER BY updated_at ASC LIMIT ?)',
        [excess],
      );
    } catch (e) {
      debugPrint('[LyricCache] 清理旧缓存失败: $e');
    }
  }

  // ---------------------------------------------------------------- 迁移

  static bool? _migrated;

  /// 迁移过程中的 Future（防止启动迁移和读缓存同时触发两次迁移）。
  static Future<void>? _migrating;

  /// 把旧版「一首歌一个 JSON 文件」的缓存导入数据库，然后删掉那个目录。
  ///
  /// 旧文件名就是 `md5(音源id_歌曲id)`，正好可以直接当主键用。
  static Future<void> migrateLegacyFiles() async {
    await _ensureMigrated();
  }

  static Future<void> _ensureMigrated() async {
    if (_migrated == true) return;
    final running = _migrating;
    if (running != null) {
      await running;
      return;
    }
    final future = _doMigrate();
    _migrating = future;
    try {
      await future;
    } finally {
      if (identical(_migrating, future)) _migrating = null;
    }
  }

  static Future<void> _doMigrate() async {
    if (_migrated == true) return;
    if (await AppDatabase.isMigrated(_migrationModule)) {
      _migrated = true;
      return;
    }
    try {
      final dir = await CachePaths.subDirectory(folderName);
      final entities = await dir.list().toList();
      var migrated = 0;
      final db = await AppDatabase.cacheDatabase();
      final batch = db.batch();
      for (final entity in entities) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (!name.endsWith('.json')) continue;
        try {
          final raw = await entity.readAsString();
          if (raw.trim().isEmpty) continue;
          final decoded = jsonDecode(raw);
          if (decoded is! Map) continue;
          batch.insert(
            'lyrics',
            {
              'cache_key': p.basenameWithoutExtension(name),
              'lrc': decoded['lrc'] as String?,
              'crlyric': decoded['crlyric'] as String?,
              'tlyric': decoded['tlyric'] as String?,
              'rlyric': decoded['rlyric'] as String?,
              'ttml': decoded['ttml'] as String?,
              'updated_at': DateTime.now().millisecondsSinceEpoch,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          migrated++;
        } catch (_) {
          // 单个文件损坏就跳过
        }
      }
      await batch.commit(noResult: true);
      // 迁完删掉旧目录，避免缓存目录里还留着一堆碎片文件。
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      if (migrated > 0) {
        debugPrint('[LyricCache] 已迁移 $migrated 条旧歌词缓存到临时库');
      }
    } catch (e) {
      debugPrint('[LyricCache] 迁移旧歌词缓存失败: $e');
    }
    if (AppDatabase.isPersistent) {
      await AppDatabase.markMigrated(_migrationModule);
    }
    _migrated = true;
  }
}
