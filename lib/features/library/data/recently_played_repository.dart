import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../../core/storage/app_database.dart';
import '../../../core/storage/app_preferences.dart';
import '../domain/models/recently_played.dart';
import 'play_stats_store.dart';
import '../../player/domain/models/song.dart';

/// 最近播放 / 播放统计的本地存储。
///
/// **最近听过的歌 / 打开过的歌单**：数据量大、变动频繁，丢了也能重新积累，
/// 放在「临时库」（Windows：`AppData\temp\db\mintmusic_cache.db`）。
///
/// **听歌统计与排行**（听了多久、听了几次、每天听多久、排行、听到哪）：属于
/// 用户长期积累的数据，放在「重要库」（`AppData\db\mintmusic.db`），由
/// [PlayStatsStore] 负责，这里只做转发。
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

  static const String _legacyKey = 'recently_played';

  /// 听歌统计 / 排行（重要库）。
  final PlayStatsStore _stats = PlayStatsStore();

  List<RecentlyPlayedItem>? _cache;
  List<RecentlyPlayedPlaylist>? _playlistsCache;

  /// 待写入的歌曲（song_id → 最新记录）。
  final Map<String, RecentlyPlayedItem> _pendingSongs = {};

  /// 待写入的歌单（id → 最新记录）。
  final Map<String, RecentlyPlayedPlaylist> _pendingPlaylists = {};

  /// 攒批写盘器：定时器兜底 + 应用切后台/退出时 flush。
  late final DeferredWriter _writer = DeferredWriter(
    _flushPending,
    interval: const Duration(seconds: 15),
  );

  int get _pendingCount => _pendingSongs.length + _pendingPlaylists.length;

  /// 最近播放的保留窗口（年）。超过这个时间没再听 / 没再打开就清掉，
  /// 免得「最近播放」越攒越长、看着也不像「最近」。
  static const int keepYears = 1;

  /// 本次运行最近一次清理的日期（`yyyy-MM-dd`），一天最多清一次。
  String? _prunedDay;

  // ---------------------------------------------------------------- 读取

  Future<List<RecentlyPlayedItem>> loadHistory() async {
    // 已经在内存里了就直接用：待写数据还没落盘时，数据库里是旧数据。
    final cached = _cache;
    if (cached != null) return cached;

    await _pruneIfDue();

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

    await _pruneIfDue();

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

  // ---------------------------------------------------------------- 清理

  Future<void> _pruneIfDue() async {
    final now = DateTime.now();
    final today = '${now.year}-${now.month}-${now.day}';
    if (_prunedDay == today) return;
    _prunedDay = today;
    await pruneOldEntries();
  }

  /// 清掉一年以上没再听过的歌、没再打开过的歌单（一天最多一次）。
  ///
  /// 「最近播放」只保留近一年：既控制表的大小，也免得列表里全是去年的歌。
  /// 这里只删临时库里的浏览记录，听歌统计 / 排行在重要库、不受影响。
  Future<void> pruneOldEntries({DateTime? now}) async {
    final current = now ?? DateTime.now();
    final cutoff = DateTime(
      current.year - keepYears,
      current.month,
      current.day,
    ).millisecondsSinceEpoch;
    try {
      final db = await AppDatabase.cacheDatabase();
      final songs = await db.delete(
        'recently_played',
        where: 'played_at < ?',
        whereArgs: [cutoff],
      );
      final playlists = await db.delete(
        'recently_played_playlists',
        where: 'opened_at < ?',
        whereArgs: [cutoff],
      );
      if (songs > 0 || playlists > 0) {
        debugPrint(
          '[RecentlyPlayed] 已清理 $songs 条一年前的播放记录 / '
          '$playlists 个一年前的歌单',
        );
      }
    } catch (e) {
      debugPrint('[RecentlyPlayed] 清理一年前的记录失败: $e');
    }
  }

  /// 听歌统计（累计总时长 / 次数 / 听过的歌 / 按粒度聚合的柱状数据）。
  Future<PlaybackStats> loadStats({
    PlaybackStatsGranularity granularity = PlaybackStatsGranularity.day,
  }) {
    return _stats.loadStats(granularity: granularity);
  }

  /// 听歌排行（重要库里的全量历史，不受最近播放 500 首上限限制）。
  Future<List<RecentlyPlayedItem>> loadRanking() => _stats.loadRanking();

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
    // 听歌次数 / 排行记在重要库（临时库这份只是「最近听过」列表）。
    _stats.recordPlay(item);
    await _afterChange();
  }

  /// 记录一段收听时长（切歌 / 退出时结算）。
  Future<void> recordListen({
    required String songId,
    required int listenedMs,
  }) async {
    if (songId.isEmpty || listenedMs <= 0) return;
    // 直接交给重要库的累计器：总时长 / 每天时长 / 每首歌时长都在那儿合并，
    // 不再按「每次播放一条」存明细（那会有几万行，还得全表扫着聚合）。
    _stats.recordListen(songId: songId, listenedMs: listenedMs);
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

  /// 清空全部最近播放数据。
  ///
  /// 最近听过的歌 / 歌单在临时库，听歌统计在重要库，两个库都要清
  /// （用户点「清除」时要的是把这几类数据一起抹掉）。
  Future<void> clearAll() async {
    _cache = <RecentlyPlayedItem>[];
    _playlistsCache = <RecentlyPlayedPlaylist>[];
    _pendingSongs.clear();
    _pendingPlaylists.clear();
    try {
      final db = await AppDatabase.cacheDatabase();
      await db.transaction((txn) async {
        await txn.delete('recently_played');
        await txn.delete('recently_played_playlists');
      });
      await AppDatabase.checkpoint();
    } catch (e) {
      debugPrint('[RecentlyPlayed] 清空失败: $e');
    }
    await _stats.clear();
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
  Future<void> flush() async {
    await _writer.writeNow();
    await _stats.flush();
  }

  /// 把攒下的变化一次性写入数据库。
  Future<void> _flushPending() async {
    if (_pendingCount == 0) return;
    final songs = List<RecentlyPlayedItem>.of(_pendingSongs.values);
    final playlists = List<RecentlyPlayedPlaylist>.of(_pendingPlaylists.values);
    _pendingSongs.clear();
    _pendingPlaylists.clear();

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
