import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/debug/temp_trace.dart'; // TEMP-TRACE
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
  TempTrace.log('Home', '热门歌单 开始 source=$sourceId'); // TEMP-TRACE
  try {
    final result = await repo.getHotPlaylists(sourceId: sourceId);
    TempTrace.log('Home', '热门歌单 完成 count=${result.length}'); // TEMP-TRACE
    return result;
  } catch (e, st) {
    TempTrace.error('Home', '热门歌单 失败', e, st); // TEMP-TRACE
    rethrow;
  }
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
  TempTrace.log('Detail', '首屏请求开始 id=$playlistId'); // TEMP-TRACE
  try {
    final page = await repo.getPlaylistDetailPage(playlistId);
    TempTrace.log(
      'Detail',
      '首屏请求完成 id=$playlistId '
      'songs=${page.playlist?.songs.length ?? 0} '
      'isEnd=${page.isEnd} total=${page.total} '
      'title=${page.playlist?.title}',
    ); // TEMP-TRACE
    return page;
  } catch (e, st) {
    TempTrace.error('Detail', '首屏请求失败 id=$playlistId', e, st); // TEMP-TRACE
    rethrow;
  }
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
  TempTrace.log('Home', '歌单分类 开始 source=$sourceId'); // TEMP-TRACE
  try {
    final groups = await repo.getPlaylistTags(sourceId: sourceId);
    TempTrace.log(
      'Home',
      '歌单分类 完成 groups=${groups.length} '
      'tags=${groups.fold<int>(0, (sum, g) => sum + g.tags.length)}',
    ); // TEMP-TRACE
    return groups;
  } catch (e, st) {
    TempTrace.error('Home', '歌单分类 失败', e, st); // TEMP-TRACE
    rethrow;
  }
});

