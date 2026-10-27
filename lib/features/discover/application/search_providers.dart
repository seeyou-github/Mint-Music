import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../../../core/storage/app_database.dart';
import '../../../core/storage/app_preferences.dart';
import '../../player/domain/models/song.dart';
import '../../discover/domain/models/playlist.dart';
import '../../discover/domain/models/search_collection.dart';
import '../../plugin/application/plugin_providers.dart';
import '../../plugin/application/music_source_manager.dart';
import '../../plugin/domain/plugin_types.dart';
import 'discover_providers.dart';

/// 搜索页结果类型切换标签。
enum SearchTab { songs, playlists, albums, artists }

final searchQueryProvider = StateProvider<String>((ref) => '');

/// 仅用于“本次进入搜索页前明确约定要带上的关键词”（如识别页跳转搜索）。
/// 搜索页进入时会消费并清空它；普通进入一律不恢复上次会话留下的关键词，
/// 避免退出后再次打开时搜索栏残留上一次搜索。
final pendingSearchQueryProvider = StateProvider<String?>((ref) => null);

/// 与 [pendingSearchQueryProvider] 配套：这次跳转希望落到的结果标签页。
/// 为空时按「歌曲」处理；消费待搜索词时一并清空。
final pendingSearchTabProvider = StateProvider<SearchTab?>((ref) => null);

/// 搜索页当前使用的音源。
///
/// 默认取「发现页正在使用的音源」；搜索页进入时会再同步一次，页内切换音源
/// 只对本次搜索有效，退出后不保留（下次进入仍回到发现页的音源）。
final searchSourceIdProvider = StateProvider<String>(
  (ref) => ref.read(discoverSourceIdProvider),
);

final searchPageProvider = StateProvider<int>((ref) => 1);

/// 当前搜索结果标签页（歌曲 / 歌单）。
final searchTabProvider = StateProvider<SearchTab>((ref) => SearchTab.songs);

final searchSuggestInputProvider = StateProvider<String>((ref) => '');

final searchSuggestResultsProvider = FutureProvider<List<String>>((ref) async {
  final input = ref.watch(searchSuggestInputProvider);
  if (input.isEmpty) return [];

  final sourceId = ref.watch(searchSourceIdProvider);
  final manager = ref.watch(musicSourceManagerProvider);
  return manager.getSearchSuggestions(input, sourceId: sourceId);
});

final searchResultsProvider = FutureProvider<List<Song>>((ref) async {
  final query = ref.watch(searchQueryProvider);
  if (query.isEmpty) return [];

  final sourceId = ref.watch(searchSourceIdProvider);
  final manager = ref.watch(musicSourceManagerProvider);
  final page = ref.watch(searchPageProvider);

  return manager.search(query, sourceId: sourceId, page: page, limit: 30);
});

/// State for the visible search list. Pages are appended here instead of
/// replacing the previous FutureProvider value when the list reaches its end.
class SearchResultsState {
  final String query;
  final String sourceId;
  final List<Song> songs;
  final int page;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;

  /// 首屏加载失败的原因。
  final String? error;

  /// 「加载下一页」失败的原因。
  ///
  /// 和 [error] 分开：首屏失败要把整页换成错误页，下一页失败只在列表底部
  /// 显示「加载失败，点击重试」，已经加载出来的内容不能丢。
  final String? loadMoreError;

  const SearchResultsState({
    this.query = '',
    this.sourceId = '',
    this.songs = const [],
    this.page = 0,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasMore = false,
    this.error,
    this.loadMoreError,
  });

  SearchResultsState copyWith({
    String? query,
    String? sourceId,
    List<Song>? songs,
    int? page,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
    String? error,
    String? loadMoreError,
    bool clearError = false,
    bool clearLoadMoreError = false,
  }) {
    return SearchResultsState(
      query: query ?? this.query,
      sourceId: sourceId ?? this.sourceId,
      songs: songs ?? this.songs,
      page: page ?? this.page,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      error: clearError ? null : (error ?? this.error),
      loadMoreError: clearLoadMoreError
          ? null
          : (loadMoreError ?? this.loadMoreError),
    );
  }
}

