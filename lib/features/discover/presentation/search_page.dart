import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/constants/app_routes.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';
import '../../../shared/widgets/cover_badge.dart';
import '../../../shared/pagination/page_slicer.dart';
import '../../../shared/widgets/load_more_footer.dart';
import '../../../shared/widgets/page_bar.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../../shared/widgets/song_list_item.dart';
import '../../../shared/widgets/source_icon.dart';
import '../../../shared/widgets/song_action_sheet.dart';
import '../../../shared/widgets/song_selection.dart';
import '../application/discover_providers.dart' as discover;
import '../application/search_providers.dart';
import '../../player/application/playback_context.dart';
import '../../library/domain/models/recently_played.dart';
import '../../library/application/playlist_providers.dart';
import '../domain/models/playlist.dart';
import '../domain/models/search_collection.dart';
import '../../player/application/playback_controller.dart';
import '../../player/domain/models/song.dart';
import '../../plugin/domain/plugin_types.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

DateTime? _globalLastTapTime;

class _SearchPageState extends ConsumerState<SearchPage> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  static const _tapDebounceMs = 500;
  bool _isFocused = false;
  String _inputText = '';
  Timer? _debounceTimer;
  final _resultsScrollController = ScrollController();

  /// 歌单 / 专辑 / 作者网格的滚动控制器（翻页后回到顶部）。
  final _gridScrollController = ScrollController();

  // ---- 分页 ----
  /// 搜索歌曲每页条数：按接口首页实际返回量（25~50）决定，首屏回来后再设置。
  final PageSlicer _songPager = PageSlicer(pageSize: 30);
  int? _songPageSize;

  /// 歌单 / 专辑 / 作者搜索结果每页 10 行（每行多少列 × 10 就是每页条数）。
  static const int _resultPageRows = 10;
  final PageSlicer _playlistPager = PageSlicer(pageSize: _resultPageRows);
  final PageSlicer _albumPager = PageSlicer(pageSize: _resultPageRows);
  final PageSlicer _artistPager = PageSlicer(pageSize: _resultPageRows);

  /// 正在为某一页补数据（防止重复触发）。
  bool _pagingLoading = false;

  /// 批量选择控制器（长按搜索结果进入多选模式）。
  final SongSelectionController _selection = SongSelectionController();

  @override
  void initState() {
    super.initState();
    // 仅接受“进入搜索页前显式安排的待搜索词”（如识别页跳转），并在消费后
    // 清空；普通进入一律恢复初始页：关键词、结果列表都归零，搜索栏为空。
    // 注意：providers 必须延迟到 post-frame 阶段修改，否则会触发
    // "Tried to modify a provider while the widget tree was building"。
    final pendingQuery = ref.read(pendingSearchQueryProvider);
    final pendingTab = ref.read(pendingSearchTabProvider);
    final query = pendingQuery ?? '';
    _inputText = query;
    _controller.text = query;
    _focusNode.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (pendingQuery != null) {
        ref.read(pendingSearchQueryProvider.notifier).state = null;
        ref.read(pendingSearchTabProvider.notifier).state = null;
        _syncSourceWithDiscover();
        _searchFromPending(pendingQuery, tab: pendingTab);
        return;
      }
      ref.read(pendingSearchTabProvider.notifier).state = null;
      ref.read(searchQueryProvider.notifier).state = '';
      ref.read(searchResultsControllerProvider.notifier).reset();
      // 搜索音源默认使用「发现页正在使用的音源」：每次进入搜索页都重置一次，
      // 页内切换只在本次搜索有效，退出后不保留。
      _syncSourceWithDiscover();
    });
    _focusNode.addListener(() {
      setState(() => _isFocused = _focusNode.hasFocus);
    });
    _controller.addListener(() {
      final text = _controller.text;
      if (text != _inputText) {
        setState(() => _inputText = text);
        _debounceTimer?.cancel();
        if (text.isEmpty) {
          ref.read(searchSuggestInputProvider.notifier).state = '';
          return;
        }
        _debounceTimer = Timer(const Duration(milliseconds: 300), () {
          ref.read(searchSuggestInputProvider.notifier).state = text;
        });
      }
    });
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    _resultsScrollController.dispose();
    _gridScrollController.dispose();
    _selection.dispose();
    _resetSearchState();
    super.dispose();
  }

  /// 退出搜索页面时清空本次会话的搜索状态，再次进入时回到初始页
  /// （搜索历史 + 热门搜索），搜索栏不再保留上次的关键词。
  ///
  /// 搜索历史本身存在临时库的 search_history 表里，不受影响。
  /// 在 dispose 中同步修改 provider 会触发 Riverpod 生命周期报错，因此
  /// 延迟到 microtask 提交。
  void _resetSearchState() {
    Future.microtask(() {
      try {
        ref.read(searchQueryProvider.notifier).state = '';
        ref.read(searchPageProvider.notifier).state = 1;
        ref.read(searchSuggestInputProvider.notifier).state = '';
        ref.read(searchTabProvider.notifier).state = SearchTab.songs;
        ref.read(pendingSearchTabProvider.notifier).state = null;
        ref.read(searchResultsControllerProvider.notifier).reset();
        ref.read(playlistSearchControllerProvider.notifier).reset();
      } catch (_) {
        // 页面销毁后 ProviderScope 可能已一并销毁（如 App 退出），忽略即可。
      }
    });
  }

  bool get _showSuggest => _isFocused && _inputText.isNotEmpty;

  /// 把搜索音源重置成「发现页正在使用的音源」。
  ///
  /// 搜索页里的音源切换只对本次搜索有效：每次进入页面都重新同步一次，
  /// 退出后再进来仍然跟着发现页的音源。发现页的音源如果不在搜索支持的
  /// 列表里（例如插件还没加载完），退回到列表里的第一个音源。
  void _syncSourceWithDiscover() {
    final sources = ref.read(searchAvailableSourcesProvider);
    final discoverSourceId = ref.read(discover.discoverSourceIdProvider);
    final current = ref.read(searchSourceIdProvider);

    String? target;
    if (sources.any((source) => source.id == discoverSourceId)) {
      target = discoverSourceId;
    } else if (sources.any((source) => source.id == current)) {
      target = current;
    } else if (sources.isNotEmpty) {
      target = sources.first.id;
    }

    if (target != null && target != current) {
      ref.read(searchSourceIdProvider.notifier).state = target;
    }
  }

  void _performSearch(String query) {
    if (query.trim().isEmpty) return;
    ref.read(searchQueryProvider.notifier).state = query;
    ref.read(searchHistoryProvider.notifier).addQuery(query);
    _runSearch(ref.read(searchSourceIdProvider));
  }

  /// 只有最上层的搜索页消费「待搜索词」：被播放页盖住时等它退场，栈里被
  /// 别的页面盖住的旧搜索页直接跳过，交给真正会显示出来的那一页。
  void _consumePendingSearch(String query, {int retries = 30}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(pendingSearchQueryProvider)?.trim() != query) return;
      if (ModalRoute.of(context)?.isCurrent != true) {
        if (retries > 0) {
          _consumePendingSearch(query, retries: retries - 1);
        }
        return;
      }
      ref.read(pendingSearchQueryProvider.notifier).state = null;
      final tab = ref.read(pendingSearchTabProvider);
      ref.read(pendingSearchTabProvider.notifier).state = null;
      _searchFromPending(query, tab: tab);
    });
  }

  /// 收到「待搜索词」（列表 / 播放页「更多」里点歌曲名、歌手名或专辑名）：
  /// 直接在当前搜索页搜索，不再压入第二个搜索页。
  ///
  /// [tab] 为空时回到「歌曲」标签，避免停留在上一次的专辑 / 作者结果；
  /// 点专辑名跳转时指定「专辑」标签。
  void _searchFromPending(String query, {SearchTab? tab}) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    ref.read(searchTabProvider.notifier).state = tab ?? SearchTab.songs;
    setState(() => _inputText = trimmed);
    _controller.text = trimmed;
    _performSearch(trimmed);
  }

  /// 按当前关键词 + 当前标签页发起搜索。
  ///
  /// [sourceId] 由调用方决定：普通搜索用当前音源，切换音源时用新选中的音源。
  /// 切换音源时用户已经看到上一批结果，需要立刻按新音源重查；旧实现只覆盖
  /// 歌曲 / 歌单，切到专辑、作者标签页后再换音源仍停留在旧结果。
  void _runSearch(String sourceId) {
    final query = ref.read(searchQueryProvider).trim();
    if (query.isEmpty) return;

    // 桌面上点击搜索框以外的地方不会自动失焦；预测面板还开着时结果会被它
    // 挡住，看起来像「没有重新搜索」，所以这里主动收起。
    _focusNode.unfocus();
    ref.read(searchSuggestInputProvider.notifier).state = '';
    ref.read(searchPageProvider.notifier).state = 1;
    _resetPagers();

    final tab = ref.read(searchTabProvider);
    switch (tab) {
      case SearchTab.songs:
        unawaited(
          ref
              .read(searchResultsControllerProvider.notifier)
              .start(query, sourceId, force: true),
        );
      case SearchTab.playlists:
        unawaited(
          ref
              .read(playlistSearchControllerProvider.notifier)
              .search(query, sourceId),
        );
      case SearchTab.albums:
      case SearchTab.artists:
        unawaited(
          ref
              .read(collectionSearchProvider.notifier)
              .search(
                query,
                sourceId,
                tab == SearchTab.albums
                    ? CollectionType.album
                    : CollectionType.artist,
              ),
        );
    }
  }

  // ---------------------------------------------------------------- 分页

  PageSlicer _collectionPager(CollectionType type) =>
      type == CollectionType.album ? _albumPager : _artistPager;

  /// 新一轮搜索：所有列表回到第 1 页。
  void _resetPagers() {
    _songPageSize = null;
    _songPager.updatePageSize(30);
    _songPager.reset();
    _playlistPager.reset();
    _albumPager.reset();
    _artistPager.reset();
  }

  /// 歌曲每页条数按接口首页实际返回量来定（25~50）。
  void _syncSongPageSize(int loaded) {
    if (_songPageSize != null || loaded <= 0) return;
    final size = loaded.clamp(25, 50);
    _songPageSize = size;
    _songPager.updatePageSize(size);
  }

  Future<void> _goToSongPage(int page) async {
    if (page < 1) return;
    setState(() => _songPager.jumpTo(page));
    if (_resultsScrollController.hasClients) {
      _resultsScrollController.jumpTo(0);
    }
    await _ensureSongPage();
  }

  /// 当前页数据不够（接口每页比设定的少）时继续取；多出来的留在已加载列表里
  /// 当缓冲，下一页接着用，不会重复请求。
  Future<void> _ensureSongPage() async {
    if (_pagingLoading) return;
    _pagingLoading = true;
    try {
      var guard = 0;
      while (mounted && guard++ < 20) {
        final state = ref.read(searchResultsControllerProvider);
        if (_songPager.missing(state.songs.length, hasMore: state.hasMore) ==
            0) {
          break;
        }
        if (state.isLoadingMore || state.loadMoreError != null) break;
        final before = state.songs.length;
        await ref.read(searchResultsControllerProvider.notifier).loadMore();
        if (!mounted) return;
        if (ref.read(searchResultsControllerProvider).songs.length == before) {
          break;
        }
      }
    } finally {
      _pagingLoading = false;
      if (mounted) {
        final state = ref.read(searchResultsControllerProvider);
        setState(
          () => _songPager.clampTo(state.songs.length, hasMore: state.hasMore),
        );
      }
    }
  }

  Future<void> _goToPlaylistPage(int page) async {
    if (page < 1) return;
    setState(() => _playlistPager.jumpTo(page));
    if (_gridScrollController.hasClients) _gridScrollController.jumpTo(0);
    await _ensurePlaylistPage();
  }

  Future<void> _ensurePlaylistPage() async {
    if (_pagingLoading) return;
    _pagingLoading = true;
    try {
      var guard = 0;
      while (mounted && guard++ < 20) {
        final state = ref.read(playlistSearchControllerProvider);
        if (_playlistPager.missing(
              state.playlists.length,
              hasMore: state.hasMore,
            ) ==
            0) {
          break;
        }
        if (state.isLoadingMore || state.loadMoreError != null) break;
        final before = state.playlists.length;
        await ref.read(playlistSearchControllerProvider.notifier).loadMore();
        if (!mounted) return;
        if (ref.read(playlistSearchControllerProvider).playlists.length ==
            before) {
          break;
        }
      }
    } finally {
      _pagingLoading = false;
      if (mounted) {
        final state = ref.read(playlistSearchControllerProvider);
        setState(
          () => _playlistPager.clampTo(
            state.playlists.length,
            hasMore: state.hasMore,
          ),
        );
      }
    }
  }

  Future<void> _goToCollectionPage(CollectionType type, int page) async {
    if (page < 1) return;
    final pager = _collectionPager(type);
    setState(() => pager.jumpTo(page));
    if (_gridScrollController.hasClients) _gridScrollController.jumpTo(0);
    await _ensureCollectionPage(type);
  }

  Future<void> _ensureCollectionPage(CollectionType type) async {
    if (_pagingLoading) return;
    final pager = _collectionPager(type);
    _pagingLoading = true;
    try {
      var guard = 0;
      while (mounted && guard++ < 20) {
        final state = ref.read(collectionSearchProvider);
        if (pager.missing(state.results.length, hasMore: state.hasMore) == 0) {
          break;
        }
        if (state.loadingMore || state.loadMoreError != null) break;
        final before = state.results.length;
        await ref.read(collectionSearchProvider.notifier).loadMore();
        if (!mounted) return;
        if (ref.read(collectionSearchProvider).results.length == before) break;
      }
    } finally {
      _pagingLoading = false;
      if (mounted) {
        final state = ref.read(collectionSearchProvider);
        setState(
          () => pager.clampTo(state.results.length, hasMore: state.hasMore),
        );
      }
    }
  }

  /// 列表底部的分页条（上面可带一行加载 / 失败提示）。
  Widget _buildPagerFooter({
    required ThemeColors colors,
    required PageSlicer pager,
    required int loaded,
    required bool hasMore,
    required bool loading,
    required String? error,
    required VoidCallback onRetry,
    required ValueChanged<int> onPage,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (loading)
          LoadMoreFooter(status: LoadMoreStatus.loading, colors: colors)
        else if (error != null)
          LoadMoreFooter(
            status: LoadMoreStatus.error,
            colors: colors,
            message: error,
            onRetry: onRetry,
          ),
        PageBar(
          currentPage: pager.page,
          pageCount: pager.pageCount(loaded, hasMore: hasMore),
          loading: loading || _pagingLoading,
          onChanged: onPage,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final searchState = ref.watch(searchResultsControllerProvider);
    final hotTagsAsync = ref.watch(hotSearchTagsProvider);
    final query = ref.watch(searchQueryProvider);
    final sourceId = ref.watch(searchSourceIdProvider);
    final sources = ref.watch(searchAvailableSourcesProvider);
    final searchHistory = ref.watch(searchHistoryProvider);

    // 当前选的音源可能已经被禁用 / 卸载（搜索页的音源切换只在本次搜索有效），
    // 这种情况回退到列表里的第一个音源，避免拿着一个不存在的音源搜出空结果。
    if (sources.isNotEmpty && sources.every((s) => s.id != sourceId)) {
      final fallback = sources.first.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (ref.read(searchSourceIdProvider) == sourceId) {
          ref.read(searchSourceIdProvider.notifier).state = fallback;
        }
      });
    }

    ref.listen<String>(searchQueryProvider, (previous, next) {
      // 换了关键词就丢弃旧的选中集合，避免选中「上一批搜索结果」里的歌曲。
      // 延迟到帧后：监听回调可能在 build 阶段触发，直接通知会触发
      // "setState() called during build"。
      if (previous != next && _selection.isActive) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _selection.exit();
        });
      }
      // 清空关键词时把歌曲 / 歌单结果清掉；非空关键词的搜索由 [_performSearch]
      // 自己发起（那里能同时处理四个标签页），这里不再重复触发。
      if (next.isEmpty) {
        ref.read(searchResultsControllerProvider.notifier).reset();
        ref.read(playlistSearchControllerProvider.notifier).reset();
        _resetPagers();
      }
    });

    ref.listen<String>(searchSourceIdProvider, (previous, next) {
      // 切换音源：按当前关键词 + 当前标签页重新搜索（歌曲 / 歌单 / 专辑 / 作者）。
      if (previous != null && previous != next) {
        _runSearch(next);
      }
    });

    // 搜索页已经打开时（「更多」里点歌名 / 歌手 / 专辑），直接按新关键词搜索；
    // 需要新开搜索页的情况由 initState 消费 pending。
    ref.listen<String?>(pendingSearchQueryProvider, (previous, next) {
      final pending = next?.trim() ?? '';
      if (pending.isEmpty) return;
      _consumePendingSearch(pending);
    });

    final searchTab = ref.watch(searchTabProvider);
    final playlistSearchState = ref.watch(playlistSearchControllerProvider);
    // 正在播放的歌曲（列表里高亮显示）。
    final currentSongId = ref.watch(
      playbackControllerProvider.select((s) => s.currentSong?.id),
    );

    return ListenableBuilder(
      listenable: _selection,
      builder: (context, _) {
        final selecting = _selection.isActive;
        return PopScope(
          // 多选模式下先拦截返回键用于退出选择
          canPop: !selecting,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _selection.exit();
          },
          child: Scaffold(
            backgroundColor: colors.background,
            body: Stack(
              children: [
                SafeArea(
                  child: Column(
                    children: [
                      _buildSearchBar(colors, sources, sourceId),
                      if (_showSuggest)
                        _buildSearchSuggest(colors)
                      else if (query.isEmpty) ...[
                        Expanded(
                          child: hotTagsAsync.when(
                            data: (hotTags) => ListView(
                              padding: const EdgeInsets.only(
                                bottom: AppSpacing.xxxl,
                              ),
                              children: [
                                if (searchHistory.isNotEmpty)
                                  _buildSearchHistory(colors, searchHistory),
                                const SizedBox(height: AppSpacing.lg),
                                _buildHotTags(colors, hotTags),
                              ],
                            ),
                            loading: () => const Center(
                              child: CircularProgressIndicator(),
                            ),
                            error: (_, __) => Center(
                              child: Text(
                                context.tr('加载失败'),
                                style: TextStyle(color: colors.textHint),
                              ),
                            ),
                          ),
                        ),
                      ] else ...[
                        // 多选时用选择栏替换标签栏：避免在多选中切换
                        // 「歌曲 / 歌单」导致选中集合失效。
                        if (selecting)
                          SongSelectionBar(
                            colors: colors,
                            controller: _selection,
                            songs: searchState.songs,
                          )
                        else
                          _buildSearchTabBar(colors, searchTab),
                        // 根据标签页显示对应结果
                        Expanded(
                          child: selecting
                              ? _buildSearchResults(
                                  colors,
                                  searchState,
                                  currentSongId: currentSongId,
                                )
                              : switch (searchTab) {
                                  SearchTab.songs => _buildSearchResults(
                                    colors,
                                    searchState,
                                    currentSongId: currentSongId,
                                  ),
                                  SearchTab.playlists => _buildPlaylistResults(
                                    colors,
                                    playlistSearchState,
                                  ),
                                  SearchTab.albums => _buildCollectionResults(
                                    colors,
                                    CollectionType.album,
                                  ),
                                  SearchTab.artists => _buildCollectionResults(
                                    colors,
                                    CollectionType.artist,
                                  ),
                                },
                        ),
                      ],
                    ],
                  ),
                ),
                if (selecting)
                  Positioned(
                    left: 0,
                    right: 0,
                    // 宽屏（左侧导航栏）布局下内容区没有迷你播放器，
                    // 批量操作栏直接贴底；窄屏才需要避开迷你播放器。
                    bottom: ResponsiveLayout.hasBottomMiniPlayer(context)
                        ? AppSpacing.miniPlayerHeight + AppSpacing.xl
                        : 0,
                    child: SongBatchActionBar(
                      colors: colors,
                      controller: _selection,
                      onPlayNext: _batchPlayNext,
                      onAddToQueue: _batchAddToQueue,
                      onAddToPlaylist: _batchAddToPlaylist,
                      onFavorite: _batchFavorite,
                      onDownload: _batchDownload,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------- 批量选择

  /// 长按搜索结果进入批量选择模式并选中该首。
  void _enterSelection(Song song) {
    if (_selection.isActive) {
      _selection.toggle(song.id);
    } else {
      _selection.enter(song.id);
    }
  }

  List<Song> _selectedSongs() =>
      _selection.selectedSongs(ref.read(searchResultsControllerProvider).songs);

  void _batchPlayNext() {
    final selected = _selectedSongs();
    if (selected.isEmpty) return;
    ref.read(playbackControllerProvider.notifier).insertNext(selected);
    _showMessage('已将 ${selected.length} 首插入到下一首播放');
  }

  void _batchAddToQueue() {
    final selected = _selectedSongs();
    if (selected.isEmpty) return;
    ref.read(playbackControllerProvider.notifier).appendToQueue(selected);
    _showMessage('已将 ${selected.length} 首加入播放列表');
  }

  void _batchAddToPlaylist() {
    final selected = _selectedSongs();
    if (selected.isEmpty) return;
    final colors = ref.read(themeColorsProvider);
    unawaited(showAddSongsToPlaylistSheet(context, ref, colors, selected));
  }

  void _batchDownload() {
    final selected = _selectedSongs();
    if (selected.isEmpty) return;
    unawaited(showBatchDownloadSheet(context, ref, selected));
  }

  Future<void> _batchFavorite() async {
    final selected = _selectedSongs();
    if (selected.isEmpty) return;
    await ref
        .read(playlistsProvider.notifier)
        .addSongsToPlaylist('__favorites__', selected);
    if (mounted) _showMessage('已收藏 ${selected.length} 首');
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.tr(message)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  final _sourceButtonKey = GlobalKey();

  Widget _buildSearchBar(
    ThemeColors colors,
    List<SourceInfo> sources,
    String currentSourceId,
  ) {
    final currentSource = sources
        .where((s) => s.id == currentSourceId)
        .firstOrNull;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        0,
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => context.pop(),
            child: Icon(Icons.arrow_back, size: 24, color: colors.textPrimary),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Container(
              height: _searchFieldHeight,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(AppRadius.full),
              ),
              child: Row(
                children: [
                  Icon(Icons.search, size: 18, color: colors.textHint),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      onSubmitted: _performSearch,
                      onChanged: (value) {
                        if (value.isEmpty) {
                          ref.read(searchQueryProvider.notifier).state = '';
                        }
                      },
                      decoration: InputDecoration(
                        hintText: context.tr('搜索音乐、歌手...'),
                        border: InputBorder.none,
                        filled: false,
                        hintStyle: TextStyle(
                          color: colors.textHint,
                          fontSize: 14,
                        ),
                      ),
                      style: TextStyle(color: colors.textPrimary, fontSize: 14),
                    ),
                  ),
                  if (_controller.text.isNotEmpty)
                    GestureDetector(
                      onTap: () {
                        _controller.clear();
                        ref.read(searchQueryProvider.notifier).state = '';
                      },
                      child: Icon(
                        Icons.close,
                        size: 18,
                        color: colors.textHint,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          // 切换音源按钮：高度与搜索框一致，图标铺满圆形
          GestureDetector(
            key: _sourceButtonKey,
            onTap: () =>
                _showSourceMenu(context, colors, sources, currentSourceId),
            child: Container(
              width: _searchFieldHeight,
              height: _searchFieldHeight,
              decoration: BoxDecoration(
                color: colors.surface,
                shape: BoxShape.circle,
              ),
              // 图标铺满圆形按钮，不留内边距
              clipBehavior: Clip.antiAlias,
              child: currentSource == null
                  ? _buildSourceIcon('', size: _searchFieldHeight)
                  : _buildSourceIcon(
                      // 变体 id 也一起传进去：插件自带图标时优先显示它。
                      currentSource.id,
                      size: _searchFieldHeight,
                      label: currentSource.name,
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// 搜索框与切换音源按钮共用的高度（两者视觉高度保持一致）。
  static const double _searchFieldHeight = 40;

  Widget _buildSearchSuggest(ThemeColors colors) {
    final suggestAsync = ref.watch(searchSuggestResultsProvider);

    return Expanded(
      child: AnimatedOpacity(
        opacity: 1.0,
        duration: const Duration(milliseconds: 200),
        // 预测面板必须算作「搜索框的一部分」：
        // 否则鼠标按下时 TextField 会先判定为「点了输入框外面」并失焦，
        // 面板随 _showSuggest 变成 false 被移除，tap 还没抬起来控件就没了，
        // 表现就是「预测词点不动」。加了这个 Region 后焦点保持，点击生效。
        child: TextFieldTapRegion(
          child: Container(
            margin: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.xs,
              AppSpacing.md,
              0,
            ),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _performSearch(_inputText),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg,
                      vertical: AppSpacing.md,
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.search, size: 18, color: colors.textHint),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: RichText(
                            overflow: TextOverflow.ellipsis,
                            text: TextSpan(
                              style: TextStyle(
                                fontSize: 14,
                                color: colors.textSecondary,
                              ),
                              children: [
                                TextSpan(text: context.tr('直接搜索：')),
                                TextSpan(
                                  text: _inputText,
                                  style: TextStyle(
                                    color: colors.primary,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Divider(height: 1, color: colors.surfaceVariant),
                Flexible(
                  child: suggestAsync.when(
                    data: (suggestions) {
                      if (suggestions.isEmpty) {
                        return Padding(
                          padding: const EdgeInsets.all(AppSpacing.xl),
                          child: Center(
                            child: Text(
                              context.tr('暂无搜索建议'),
                              style: TextStyle(
                                fontSize: 13,
                                color: colors.textHint,
                              ),
                            ),
                          ),
                        );
                      }
                      return ListView.separated(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.xs,
                        ),
                        itemCount: suggestions.length,
                        separatorBuilder: (_, __) => Divider(
                          height: 1,
                          indent: AppSpacing.xxl,
                          color: colors.surfaceVariant,
                        ),
                        itemBuilder: (context, index) {
                          final suggestion = suggestions[index];
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              _controller.text = suggestion;
                              _performSearch(suggestion);
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.lg,
                                vertical: AppSpacing.md,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.music_note,
                                    size: 16,
                                    color: colors.textHint,
                                  ),
                                  const SizedBox(width: AppSpacing.sm),
                                  Expanded(
                                    child: Text(
                                      suggestion,
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: colors.textPrimary,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                    loading: () => const Padding(
                      padding: EdgeInsets.all(AppSpacing.xl),
                      child: Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
                    error: (_, __) => Padding(
                      padding: const EdgeInsets.all(AppSpacing.xl),
                      child: Center(
                        child: Text(
                          context.tr('获取建议失败'),
                          style: TextStyle(
                            fontSize: 13,
                            color: colors.textHint,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showSourceMenu(
    BuildContext context,
    ThemeColors colors,
    List<SourceInfo> sources,
    String currentSourceId,
  ) {
    final renderBox =
        _sourceButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        renderBox.localToGlobal(Offset.zero, ancestor: overlay),
        renderBox.localToGlobal(
          renderBox.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );

    showMenu<String>(
      context: context,
      position: position,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      color: colors.surface,
      elevation: 8,
      items: sources.map((source) {
        return PopupMenuItem<String>(
          value: source.id,
          height: 44,
          child: Row(
            children: [
              _buildSourceIcon(
                // 变体 id 也一起传进去：插件自带图标时优先显示它。
                source.id,
                size: 18,
                label: source.name,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  source.name,
                  style: TextStyle(
                    fontSize: 13,
                    color: source.id == currentSourceId
                        ? colors.primary
                        : colors.textPrimary,
                    fontWeight: source.id == currentSourceId
                        ? FontWeight.w500
                        : FontWeight.normal,
                  ),
                ),
              ),
              if (source.id == currentSourceId)
                Icon(Icons.check, size: 16, color: colors.primary),
            ],
          ),
        );
      }).toList(),
    ).then((selectedId) {
      if (selectedId == null) return;
      if (selectedId == ref.read(searchSourceIdProvider)) return;
      // 只改搜索页自己的音源，不写「默认音源」设置：发现页 / 歌单的音源
      // 不受搜索页影响。页内切换只对本次搜索有效，退出页面后重置。
      // 选中后由上面对 searchSourceIdProvider 的监听统一重新搜索（覆盖全部标签页）。
      ref.read(searchSourceIdProvider.notifier).state = selectedId;
    });
  }

  Widget _buildSourceIcon(String sourceId, {double size = 20, String? label}) {
    return SourceIcon(sourceId: sourceId, size: size, label: label);
  }

  Widget _buildSearchHistory(ThemeColors colors, List<String> history) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                context.tr('搜索历史'),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: colors.textPrimary,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () =>
                    ref.read(searchHistoryProvider.notifier).clearHistory(),
                child: Icon(
                  Icons.delete_outline,
                  size: 18,
                  color: colors.textHint,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: history.map((tag) {
              return GestureDetector(
                onTap: () {
                  _controller.text = tag;
                  _performSearch(tag);
                },
                onLongPress: () =>
                    ref.read(searchHistoryProvider.notifier).removeQuery(tag),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(AppRadius.full),
                  ),
                  child: Text(
                    tag,
                    style: TextStyle(fontSize: 13, color: colors.textSecondary),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildHotTags(ThemeColors colors, List<String> tags) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.tr('热门搜索'),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: tags.asMap().entries.map((entry) {
              final index = entry.key;
              final tag = entry.value;
              return GestureDetector(
                onTap: () {
                  _controller.text = tag;
                  _performSearch(tag);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(AppRadius.full),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (index < 3)
                        Text(
                          '${index + 1}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: index == 0
                                ? Colors.red
                                : index == 1
                                ? Colors.orange
                                : Colors.amber,
                          ),
                        )
                      else
                        Text(
                          '${index + 1}',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.textHint,
                          ),
                        ),
                      const SizedBox(width: 4),
                      Text(
                        tag,
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  /// 歌曲搜索列表底部的状态条；返回 null 表示不需要占位。
  Widget _buildSearchResults(
    ThemeColors colors,
    SearchResultsState state, {
    String? currentSongId,
  }) {
    if (state.isLoading && state.songs.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null && state.songs.isEmpty) {
      return LoadErrorView(
        colors: colors,
        title: context.tr('搜索失败'),
        message: state.error,
        onRetry: () => unawaited(
          ref
              .read(searchResultsControllerProvider.notifier)
              .start(state.query, state.sourceId, force: true),
        ),
      );
    }
    if (state.songs.isEmpty) return _buildEmptyResult(colors);

    _syncSongPageSize(state.songs.length);
    final songs = state.songs;
    // 只渲染当前页（每页按接口首页返回量，25~50 首）。
    final visible = _songPager.slice(songs);
    if (_songPager.missing(songs.length, hasMore: state.hasMore) > 0 &&
        !state.isLoadingMore &&
        state.loadMoreError == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_ensureSongPage());
      });
    }
    final footer = _buildPagerFooter(
      colors: colors,
      pager: _songPager,
      loaded: songs.length,
      hasMore: state.hasMore,
      loading: state.isLoadingMore,
      error: state.loadMoreError,
      onRetry: () => unawaited(
        ref.read(searchResultsControllerProvider.notifier).retryLoadMore(),
      ),
      onPage: (page) => unawaited(_goToSongPage(page)),
    );
    final selecting = _selection.isActive;
    // 宽屏下内容区没有迷你播放器，列表底部只需避开批量操作栏。
    final bottomInset = ResponsiveLayout.hasBottomMiniPlayer(context)
        ? AppSpacing.xxxl
        : AppSpacing.lg;
    return ListView.builder(
      controller: _resultsScrollController,
      // 多选模式下为底部批量操作栏留出空间
      padding: EdgeInsets.only(
        bottom: bottomInset + (selecting ? SongBatchActionBar.height : 0),
      ),
      // 最后一格是分页条
      itemCount: visible.length + 1,
      cacheExtent: 360,
      addAutomaticKeepAlives: false,
      addRepaintBoundaries: true,
      itemBuilder: (context, index) {
        if (index >= visible.length) return footer;
        final song = visible[index];
        // 序号接着上一页继续编号
        final songIndex = _songPager.start + index;
        return SongListItem(
          song: song,
          index: songIndex,
          showIndex: true,
          showCover: true,
          showQuality: true,
          // 歌手名左侧显示音源标签。
          showSource: true,
          showDuration: true,
          showMenuButton: true,
          showPlayedTag: true,
          // 正在播放的歌曲高亮显示。
          isPlaying: currentSongId != null && currentSongId == song.id,
          // 主操作为「下一首播放」：插到当前播放歌曲之后，
          // 不会把播放队列替换成全部搜索结果。
          onMenuTap: () => SongActionSheet.show(
            context,
            song: song,
            showPlayNextInsteadOfPlay: true,
          ),
          selectionMode: selecting,
          selected: _selection.isSelected(song.id),
          onSelectionToggle: (s) => _selection.toggle(s.id),
          // 长按进入批量选择模式
          onLongPress: () => _enterSelection(song),
          onPlayTap: () async {
            final now = DateTime.now();
            final lastTap = _globalLastTapTime;
            final diff = lastTap != null
                ? now.difference(lastTap).inMilliseconds
                : null;
            if (lastTap != null && diff! < _tapDebounceMs) return;
            _globalLastTapTime = now;
            final controller = ref.read(playbackControllerProvider.notifier);
            PlaybackContext.instance.set(PlaybackSourceType.search);
            await controller.setQueue(songs, startIndex: songIndex);
          },
        );
      },
    );
  }

  Widget _buildSearchTabBar(ThemeColors colors, SearchTab currentTab) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        0,
      ),
      child: Row(
        children: [
          _buildTabChip(
            label: context.tr('歌曲'),
            isActive: currentTab == SearchTab.songs,
            colors: colors,
            onTap: () {
              if (currentTab == SearchTab.songs) return;
              ref.read(searchTabProvider.notifier).state = SearchTab.songs;
              // 切换到歌曲标签时，如果有搜索词则触发歌曲搜索
              final query = ref.read(searchQueryProvider).trim();
              if (query.isNotEmpty) {
                unawaited(
                  ref
                      .read(searchResultsControllerProvider.notifier)
                      .start(
                        query,
                        ref.read(searchSourceIdProvider),
                        force: true,
                      ),
                );
              }
            },
          ),
          const SizedBox(width: AppSpacing.sm),
          _buildTabChip(
            label: context.tr('歌单'),
            isActive: currentTab == SearchTab.playlists,
            colors: colors,
            onTap: () {
              if (currentTab == SearchTab.playlists) return;
              ref.read(searchTabProvider.notifier).state = SearchTab.playlists;
              // 切换到歌单标签时，如果有搜索词则触发歌单搜索
              final query = ref.read(searchQueryProvider).trim();
              if (query.isNotEmpty) {
                unawaited(
                  ref
                      .read(playlistSearchControllerProvider.notifier)
                      .search(query, ref.read(searchSourceIdProvider)),
                );
              }
            },
          ),
          const SizedBox(width: AppSpacing.sm),
          _buildTabChip(
            label: context.tr('专辑'),
            isActive: currentTab == SearchTab.albums,
            colors: colors,
            onTap: () =>
                _switchCollectionTab(SearchTab.albums, CollectionType.album),
          ),
          const SizedBox(width: AppSpacing.sm),
          _buildTabChip(
            label: context.tr('作者'),
            isActive: currentTab == SearchTab.artists,
            colors: colors,
            onTap: () =>
                _switchCollectionTab(SearchTab.artists, CollectionType.artist),
          ),
        ],
      ),
    );
  }

  /// 切到专辑 / 作者分类：有搜索词就立刻查一次。
  void _switchCollectionTab(SearchTab tab, CollectionType type) {
    if (ref.read(searchTabProvider) == tab) return;
    ref.read(searchTabProvider.notifier).state = tab;
    final query = ref.read(searchQueryProvider).trim();
    if (query.isEmpty) return;
    unawaited(
      ref
          .read(collectionSearchProvider.notifier)
          .search(query, ref.read(searchSourceIdProvider), type),
    );
  }

  Widget _buildTabChip({
    required String label,
    required bool isActive,
    required ThemeColors colors,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: isActive ? colors.primary : colors.surface,
          borderRadius: BorderRadius.circular(AppRadius.full),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isActive ? colors.textOnPrimary : colors.textSecondary,
          ),
        ),
      ),
    );
  }

  /// 专辑 / 作者结果（网格）。
  Widget _buildCollectionResults(ThemeColors colors, CollectionType type) {
    final state = ref.watch(collectionSearchProvider);

    if (state.unsupported) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.info_outline,
                size: 40,
                color: colors.textHint.withValues(alpha: 0.6),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                context.tr('当前音源不支持搜索${type.label}'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: colors.textHint),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                context.tr('换一个支持该能力的插件音源试试'),
                style: TextStyle(fontSize: 12, color: colors.textHint),
              ),
            ],
          ),
        ),
      );
    }
    if (state.loading && state.results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null && state.results.isEmpty) {
      return LoadErrorView(
        colors: colors,
        title: context.tr('搜索失败'),
        message: state.error,
        onRetry: () => unawaited(
          ref
              .read(collectionSearchProvider.notifier)
              .search(state.query, ref.read(searchSourceIdProvider), type),
        ),
      );
    }
    if (state.results.isEmpty) {
      return Center(
        child: Text(
          context.tr(state.query.isEmpty ? '输入关键词开始搜索' : '未找到相关结果'),
          style: TextStyle(fontSize: 14, color: colors.textHint),
        ),
      );
    }

    final width = MediaQuery.sizeOf(context).width;
    final columns = Platform.isAndroid ? 3 : math.max(2, (width / 260).ceil());
    final pager = _collectionPager(type);
    // 每页 10 行：每页条数 = 10 × 列数。
    pager.updatePageSize(_resultPageRows * columns);
    final visible = pager.slice(state.results);
    if (pager.missing(state.results.length, hasMore: state.hasMore) > 0 &&
        !state.loadingMore &&
        state.loadMoreError == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_ensureCollectionPage(type));
      });
    }
    return _buildPagedGrid(
      sliver: SliverPadding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.sm,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: AppSpacing.md,
            crossAxisSpacing: AppSpacing.md,
            mainAxisExtent: 210,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, index) => _buildCollectionCard(colors, visible[index]),
            childCount: visible.length,
          ),
        ),
      ),
      footer: _buildPagerFooter(
        colors: colors,
        pager: pager,
        loaded: state.results.length,
        hasMore: state.hasMore,
        loading: state.loadingMore,
        error: state.loadMoreError,
        onRetry: () => unawaited(
          ref.read(collectionSearchProvider.notifier).retryLoadMore(),
        ),
        onPage: (page) => unawaited(_goToCollectionPage(type, page)),
      ),
    );
  }

  Widget _buildCollectionCard(ThemeColors colors, SearchCollection item) {
    final isArtist = item.type == CollectionType.artist;
    final subtitle = <String>[
      if (!isArtist && (item.artist ?? '').isNotEmpty) item.artist!,
      if ((item.date ?? '').isNotEmpty) item.date!,
      if (item.worksNum > 0) context.tr('${item.worksNum} 首'),
    ].join(' · ');
    return GestureDetector(
      onTap: () => context.push(
        '${AppRoutes.collectionDetail}?type=${item.type.id}'
        '&id=${Uri.encodeComponent(item.id)}',
        extra: item,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: MusicCoverImage(
                      url: item.coverUrl,
                      fit: BoxFit.cover,
                      errorWidget: Container(
                        color: colors.surfaceVariant,
                        child: Icon(
                          isArtist ? Icons.person : Icons.album,
                          size: 36,
                          color: colors.textHint,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 6,
                    top: 6,
                    child: CoverCountBadge(
                      label: context.tr(item.type.label),
                      fontSize: 11,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      radius: AppRadius.sm,
                      background: Colors.black.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: colors.textPrimary,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: colors.textHint),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaylistResults(ThemeColors colors, PlaylistSearchState state) {
    if (state.isLoading && state.playlists.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null && state.playlists.isEmpty) {
      return LoadErrorView(
        colors: colors,
        title: context.tr('搜索失败'),
        message: state.error,
        onRetry: () => unawaited(
          ref
              .read(playlistSearchControllerProvider.notifier)
              .search(state.query, ref.read(searchSourceIdProvider)),
        ),
      );
    }
    if (state.playlists.isEmpty) return _buildEmptyPlaylistResult(colors);

    // 与「发现 - 歌单」使用同一套网格参数，歌单封面宽度保持一致，
    // 同时随窗口宽度自适应列数（不再固定两列导致封面过宽）。
    final crossAxisCount = ResponsiveLayout.gridCrossAxisCount(context);
    final isTablet = ResponsiveLayout.isTablet(context);

    // 每页 10 行：每页条数 = 10 × 列数。
    _playlistPager.updatePageSize(_resultPageRows * crossAxisCount);
    final visible = _playlistPager.slice(state.playlists);
    if (_playlistPager.missing(state.playlists.length, hasMore: state.hasMore) >
            0 &&
        !state.isLoadingMore &&
        state.loadMoreError == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_ensurePlaylistPage());
      });
    }

    return _buildPagedGrid(
      sliver: SliverPadding(
        padding: EdgeInsets.symmetric(
          horizontal: ResponsiveLayout.horizontalPadding(context),
          vertical: AppSpacing.lg,
        ),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: isTablet ? 16 : AppSpacing.md,
            crossAxisSpacing: isTablet ? 16 : AppSpacing.md,
            childAspectRatio: isTablet ? 0.88 : 0.82,
          ),
          delegate: SliverChildBuilderDelegate((context, index) {
            final playlist = visible[index];
            return _buildPlaylistSearchCard(colors, playlist, index);
          }, childCount: visible.length),
        ),
      ),
      footer: _buildPagerFooter(
        colors: colors,
        pager: _playlistPager,
        loaded: state.playlists.length,
        hasMore: state.hasMore,
        loading: state.isLoadingMore,
        error: state.loadMoreError,
        onRetry: () => unawaited(
          ref.read(playlistSearchControllerProvider.notifier).retryLoadMore(),
        ),
        onPage: (page) => unawaited(_goToPlaylistPage(page)),
      ),
    );
  }

  /// 网格 + 底部分页条的通用容器。
  Widget _buildPagedGrid({required Widget sliver, required Widget footer}) {
    return CustomScrollView(
      controller: _gridScrollController,
      slivers: [
        sliver,
        SliverToBoxAdapter(child: footer),
        const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xxxl)),
      ],
    );
  }

  Widget _buildPlaylistSearchCard(
    ThemeColors colors,
    Playlist playlist,
    int index,
  ) {
    return GestureDetector(
      onTap: () {
        context.push('/playlist/${playlist.id}');
      },
      child: Container(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          colors.primary.withValues(alpha: 0.3 + index * 0.05),
                          colors.surfaceVariant,
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: MusicCoverImage(
                      url: playlist.coverUrl,
                      fit: BoxFit.cover,
                      useDiscoveryCache: true,
                      errorWidget: Icon(
                        Icons.music_note,
                        size: 40,
                        color: colors.textHint,
                      ),
                    ),
                  ),
                  if (playlist.playCount != null &&
                      playlist.playCount!.isNotEmpty)
                    Positioned(
                      top: AppSpacing.xs,
                      right: AppSpacing.xs,
                      child: CoverCountBadge(
                        label: playlist.playCount!,
                        icon: Icons.play_arrow,
                        fontSize: 11,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                          vertical: 2,
                        ),
                        radius: AppRadius.xs,
                        background: Colors.black54,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    playlist.title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: colors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    context.tr('${playlist.songCount}首歌曲'),
                    style: TextStyle(fontSize: 11, color: colors.textHint),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyPlaylistResult(ThemeColors colors) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.queue_music, size: 48, color: colors.textHint),
          const SizedBox(height: AppSpacing.md),
          Text(
            context.tr('未找到相关歌单'),
            style: TextStyle(fontSize: 14, color: colors.textHint),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyResult(ThemeColors colors) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off, size: 48, color: colors.textHint),
          const SizedBox(height: AppSpacing.md),
          Text(
            context.tr('未找到相关结果'),
            style: TextStyle(fontSize: 14, color: colors.textHint),
          ),
        ],
      ),
    );
  }
}
