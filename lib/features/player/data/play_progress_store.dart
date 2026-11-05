import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../../core/storage/app_database.dart';

/// 一首歌的已播放进度。
class PlayedProgress {
  const PlayedProgress({
    required this.ratio,
    this.positionMs = 0,
    this.durationMs = 0,
  });

  /// 0~1 的播放进度，只增不减；1 表示完整听过一遍。
  final double ratio;
  final int positionMs;
  final int durationMs;
}

/// 已播放进度存储（**重要库**：`AppData\db\mintmusic.db` 的
/// `song_play_progress` 表）。
///
/// 这份数据既是歌曲列表上的「已听 N%」标签，也是「接着上次继续播放」的位置，
/// 属于用户长期积累的数据——以前放在临时库，清一次缓存 / 还原一次备份就全丢
/// 了，现在跟收藏一起进重要库（重要库写入立刻落盘、synchronous=FULL）。
///
/// 播放位置每秒都会变，但界面只关心「已听 N%」，所以这里按 1% 粒度攒批，
/// 交给 [DeferredWriter] 合并写盘（切后台 / 退出时统一 flush），
/// 避免每播放一秒就写一次硬盘。
class PlayProgressStore {
  PlayProgressStore() {
    AppDatabase.registerWriter(_writer);
  }

  /// 旧临时库那张表的迁移标记（`db_migrated_play_progress`）。
  static const String _migrationModule = 'play_progress';

  /// 迁移只执行一次，并发调用共用同一个 Future。
  Future<void>? _migration;

  /// 待写入的进度（songId → 最新进度）。
  final Map<String, PlayedProgress> _pending = {};

  late final DeferredWriter _writer = DeferredWriter(
    _persist,
    interval: const Duration(seconds: 6),
  );

  /// 读取全部已播放进度。
  Future<Map<String, PlayedProgress>> loadAll() async {
    await (_migration ??= _migrateLegacy());
    final result = <String, PlayedProgress>{};
    try {
      final db = await AppDatabase.importantDatabase();
      final rows = await db.query(
        'song_play_progress',
        columns: ['song_id', 'ratio', 'position_ms', 'duration_ms'],
      );
      for (final row in rows) {
        final songId = '${row['song_id'] ?? ''}';
        if (songId.isEmpty) continue;
        final ratio = (row['ratio'] as num?)?.toDouble() ?? 0;
        if (ratio <= 0) continue;
        result[songId] = PlayedProgress(
          ratio: ratio.clamp(0.0, 1.0),
          positionMs: (row['position_ms'] as num?)?.toInt() ?? 0,
          durationMs: (row['duration_ms'] as num?)?.toInt() ?? 0,
        );
      }
    } catch (e) {
      debugPrint('[PlayProgress] 读取已播放进度失败: $e');
    }
    return result;
  }

  /// 标记某首歌的进度需要落盘。
  void enqueue(String songId, PlayedProgress progress) {
    _pending[songId] = progress;
    _writer.schedule();
  }

  /// 立即落盘（测试 / 退出前用）。
  Future<void> flush() => _writer.writeNow();

  /// 清空全部播放进度（「最近播放」页的「清除」）。
  Future<void> clear() async {
    _pending.clear();
    try {
      final db = await AppDatabase.importantDatabase();
      await db.delete('song_play_progress');
      await AppDatabase.checkpointImportant();
    } catch (e) {
      debugPrint('[PlayProgress] 清空已播放进度失败: $e');
    }
  }

  Future<void> _persist() async {
    if (_pending.isEmpty) return;
    final entries = Map<String, PlayedProgress>.of(_pending);
    _pending.clear();
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      final db = await AppDatabase.importantDatabase();
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (final entry in entries.entries) {
          batch.insert('song_play_progress', {
            'song_id': entry.key,
            'ratio': entry.value.ratio,
            'position_ms': entry.value.positionMs,
            'duration_ms': entry.value.durationMs,
            'updated_at': now,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await batch.commit(noResult: true);
      });
    } catch (e) {
      debugPrint('[PlayProgress] 写入已播放进度失败: $e');
      // 写失败就放回队列，下次再试（已存在的不覆盖更新的进度）。
      for (final entry in entries.entries) {
        final existing = _pending[entry.key];
        if (existing == null || existing.ratio < entry.value.ratio) {
          _pending[entry.key] = entry.value;
        }
      }
    }
  }

  /// 把旧临时库里的进度搬进重要库（只做一次）。
  ///
  /// 旧版本的进度表在 `mintmusic_cache.db`，清缓存就没了；升级后搬到重要库
  /// 并清空旧表，避免两份数据各自增长。
  Future<void> _migrateLegacy() async {
    if (await AppDatabase.isMigrated(_migrationModule)) return;
    // 内存库（打开失败降级）不迁移：清了旧表就再也找不回来了。
    if (!AppDatabase.isPersistent) return;
    try {
      final cacheDb = await AppDatabase.cacheDatabase();
      final rows = await cacheDb.query('song_play_progress');
      if (rows.isNotEmpty) {
        final db = await AppDatabase.importantDatabase();
        final batch = db.batch();
        for (final row in rows) {
          batch.insert('song_play_progress', {
            'song_id': row['song_id'],
            'ratio': row['ratio'] ?? 0,
            'position_ms': row['position_ms'] ?? 0,
            'duration_ms': row['duration_ms'] ?? 0,
            'updated_at': row['updated_at'] ?? 0,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await batch.commit(noResult: true);
        await cacheDb.delete('song_play_progress');
        debugPrint('[PlayProgress] 已把 ${rows.length} 条旧进度搬进重要库');
      }
      await AppDatabase.markMigrated(_migrationModule);
    } catch (e) {
      debugPrint('[PlayProgress] 迁移旧进度失败: $e');
    }
  }
}
