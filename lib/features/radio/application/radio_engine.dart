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

/// 一次随机取到的歌，附带「这些歌来自哪个歌单」。
///
/// 每轮补歌会换一个随机歌单（只避开最近用过的几个），所以 [playlistId] 表示
/// 这一批歌主要来自哪个歌单；每首歌各自的来源见 [songPlaylists]。
class RadioBatch {
  const RadioBatch({
    required this.songs,
    this.playlistId,
    this.playlistSource,
    this.playlistTitle,
    this.songPlaylists = const {},
    this.usedPlaylistIds = const <String>{},
  });

  final List<Song> songs;
  final String? playlistId;
  final String? playlistSource;
  final String? playlistTitle;

  /// 每首歌各自来自哪个歌单：一批歌可能跨多个歌单，不能只看 [playlistId]。
  final Map<String, RadioPlaylistRef> songPlaylists;

  /// 这一批歌实际用掉的歌单 id：会话据此把它们记进「本次电台用过的歌单」，
  /// 下一轮补歌不再用。
  final Set<String> usedPlaylistIds;

  bool get isEmpty => songs.isEmpty;
}

/// 电台取歌引擎：负责「随机音源 → 随机分类/关键词 → 随机页 → 随机歌单 →
/// 随机歌曲」，并过滤掉黑名单里的歌。
class RadioEngine {
  RadioEngine({required this.manager, required this.isBlocked});

  final MusicSourceManager manager;
  final bool Function(Song song) isBlocked;

  final Random _random = Random();

  /// 电台里实际可用的音源 id（用户显式选择时可以包含插件源）。
  ///
  /// 只保留提供「推荐歌单」的音源：只有搜索 / 播放能力的脚本（例如 LX 源）
  /// 没有歌单分类，纳入电台随机只会让取歌频繁落空。
  List<String> availableSources() => [
    for (final source in manager.getDiscoverSupportedSources())
      if (manager.sourceSupportsRecommendSheets(source.id)) source.id,
  ];

  /// 没选音源时可自动随机使用的「数据源」。
  ///
  /// 排除 bilibili、LX 这类插件源：电台只用元数据源取歌单分类。
  List<String> dataSources() => [
    for (final source in manager.getDiscoverSupportedSources())
      if (manager.isRadioDataSource(source.id)) source.id,
  ];

  /// 电台里实际可用的音源。
  ///
  /// * [configured] 为空：用 [fallback]（一般是发现页当前音源）；
  /// * 配了但被关闭 / 卸载：只能用剩下那些，全都不可用就返回空，由调用方
  ///   弹错误提示（不偷偷换成没配置的音源）。
  List<String> usableSources({
    required List<String> configured,
    List<String> fallback = const [],
  }) {
    final available = availableSources().toSet();
    final candidates = configured.isEmpty ? fallback : configured;
    final usable = <String>[];
    for (final id in candidates) {
      if (available.contains(id) && !usable.contains(id)) usable.add(id);
    }
    return usable;
  }

  T _pick<T>(List<T> items) => items[_random.nextInt(items.length)];

  /// 起播第一批：只随机一个歌单，取 [count] 首（默认 3），尽快出声。
  ///
  /// 后续由会话在歌曲真正开始播放后调用 [nextBatch] 继续补歌。
  Future<RadioBatch> firstBatch({
    required List<String> sourceIds,
    required List<RadioTagRef> tags,
    required List<String> keywords,
    int count = 3,
    Set<String> excludePlaylistIds = const <String>{},
    Set<String> excludeIds = const <String>{},
  }) async {
    if (sourceIds.isEmpty) {
      throw const RadioException('没有可用的音源，请检查电台的音源设置');
    }
    var usableTags = tags
        .where((tag) => sourceIds.contains(tag.sourceId))
        .toList(growable: false);
    // 没指定分类、也没填关键词：默认从所有可用音源的所有分类里随机。
    if (usableTags.isEmpty && keywords.isEmpty) {
      usableTags = await _tagsForSources(sourceIds);
    }
    final batch = await _collectFirstBatch(
      sourceIds: sourceIds,
      tags: usableTags,
      keywords: keywords,
      minCount: count,
      songsPerPlaylist: count,
      excludePlaylistIds: excludePlaylistIds,
      excludeIds: excludeIds,
      visitedPages: <String>{},
    );
    if (batch.isEmpty) {
      throw const RadioException('随机不到可播放的歌曲，换个分类或关键词试试');
    }
    return batch;
  }

