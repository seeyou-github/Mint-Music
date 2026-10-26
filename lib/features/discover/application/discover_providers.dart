import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/discover_repository.dart';
import '../domain/models/playlist.dart';
import '../domain/models/playlist_page.dart';
import '../domain/models/leaderboard.dart';
import '../../player/domain/models/song.dart';
import '../../plugin/application/plugin_providers.dart';
import '../../plugin/application/music_source_manager.dart';
import '../../plugin/domain/plugin_types.dart';
import '../../settings/application/settings_providers.dart';

final discoverRepositoryProvider = Provider<DiscoverRepository>((ref) {
  final manager = ref.watch(musicSourceManagerProvider);
  return DiscoverRepository(manager);
});

final discoverSourceIdProvider = StateProvider<String>(
  (ref) => ref.read(defaultSourceIdProvider),
);

final discoverSupportedSourcesProvider = Provider<List<SourceInfo>>((ref) {
  // 插件初始化 + 内置音源启用/卸载状态 + 插件自带音源开关都会影响这里的列表。
  ref.watch(pluginInitializedProvider);
  ref.watch(builtInSourceStateProvider);
  ref.watch(pluginSourceStateProvider);

  final manager = ref.watch(musicSourceManagerProvider);
  return manager.getDiscoverSupportedSources();
});

final hotPlaylistsProvider = FutureProvider<List<Playlist>>((ref) async {
  final repo = ref.watch(discoverRepositoryProvider);
  final sourceId = ref.watch(discoverSourceIdProvider);
  return repo.getHotPlaylists(sourceId: sourceId);
});

final hotSearchTagsProvider = FutureProvider<List<String>>((ref) async {
  final repo = ref.watch(discoverRepositoryProvider);
  return repo.getHotSearchTags();
});

final searchQueryProvider = StateProvider<String>((ref) => '');

final searchResultsProvider = FutureProvider<List<Song>>((ref) async {
  final query = ref.watch(searchQueryProvider);
  if (query.isEmpty) return [];
  final repo = ref.watch(discoverRepositoryProvider);
  return repo.search(query);
});

final playlistDetailProvider = FutureProvider.family<PlaylistPage, String>((
  ref,
  playlistId,
) async {
  final repo = ref.watch(discoverRepositoryProvider);
  return repo.getPlaylistDetailPage(playlistId);
});

final playlistTagsProvider = FutureProvider<List<PlaylistTagGroup>>((
  ref,
) async {
  // 插件接管平台时，分类由插件提供（插件可能带「置顶分类」）；必须等插件加载
  // 完成再取，否则重启后只能拿到内置源的分类。
  await ref.watch(pluginInitializedProvider.future);
  final repo = ref.watch(discoverRepositoryProvider);
  final sourceId = ref.watch(discoverSourceIdProvider);
  return repo.getPlaylistTags(sourceId: sourceId);
});

final hotPlaylistTagsProvider = FutureProvider<List<PlaylistTag>>((ref) async {
  await ref.watch(pluginInitializedProvider.future);
  final repo = ref.watch(discoverRepositoryProvider);
  final sourceId = ref.watch(discoverSourceIdProvider);
  return repo.getHotPlaylistTags(sourceId: sourceId);
});

final activeTagIdProvider = StateProvider<String>((ref) => '');

final activeCategoryNameProvider = StateProvider<String>((ref) => '热门');

final categoryPlaylistsPageProvider = StateProvider<int>((ref) => 1);

final categoryPlaylistsProvider =
    StateNotifierProvider<
      CategoryPlaylistsNotifier,
      AsyncValue<List<Playlist>>
    >((ref) {
      final repo = ref.watch(discoverRepositoryProvider);
      return CategoryPlaylistsNotifier(repo);
    });

class CategoryPlaylistsNotifier
    extends StateNotifier<AsyncValue<List<Playlist>>> {
  final DiscoverRepository _repo;

  CategoryPlaylistsNotifier(this._repo) : super(const AsyncValue.loading());

  int _page = 1;
  bool _noMore = false;
  bool _loadingMore = false;

  /// 请求序号：切歌 / 切分类时会同时有多个请求在飞，只认最后一次的结果，
  /// 否则慢的旧请求会把新内容覆盖掉。
  int _requestId = 0;

  bool get noMore => _noMore;
  bool get loadingMore => _loadingMore;

  Future<void> fetchPlaylists({
    required String sortId,
    required String tagId,
    String? sourceId,
    bool reset = false,
  }) async {
    // 有请求在飞时，只有「重置」类请求（切歌 / 切分类）可以顶掉旧的继续发，
    // 否则旧请求回来会把新内容覆盖掉。
    if (_loadingMore && !reset) return;

    final requestId = ++_requestId;

    if (reset) {
      _page = 1;
      _noMore = false;
      state = const AsyncValue.loading();
    }

    _loadingMore = true;
    try {
      final (playlists, isEnd) = await _repo.getCategoryPlaylists(
        sortId: sortId,
        tagId: tagId,
        page: _page,
        limit: 30,
        sourceId: sourceId ?? 'wy',
      );
      if (requestId != _requestId) return;

      final current = state.valueOrNull ?? [];
      // 去重：部分插件脚本的分页接口并不支持翻页（例如“推荐歌单”接口不接收
      // offset），会反复返回同一批歌单；重复项不再追加，避免一直刷出
      // 和第一页相同的内容。
      final merged = <String, Playlist>{
        for (final playlist in [...current, ...playlists])
          playlist.id: playlist,
      }.values.toList();

      if (merged.length == current.length) {
        // 没有新歌单 → 已经到底。
        _noMore = true;
        state = AsyncValue.data(current);
      } else {
        state = AsyncValue.data(merged);
      }

      if (isEnd || playlists.length < 30) {
        _noMore = true;
      } else {
        _page++;
      }
    } catch (e, st) {
      if (requestId != _requestId) return;
      state = AsyncValue.error(e, st);
    } finally {
      if (requestId == _requestId) {
        _loadingMore = false;
      }
    }
  }
}

final leaderboardsProvider = FutureProvider<List<Leaderboard>>((ref) async {
  final repo = ref.watch(discoverRepositoryProvider);
  final sourceId = ref.watch(discoverSourceIdProvider);
  return repo.getLeaderboards(sourceId: sourceId);
});

enum DiscoverTab { playlists, leaderboards, radio }

final discoverTabProvider = StateProvider<DiscoverTab>(
  (ref) => DiscoverTab.playlists,
);