class SearchResultsNotifier extends StateNotifier<SearchResultsState> {
  SearchResultsNotifier(this._manager) : super(const SearchResultsState());

  static const _pageSize = 30;
  final MusicSourceManager _manager;
  int _requestId = 0;
  String _requestKey = '';

  Future<void> start(
    String query,
    String sourceId, {
    bool force = false,
  }) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) {
      reset();
      return;
    }

    final key = '$sourceId:$normalizedQuery';
    if (key == _requestKey &&
        (state.isLoading ||
            state.isLoadingMore ||
            (!force && state.songs.isNotEmpty))) {
      return;
    }

    final requestId = ++_requestId;
    _requestKey = key;
    state = SearchResultsState(
      query: normalizedQuery,
      sourceId: sourceId,
      isLoading: true,
      hasMore: true,
    );
    await _loadPage(requestId, 1, replace: true);
  }

  Future<void> loadMore() async {
    if (state.query.isEmpty ||
        state.isLoading ||
        state.isLoadingMore ||
        !state.hasMore ||
        // 上一次已经失败了：等用户点重试，不要被滚动反复触发。
        state.loadMoreError != null) {
      return;
    }
    await _loadPage(_requestId, state.page + 1, replace: false);
  }

  /// 底部「加载失败，点击重试」：重试同一页，失败原因清掉。
  Future<void> retryLoadMore() async {
    if (state.query.isEmpty || state.isLoading || state.isLoadingMore) return;
    state = state.copyWith(clearLoadMoreError: true, hasMore: true);
    await _loadPage(_requestId, state.page + 1, replace: false);
  }

  void reset() {
    _requestId++;
    _requestKey = '';
    state = const SearchResultsState();
  }

  Future<void> _loadPage(
    int requestId,
    int page, {
    required bool replace,
  }) async {
    if (requestId != _requestId) return;
    state = state.copyWith(
      isLoading: replace,
      isLoadingMore: !replace,
      clearError: replace,
      clearLoadMoreError: true,
    );

    try {
      final pageSongs = await _loadSingleSourcePage(
        state.sourceId,
        state.query,
        page,
      );
      if (requestId != _requestId) return;

      final merged = replace
          ? pageSongs
          : _appendUnique(state.songs, pageSongs);
      final appendedAny = merged.length > state.songs.length;
      // Different source endpoints do not consistently honor the requested
      // page size. In particular, QQ may return a partial non-final page.
      // Continue until the source actually returns no new songs, rather
      // than treating a page shorter than 30 as the final page.
      final hasMore = pageSongs.isNotEmpty && (replace || appendedAny);
      state = state.copyWith(
        songs: merged,
        page: page,
        isLoading: false,
        isLoadingMore: false,
        hasMore: hasMore,
        clearError: true,
      );
    } catch (error) {
      if (requestId != _requestId) return;
      if (replace) {
        // 首屏失败：整页显示错误 + 重试。
        state = state.copyWith(
          isLoading: false,
          isLoadingMore: false,
          error: _readableError(error),
          hasMore: false,
        );
      } else {
        // 下一页失败：保留已加载的内容，底部显示重试。
        state = state.copyWith(
          isLoading: false,
          isLoadingMore: false,
          loadMoreError: _readableError(error),
          hasMore: true,
        );
      }
    }
  }

  Future<List<Song>> _loadSingleSourcePage(
    String sourceId,
    String query,
    int page,
  ) async {
    return _manager.search(
      query,
      sourceId: sourceId,
      page: page,
      limit: _pageSize,
    );
  }

  List<Song> _appendUnique(List<Song> current, List<Song> next) {
    final result = [...current];
    final seen = result.map((song) => '${song.source}:${song.id}').toSet();
    for (final song in next) {
      if (seen.add('${song.source}:${song.id}')) result.add(song);
    }
    return result;
  }
}

