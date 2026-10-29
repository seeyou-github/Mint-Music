import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/discover_repository.dart';
import '../domain/models/playlist.dart';
import '../domain/models/playlist_page.dart';
import '../domain/models/leaderboard.dart';
import '../../player/domain/models/song.dart';
import '../../custom_sheet/application/custom_sheet_providers.dart';
import '../../plugin/application/plugin_providers.dart';
import '../../plugin/domain/plugin_types.dart';
import '../../settings/application/settings_providers.dart';

final discoverRepositoryProvider = Provider<DiscoverRepository>((ref) {
  final manager = ref.watch(musicSourceManagerProvider);
  // 自定义歌单存在 App 侧（provider 里），仓库按需读取；读的时候不走 ref，
  // 避免歌单列表变化把仓库实例重建、连带清掉它的分页缓存。
  return DiscoverRepository(
    manager,
    customSheets: () => ref.read(customSheetProvider).sheets,
  );
});

final discoverSourceIdProvider = StateProvider<String>(
  (ref) => ref.read(defaultSourceIdProvider),
);

final discoverSupportedSourcesProvider = Provider<List<SourceInfo>>((ref) {
  // 落雪（LX）格式插件没有歌单 / 榜单接口，列在主页切换列表里只会是空页面，
  // 所以统一用「可切换音源」（已过滤落雪格式）。
  return ref.watch(switchableSourcesProvider);
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
  // 完成再取，否则重启后分类可能为空。
  ref.watch(pluginSupportedSourcesProvider);
  await ref.watch(pluginInitializedProvider.future);
  final repo = ref.watch(discoverRepositoryProvider);
  final sourceId = ref.watch(discoverSourceIdProvider);
  return repo.getPlaylistTags(sourceId: sourceId);
});