final hotPlaylistTagsProvider = FutureProvider<List<PlaylistTag>>((ref) async {
  ref.watch(pluginSupportedSourcesProvider);
  await ref.watch(pluginInitializedProvider.future);
  final repo = ref.watch(discoverRepositoryProvider);
  final sourceId = ref.watch(discoverSourceIdProvider);
  TempTrace.log('Home', '热门标签 开始 source=$sourceId'); // TEMP-TRACE
  try {
    final tags = await repo.getHotPlaylistTags(sourceId: sourceId);
    TempTrace.log(
      'Home',
      '热门标签 完成 count=${tags.length} '
      'names=${tags.take(6).map((t) => t.name).toList()}',
    ); // TEMP-TRACE
    return tags;
  } catch (e, st) {
    TempTrace.error('Home', '热门标签 失败', e, st); // TEMP-TRACE
    rethrow;
  }
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
    TempTrace.log(
      'Home',
      '分类歌单请求开始 apiPage=$_page sort=$sortId tag=$tagId '
      'source=${sourceId ?? 'wy'} reset=$reset',
    ); // TEMP-TRACE
    try {
      final result = await _repo.getCategoryPlaylists(
        sortId: sortId,
        tagId: tagId,
        page: _page,
        limit: 30,
        sourceId: sourceId ?? 'wy',
      );
      TempTrace.log(
        'Home',
        '分类歌单请求完成 apiPage=$_page items=${result.items.length} '
        'total=${result.total} isEnd=${result.isEnd}',
      ); // TEMP-TRACE
      if (!mounted || requestId != _requestId) return;

      if (result.items.length > (_apiPageSize ?? 0)) {
        _apiPageSize = result.items.length;
      }

      final current = state.valueOrNull ?? [];
      final merged = <String, Playlist>{
        for (final playlist in [...current, ...result.items])
          playlist.id: playlist,
      }.values.toList();
      // 超时 / 失败时插件可能返回 total: 0，不能让它覆盖之前学到的总条数。
      if (result.total != null && result.total! > 0) {
        _total = result.total;
      }
      // 接口给了总条数时只认「已加载 >= 总数」这一个收尾条件。单次请求返回
      // 空 / 全是重复项（网络抖动常见）就置 noMore，分页条会按当前缓冲把
      // 49 页收窄成 10 页。没给总条数才沿用原来的启发式判断。
      final hasApiTotal = _total != null && _total! > 0;
      _noMore = hasApiTotal
          ? merged.length >= _total!
          : result.isEnd == true || merged.length == current.length;
      if (_noMore) {
        // 有总数时保留它，不要用已加载条数覆盖（否则总页数会被改写）。
        _total ??= merged.length;
      } else {
        _page++;
      }
      state = AsyncValue.data(merged);
    } catch (e, st) {
      TempTrace.error('Home', '分类歌单请求失败 apiPage=$_page', e, st); // TEMP-TRACE
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
      // 接口给了总条数（分类歌单会返回 total）时，目标页取不到数据基本都是
      // 这次请求超时 / 失败，不能据此判定「数据到此为止」。以前会往回退到
      // 上一页并按实际停留页收窄 total，49 页就这样被缩成了 10 页，后面的
      // 页码也没法再点。这里直接当失败返回：缓冲、总条数、分页条原样保留，
      // 用户重新点一次页码即可重试。
      final initialTotal = window?.total ?? _total;
      final hasApiTotal = initialTotal != null && initialTotal > 0;
      if (hasApiTotal && (window == null || window.items.isEmpty)) {
        return null;
      }
      // 只有拿不到总条数的音源才沿用「上游总数偏大」的兜底：往回找最近的
      // 有数据页，避免停在空白页上。最多退 3 页，不让跳转变成逐页扫描。
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
      final recovered = target != page;
      final fullPage = window.items.length >= pageSize;
      // 接口给了总条数就以它为准：一次只拿到不满页的数据（网络抖动）或往回
      // 退过，都不能拿窗口条数覆盖总条数，否则分页条会从 49 页缩到当前这一页。
      // 只有拿不到总条数时才按「实际停留页」兜底收尾。
      if (hasApiTotal) {
        _total = window.total ?? _total;
        // 总条数对应的数据没取完就一直保留 hasMore，页码始终按总条数算；
        // 收尾交给 fetchPlaylists 的「已加载 >= total」。
        _noMore = false;
      } else {
        _noMore = recovered || window.ended || !fullPage;
        _total = recovered || !fullPage
            ? (target - 1) * pageSize + window.items.length
            : null;
      }
      state = AsyncValue.data(window.items);
      return target;
    } catch (e) {
      TempTrace.error('Home', '跳页失败 page=$page', e); // TEMP-TRACE
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
      TempTrace.log(
        'Home',
        '跳页取数 uiPage=$page apiPage=$apiPage skip=$skip',
      ); // TEMP-TRACE
      final result = await _repo.getCategoryPlaylists(
        sortId: sortId,
        tagId: tagId,
        page: apiPage,
        limit: 30,
        sourceId: sourceId ?? 'wy',
      );
      TempTrace.log(
        'Home',
        '跳页取数完成 apiPage=$apiPage items=${result.items.length} '
        'total=${result.total} isEnd=${result.isEnd}',
      ); // TEMP-TRACE
      if (!mounted || requestId != _requestId) return null;
      if (result.items.isEmpty) {
        ended = true;
        nextApiPage = apiPage;
        break;
      }
      if (result.items.length > (_apiPageSize ?? 0)) {
        _apiPageSize = result.items.length;
      }
      // 失败时插件可能给 total: 0，保留之前学到的总数（同上）。
      if (result.total != null && result.total! > 0) {
        total = result.total;
      }
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
  TempTrace.log('Home', '榜单列表 开始 source=$sourceId'); // TEMP-TRACE
  try {
    final boards = await repo.getLeaderboards(sourceId: sourceId);
    TempTrace.log(
      'Home',
      '榜单列表 完成 count=${boards.length}',
    ); // TEMP-TRACE
    return boards;
  } catch (e, st) {
    TempTrace.error('Home', '榜单列表 失败', e, st); // TEMP-TRACE
    rethrow;
  }
});

/// 指定音源的榜单列表（「新增热榜数据」里按音源分 tab 用）。
///
/// [leaderboardsProvider] 跟着主页当前音源走，弹框要同时看多个音源，
/// 所以单独按音源缓存一份。
final leaderboardsForSourceProvider =
    FutureProvider.family<List<Leaderboard>, String>((ref, sourceId) async {
      final repo = ref.watch(discoverRepositoryProvider);
      return repo.getLeaderboards(sourceId: sourceId);
    });

enum DiscoverTab { playlists, leaderboards, radio }

final discoverTabProvider = StateProvider<DiscoverTab>(
  (ref) => DiscoverTab.playlists,
);
