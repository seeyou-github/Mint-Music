import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../../core/storage/app_database.dart';
import '../domain/models/recently_played.dart';

/// 一首歌待写入的增量。
class _SongDelta {
  int playCount = 0;
  int listenedMs = 0;
  int lastPlayedAt = 0;

  /// 歌曲 JSON（`RecentlyPlayedItem.toPersistJson()`）；null 表示这次只累计
  /// 时长 / 次数，不要覆盖已有的歌曲信息。
  String? data;

  void merge(_SongDelta other) {
    playCount += other.playCount;
    listenedMs += other.listenedMs;
    if (other.lastPlayedAt > lastPlayedAt) lastPlayedAt = other.lastPlayedAt;
    if (other.data != null) data = other.data;
  }
}

/// 某一天待写入的增量。
class _DayDelta {
  int listenedMs = 0;
  int plays = 0;

  void merge(_DayDelta other) {
    listenedMs += other.listenedMs;
    plays += other.plays;
  }
}

/// 听歌数据的长期存储（**重要库**：`AppData\db\mintmusic.db`）。
///
/// 存四类东西：
///
/// * `play_totals`：累计总时长 / 播放次数（一行，只记累计值）；
/// * `play_daily`：每天的累计时长 / 次数（周 / 月 / 年由它汇总，一年 365 行）；
/// * `song_play_stats`：每首歌的播放次数 / 时长（「排行」分类的数据源）；
/// * `song_play_progress`：每首歌「听到哪里」（由 `PlayProgressStore` 维护）。
///
/// 这些数据是用户长期积累的（换设备后还要在），所以不能留在临时库——
/// 清缓存、还原备份都会把临时库清掉。
///
/// **写盘策略**：先攒在内存里（[DeferredWriter]，最长 15 秒 / 攒够
/// [batchSize] 次变化写一次），写的时候合并成「每首歌一条增量 + 每天一条
/// 增量 + 一次 totals 更新」，不会因为听了 1 秒就写一次盘。
class PlayStatsStore {
  PlayStatsStore() {
    AppDatabase.registerWriter(_writer);
  }

  /// 攒够多少次变化就直接写库。
  static const int batchSize = 12;

  /// 排行最多显示多少首。
  static const int rankingLimit = 100;

  /// 旧明细表迁移标记（`db_migrated_play_stats`）。
  static const String _migrationModule = 'play_stats';

  final Map<String, _SongDelta> _pendingSongs = {};
  final Map<String, _DayDelta> _pendingDaily = {};

  late final DeferredWriter _writer = DeferredWriter(
    _persist,
    interval: const Duration(seconds: 15),
  );

  int get _pendingCount => _pendingSongs.length + _pendingDaily.length;

  // ---------------------------------------------------------------- 写入

  /// 开始播放一首歌：次数 +1，并刷新「最近一次播放」与歌曲信息。
  void recordPlay(RecentlyPlayedItem item) {
    final songId = item.song.id;
    if (songId.isEmpty) return;
    final now = item.playedAt.millisecondsSinceEpoch;
    // 排行只需要歌曲本身与来源，`sourceMeta`（作者 / 专辑主页 json）会显著
    // 放大存储，去掉。
    final data = jsonEncode(
      item.copyWith(clearSourceMeta: true).toPersistJson(),
    );

    _pendingSongs
        .putIfAbsent(songId, _SongDelta.new)
        .merge(_SongDelta()
          ..playCount = 1
          ..lastPlayedAt = now
          ..data = data);
    _pendingDaily.putIfAbsent(_dayKey(item.playedAt), _DayDelta.new).plays += 1;
    _schedule();
  }

  /// 结算一段收听时长。
  void recordListen({required String songId, required int listenedMs}) {
    if (songId.isEmpty || listenedMs <= 0) return;
    _pendingSongs.putIfAbsent(songId, _SongDelta.new).listenedMs += listenedMs;
    _pendingDaily
        .putIfAbsent(_dayKey(DateTime.now()), _DayDelta.new)
        .listenedMs += listenedMs;
    _schedule();
  }

  void _schedule() {
    if (_pendingCount >= batchSize) {
      _writer.writeNow();
    } else {
      _writer.schedule();
    }
  }

  /// 立即落盘（切后台 / 退出 / 备份前）。
  Future<void> flush() => _writer.writeNow();