/// 把异常整理成一句能显示给用户的话。
String _readableError(Object error) {
  if (error is CollectionDetailException) return error.message;
  final text = error.toString();
  if (text.startsWith('Exception: ')) return text.substring(11);
  return text;
}

final searchResultsControllerProvider =
    StateNotifierProvider<SearchResultsNotifier, SearchResultsState>((ref) {
      return SearchResultsNotifier(ref.watch(musicSourceManagerProvider));
    });

final hotSearchTagsProvider = FutureProvider<List<String>>((ref) async {
  final sourceId = ref.watch(searchSourceIdProvider);
  final manager = ref.watch(musicSourceManagerProvider);
  return manager.getHotSearchTags(sourceId: sourceId);
});

final searchSuggestionsProvider = FutureProvider<List<String>>((ref) async {
  final query = ref.watch(searchQueryProvider);
  if (query.isEmpty) return [];

  final sourceId = ref.watch(searchSourceIdProvider);
  final manager = ref.watch(musicSourceManagerProvider);
  return manager.getSearchSuggestions(query, sourceId: sourceId);
});

final searchHistoryProvider =
    StateNotifierProvider<SearchHistoryNotifier, List<String>>((ref) {
      return SearchHistoryNotifier();
    });

class SearchHistoryNotifier extends StateNotifier<List<String>> {
  SearchHistoryNotifier() : super([]) {
    AppDatabase.registerWriter(_writer);
    _loadPersisted();
  }

  /// 最多保留的搜索历史条数，超出时自动删除最旧的。
  static const int _maxHistory = 10;

  /// 旧版把搜索历史存在设置文件里的键（首次启动时迁移）。
  static const String _storageKey = 'search_history';

  /// 搜索历史写得频繁但丢了无所谓，因此放在临时库，
  /// 并且写入走合并延迟写，避免每搜一次就写一次硬盘。
  late final DeferredWriter _writer = DeferredWriter(() => _persist());

  /// 启动时从临时库恢复搜索历史。
  /// 若加载期间用户已新增搜索词，则合并去重，避免覆盖用户操作。
  Future<void> _loadPersisted() async {
    try {
      final db = await AppDatabase.cacheDatabase();
      final rows = await db.query(
        'search_history',
        orderBy: 'searched_at DESC',
        limit: _maxHistory,
      );
      var stored = rows.map((r) => '${r['keyword']}').toList();

      if (stored.isEmpty && !await AppDatabase.isMigrated('search_history')) {
        stored = await _importLegacy();
        if (AppDatabase.isPersistent) {
          await AppDatabase.markMigrated('search_history');
        }
      }

      final merged = [...state, ...stored.where((q) => !state.contains(q))];
      if (!mounted) return;
      state = merged.take(_maxHistory).toList();
    } catch (_) {
      // 读取失败时保持空历史，不影响搜索功能
    }
  }

