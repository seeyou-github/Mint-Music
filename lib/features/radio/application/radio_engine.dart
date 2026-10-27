import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../discover/domain/models/leaderboard.dart';
import '../../discover/domain/models/playlist.dart';
import '../../player/domain/models/song.dart';
import '../../plugin/application/music_source_manager.dart';
import '../data/radio_page_limits.dart';
import '../domain/models/radio_station.dart';

/// 电台取歌失败（没有可用音源 / 随机不到歌单等），带一句能直接显示的说明。
class RadioException implements Exception {
  const RadioException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 电台歌曲所属的歌单：播放页「更多」里据此显示来源并跳转。
class RadioPlaylistRef {
  const RadioPlaylistRef({required this.id, this.source, this.title});

  final String id;
  final String? source;
  final String? title;
}

/// 一次随机取到的歌，附带「这些歌来自哪个歌单」，便于随机电台继续从同一个
/// 歌单补歌。
class RadioBatch {
  const RadioBatch({
    required this.songs,
    this.playlistId,
    this.playlistSource,
    this.playlistTitle,
    this.songPlaylists = const {},
  });

  final List<Song> songs;
  final String? playlistId;
  final String? playlistSource;
  final String? playlistTitle;

  /// 每首歌各自来自哪个歌单：随机电台一次可能跨多个歌单，不能只看
  /// [playlistId]。
  final Map<String, RadioPlaylistRef> songPlaylists;

  bool get isEmpty => songs.isEmpty;
}

/// 电台取歌引擎：负责「随机音源 → 随机分类/关键词 → 随机页 → 随机歌单 →
/// 随机歌曲」，并过滤掉黑名单里的歌。
class RadioEngine {
  RadioEngine({required this.manager, required this.isBlocked});

  final MusicSourceManager manager;
  final bool Function(Song song) isBlocked;

  final Random _random = Random();

  /// 电台里实际可用的音源。
  ///
  /// * [configured] 为空：用 [fallback]（一般是发现页当前音源）；
  /// * 配了但被关闭 / 卸载：只能用剩下那些，全都不可用就返回空，由调用方
  ///   弹错误提示（不偷偷换成没配置的音源）。
  List<String> usableSources({
    required List<String> configured,
    List<String> fallback = const [],
  }) {
    final available = manager
        .getDiscoverSupportedSources()
        .map((source) => source.id)
        .toSet();
    final candidates = configured.isEmpty ? fallback : configured;
    final usable = <String>[];
    for (final id in candidates) {
      if (available.contains(id) && !usable.contains(id)) usable.add(id);
    }
    return usable;
  }

  T _pick<T>(List<T> items) => items[_random.nextInt(items.length)];

  /// 电台取一批歌（至少 [minCount] 首，拿不到就返回现有的）。
  Future<RadioBatch> nextBatch({
    required List<String> sourceIds,
    required List<RadioTagRef> tags,
    required List<String> keywords,
    int minCount = 20,
    String? preferPlaylistId,
    String? preferPlaylistSource,
    Set<String> excludeIds = const <String>{},
  }) async {
    if (sourceIds.isEmpty) {
      throw const RadioException('没有可用的音源，请检查电台的音源设置');
    }
    final usable = tags
        .where((tag) => sourceIds.contains(tag.sourceId))
        .toList(growable: false);
    final hasTags = usable.isNotEmpty;
    final hasKeywords = keywords.isNotEmpty;
    if (!hasTags && !hasKeywords) {
      throw const RadioException('这个电台还没有设置歌单分类或搜索关键词');
    }

    // 上一次的歌单还能用就先用它（随机电台补歌时更像「正在听一个歌单」）。
    if (preferPlaylistId != null && preferPlaylistId.isNotEmpty) {
      final batch = await _songsFromPlaylist(
        preferPlaylistId,
        source: preferPlaylistSource,
        minCount: minCount,
        excludeIds: excludeIds,
      );
      if (!batch.isEmpty) return batch;
    }

    // 两种来源都配了：随机挑一种。
    final useTags = hasTags && (!hasKeywords || _random.nextBool());

    if (useTags) {
      final tag = _pick(usable);
      final playlist = await _randomPlaylistFromTags(tag);
      if (playlist != null) {
        final batch = await _songsFromPlaylist(
          playlist.id,
          minCount: minCount,
          excludeIds: excludeIds,
        );
        if (!batch.isEmpty) {
          final ref = RadioPlaylistRef(
            id: playlist.id,
            source: playlist.source,
            title: playlist.title,
          );
          return RadioBatch(
            songs: batch.songs,
            playlistId: playlist.id,
            playlistSource: playlist.source,
            playlistTitle: playlist.title,
            songPlaylists: {for (final song in batch.songs) song.id: ref},
          );
        }
      }
      // 分类取不到歌：如果还配了关键词，改用关键词再试一次。
      if (!hasKeywords) {
        throw const RadioException('随机不到可播放的歌曲，换个分类或音源试试');
      }
    }

    return _batchFromKeywords(
      sourceIds: sourceIds,
      keywords: keywords,
      minCount: minCount,
      excludeIds: excludeIds,
    );
  }