  Future<void> _persist() async {
    if (_pendingSongs.isEmpty && _pendingDaily.isEmpty) return;
    final songs = Map<String, _SongDelta>.of(_pendingSongs);
    final daily = Map<String, _DayDelta>.of(_pendingDaily);
    _pendingSongs.clear();
    _pendingDaily.clear();

    try {
      final db = await AppDatabase.importantDatabase();
      await db.transaction((txn) async {
        await _applyDeltas(txn, songs, daily);
        await _addTotals(
          txn,
          listenedMs: daily.values.fold(0, (sum, d) => sum + d.listenedMs),
          plays: songs.values.fold(0, (sum, d) => sum + d.playCount),
        );
      });
    } catch (e) {
      debugPrint('[PlayStats] 写入听歌统计失败: $e');
      // 写失败就放回队列，下次再试（内存里仍是最新的）。
      for (final entry in songs.entries) {
        _pendingSongs
            .putIfAbsent(entry.key, _SongDelta.new)
            .merge(entry.value);
      }
      for (final entry in daily.entries) {
        _pendingDaily
            .putIfAbsent(entry.key, _DayDelta.new)
            .merge(entry.value);
      }
    }
  }

  /// 把增量写进三张表（只做 +，不覆盖已有累计值）。
  static Future<void> _applyDeltas(
    DatabaseExecutor db,
    Map<String, _SongDelta> songs,
    Map<String, _DayDelta> daily,
  ) async {
    for (final entry in songs.entries) {
      final delta = entry.value;
      // 用 UPDATE ... SET x = x + ? 而不是 UPSERT：Android 7~10 自带的
      // SQLite 还不支持 `ON CONFLICT DO UPDATE`。
      final updated = await db.rawUpdate(
        'UPDATE song_play_stats SET '
        'play_count = play_count + ?, '
        'listened_ms = listened_ms + ?, '
        'last_played_at = MAX(last_played_at, ?), '
        'data = COALESCE(NULLIF(?, \'\'), data) '
        'WHERE song_id = ?',
        [
          delta.playCount,
          delta.listenedMs,
          delta.lastPlayedAt,
          delta.data ?? '',
          entry.key,
        ],
      );
      if (updated == 0) {
        await db.insert('song_play_stats', {
          'song_id': entry.key,
          'play_count': delta.playCount,
          'listened_ms': delta.listenedMs,
          'last_played_at': delta.lastPlayedAt,
          'data': delta.data ?? '{}',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }

    for (final entry in daily.entries) {
      final delta = entry.value;
      final updated = await db.rawUpdate(
        'UPDATE play_daily SET listened_ms = listened_ms + ?, '
        'plays = plays + ? WHERE day = ?',
        [delta.listenedMs, delta.plays, entry.key],
      );
      if (updated == 0) {
        await db.insert('play_daily', {
          'day': entry.key,
          'listened_ms': delta.listenedMs,
          'plays': delta.plays,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
  }

  static Future<void> _addTotals(
    DatabaseExecutor db, {
    required int listenedMs,
    required int plays,
  }) async {
    if (listenedMs == 0 && plays == 0) return;
    final updated = await db.rawUpdate(
      'UPDATE play_totals SET total_listened_ms = total_listened_ms + ?, '
      'total_plays = total_plays + ?, updated_at = ? WHERE id = 1',
      [listenedMs, plays, DateTime.now().millisecondsSinceEpoch],
    );
    if (updated == 0) {
      await db.insert('play_totals', {
        'id': 1,
        'total_listened_ms': listenedMs,
        'total_plays': plays,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  // ---------------------------------------------------------------- 读取

  /// 听歌统计。累计值直接读 totals / 按天表，不扫明细。
  Future<PlaybackStats> loadStats({
    PlaybackStatsGranularity granularity = PlaybackStatsGranularity.day,
  }) async {
    await _migrateLegacyEvents();

    var totalMs = 0;
    var totalPlays = 0;
    var songCount = 0;
    final daily = <String, ({int ms, int plays})>{};
    try {
      final db = await AppDatabase.importantDatabase();
      final totals = await db.query('play_totals', where: 'id = 1', limit: 1);
      if (totals.isNotEmpty) {
        totalMs = (totals.first['total_listened_ms'] as num?)?.toInt() ?? 0;
        totalPlays = (totals.first['total_plays'] as num?)?.toInt() ?? 0;
      }
      final counted = await db.rawQuery(
        'SELECT COUNT(*) AS n FROM song_play_stats',
      );
      songCount = (counted.first['n'] as num?)?.toInt() ?? 0;
      for (final row in await db.query(
        'play_daily',
        columns: ['day', 'listened_ms', 'plays'],
      )) {
        daily['${row['day']}'] = (
          ms: (row['listened_ms'] as num?)?.toInt() ?? 0,
          plays: (row['plays'] as num?)?.toInt() ?? 0,
        );
      }
    } catch (e) {
      debugPrint('[PlayStats] 读取听歌统计失败: $e');
    }

    // 还没落盘的增量也要算进去：刚听完歌就打开「统计」时，数据库里可能还是
    // 旧的（攒批写盘有 15 秒窗口）。
    for (final entry in _pendingDaily.entries) {
      final existing = daily[entry.key];
      daily[entry.key] = (
        ms: (existing?.ms ?? 0) + entry.value.listenedMs,
        plays: (existing?.plays ?? 0) + entry.value.plays,
      );
      totalMs += entry.value.listenedMs;
      totalPlays += entry.value.plays;
    }
    songCount += await _countPendingNewSongs();

    return PlaybackStats(
      totalListenedMs: totalMs,
      totalPlays: totalPlays,
      songCount: songCount,
      buckets: _buildBuckets(daily, granularity),
    );
  }

  /// 待写增量里有多少首是库里还没有的（「听过的歌」要算上它们）。
  Future<int> _countPendingNewSongs() async {
    if (_pendingSongs.isEmpty) return 0;
    try {
      final db = await AppDatabase.importantDatabase();
      final ids = _pendingSongs.keys.toList(growable: false);
      final marks = List.filled(ids.length, '?').join(', ');
      final rows = await db.rawQuery(
        'SELECT COUNT(*) AS n FROM song_play_stats WHERE song_id IN ($marks)',
        ids,
      );
      final existing = (rows.first['n'] as num?)?.toInt() ?? 0;
      return ids.length - existing;
    } catch (_) {
      return 0;
    }
  }

  /// 听歌排行（全部历史，不只最近的几百首）。
  Future<List<RecentlyPlayedItem>> loadRanking({
    int limit = rankingLimit,
  }) async {
    await _migrateLegacyEvents();
    // 先把攒在内存里的次数写下去：刚听完一首歌就打开「排行」时，榜单应该
    // 立刻包含这次播放（攒批写盘本来有 15 秒窗口）。
    await flush();
    final items = <RecentlyPlayedItem>[];
    try {
      final db = await AppDatabase.importantDatabase();
      final rows = await db.query(
        'song_play_stats',
        // 没有歌曲信息的行（老明细里歌已经被挤出最近播放列表，拿不到歌名 /
        // 封面）没法展示，也不该出现在排行里。
        where: "data <> '{}' AND data <> ''",
        orderBy: 'play_count DESC, listened_ms DESC, last_played_at DESC',
        limit: limit,
      );
      for (final row in rows) {
        final json = AppDatabase.decodeMap(row['data']);
        if (json.isEmpty) continue;
        try {
          final item = RecentlyPlayedItem.fromJson(json);
          items.add(
            item.copyWith(
              playCount: (row['play_count'] as num?)?.toInt() ??
                  item.playCount,
              listenedMs: (row['listened_ms'] as num?)?.toInt() ??
                  item.listenedMs,
              playedAt: DateTime.fromMillisecondsSinceEpoch(
                (row['last_played_at'] as num?)?.toInt() ?? 0,
              ),
            ),
          );
        } catch (_) {
          // 单条数据损坏就跳过
        }
      }
    } catch (e) {
      debugPrint('[PlayStats] 读取听歌排行失败: $e');
    }

    // 还没落盘的次数补到已有条目上（顺序在下次读库时自然更新）。
    for (final entry in _pendingSongs.entries) {
      final index = items.indexWhere((item) => item.song.id == entry.key);
      if (index < 0) continue;
      final item = items[index];
      items[index] = item.copyWith(
        playCount: item.playCount + entry.value.playCount,
        listenedMs: item.listenedMs + entry.value.listenedMs,
      );
    }
    return items;
  }

  /// 清空全部听歌统计（排行 + 累计 + 按天）。
  Future<void> clear() async {
    _pendingSongs.clear();
    _pendingDaily.clear();
    try {
      final db = await AppDatabase.importantDatabase();
      await db.transaction((txn) async {
        await txn.delete('song_play_stats');
        await txn.delete('play_daily');
        await txn.rawUpdate(
          'UPDATE play_totals SET total_listened_ms = 0, total_plays = 0, '
          'updated_at = ? WHERE id = 1',
          [DateTime.now().millisecondsSinceEpoch],
        );
      });
      await AppDatabase.checkpointImportant();
    } catch (e) {
      debugPrint('[PlayStats] 清空听歌统计失败: $e');
    }
  }

  // ---------------------------------------------------------------- 旧数据

  /// 旧明细表迁移只在第一次调用时真正执行；并发调用共用同一个 Future，
  /// 否则「统计」和「排行」同时打开会把同一批明细聚合两遍。
  Future<void>? _migration;

  Future<void> _migrateLegacyEvents() {
    return _migration ??= _runLegacyMigration();
  }

  /// 把临时库 `play_events` 里的旧明细聚合成累计值搬进重要库（只做一次）。
  ///
  /// 老版本按「每听一段记一条」存明细（一首歌几百条），既占地方又只能靠
  /// 全表扫出来聚合。升级后只保留聚合结果：总时长 / 次数 / 每天累计 /
  /// 每首歌汇总，明细表清空。
  Future<void> _runLegacyMigration() async {
    if (await AppDatabase.isMigrated(_migrationModule)) return;
    // 数据库降级成内存库时不迁移：清掉明细后下次启动就再也找不回来了。
    if (!AppDatabase.isPersistent) return;
    try {
      final cacheDb = await AppDatabase.cacheDatabase();
      final rows = await cacheDb.query(
        'play_events',
        columns: ['song_id', 'played_at', 'listened_ms'],
        orderBy: 'played_at ASC',
      );
      if (rows.isEmpty) {
        await AppDatabase.markMigrated(_migrationModule);
        return;
      }

      // 歌曲信息从「最近播放」里取：明细表只有 song_id。已经被挤出最近播放
      // 列表（超过 500 首）的歌拿不到歌名，只统计数字、不进排行。
      final songJson = <String, String>{};
      for (final row in await cacheDb.query(
        'recently_played',
        columns: ['song_id', 'data'],
      )) {
        final id = '${row['song_id'] ?? ''}';
        final data = '${row['data'] ?? ''}';
        if (id.isEmpty || data.isEmpty) continue;
        songJson[id] = data;
      }

      final songs = <String, _SongDelta>{};
      final daily = <String, _DayDelta>{};
      for (final row in rows) {
        final songId = '${row['song_id'] ?? ''}';
        final listenedMs = (row['listened_ms'] as num?)?.toInt() ?? 0;
        if (listenedMs <= 0) continue;
        final at = DateTime.fromMillisecondsSinceEpoch(
          (row['played_at'] as num?)?.toInt() ?? 0,
        );
        daily.putIfAbsent(_dayKey(at), _DayDelta.new)
          ..listenedMs += listenedMs
          ..plays += 1;
        if (songId.isEmpty) continue;
        final delta = songs.putIfAbsent(songId, _SongDelta.new)
          ..listenedMs += listenedMs
          ..playCount += 1
          ..lastPlayedAt = at.millisecondsSinceEpoch;
        final data = songJson[songId];
        if (data != null) delta.data = data;
      }

      final db = await AppDatabase.importantDatabase();
      await db.transaction((txn) async {
        await _applyDeltas(txn, songs, daily);
        await _addTotals(
          txn,
          listenedMs: daily.values.fold(0, (sum, d) => sum + d.listenedMs),
          plays: daily.values.fold(0, (sum, d) => sum + d.plays),
        );
      });
      // 明细已经变成累计值了，清掉，省得两份数据对不上。
      await cacheDb.delete('play_events');
      await AppDatabase.markMigrated(_migrationModule);
      debugPrint(
        '[PlayStats] 已把 ${rows.length} 条旧播放明细聚合进重要库'
        '（${songs.length} 首歌 / ${daily.length} 天）',
      );
    } catch (e) {
      debugPrint('[PlayStats] 迁移旧播放明细失败: $e');
    }
  }

  // ---------------------------------------------------------------- 备份

  /// 导出听歌数据快照（备份包里的 `playstats.json`）。
  ///
  /// 直接导「逻辑数据」而不是数据库文件：拷一个正在使用的 SQLite 文件
  /// （还有 `-wal` 没合并）很容易漏掉刚写的事务，而且两端 schema 版本不同时
  /// 换文件会直接把库读坏。
  static Future<Map<String, dynamic>> exportSnapshot() async {
    final result = <String, dynamic>{
      'version': 1,
      'exportedAt': DateTime.now().millisecondsSinceEpoch,
    };
    try {
      final db = await AppDatabase.importantDatabase();
      final totals = await db.query('play_totals', where: 'id = 1', limit: 1);
      if (totals.isNotEmpty) {
        result['totals'] = {
          'listenedMs': totals.first['total_listened_ms'] ?? 0,
          'plays': totals.first['total_plays'] ?? 0,
          'updatedAt': totals.first['updated_at'] ?? 0,
        };
      }
      result['daily'] = [
        for (final row in await db.query('play_daily'))
          {
            'day': row['day'],
            'listenedMs': row['listened_ms'] ?? 0,
            'plays': row['plays'] ?? 0,
          },
      ];
      result['songs'] = [
        for (final row in await db.query('song_play_stats'))
          {
            'songId': row['song_id'],
            'playCount': row['play_count'] ?? 0,
            'listenedMs': row['listened_ms'] ?? 0,
            'lastPlayedAt': row['last_played_at'] ?? 0,
            'data': row['data'] ?? '{}',
          },
      ];
      result['progress'] = [
        for (final row in await db.query('song_play_progress'))
          {
            'songId': row['song_id'],
            'ratio': row['ratio'] ?? 0,
            'positionMs': row['position_ms'] ?? 0,
            'durationMs': row['duration_ms'] ?? 0,
            'updatedAt': row['updated_at'] ?? 0,
          },
      ];
    } catch (e) {
      debugPrint('[PlayStats] 导出听歌数据失败: $e');
    }
    return result;
  }

  /// 用备份里的快照覆盖本机的听歌数据（累计 / 按天 / 每首歌 / 已听进度）。
  static Future<void> importSnapshot(Map<String, dynamic> snapshot) async {
    if (snapshot.isEmpty) return;
    final daily = _listOfMaps(snapshot['daily']);
    final songs = _listOfMaps(snapshot['songs']);
    final progress = _listOfMaps(snapshot['progress']);
    final totals = snapshot['totals'];
    try {
      final db = await AppDatabase.importantDatabase();
      await db.transaction((txn) async {
        await txn.delete('song_play_stats');
        await txn.delete('play_daily');
        await txn.delete('song_play_progress');
        for (final row in songs) {
          final songId = '${row['songId'] ?? ''}';
          if (songId.isEmpty) continue;
          await txn.insert('song_play_stats', {
            'song_id': songId,
            'play_count': (row['playCount'] as num?)?.toInt() ?? 0,
            'listened_ms': (row['listenedMs'] as num?)?.toInt() ?? 0,
            'last_played_at': (row['lastPlayedAt'] as num?)?.toInt() ?? 0,
            'data': '${row['data'] ?? '{}'}',
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        for (final row in daily) {
          final day = '${row['day'] ?? ''}';
          if (day.isEmpty) continue;
          await txn.insert('play_daily', {
            'day': day,
            'listened_ms': (row['listenedMs'] as num?)?.toInt() ?? 0,
            'plays': (row['plays'] as num?)?.toInt() ?? 0,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        for (final row in progress) {
          final songId = '${row['songId'] ?? ''}';
          if (songId.isEmpty) continue;
          await txn.insert('song_play_progress', {
            'song_id': songId,
            'ratio': (row['ratio'] as num?)?.toDouble() ?? 0,
            'position_ms': (row['positionMs'] as num?)?.toInt() ?? 0,
            'duration_ms': (row['durationMs'] as num?)?.toInt() ?? 0,
            'updated_at': (row['updatedAt'] as num?)?.toInt() ?? 0,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        final listenedMs = totals is Map
            ? (totals['listenedMs'] as num?)?.toInt() ?? 0
            : daily.fold<int>(
                0,
                (sum, row) => sum + ((row['listenedMs'] as num?)?.toInt() ?? 0),
              );
        final plays = totals is Map
            ? (totals['plays'] as num?)?.toInt() ?? 0
            : daily.fold<int>(
                0,
                (sum, row) => sum + ((row['plays'] as num?)?.toInt() ?? 0),
              );
        await txn.rawUpdate(
          'UPDATE play_totals SET total_listened_ms = ?, total_plays = ?, '
          'updated_at = ? WHERE id = 1',
          [listenedMs, plays, DateTime.now().millisecondsSinceEpoch],
        );
      });
      await AppDatabase.checkpointImportant();
      debugPrint(
        '[PlayStats] 已还原 ${songs.length} 首歌的统计 / '
        '${daily.length} 天记录 / ${progress.length} 条进度',
      );
    } catch (e) {
      debugPrint('[PlayStats] 还原听歌数据失败: $e');
    }
  }

  static List<Map<String, dynamic>> _listOfMaps(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) item.map((key, value) => MapEntry('$key', value)),
    ];
  }

  // ---------------------------------------------------------------- 工具

  /// 本地时区的日期键（`yyyy-MM-dd`，不补零，和旧统计的轴标签一致）。
  static String _dayKey(DateTime time) =>
      '${time.year}-${time.month}-${time.day}';

  static DateTime? _parseDayKey(String key) {
    final parts = key.split('-');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    return DateTime(year, month, day);
  }

  /// 生成时间轴（从早到晚，没有播放的区间也占一个空柱），再把每天的累计值
  /// 折进对应粒度。
  List<PlaybackStatBucket> _buildBuckets(
    Map<String, ({int ms, int plays})> daily,
    PlaybackStatsGranularity granularity,
  ) {
    final now = DateTime.now();
    final buckets = <String, ({String label, int ms, int plays})>{};
    final keys = <String>[];

    void addKey(String key, String label) {
      keys.add(key);
      buckets[key] = (label: label, ms: 0, plays: 0);
    }

    switch (granularity) {
      case PlaybackStatsGranularity.day:
        for (var i = 6; i >= 0; i--) {
          final d = DateTime(
            now.year,
            now.month,
            now.day,
          ).subtract(Duration(days: i));
          addKey(_dayKey(d), '${d.month}/${d.day}');
        }
      case PlaybackStatsGranularity.week:
        final thisMonday = DateTime(
          now.year,
          now.month,
          now.day,
        ).subtract(Duration(days: now.weekday - 1));
        for (var i = 7; i >= 0; i--) {
          final d = thisMonday.subtract(Duration(days: i * 7));
          addKey(_dayKey(d), '${d.month}/${d.day}');
        }
      case PlaybackStatsGranularity.month:
        for (var i = 5; i >= 0; i--) {
          final m = DateTime(now.year, now.month - i, 1);
          addKey('${m.year}-${m.month}', '${m.month}月');
        }
      case PlaybackStatsGranularity.year:
        for (var i = 4; i >= 0; i--) {
          addKey('${now.year - i}', '${now.year - i}');
        }
    }

    daily.forEach((dayKey, value) {
      final date = _parseDayKey(dayKey);
      if (date == null) return;
      final String key;
      switch (granularity) {
        case PlaybackStatsGranularity.day:
          key = dayKey;
        case PlaybackStatsGranularity.week:
          final monday = date.subtract(Duration(days: date.weekday - 1));
          key = _dayKey(monday);
        case PlaybackStatsGranularity.month:
          key = '${date.year}-${date.month}';
        case PlaybackStatsGranularity.year:
          key = '${date.year}';
      }
      final bucket = buckets[key];
      if (bucket == null) return;
      buckets[key] = (
        label: bucket.label,
        ms: bucket.ms + value.ms,
        plays: bucket.plays + value.plays,
      );
    });

    return [
      for (final key in keys)
        PlaybackStatBucket(
          label: buckets[key]!.label,
          listenedMs: buckets[key]!.ms,
          plays: buckets[key]!.plays,
        ),
    ];
  }
}