  /// 电台补歌：**一轮只随机一页歌单**。
  ///
  /// 按接口返回的歌单顺序，从每个歌单随机取 [songsPerPlaylist] 首，
  /// 最多取 [maxCount] 首（默认 30）。本次电台用过的歌单、已经入队的歌曲
  /// 都会避开；歌单池用尽时允许复用歌单，避免电台直接没歌可放。
  Future<RadioBatch> nextBatch({
    required List<String> sourceIds,
    required List<RadioTagRef> tags,
    required List<String> keywords,
    int maxCount = 30,
    int songsPerPlaylist = 3,
    Set<String> excludePlaylistIds = const <String>{},
    Set<String> excludeIds = const <String>{},
  }) async {
    if (sourceIds.isEmpty) {
      throw const RadioException('没有可用的音源，请检查电台的音源设置');
    }
    var usableTags = tags
        .where((tag) => sourceIds.contains(tag.sourceId))
        .toList(growable: false);
    if (usableTags.isEmpty && keywords.isEmpty) {
      usableTags = await _tagsForSources(sourceIds);
    }

    final batch = await _collectPageBatch(
      sourceIds: sourceIds,
      tags: usableTags,
      keywords: keywords,
      maxCount: maxCount,
      songsPerPlaylist: songsPerPlaylist,
      excludePlaylistIds: excludePlaylistIds,
      excludeIds: excludeIds,
    );
    if (!batch.isEmpty) return batch;

    // 分类 / 关键词下的歌单都听过了：允许复用歌单把电台续上（歌曲仍然不重复），
    // 总比电台突然没歌可放好。
    if (excludePlaylistIds.isNotEmpty) {
      final relaxed = await _collectPageBatch(
        sourceIds: sourceIds,
        tags: usableTags,
        keywords: keywords,
        maxCount: maxCount,
        songsPerPlaylist: songsPerPlaylist,
        excludePlaylistIds: const <String>{},
        excludeIds: excludeIds,
      );
      if (!relaxed.isEmpty) return relaxed;
    }
    throw const RadioException('随机不到可播放的歌曲，换个分类或关键词试试');
  }

  /// 取一页歌单，按返回顺序逐个歌单取歌。
  ///
  /// 每轮只随机一种来源（分类标签 / 搜索关键词），只翻一页；从该页返回的
  /// 歌单列表中按顺序每个歌单随机取 [songsPerPlaylist] 首，凑够 [maxCount]
  /// 首就停（每个歌单都够 3 首时，一批正好来自 10 个歌单）。
  Future<RadioBatch> _collectPageBatch({
    required List<String> sourceIds,
    required List<RadioTagRef> tags,
    required List<String> keywords,
    required int maxCount,
    required int songsPerPlaylist,
    required Set<String> excludePlaylistIds,
    required Set<String> excludeIds,
  }) async {
    final visitedPages = <String>{};
    final wantTags =
        tags.isNotEmpty && (keywords.isEmpty || _random.nextBool());
    final playlists = wantTags
        ? await _playlistPageFromTags(_pick(tags), visitedPages: visitedPages)
        : await _playlistPageFromKeywords(
            sourceIds: sourceIds,
            keywords: keywords,
            visitedPages: visitedPages,
          );
    if (playlists.isEmpty) return const RadioBatch(songs: []);

    // 用 Map 去重并保留「歌单顺序 → 歌单内取歌顺序」。
    final collected = <String, Song>{};
    final songPlaylists = <String, RadioPlaylistRef>{};
    final used = <String>{};
    String? lastPlaylistId;
    String? lastPlaylistSource;
    String? lastPlaylistTitle;

    for (final playlist in playlists) {
      if (collected.length >= maxCount) break;
      // 本次电台已经用过的歌单跳过，其它过滤规则（黑名单 / 已入队）在
      // _songsFromPlaylist 里统一处理。
      if (excludePlaylistIds.contains(playlist.id)) continue;
      // 先记账再取歌：取不出新歌的歌单也记进「用过」，下一轮不再白跑。
      used.add(playlist.id);
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
        if (collected.length >= maxCount) break;
        if (collected.containsKey(song.id)) continue;
        collected[song.id] = song;
        songPlaylists[song.id] = ref;
      }
      lastPlaylistId = playlist.id;
      lastPlaylistSource = playlist.source;
      lastPlaylistTitle = playlist.title;
    }

