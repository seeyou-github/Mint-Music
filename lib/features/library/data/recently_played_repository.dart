import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../../core/storage/app_database.dart';
import '../../../core/storage/app_preferences.dart';
import '../domain/models/recently_played.dart';
import '../../player/domain/models/song.dart';

/// 最近播放 / 播放统计的本地存储。
///
/// 数据量大、变动频繁（每次播放都会变），丢了也无所谓，因此放在「临时库」
/// （Windows：`AppData\temp\db\mintmusic_cache.db`）。
///
/// **写盘策略**：运行期只改内存，并把变化攒在待写队列里；攒够 [batchSize]
/// 条（默认 10）才真正写一次数据库。不足 10 条时由 [DeferredWriter] 的
/// 定时器兜底，应用切后台 / 退出时统一 flush。写库后**不做** checkpoint
/// （TRUNCATE 要等所有读者并整段回写 WAL，播放期间每 15 秒一次太重）；
/// 退出时 [AppDatabase.checkpoint] 会统一兜底，进程被杀也不影响
/// 已提交的事务（WAL 仍在，下次打开自动恢复）。
class RecentlyPlayedRepository {
  RecentlyPlayedRepository() {
    AppDatabase.registerWriter(_writer);
  }

  /// 攒够多少条变化才写库。
  static const int batchSize = 10;

  /// 最多保留多少首最近播放。
  static const int maxItems = 500;

  /// 最多保留多少条播放事件（统计用）。
  static const int maxEvents = 20000;

  static const String _legacyKey = 'recently_played';

  List<RecentlyPlayedItem>? _cache;
  List<RecentlyPlayedPlaylist>? _playlistsCache;

  /// 待写入的歌曲（song_id → 最新记录）。
  final Map<String, RecentlyPlayedItem> _pendingSongs = {};

  /// 待写入的歌单（id → 最新记录）。
  final Map<String, RecentlyPlayedPlaylist> _pendingPlaylists = {};

  /// 待写入的播放事件。
  final List<Map<String, Object?>> _pendingEvents = [];

  /// 攒批写盘器：定时器兜底 + 应用切后台/退出时 flush。
  late final DeferredWriter _writer = DeferredWriter(
    _flushPending,
    interval: const Duration(seconds: 15),
  );

  int get _pendingCount =>
      _pendingSongs.length + _pendingPlaylists.length + _pendingEvents.length;

  // ---------------------------------------------------------------- 读取

  Future<List<RecentlyPlayedItem>> loadHistory() async {
    // 已经在内存里了就直接用：待写数据还没落盘时，数据库里是旧数据。
    final cached = _cache;
    if (cached != null) return cached;

    final history = <RecentlyPlayedItem>[];
    try {
      final db = await AppDatabase.cacheDatabase();
      final rows = await db.query(
        'recently_played',
        orderBy: 'played_at DESC',
        limit: maxItems,
      );
      for (final row in rows) {
        final data = AppDatabase.decodeMap(row['data']);
        if (data.isEmpty) continue;
        try {
          history.add(RecentlyPlayedItem.fromJson(data));
        } catch (_) {
          // 单条数据损坏就跳过，不影响其它记录
        }
      }
    } catch (e) {
      debugPrint('[RecentlyPlayed] 读取最近播放失败: $e');
    }

    if (history.isEmpty && !await AppDatabase.isMigrated('recently_played')) {
      final legacy = await _importLegacy();
      if (legacy.isNotEmpty) {
        history.addAll(legacy);
      }
      if (AppDatabase.isPersistent) {
        await AppDatabase.markMigrated('recently_played');
      }
    }

    _cache = history;
    return history;
  }

