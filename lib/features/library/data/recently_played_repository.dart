import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../../core/storage/app_database.dart';
import '../../../core/storage/app_preferences.dart';
import '../domain/models/recently_played.dart';
import '../../player/domain/models/song.dart';

/// 最近播放记录。
///
/// 数据量大、变动频繁（每次播放都会变），但丢了也无所谓，因此放在
/// 「临时库」（Windows：`AppData\temp\db\mintmusic_cache.db`），
/// 并且写入走 **合并延迟写**：运行期只改内存，攒够一批再落盘，
/// 应用切后台 / 退出时统一 flush，避免每次播放都写一次硬盘。
class RecentlyPlayedRepository {
  static const int _maxItems = 500;

  /// 旧版把最近播放存在设置文件里的键（首次启动时迁移）。
  static const String _legacyKey = 'recently_played';

  List<RecentlyPlayedItem>? _cache;


  Future<List<RecentlyPlayedItem>> loadHistory() async {
    // 已经在内存里了就直接用：延迟写还没落盘时，数据库里是旧数据，
    // 重新读会把刚加的记录冲掉。
    final cached = _cache;
    if (cached != null) return cached;

    final db = await AppDatabase.cacheDatabase();
    final rows = await db.query(
      'recently_played',
      orderBy: 'played_at DESC',
      limit: _maxItems,
    );
    var history = <RecentlyPlayedItem>[];
    for (final row in rows) {
      final data = AppDatabase.decodeMap(row['data']);
      if (data.isEmpty) continue;
      try {
        history.add(RecentlyPlayedItem.fromJson(data));
      } catch (_) {
        // 单条数据损坏就跳过，不影响其它记录
      }
    }

    if (history.isEmpty &&
        !await AppDatabase.isMigrated('recently_played')) {
      history = await _importLegacy();
      if (AppDatabase.isPersistent) {
        await AppDatabase.markMigrated('recently_played');
      }
    }

    _cache = history;
    return history;
  }

  /// 立即落盘（显式调用时使用）。
  Future<void> saveHistory(List<RecentlyPlayedItem> history) async {
    _cache = history;
    await _persist();
  }

  Future<void> addToHistory(Song song) async {
    final history = await loadHistory();
    final existingIndex = history.indexWhere((h) => h.song.id == song.id);

    if (existingIndex != -1) {
      final existing = history[existingIndex];
      history[existingIndex] = existing.copyWith(
        playedAt: DateTime.now(),
        playCount: existing.playCount + 1,
      );
    } else {
      history.insert(
        0,
        RecentlyPlayedItem(song: song, playedAt: DateTime.now()),
      );
    }

    if (history.length > _maxItems) {
      history.removeRange(_maxItems, history.length);
    }

    _cache = history;
    // 立即写库：关闭应用时进程会被直接结束，来不及等延迟写，
    // 结果就是「退出前没写进去，重启后最近播放是空的」。
    final changed = history.firstWhere(
      (h) => h.song.id == song.id,
      orElse: () => history.first,
    );
    await _writeItem(changed);
  }

  Future<void> clearHistory() async {
    _cache = <RecentlyPlayedItem>[];
    await _deleteAll();
  }

  Future<void> removeFromHistory(String songId) async {
    final history = await loadHistory();
    history.removeWhere((h) => h.song.id == songId);
    _cache = history;
    await _deleteItem(songId);
  }

  // ---------------------------------------------------------------- 落盘

  /// 只写变化的那一行（每次播放只写一行，不用重写整张表）。
  Future<void> _writeItem(RecentlyPlayedItem item) async {
    try {
      final db = await AppDatabase.cacheDatabase();
      await db.insert('recently_played', {
        'song_id': item.song.id,
        'played_at': item.playedAt.millisecondsSinceEpoch,
        'play_count': item.playCount,
        'data': jsonEncode(item.toJson()),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      // 写完 checkpoint：应用退出时进程会被直接结束，不 checkpoint 的话
      // 刚播放的记录会丢（重启后最近播放是空的）。
      await AppDatabase.checkpoint();
    } catch (e) {
      debugPrint('[RecentlyPlayedRepository] 写入最近播放失败: $e');
    }
  }

  /// 删除一条记录。
  Future<void> _deleteItem(String songId) async {
    try {
      final db = await AppDatabase.cacheDatabase();
      await db.delete(
        'recently_played',
        where: 'song_id = ?',
        whereArgs: [songId],
      );
    } catch (e) {
      debugPrint('[RecentlyPlayedRepository] 删除最近播放失败: $e');
    }
  }

  /// 清空全部记录。
  Future<void> _deleteAll() async {
    try {
      final db = await AppDatabase.cacheDatabase();
      await db.delete('recently_played');
    } catch (e) {
      debugPrint('[RecentlyPlayedRepository] 清空最近播放失败: $e');
    }
  }

  /// 旧数据迁移用：整表重写一次。
  Future<void> _persist() async {
    final history = _cache;
    if (history == null) return;
    final db = await AppDatabase.cacheDatabase();
    await db.transaction((txn) async {
      await txn.delete('recently_played');
      final batch = txn.batch();
      for (final item in history.take(_maxItems)) {
        batch.insert('recently_played', {
          'song_id': item.song.id,
          'played_at': item.playedAt.millisecondsSinceEpoch,
          'play_count': item.playCount,
          'data': jsonEncode(item.toJson()),
        });
      }
      await batch.commit(noResult: true);
    });
  }

  /// 首次启动：把旧设置文件里的最近播放导入数据库。
  Future<List<RecentlyPlayedItem>> _importLegacy() async {
    final history = <RecentlyPlayedItem>[];
    try {
      final prefs = await AppPreferences.getInstance();
      final raw = prefs.getString(_legacyKey);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List<dynamic>;
        history.addAll(
          list.map(
            (e) => RecentlyPlayedItem.fromJson(e as Map<String, dynamic>),
          ),
        );
      }
      if (history.isNotEmpty) {
        _cache = history;
        await _persist();
        await AppDatabase.removeLegacyKey(_legacyKey);
        // ignore: avoid_print
        print('[RecentlyPlayedRepository] 已从旧设置迁移 ${history.length} 条记录');
      }
    } catch (e) {
      // ignore: avoid_print
      print('[RecentlyPlayedRepository] 迁移旧记录失败: $e');
    }
    return history;
  }
}