    if (collected.isEmpty) return const RadioBatch(songs: []);
    // 不整体打乱：按歌单返回顺序追加，第一页歌单的歌先进入播放队列。
    final selected = collected.values.toList(growable: false);
    return RadioBatch(
      songs: selected,
      playlistId: lastPlaylistId,
      playlistSource: lastPlaylistSource,
      playlistTitle: lastPlaylistTitle,
      songPlaylists: songPlaylists,
      usedPlaylistIds: used,
    );
  }

  /// 起播收集：反复「随机来源 → 随机页 → 随机歌单 → 取至多 N 首」，直到够数。
  ///
  /// 起播只传 [firstBatch] 的 3 首，正常第一个歌单就能凑够并立即返回。
  Future<RadioBatch> _collectFirstBatch({
    required List<String> sourceIds,
    required List<RadioTagRef> tags,
    required List<String> keywords,
    required int minCount,
    required int songsPerPlaylist,
    required Set<String> excludePlaylistIds,
    required Set<String> excludeIds,
    required Set<String> visitedPages,
  }) async {
    final collected = <String, Song>{};
    final songPlaylists = <String, RadioPlaylistRef>{};
    final tried = <String>{...excludePlaylistIds};
    final used = <String>{};
    String? lastPlaylistId;
    String? lastPlaylistSource;
    String? lastPlaylistTitle;

    // 每个歌单只取几首，凑够 minCount 需要翻很多个歌单；留 3 倍余量，
    // 避免取不到歌的歌单（黑名单过滤后为空）把预算耗光。
    final maxPlaylists = (minCount / songsPerPlaylist).ceil() * 3 + 8;
    var attempts = 0;
    // 连续 2 次（即重试 1 次）都挑不到「没用过的歌单」就收工，
    // 别把请求预算耗在网络往返上。
    var nullStreak = 0;
    while (collected.length < minCount &&
        attempts < maxPlaylists &&
        nullStreak < 2) {
      attempts++;
      final wantTags =
          tags.isNotEmpty && (keywords.isEmpty || _random.nextBool());
      final Playlist? playlist = wantTags
          ? await _randomPlaylistFromTags(
              _pick(tags),
              excludePlaylistIds: tried,
              visitedPages: visitedPages,
            )
          : await _randomPlaylistFromKeywords(
              sourceIds: sourceIds,
              keywords: keywords,
              excludePlaylistIds: tried,
              visitedPages: visitedPages,
            );
      if (playlist == null) {
        // 这个分类 / 关键词翻不到新歌单：换一个分类 / 页重试一次；
        // 再空就判定这次起播失败。
        nullStreak++;
        continue;
      }
      nullStreak = 0;
      tried.add(playlist.id);

      // 先记账再取歌：取不出新歌（整单都播过了 / 全在黑名单）的歌单也记进
      // 「用过」，下一轮不再白跑一趟。
      used.add(playlist.id);
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

    if (collected.isEmpty) return const RadioBatch(songs: []);
    final shuffled = collected.values.toList(growable: false)..shuffle(_random);
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
      usedPlaylistIds: used,
    );
  }

  /// 多个音源的全部歌单分类（默认「不选分类」时用）。
  Future<List<RadioTagRef>> _tagsForSources(List<String> sourceIds) async {
    // 并行拉取：不选分类时起播要等所有音源的分类，串行会叠加每个插件的
    // 网络往返时间，明显拖慢出声。
    final groups = await Future.wait([
      for (final sourceId in sourceIds) _tagsForSource(sourceId),
    ]);
    return [for (final group in groups) ...group];
  }

  /// 随机电台（内置那个）的可用分类；插件没给分类时退回「全部」。
  Future<List<RadioTagRef>> _tagsForSource(String sourceId) async {
    List<PlaylistTag> tagList = const [];
    try {
      final groups = await manager.getPlaylistTags(sourceId: sourceId);
      tagList = [for (final group in groups) ...group.tags];
    } catch (e) {
      debugPrint('[RadioEngine] 取分类失败: $e');
    }
    final tags = <RadioTagRef>[
      for (final tag in tagList)
        if (tag.id.isNotEmpty)
          RadioTagRef(sourceId: sourceId, tagId: tag.id, tagName: tag.name),
    ];
    if (tags.isEmpty) {
      // 插件没给分类：用「全部」（tagId 为空）取歌单，别让随机电台直接报错。
      tags.add(RadioTagRef(sourceId: sourceId, tagId: '', tagName: '全部'));
    }
    return tags;
  }

  /// 随机电台起播：只取一个歌单的 [count] 首，尽快出声。
  Future<RadioBatch> firstRandomSongs({
    required String sourceId,
    int count = 3,
    Set<String> excludePlaylistIds = const <String>{},
    Set<String> excludeIds = const <String>{},
  }) async {
    final tags = await _tagsForSource(sourceId);
    return firstBatch(
      sourceIds: [sourceId],
      tags: tags,
      keywords: const [],
      count: count,
      excludePlaylistIds: excludePlaylistIds,
      excludeIds: excludeIds,
    );
  }

  /// 随机电台补歌：随机一页歌单，按顺序每个歌单取 3 首，最多 30 首。
  Future<RadioBatch> randomSongs({
    required String sourceId,
    int maxCount = 30,
    int songsPerPlaylist = 3,
    Set<String> excludePlaylistIds = const <String>{},
    Set<String> excludeIds = const <String>{},
  }) async {
    final tags = await _tagsForSource(sourceId);
    return nextBatch(
      sourceIds: [sourceId],
      tags: tags,
      keywords: const [],
      maxCount: maxCount,
      songsPerPlaylist: songsPerPlaylist,
      excludePlaylistIds: excludePlaylistIds,
      excludeIds: excludeIds,
    );
  }

  /// 分类下随机取一页歌单。
  Future<List<Playlist>> _playlistPageFromTags(
    RadioTagRef tag, {
    Set<String> visitedPages = const <String>{},
  }) {
    final cacheKey = 'tag:${tag.sourceId}:${tag.tagId}';
    return _playlistsForQuery(
      cacheKey: cacheKey,
      visitedPages: visitedPages,
      fetch: (page) async {
        final result = await manager.getCategoryPlaylists(
          sortId: 'hot',
          tagId: tag.tagId,
          page: page,
          limit: 30,
          sourceId: tag.sourceId,
        );
        return result.items;
      },
    );
  }

  /// 关键词下随机取一页歌单。
  Future<List<Playlist>> _playlistPageFromKeywords({
    required List<String> sourceIds,
    required List<String> keywords,
    Set<String> visitedPages = const <String>{},
  }) {
    if (keywords.isEmpty) return Future.value(const <Playlist>[]);
    final keyword = _pick(keywords);
    final sourceId = _pick(sourceIds);
    final cacheKey = 'kw:$sourceId:$keyword';
    return _playlistsForQuery(
      cacheKey: cacheKey,
      visitedPages: visitedPages,
      fetch: (page) => manager.searchPlaylists(
        keyword,
        sourceId: sourceId,
        page: page,
        limit: 30,
      ),
    );
  }

  /// 分类下随机取一页歌单，再从中挑一个**没用过**的。
  Future<Playlist?> _randomPlaylistFromTags(
    RadioTagRef tag, {
    Set<String> excludePlaylistIds = const <String>{},
    Set<String> visitedPages = const <String>{},
  }) async {
    final playlists = await _playlistPageFromTags(
      tag,
      visitedPages: visitedPages,
    );
    return _pickUnused(playlists, excludePlaylistIds);
  }

  /// 关键词搜索里随机取一页，再从中挑一个**没用过**的歌单。
  Future<Playlist?> _randomPlaylistFromKeywords({
    required List<String> sourceIds,
    required List<String> keywords,
    Set<String> excludePlaylistIds = const <String>{},
    Set<String> visitedPages = const <String>{},
  }) async {
    if (keywords.isEmpty) return null;
    final playlists = await _playlistPageFromKeywords(
      sourceIds: sourceIds,
      keywords: keywords,
      visitedPages: visitedPages,
    );
    return _pickUnused(playlists, excludePlaylistIds);
  }

  /// 从候选歌单里挑一个没用过的；全用过了返回 null（由调用方换来源/页再试）。
  Playlist? _pickUnused(List<Playlist> playlists, Set<String> usedIds) {
    if (playlists.isEmpty) return null;
    final fresh = usedIds.isEmpty
        ? playlists
        : playlists
              .where((p) => !usedIds.contains(p.id))
              .toList(growable: false);
    if (fresh.isEmpty) return null;
    return _pick(fresh);
  }

  /// 取「某一页」的歌单列表。
  ///
  /// 页码上限记忆在设置文件里（按音源 + 分类 / 关键词区分）。优先挑**本次补歌
  /// 里还没翻过**的页，让每轮拿到的歌单尽量不一样（池子更大、重复更少）；
  /// 都翻过了再随机；挑中的页取不到歌单就回落到第 1 页再试一次。
  Future<List<Playlist>> _playlistsForQuery({
    required String cacheKey,
    required Set<String> visitedPages,
    required Future<List<Playlist>> Function(int page) fetch,
  }) async {
    await RadioPageLimits.ensureLoaded();
    final limit = RadioPageLimits.limitFor(cacheKey);
    final maxPage = limit < 1 ? 1 : limit;
    final unvisited = [
      for (var page = 1; page <= maxPage; page++)
        if (!visitedPages.contains('$cacheKey#$page')) page,
    ];
    var page = unvisited.isEmpty
        ? 1 + _random.nextInt(maxPage)
        : _pick(unvisited);
    visitedPages.add('$cacheKey#$page');

    // 最多试两页：先试挑中的页，空了直接回落到第 1 页（见
    // [nextPageAfterEmpty]）。以前是逐页 −5 / −1 回缩，一次抖动要发十几条
    // 请求；而且「缩到第 1 页有数据」会被误记成「上限 = 1」，把关键词永久
    // 锁死在第一页。
    final tried = <int>{};
    var highestEmpty = 0;
    while (tried.length < 2) {
      if (page < 1 || !tried.add(page)) break;
      try {
        final playlists = await fetch(page);
        if (playlists.isNotEmpty) {
          // 只把「确认有数据」的页记成上限：本轮最高空页是 41，说明 41 及
          // 以上大概率超范围，可用的最大页取 40，而不是缩到第 1 页。
          if (highestEmpty > 1) {
            unawaited(RadioPageLimits.record(cacheKey, highestEmpty - 1));
          }
          return playlists;
        }
      } catch (e) {
        debugPrint('[RadioEngine] 第 $page 页取歌单失败: $e');
      }
      if (page > highestEmpty) highestEmpty = page;
      page = nextPageAfterEmpty(page);
    }
    return const [];
  }

  /// 从一个歌单里取随机歌曲（至少 [minCount] 首，够不够都把能拿到的过滤后返回）。
  Future<RadioBatch> _songsFromPlaylist(
    String playlistId, {
    String? source,
    int minCount = 3,
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
