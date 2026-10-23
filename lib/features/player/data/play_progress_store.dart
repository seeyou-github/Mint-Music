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

/// 已播放进度存储（临时库 `song_play_progress` 表）。
///
/// 播放位置每秒都会变，但界面只关心「已听 N%」，所以这里按 1% 粒度攒批，
/// 交给 [DeferredWriter] 合并写盘（切后台 / 退出时统一 flush），
/// 避免每播放一秒就写一次硬盘。
class PlayProgressStore {
  PlayProgressStore() {
    AppDatabase.registerWriter(_writer);
  }

  /// 待写入的进度（songId → 最新进度）。
  final Map<String, PlayedProgress> _pending = {};

  late final DeferredWriter _writer = DeferredWriter(
    _persist,
    interval: const Duration(seconds: 6),
  );

  /// 读取全部已播放进度。
  Future<Map<String, PlayedProgress>> loadAll() async {
    final result = <String, PlayedProgress>{};
    try {
      final db = await AppDatabase.cacheDatabase();
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

  /// 清空全部播放进度。
  Future<void> clear() async {
    _pending.clear();
    try {
      final db = await AppDatabase.cacheDatabase();
      await db.delete('song_play_progress');
      await AppDatabase.checkpoint();
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
      final db = await AppDatabase.cacheDatabase();
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
}