final hotPlaylistTagsProvider = FutureProvider<List<PlaylistTag>>((ref) async {
  ref.watch(pluginSupportedSourcesProvider);
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
  int? _total;
  String? _loadMoreError;

  /// 接口每页实际返回的条数（插件可能是 20 / 30 等，和界面每页条数不同）。
  /// 跳页直达时用它把界面页码换算成接口页码；首页请求后学习到真实值。
  int? _apiPageSize;

  /// 请求序号：切歌 / 切分类时会同时有多个请求在飞，只认最后一次的结果，
  /// 否则慢的旧请求会把新内容覆盖掉。
  int _requestId = 0;

  bool get noMore => _noMore;
  bool get loadingMore => _loadingMore;
  int? get total => _total;
  String? get loadMoreError => _loadMoreError;

  Future<void> fetchPlaylists({
    required String sortId,
    required String tagId,
    String? sourceId,
    bool reset = false,
  }) async {
    // 有请求在飞时，只有「重置」类请求（切歌 / 切分类）可以顶掉旧的继续发，
    // 否则旧请求回来会把新内容覆盖掉。
    if ((_loadingMore || _noMore) && !reset) return;

    final requestId = ++_requestId;
    _loadMoreError = null;

    if (reset) {
      _page = 1;
      _noMore = false;
      _total = null;
      _apiPageSize = null;
      state = const AsyncValue.loading();
    }

    _loadingMore = true;
    try {
      final result = await _repo.getCategoryPlaylists(
        sortId: sortId,
        tagId: tagId,
        page: _page,
        limit: 30,
        sourceId: sourceId ?? 'wy',
      );
      if (!mounted || requestId != _requestId) return;

      if (result.items.length > (_apiPageSize ?? 0)) {
        _apiPageSize = result.items.length;
      }

      final current = state.valueOrNull ?? [];
      final merged = <String, Playlist>{
        for (final playlist in [...current, ...result.items])
          playlist.id: playlist,
      }.values.toList();
      _total = result.total ?? _total;
      _noMore =
          result.isEnd == true ||
          merged.length == current.length ||
          (_total != null && merged.length >= _total!);
      if (_noMore) {
        _total = merged.length;
      } else {
        _page++;
      }
      state = AsyncValue.data(merged);
    } catch (e, st) {
      if (!mounted || requestId != _requestId) return;
      final current = state.valueOrNull;
      if (current != null && current.isNotEmpty) {
        _loadMoreError = e.toString().replaceFirst('Exception: ', '');
        state = AsyncValue.data(current);
      } else {
        state = AsyncValue.error(e, st);
      }
    } finally {
      if (requestId == _requestId) {
        _loadingMore = false;
      }
    }
  }

  /// 跳页直达：只请求目标页覆盖到的接口页，不把前面的页逐页拉一遍。
  ///
  /// [page] 是界面页码，[pageSize] 是网格每页条数（行数 × 列数）；两者与
  /// 接口每页条数都不同，所以按 [_apiPageSize] 换算出目标数据所在的接口页，
  /// 一般 1~2 个请求就够。成功时缓冲区只剩目标页数据，返回实际停留的页码；
  /// 失败（网络错误，或往回也找不到有数据的页）返回 null，原缓冲保留。
  Future<int?> goToPage({
    required int page,
    required int pageSize,
    required String sortId,
    required String tagId,
    String? sourceId,
  }) async {
    if (page < 1 || pageSize <= 0 || _loadingMore) return null;
    final requestId = ++_requestId;
    _loadMoreError = null;
    _loadingMore = true;
    try {
      var target = page;
      var window = await _fetchWindow(
        page: target,
        pageSize: pageSize,
        sortId: sortId,
        tagId: tagId,
        sourceId: sourceId,
        requestId: requestId,
      );
      if (!mounted || requestId != _requestId) return null;
      // 上游总数偏大时目标页可能取不到数据：往回找最近的有数据页，
      // 避免停在空白页上。最多退 3 页，不让这次跳转变成逐页扫描。
      for (
        var attempt = 0;
        window != null && window.items.isEmpty && target > 1 && attempt < 3;
        attempt++
      ) {
        target--;
        window = await _fetchWindow(
          page: target,
          pageSize: pageSize,
          sortId: sortId,
          tagId: tagId,
          sourceId: sourceId,
          requestId: requestId,
        );
        if (!mounted || requestId != _requestId) return null;
      }
      if (window == null || window.items.isEmpty) return null;

      _page = window.nextApiPage;
      // 往回退过说明目标页之后已经没有数据了（上游总数偏大）：按实际停留的
      // 页收尾，避免分页条仍显示一个点进去是空白的末页。
      final recovered = target != page;
      final fullPage = window.items.length >= pageSize;
      _noMore = recovered || window.ended || !fullPage;
      _total = recovered || !fullPage
          ? (target - 1) * pageSize + window.items.length
          : window.total;
      state = AsyncValue.data(window.items);
      return target;
    } catch (_) {
      if (!mounted || requestId != _requestId) return null;
      // 跳页失败不写进 loadMoreError（底部那个重试按钮对应的是追加下一页），
      // 由页面提示并保留原缓冲，用户重新点页码即可再次直取。
      return null;
    } finally {
      if (requestId == _requestId) {
        _loadingMore = false;
      }
    }
  }

  /// 取界面第 [page] 页的数据：按接口页大小换算后，只请求覆盖这页的接口页。
  Future<_PlaylistWindow?> _fetchWindow({
    required int page,
    required int pageSize,
    required String sortId,
    required String tagId,
    String? sourceId,
    required int requestId,
  }) async {
    final apiPageSize = _apiPageSize ?? 30;
    var offset = (page - 1) * pageSize;
    var apiPage = offset ~/ apiPageSize + 1;
    var skip = offset % apiPageSize;
    final items = <Playlist>[];
    final seen = <String>{};
    var total = _total;
    var ended = false;
    var nextApiPage = apiPage;
    // 界面每页通常不超过接口一页的两倍，循环上限只是兜底。
    for (var attempt = 0; attempt < 6 && items.length < pageSize; attempt++) {
      final result = await _repo.getCategoryPlaylists(
        sortId: sortId,
        tagId: tagId,
        page: apiPage,
        limit: 30,
        sourceId: sourceId ?? 'wy',
      );
      if (!mounted || requestId != _requestId) return null;
      if (result.items.isEmpty) {
        ended = true;
        nextApiPage = apiPage;
        break;
      }
      if (result.items.length > (_apiPageSize ?? 0)) {
        _apiPageSize = result.items.length;
      }
      total = result.total ?? total;
      var index = skip < result.items.length ? skip : result.items.length;
      skip = 0;
      for (; index < result.items.length && items.length < pageSize; index++) {
        final playlist = result.items[index];
        if (seen.add(playlist.id)) items.add(playlist);
      }
      final consumedAll = index >= result.items.length;
      ended = result.isEnd == true;
      // 这页只取走前半段时，下次追加要从这页重新取（重复的会按 id 去掉）。
      nextApiPage = consumedAll ? apiPage + 1 : apiPage;
      if (items.length >= pageSize || ended) break;
      apiPage++;
    }
    return _PlaylistWindow(
      items: items,
      total: total,
      ended: ended,
      nextApiPage: nextApiPage,
    );
  }
}

class _PlaylistWindow {
  const _PlaylistWindow({
    required this.items,
    required this.total,
    required this.ended,
    required this.nextApiPage,
  });

  final List<Playlist> items;
  final int? total;
  final bool ended;
  final int nextApiPage;
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