  /// 把历史写入临时库（延迟写）。
  Future<void> _persist() async {
    if (!mounted) return;
    try {
      final db = await AppDatabase.cacheDatabase();
      final now = DateTime.now().millisecondsSinceEpoch;
      final keywords = state;
      await db.transaction((txn) async {
        await txn.delete('search_history');
        final batch = txn.batch();
        for (var i = 0; i < keywords.length; i++) {
          // 时间戳按顺序递减：重新读取时 `ORDER BY searched_at DESC`
          // 才能还原「最近搜的在前」的顺序（以前全用同一个 now，顺序会乱）。
          batch.insert('search_history', {
            'keyword': keywords[i],
            'searched_at': now - i,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await batch.commit(noResult: true);
      });
    } catch (_) {
      // 写入失败时仅丢失持久化，不影响内存中的历史
    }
  }

  /// 首次启动：把旧设置文件里的搜索历史导入数据库。
  Future<List<String>> _importLegacy() async {
    try {
      final prefs = await AppPreferences.getInstance();
      final legacy = prefs.getStringList(_storageKey) ?? const <String>[];
      if (legacy.isEmpty) return const <String>[];
      final db = await AppDatabase.cacheDatabase();
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (var i = 0; i < legacy.length; i++) {
          batch.insert('search_history', {
            'keyword': legacy[i],
            'searched_at': now - i,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await batch.commit(noResult: true);
      });
      await AppDatabase.removeLegacyKey(_storageKey);
      return legacy;
    } catch (_) {
      return const <String>[];
    }
  }

  void addQuery(String query) {
    if (query.trim().isEmpty) return;
    final trimmed = query.trim();
    final updated = [trimmed, ...state.where((q) => q != trimmed)];
    state = updated.take(_maxHistory).toList();
    // 立即写库：关闭应用时进程会被直接结束，延迟写会丢。
    unawaited(_writer.writeNow().then((_) => AppDatabase.checkpoint()));
  }

  void removeQuery(String query) {
    state = state.where((q) => q != query).toList();
    unawaited(_writer.writeNow());
  }

  void clearHistory() {
    state = [];
    unawaited(_writer.writeNow());
  }
}

/// 搜索页可选的音源列表（与发现页一致：内置音源 + 已启用的插件音源）。
///
/// 没有「聚合搜索」这一项：搜索始终使用单个音源，默认是发现页正在用的音源。
final searchAvailableSourcesProvider = Provider<List<SourceInfo>>((ref) {
  // searchSupportedSourcesProvider 已经包含「仍启用」的内置音源与插件音源。
  final searchSources = ref.watch(searchSupportedSourcesProvider);

  final allSources = <SourceInfo>[];
  final seenIds = <String>{};

  for (final source in searchSources) {
    if (!seenIds.contains(source.id)) {
      allSources.add(source);
      seenIds.add(source.id);
    }
  }

  return allSources;
});

/// 歌单搜索结果状态。
class PlaylistSearchState {
  const PlaylistSearchState({
    this.query = '',
    this.playlists = const [],
    this.page = 0,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasMore = false,
    this.error,
    this.loadMoreError,
  });

  final String query;
  final List<Playlist> playlists;
  final int page;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;

  /// 首屏加载失败原因。
  final String? error;

  /// 下一页加载失败原因（列表底部显示重试）。
  final String? loadMoreError;

  PlaylistSearchState copyWith({
    String? query,
    List<Playlist>? playlists,
    int? page,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
    String? error,
    String? loadMoreError,
    bool clearError = false,
    bool clearLoadMoreError = false,
  }) {
    return PlaylistSearchState(
      query: query ?? this.query,
      playlists: playlists ?? this.playlists,
      page: page ?? this.page,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      error: clearError ? null : (error ?? this.error),
      loadMoreError: clearLoadMoreError
          ? null
          : (loadMoreError ?? this.loadMoreError),
    );
  }
}

class PlaylistSearchNotifier extends StateNotifier<PlaylistSearchState> {
  PlaylistSearchNotifier(this._manager) : super(const PlaylistSearchState());

  static const _pageSize = 30;

  final MusicSourceManager _manager;
  int _requestId = 0;
  String _sourceId = '';

  Future<void> search(String query, String sourceId) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) {
      reset();
      return;
    }

    final requestId = ++_requestId;
    _sourceId = sourceId;
    state = PlaylistSearchState(query: normalizedQuery, isLoading: true);
    await _loadPage(requestId, normalizedQuery, sourceId, 1, replace: true);
  }

  /// 加载下一页（滚动到底部时调用）。
  Future<void> loadMore() async {
    if (state.query.isEmpty ||
        state.isLoading ||
        state.isLoadingMore ||
        !state.hasMore ||
        state.loadMoreError != null) {
      return;
    }
    await _loadPage(
      _requestId,
      state.query,
      _sourceId,
      state.page + 1,
      replace: false,
    );
  }

  /// 底部「加载失败，点击重试」。
  Future<void> retryLoadMore() async {
    if (state.query.isEmpty || state.isLoading || state.isLoadingMore) return;
    state = state.copyWith(clearLoadMoreError: true, hasMore: true);
    await _loadPage(
      _requestId,
      state.query,
      _sourceId,
      state.page + 1,
      replace: false,
    );
  }

  Future<void> _loadPage(
    int requestId,
    String query,
    String sourceId,
    int page, {
    required bool replace,
  }) async {
    if (requestId != _requestId) return;
    if (!replace) {
      state = state.copyWith(isLoadingMore: true, clearLoadMoreError: true);
    }
    try {
      final playlists = await _manager.searchPlaylists(
        query,
        sourceId: sourceId,
        page: page,
        limit: _pageSize,
      );
      if (!mounted || requestId != _requestId) return;
      final merged = replace
          ? playlists
          : _appendUniquePlaylists(state.playlists, playlists);
      final appended = merged.length > state.playlists.length;
      state = state.copyWith(
        query: query,
        playlists: merged,
        page: page,
        isLoading: false,
        isLoadingMore: false,
        // 接口没有 isEnd：只要这一页拿到了新数据就还可能下一页（哪怕不足
        // 请求条数，例如接口每页只给 20 条）；真到末页时下一页返回空 /
        // 全是重复项，这里自然变 false。
        hasMore: playlists.isNotEmpty && (replace || appended),
        clearError: true,
        clearLoadMoreError: true,
      );
    } catch (e) {
      if (!mounted || requestId != _requestId) return;
      if (replace) {
        state = state.copyWith(
          query: query,
          isLoading: false,
          isLoadingMore: false,
          error: _readableError(e),
          hasMore: false,
        );
      } else {
        state = state.copyWith(
          isLoadingMore: false,
          loadMoreError: _readableError(e),
          hasMore: true,
        );
      }
    }
  }

  List<Playlist> _appendUniquePlaylists(
    List<Playlist> current,
    List<Playlist> next,
  ) {
    final result = [...current];
    final seen = result.map((p) => p.id).toSet();
    for (final playlist in next) {
      if (seen.add(playlist.id)) result.add(playlist);
    }
    return result;
  }

  void reset() {
    _requestId++;
    state = const PlaylistSearchState();
  }
}

final playlistSearchControllerProvider =
    StateNotifierProvider<PlaylistSearchNotifier, PlaylistSearchState>((ref) {
      return PlaylistSearchNotifier(ref.watch(musicSourceManagerProvider));
    });

/// 专辑 / 作者搜索结果。
class CollectionSearchState {
  const CollectionSearchState({
    this.query = '',
    this.loading = false,
    this.unsupported = false,
    this.results = const [],
    this.page = 0,
    this.loadingMore = false,
    this.hasMore = false,
    this.error,
    this.loadMoreError,
  });

  final String query;
  final bool loading;

  /// 当前音源不支持搜索专辑 / 作者。
  final bool unsupported;

  final List<SearchCollection> results;
  final int page;
  final bool loadingMore;
  final bool hasMore;

  /// 首屏加载失败原因。
  final String? error;

  /// 下一页加载失败原因。
  final String? loadMoreError;

  CollectionSearchState copyWith({
    String? query,
    bool? loading,
    bool? unsupported,
    List<SearchCollection>? results,
    int? page,
    bool? loadingMore,
    bool? hasMore,
    String? error,
    String? loadMoreError,
    bool clearError = false,
    bool clearLoadMoreError = false,
  }) {
    return CollectionSearchState(
      query: query ?? this.query,
      loading: loading ?? this.loading,
      unsupported: unsupported ?? this.unsupported,
      results: results ?? this.results,
      page: page ?? this.page,
      loadingMore: loadingMore ?? this.loadingMore,
      hasMore: hasMore ?? this.hasMore,
      error: clearError ? null : (error ?? this.error),
      loadMoreError: clearLoadMoreError
          ? null
          : (loadMoreError ?? this.loadMoreError),
    );
  }
}

final collectionSearchProvider =
    StateNotifierProvider<CollectionSearchController, CollectionSearchState>((
      ref,
    ) {
      return CollectionSearchController(ref.watch(musicSourceManagerProvider));
    });

class CollectionSearchController extends StateNotifier<CollectionSearchState> {
  CollectionSearchController(this._manager)
    : super(const CollectionSearchState());

  static const _pageSize = 30;

  final MusicSourceManager _manager;
  int _requestId = 0;
  String _sourceId = '';
  CollectionType _type = CollectionType.album;

  Future<void> search(
    String query,
    String sourceId,
    CollectionType type,
  ) async {
    final keyword = query.trim();
    final requestId = ++_requestId;
    if (keyword.isEmpty) {
      state = const CollectionSearchState();
      return;
    }
    _sourceId = sourceId;
    _type = type;
    if (!_manager.sourceSupportsCollectionSearch(sourceId, type)) {
      state = CollectionSearchState(query: keyword, unsupported: true);
      return;
    }
    state = CollectionSearchState(query: keyword, loading: true);
    await _loadPage(requestId, keyword, sourceId, type, 1, replace: true);
  }

  /// 加载下一页（网格滚动到底部时调用）。
  Future<void> loadMore() async {
    if (state.query.isEmpty ||
        state.loading ||
        state.loadingMore ||
        !state.hasMore ||
        state.loadMoreError != null) {
      return;
    }
    await _loadPage(
      _requestId,
      state.query,
      _sourceId,
      _type,
      state.page + 1,
      replace: false,
    );
  }

  /// 底部「加载失败，点击重试」。
  Future<void> retryLoadMore() async {
    if (state.query.isEmpty || state.loading || state.loadingMore) return;
    state = state.copyWith(clearLoadMoreError: true, hasMore: true);
    await _loadPage(
      _requestId,
      state.query,
      _sourceId,
      _type,
      state.page + 1,
      replace: false,
    );
  }

  Future<void> _loadPage(
    int requestId,
    String keyword,
    String sourceId,
    CollectionType type,
    int page, {
    required bool replace,
  }) async {
    if (requestId != _requestId) return;
    if (!replace) {
      state = state.copyWith(loadingMore: true, clearLoadMoreError: true);
    }
    try {
      final result = await _manager.searchCollections(
        keyword,
        sourceId: sourceId,
        type: type,
        page: page,
        limit: _pageSize,
      );
      if (!mounted || requestId != _requestId) return;
      final merged = replace
          ? result.items
          : _appendUniqueCollections(state.results, result.items);
      state = state.copyWith(
        query: keyword,
        results: merged,
        page: page,
        loading: false,
        loadingMore: false,
        hasMore: !result.isEnd,
        clearError: true,
        clearLoadMoreError: true,
      );
    } catch (e) {
      if (!mounted || requestId != _requestId) return;
      if (replace) {
        state = state.copyWith(
          query: keyword,
          loading: false,
          loadingMore: false,
          error: _readableError(e),
          hasMore: false,
        );
      } else {
        state = state.copyWith(
          loadingMore: false,
          loadMoreError: _readableError(e),
          hasMore: true,
        );
      }
    }
  }

  List<SearchCollection> _appendUniqueCollections(
    List<SearchCollection> current,
    List<SearchCollection> next,
  ) {
    final result = [...current];
    final seen = result.map((c) => '${c.source}:${c.id}').toSet();
    for (final item in next) {
      if (seen.add('${item.source}:${item.id}')) result.add(item);
    }
    return result;
  }
}