  Future<List<RecentlyPlayedPlaylist>> loadPlaylists() async {
    final cached = _playlistsCache;
    if (cached != null) return cached;

    final playlists = <RecentlyPlayedPlaylist>[];
    try {
      final db = await AppDatabase.cacheDatabase();
      final rows = await db.query(
        'recently_played_playlists',
        orderBy: 'opened_at DESC',
        limit: 200,
      );
      for (final row in rows) {
        final data = AppDatabase.decodeMap(row['data']);
        if (data.isEmpty) continue;
        try {
          playlists.add(RecentlyPlayedPlaylist.fromJson(data));
        } catch (_) {
          // 忽略损坏记录
        }
      }
    } catch (e) {
      debugPrint('[RecentlyPlayed] 读取最近歌单失败: $e');
    }
    _playlistsCache = playlists;
    return playlists;
  }

  /// 听歌统计。数据量不大（几千条事件），直接读出来在内存里聚合。
  Future<PlaybackStats> loadStats({
    PlaybackStatsGranularity granularity = PlaybackStatsGranularity.day,
  }) async {
    final events = <({DateTime at, int listenedMs})>[];
    final songIds = <String>{};
    try {
      final db = await AppDatabase.cacheDatabase();
      final rows = await db.query(
        'play_events',
        columns: ['song_id', 'played_at', 'listened_ms'],
        orderBy: 'played_at ASC',
      );
      for (final row in rows) {
        final songId = '${row['song_id'] ?? ''}';
        if (songId.isNotEmpty) songIds.add(songId);
        events.add((
          at: DateTime.fromMillisecondsSinceEpoch(
            (row['played_at'] as num?)?.toInt() ?? 0,
          ),
          listenedMs: (row['listened_ms'] as num?)?.toInt() ?? 0,
        ));
      }
    } catch (e) {
      debugPrint('[RecentlyPlayed] 读取播放事件失败: $e');
    }

    // 还没落盘的播放事件也要算进去：刚听完歌就打开「统计」时，
    // 数据库里可能还是旧的（攒批写盘有 15 秒窗口）。
    for (final event in List<Map<String, Object?>>.of(_pendingEvents)) {
      final listenedMs = (event['listened_ms'] as num?)?.toInt() ?? 0;
      if (listenedMs <= 0) continue;
      final songId = '${event['song_id'] ?? ''}';
      if (songId.isNotEmpty) songIds.add(songId);
      events.add((
        at: DateTime.fromMillisecondsSinceEpoch(
          (event['played_at'] as num?)?.toInt() ?? 0,
        ),
        listenedMs: listenedMs,
      ));
    }

    var totalMs = 0;
    for (final event in events) {
      totalMs += event.listenedMs;
    }

    return PlaybackStats(
      totalListenedMs: totalMs,
      totalPlays: events.length,
      songCount: songIds.length,
      buckets: _buildBuckets(events, granularity),
    );
  }