  /// 随机电台：在指定音源里随机分类 / 随机页 / 随机歌单取歌。
  ///
  /// 每个歌单只取 [songsPerPlaylist] 首（默认 3），然后换下一个随机歌单，
  /// 一直凑到 [minCount] 首，尽量保证「越随机越好」。
  Future<RadioBatch> randomSongs({
    required String sourceId,
    int minCount = 20,
    int songsPerPlaylist = 3,
    Set<String> excludeIds = const <String>{},
  }) async {
    // 随机一个分类（拿不到分类就用「热门」）。
    List<PlaylistTag> tags = const [];
    try {
      final groups = await manager.getPlaylistTags(sourceId: sourceId);
      tags = [for (final group in groups) ...group.tags];
    } catch (e) {
      debugPrint('[RadioEngine] 取分类失败: $e');
    }
    final candidates = tags
        .where((t) => t.id.isNotEmpty)
        .toList(growable: false);

    final collected = <String, Song>{};
    final songPlaylists = <String, RadioPlaylistRef>{};
    final triedPlaylists = <String>{};
    String? lastPlaylistId;
    String? lastPlaylistSource;
    String? lastPlaylistTitle;

    // 最多换这么多个歌单，避免一直随机不到就无限请求。
    final maxPlaylists = (minCount / songsPerPlaylist).ceil() + 6;
    var attempts = 0;
    while (collected.length < minCount && attempts < maxPlaylists) {
      attempts++;
      final tag = candidates.isEmpty ? null : _pick(candidates);
      final playlists = await _randomCategoryPlaylists(
        sourceId: sourceId,
        tagId: tag?.id ?? '',
      );
      if (playlists.isEmpty) break;
      // 同一轮里不重复用同一个歌单。
      final pool = playlists
          .where((p) => !triedPlaylists.contains(p.id))
          .toList(growable: false);
      if (pool.isEmpty) break;
      final playlist = _pick(pool);
      triedPlaylists.add(playlist.id);

      final batch = await _songsFromPlaylist(
        playlist.id,
        minCount: songsPerPlaylist,
        excludeIds: {...excludeIds, ...collected.keys},
      );
      if (batch.isEmpty) continue;
      final ref = RadioPlaylistRef(
        id: playlist.id,
        source: playlist.source,
        title: playlist.title,
      );
      for (final song in batch.songs) {
        if (collected.containsKey(song.id)) continue;
        collected[song.id] = song;
        songPlaylists[song.id] = ref;
      }
      lastPlaylistId = playlist.id;
      lastPlaylistSource = playlist.source;
      lastPlaylistTitle = playlist.title;
    }

    if (collected.isEmpty) {
      throw const RadioException('随机不到可播放的歌曲，请稍后重试');
    }
    final songs = collected.values.toList(growable: false);
    final shuffled = [...songs]..shuffle(_random);
    final take = shuffled.length > minCount ? minCount : shuffled.length;
    final selected = shuffled.take(take).toList(growable: false);
    return RadioBatch(
      songs: selected,
      playlistId: lastPlaylistId,
      playlistSource: lastPlaylistSource,
      playlistTitle: lastPlaylistTitle,
      songPlaylists: {
        for (final song in selected)
          if (songPlaylists[song.id] != null) song.id: songPlaylists[song.id]!,
      },
    );
  }

  /// 分类页：随机取一页，取不到就按规则往回缩。
  Future<List<Playlist>> _randomCategoryPlaylists({
    required String sourceId,
    required String tagId,
  }) {
    return _randomPagePlaylists(
      cacheKey: 'tag:$sourceId:$tagId',
      fetch: (page) async {
        final result = await manager.getCategoryPlaylists(
          sortId: 'hot',
          tagId: tagId,
          page: page,
          limit: 30,
          sourceId: sourceId,
        );
        return result.items;
      },
    );
  }

