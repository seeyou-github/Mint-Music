import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../discover/domain/models/leaderboard.dart';
import '../../discover/domain/models/playlist.dart';
import '../../player/domain/models/song.dart';
import '../../plugin/application/music_source_manager.dart';
import '../domain/models/radio_station.dart';

/// 电台取歌失败（没有可用音源 / 随机不到歌单等），带一句能直接显示的说明。
class RadioException implements Exception {
  const RadioException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一次随机取到的歌，附带「这些歌来自哪个歌单」，便于随机电台继续从同一个
/// 歌单补歌。
class RadioBatch {
  const RadioBatch({
    required this.songs,
    this.playlistId,
    this.playlistSource,
    this.playlistTitle,
  });

  final List<Song> songs;
  final String? playlistId;
  final String? playlistSource;
  final String? playlistTitle;

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
          return RadioBatch(
            songs: batch.songs,
            playlistId: playlist.id,
            playlistSource: playlist.source,
            playlistTitle: playlist.title,
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
  Future<RadioBatch> randomSongs({
    required String sourceId,
    int minCount = 20,
    String? preferPlaylistId,
    Set<String> excludeIds = const <String>{},
  }) async {
    if (preferPlaylistId != null && preferPlaylistId.isNotEmpty) {
      final batch = await _songsFromPlaylist(
        preferPlaylistId,
        minCount: minCount,
        excludeIds: excludeIds,
      );
      if (!batch.isEmpty) return batch;
    }

    // 随机一个分类（拿不到分类就用「热门」）。
    List<PlaylistTag> tags = const [];
    try {
      final groups = await manager.getPlaylistTags(sourceId: sourceId);
      tags = [for (final group in groups) ...group.tags];
    } catch (e) {
      debugPrint('[RadioEngine] 取分类失败: $e');
    }
    final tag = tags.isEmpty
        ? null
        : _pick(tags.where((t) => t.id.isNotEmpty).toList(growable: false));

    final playlists = await _randomCategoryPlaylists(
      sourceId: sourceId,
      tagId: tag?.id ?? '',
    );
    if (playlists.isEmpty) {
      throw const RadioException('这个音源暂时没有可用的歌单');
    }
    final playlist = _pick(playlists);
    final batch = await _songsFromPlaylist(
      playlist.id,
      minCount: minCount,
      excludeIds: excludeIds,
    );
    if (batch.isEmpty) {
      throw const RadioException('随机到的歌单里没有可播放的歌曲');
    }
    return RadioBatch(
      songs: batch.songs,
      playlistId: playlist.id,
      playlistSource: playlist.source,
      playlistTitle: playlist.title,
    );
  }

  /// 分类页：随机取一页，取不到就往回缩（返回空数据时缩小随机范围）。
  Future<List<Playlist>> _randomCategoryPlaylists({
    required String sourceId,
    required String tagId,
    int maxPage = 6,
  }) async {
    final start = 1 + _random.nextInt(maxPage);
    for (var page = start; page >= 1; page--) {
      try {
        final (playlists, _) = await manager.getCategoryPlaylists(
          sortId: 'hot',
          tagId: tagId,
          page: page,
          limit: 30,
          sourceId: sourceId,
        );
        if (playlists.isNotEmpty) return playlists;
      } catch (e) {
        debugPrint('[RadioEngine] 分类歌单第 $page 页失败: $e');
      }
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
          return RadioBatch(
            songs: batch.songs,
            playlistId: playlist.id,
            playlistSource: playlist.source,
            playlistTitle: playlist.title,
          );
        }
      }
    }
    throw const RadioException('按关键词随机不到可播放的歌曲');
  }

  Future<List<Playlist>> _searchPlaylists(
    String sourceId,
    String keyword, {
    int maxPage = 4,
  }) async {
    final start = 1 + _random.nextInt(maxPage);
    for (var page = start; page >= 1; page--) {
      try {
        final playlists = await manager.searchPlaylists(
          keyword,
          sourceId: sourceId,
          page: page,
          limit: 30,
        );
        if (playlists.isNotEmpty) return playlists;
      } catch (e) {
        debugPrint('[RadioEngine] 搜索歌单第 $page 页失败: $e');
      }
    }
    return const [];
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
        // 内置源一次给全量，不需要继续翻。
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
    return RadioBatch(
      songs: shuffled.take(take).toList(growable: false),
      playlistId: playlistId,
      playlistSource: playlistSource,
      playlistTitle: title,
    );
  }
}