  List<PlaybackStatBucket> _buildBuckets(
    List<({DateTime at, int listenedMs})> events,
    PlaybackStatsGranularity granularity,
  ) {
    final now = DateTime.now();
    final buckets = <String, ({String label, int ms, int plays})>{};
    final keys = <String>[];

    void addKey(String key, String label) {
      keys.add(key);
      buckets[key] = (label: label, ms: 0, plays: 0);
    }

    // 生成时间轴（从早到晚），保证没有播放的区间也占一个空柱。
    switch (granularity) {
      case PlaybackStatsGranularity.day:
        for (var i = 6; i >= 0; i--) {
          final d = DateTime(
            now.year,
            now.month,
            now.day,
          ).subtract(Duration(days: i));
          addKey('${d.year}-${d.month}-${d.day}', '${d.month}/${d.day}');
        }
      case PlaybackStatsGranularity.week:
        final thisMonday = DateTime(
          now.year,
          now.month,
          now.day,
        ).subtract(Duration(days: now.weekday - 1));
        for (var i = 7; i >= 0; i--) {
          final d = thisMonday.subtract(Duration(days: i * 7));
          addKey('${d.year}-${d.month}-${d.day}', '${d.month}/${d.day}');
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

    for (final event in events) {
      final d = event.at;
      final String key;
      switch (granularity) {
        case PlaybackStatsGranularity.day:
          key = '${d.year}-${d.month}-${d.day}';
        case PlaybackStatsGranularity.week:
          final monday = DateTime(
            d.year,
            d.month,
            d.day,
          ).subtract(Duration(days: d.weekday - 1));
          key = '${monday.year}-${monday.month}-${monday.day}';
        case PlaybackStatsGranularity.month:
          key = '${d.year}-${d.month}';
        case PlaybackStatsGranularity.year:
          key = '${d.year}';
      }
      final bucket = buckets[key];
      if (bucket == null) continue;
      buckets[key] = (
        label: bucket.label,
        ms: bucket.ms + event.listenedMs,
        plays: bucket.plays + 1,
      );
    }

    return [
      for (final key in keys)
        PlaybackStatBucket(
          label: buckets[key]!.label,
          listenedMs: buckets[key]!.ms,
          plays: buckets[key]!.plays,
        ),
    ];
  }

  // ---------------------------------------------------------------- 写入

  /// 记录一次播放（同一首歌合并为一条，次数累加、时间刷新）。
  Future<void> recordPlay(
    Song song, {
    PlaybackSourceType sourceType = PlaybackSourceType.unknown,
    String? sourceId,
    String? sourceName,
    Map<String, dynamic>? sourceMeta,
  }) async {
    final history = await loadHistory();
    final index = history.indexWhere((item) => item.song.id == song.id);
    final now = DateTime.now();

    final RecentlyPlayedItem item;
    if (index != -1) {
      final existing = history.removeAt(index);
      item = existing.copyWith(
        song: song,
        playedAt: now,
        playCount: existing.playCount + 1,
        sourceType: sourceType,
        sourceId: sourceId,
        sourceName: sourceName,
        sourceMeta: sourceMeta,
        clearSourceMeta: sourceMeta == null,
      );
    } else {
      item = RecentlyPlayedItem(
        song: song,
        playedAt: now,
        sourceType: sourceType,
        sourceId: sourceId,
        sourceName: sourceName,
        sourceMeta: sourceMeta,
      );
    }
    history.insert(0, item);
    if (history.length > maxItems) {
      history.removeRange(maxItems, history.length);
    }
    _cache = history;

    _pendingSongs[song.id] = item;
    await _afterChange();
  }

  /// 记录一段收听时长（切歌 / 退出时结算）。
  Future<void> recordListen({
    required String songId,
    required int listenedMs,
    required int durationMs,
  }) async {
    if (songId.isEmpty || listenedMs <= 0) return;
    _pendingEvents.add({
      'song_id': songId,
      'played_at': DateTime.now().millisecondsSinceEpoch,
      'listened_ms': listenedMs,
      'duration_ms': durationMs,
    });
    if (_pendingEvents.length > maxEvents) {
      _pendingEvents.removeRange(0, _pendingEvents.length - maxEvents);
    }
    await _afterChange();
  }

  /// 记录一次「打开歌单」。
  Future<void> recordPlaylistOpened({
    required String id,
    required String name,
    String coverUrl = '',
    int songCount = 0,
    String source = '',
    PlaybackSourceType? collectionType,
  }) async {
    if (id.isEmpty || name.isEmpty) return;
    final playlists = await loadPlaylists();
    playlists.removeWhere((p) => p.id == id);
    final item = RecentlyPlayedPlaylist(
      id: id,
      name: name,
      openedAt: DateTime.now(),
      coverUrl: coverUrl,
      songCount: songCount,
      source: source,
      collectionType: collectionType,
    );
    playlists.insert(0, item);
    if (playlists.length > 200) {
      playlists.removeRange(200, playlists.length);
    }
    _playlistsCache = playlists;

    _pendingPlaylists[id] = item;
    await _afterChange();
  }

  /// 攒够一批就立即写库，否则交给定时器兜底。
  Future<void> _afterChange() async {
    if (_pendingCount >= batchSize) {
      await _writer.writeNow();
    } else {
      _writer.schedule();
    }
  }

  /// 清空全部最近播放数据（歌曲 / 歌单 / 统计）。
  Future<void> clearAll() async {
    _cache = <RecentlyPlayedItem>[];
    _playlistsCache = <RecentlyPlayedPlaylist>[];
    _pendingSongs.clear();
    _pendingPlaylists.clear();
    _pendingEvents.clear();
    try {
      final db = await AppDatabase.cacheDatabase();
      await db.transaction((txn) async {
        await txn.delete('recently_played');
        await txn.delete('recently_played_playlists');
        await txn.delete('play_events');
      });
      await AppDatabase.checkpoint();
    } catch (e) {
      debugPrint('[RecentlyPlayed] 清空失败: $e');
    }
  }

  /// 删除一首歌的记录。
  Future<void> removeFromHistory(String songId) async {
    final history = await loadHistory();
    history.removeWhere((item) => item.song.id == songId);
    _cache = history;
    _pendingSongs.remove(songId);
    try {
      final db = await AppDatabase.cacheDatabase();
      await db.delete(
        'recently_played',
        where: 'song_id = ?',
        whereArgs: [songId],
      );
    } catch (e) {
      debugPrint('[RecentlyPlayed] 删除记录失败: $e');
    }
  }

  /// 立即落盘（应用切后台 / 退出时由 [AppDatabase.flushAll] 调用）。
  Future<void> flush() => _writer.writeNow();

  /// 把攒下的变化一次性写入数据库。
  Future<void> _flushPending() async {
    if (_pendingCount == 0) return;
    final songs = List<RecentlyPlayedItem>.of(_pendingSongs.values);
    final playlists = List<RecentlyPlayedPlaylist>.of(_pendingPlaylists.values);
    final events = List<Map<String, Object?>>.of(_pendingEvents);
    _pendingSongs.clear();
    _pendingPlaylists.clear();
    _pendingEvents.clear();

    try {
      final db = await AppDatabase.cacheDatabase();
      await db.transaction((txn) async {
        for (final item in songs) {
          await txn.insert('recently_played', {
            'song_id': item.song.id,
            'played_at': item.playedAt.millisecondsSinceEpoch,
            'play_count': item.playCount,
            'data': jsonEncode(item.toPersistJson()),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        for (final item in playlists) {
          await txn.insert(
            'recently_played_playlists',
            {
              'id': item.id,
              'name': item.name,
              'cover_url': item.coverUrl,
              'song_count': item.songCount,
              'source': item.source,
              'opened_at': item.openedAt.millisecondsSinceEpoch,
              'data': jsonEncode(item.toJson()),
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        for (final event in events) {
          await txn.insert('play_events', event);
        }
      });
    } catch (e) {
      debugPrint('[RecentlyPlayed] 写库失败: $e');
      // 写失败就把数据放回队列，下次再试（内存里仍是最新的）。
      for (final item in songs) {
        _pendingSongs[item.song.id] = item;
      }
      for (final item in playlists) {
        _pendingPlaylists[item.id] = item;
      }
      _pendingEvents.insertAll(0, events);
    }
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
            (e) => RecentlyPlayedItem.fromJson(
              (e as Map).map((k, v) => MapEntry('$k', v)),
            ),
          ),
        );
      }
      if (history.isNotEmpty) {
        _cache = history;
        for (final item in history) {
          _pendingSongs[item.song.id] = item;
        }
        await _writer.writeNow();
        await AppDatabase.removeLegacyKey(_legacyKey);
        debugPrint('[RecentlyPlayed] 已从旧设置迁移 ${history.length} 条记录');
      }
    } catch (e) {
      debugPrint('[RecentlyPlayed] 迁移旧记录失败: $e');
    }
    return history;
  }
}