  Future<List<Playlist>> _randomPagePlaylists({
    required String cacheKey,
    required Future<List<Playlist>> Function(int page) fetch,
  }) async {
    // 随机页：上限记忆在设置文件里（按音源 + 分类 / 关键词区分）。
    await RadioPageLimits.ensureLoaded();
    final limit = RadioPageLimits.limitFor(cacheKey);
    var page = 1 + _random.nextInt(limit < 1 ? 1 : limit);
    var shrunk = false;
    while (page >= 1) {
      try {
        final playlists = await fetch(page);
        if (playlists.isNotEmpty) {
          // 这次是缩回来的页：把它记成新的上限（只减不增），下次直接从这之内随机。
          if (shrunk) unawaited(RadioPageLimits.record(cacheKey, page));
          return playlists;
        }
      } catch (e) {
        debugPrint('[RadioEngine] 第 $page 页取歌单失败: $e');
      }
      shrunk = true;
      page = nextPageAfterEmpty(page);
    }
    return const [];
  }

  Future<Playlist?> _randomPlaylistFromTags(RadioTagRef tag) async {
    final playlists = await _randomCategoryPlaylists(
      sourceId: tag.sourceId,
      tagId: tag.tagId,
    );
    if (playlists.isEmpty) return null;
    return _pick(playlists);
  }

  Future<RadioBatch> _batchFromKeywords({
    required List<String> sourceIds,
    required List<String> keywords,
    required int minCount,
    Set<String> excludeIds = const <String>{},
  }) async {
    // 关键词顺序也随机，避免每次都从第一个词开始。
    final shuffled = [...keywords]..shuffle(_random);
    for (final keyword in shuffled) {
      final sourceId = _pick(sourceIds);
      final playlists = await _searchPlaylists(sourceId, keyword);
      if (playlists.isEmpty) continue;
      for (final playlist in ([...playlists]..shuffle(_random))) {
        final batch = await _songsFromPlaylist(playlist.id, minCount: minCount);
        if (!batch.isEmpty) {
          final ref = RadioPlaylistRef(
            id: playlist.id,
            source: playlist.source,
            title: playlist.title,
          );
          return RadioBatch(
            songs: batch.songs,
            playlistId: playlist.id,
            playlistSource: playlist.source,
            playlistTitle: playlist.title,
            songPlaylists: {for (final song in batch.songs) song.id: ref},
          );
        }
      }
    }
    throw const RadioException('按关键词随机不到可播放的歌曲');
  }

  Future<List<Playlist>> _searchPlaylists(String sourceId, String keyword) {
    return _randomPagePlaylists(
      cacheKey: 'kw:$sourceId:$keyword',
      fetch: (page) => manager.searchPlaylists(
        keyword,
        sourceId: sourceId,
        page: page,
        limit: 30,
      ),
    );
  }

  /// 从一个歌单里取随机歌曲（至少 [minCount] 首，够不够都把能拿到的过滤后返回）。
  Future<RadioBatch> _songsFromPlaylist(
    String playlistId, {
    String? source,
    int minCount = 20,
    int maxPages = 3,
    Set<String> excludeIds = const <String>{},
  }) async {
    final collected = <String, Song>{};
    String? title;
    String? playlistSource = source;
    for (var page = 1; page <= maxPages; page++) {
      try {
        final result = await manager.getPlaylistDetailPage(
          playlistId,
          page: page,
        );
        final playlist = result.playlist;
        if (playlist == null) break;
        title ??= playlist.title;
        playlistSource ??= playlist.source;
        for (final song in playlist.songs) {
          if (isBlocked(song)) continue; // 黑名单歌曲直接排除
          if (excludeIds.contains(song.id)) continue; // 已经在队列里的不再取
          collected.putIfAbsent(song.id, () => song);
        }
        if (result.isEnd) break;
        // 只有一页内容时（插件直接给全量）不用继续翻。
        if (page == 1 && playlist.songs.isEmpty) break;
      } catch (e) {
        debugPrint('[RadioEngine] 歌单第 $page 页取歌失败: $e');
        break;
      }
      if (collected.length >= minCount) break;
    }

    final songs = collected.values.toList(growable: false);
    if (songs.isEmpty) return const RadioBatch(songs: []);
    final shuffled = [...songs]..shuffle(_random);
    final take = shuffled.length > minCount ? minCount : shuffled.length;
    final selected = shuffled.take(take).toList(growable: false);
    final ref = RadioPlaylistRef(
      id: playlistId,
      source: playlistSource,
      title: title,
    );
    return RadioBatch(
      songs: selected,
      playlistId: playlistId,
      playlistSource: playlistSource,
      playlistTitle: title,
      songPlaylists: {for (final song in selected) song.id: ref},
    );
  }
}
