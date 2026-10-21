import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../../shared/widgets/song_list_item.dart';
import '../../../shared/widgets/source_icon.dart';
import '../../../shared/widgets/song_action_sheet.dart';
import '../../../shared/widgets/song_selection.dart';
import '../../player/presentation/mini_player.dart';
import '../application/search_providers.dart';
import '../../library/application/playlist_providers.dart';
import '../domain/models/playlist.dart';
import '../../player/application/playback_controller.dart';
import '../../player/domain/models/song.dart';
import '../../plugin/domain/plugin_types.dart';
import '../../settings/application/settings_providers.dart';

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
    final query = pendingQuery ?? '';
    _inputText = query;
    _controller.text = query;
    _focusNode.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (pendingQuery != null) {
        ref.read(searchQueryProvider.notifier).state = pendingQuery;
        ref.read(pendingSearchQueryProvider.notifier).state = null;
      } else {
        ref.read(searchQueryProvider.notifier).state = '';
        ref.read(searchResultsControllerProvider.notifier).reset();
      }
      final defaultSource = ref.read(defaultSourceIdProvider);
      final currentSource = ref.read(searchSourceIdProvider);
      if (currentSource == 'all' || currentSource != defaultSource) {
        ref.read(searchSourceIdProvider.notifier).state = defaultSource;
      }
      final currentQuery = ref.read(searchQueryProvider).trim();
      if (currentQuery.isNotEmpty) {
        unawaited(
          ref
              .read(searchResultsControllerProvider.notifier)
              .start(currentQuery, ref.read(searchSourceIdProvider)),
        );
      }
    });
    _resultsScrollController.addListener(_handleResultsScroll);
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
    _selection.dispose();
    _resetSearchState();
    super.dispose();
  }

  /// 退出搜索页面时清空本次会话的搜索状态，再次进入时回到初始页
  /// （搜索历史 + 热门搜索），搜索栏不再保留上次的关键词。
  ///
  /// 搜索历史本身由偏好设置持久化，不受影响。
  /// 在 dispose 中同步修改 provider 会触发 Riverpod 生命周期报错，因此
  /// 延迟到 microtask 提交。
  void _resetSearchState() {
    Future.microtask(() {
      try {
        ref.read(searchQueryProvider.notifier).state = '';
        ref.read(searchPageProvider.notifier).state = 1;
        ref.read(searchSuggestInputProvider.notifier).state = '';
        ref.read(searchTabProvider.notifier).state = SearchTab.songs;
        ref.read(searchResultsControllerProvider.notifier).reset();
        ref.read(playlistSearchControllerProvider.notifier).reset();
      } catch (_) {
        // 页面销毁后 ProviderScope 可能已一并销毁（如 App 退出），忽略即可。
      }
    });
  }

  bool get _showSuggest => _isFocused && _inputText.isNotEmpty;

  void _performSearch(String query) {
    if (query.trim().isEmpty) return;
    _focusNode.unfocus();
    ref.read(searchSuggestInputProvider.notifier).state = '';
    ref.read(searchQueryProvider.notifier).state = query;
    ref.read(searchHistoryProvider.notifier).addQuery(query);
    ref.read(searchPageProvider.notifier).state = 1;
    final currentTab = ref.read(searchTabProvider);
    final sourceId = ref.read(searchSourceIdProvider);
    if (currentTab == SearchTab.songs) {
      unawaited(
        ref
            .read(searchResultsControllerProvider.notifier)
            .start(query, sourceId, force: true),
      );
    } else {
      unawaited(
        ref
            .read(playlistSearchControllerProvider.notifier)
            .search(query, sourceId),
      );
    }
  }

  void _handleResultsScroll() {
    if (!_resultsScrollController.hasClients) return;
    final position = _resultsScrollController.position;
    if (position.maxScrollExtent - position.pixels < 360) {
      unawaited(ref.read(searchResultsControllerProvider.notifier).loadMore());
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final searchState = ref.watch(searchResultsControllerProvider);
    final hotTagsAsync = ref.watch(hotSearchTagsProvider);
    final query = ref.watch(searchQueryProvider);
    final sourceId = ref.watch(searchSourceIdProvider);
    final sources = ref.watch(allAvailableSourcesProvider);
    final searchHistory = ref.watch(searchHistoryProvider);

    ref.listen<String>(defaultSourceIdProvider, (previous, next) {
      if (previous != null && previous != next) {
        ref.read(searchSourceIdProvider.notifier).state = next;
        ref.read(searchPageProvider.notifier).state = 1;
        final query = ref.read(searchQueryProvider);
        if (query.isNotEmpty) {
          final currentTab = ref.read(searchTabProvider);
          if (currentTab == SearchTab.songs) {
            unawaited(
              ref
                  .read(searchResultsControllerProvider.notifier)
                  .start(query, next, force: true),
            );
          } else {
            unawaited(
              ref
                  .read(playlistSearchControllerProvider.notifier)
                  .search(query, next),
            );
          }
        }
      }
    });

    ref.listen<String>(searchQueryProvider, (previous, next) {
      // 换了关键词就丢弃旧的选中集合，避免选中「上一批搜索结果」里的歌曲。
      // 延迟到帧后：监听回调可能在 build 阶段触发，直接通知会触发
      // "setState() called during build"。
      if (previous != next && _selection.isActive) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _selection.exit();
        });
      }
      if (next.isEmpty) {
        ref.read(searchResultsControllerProvider.notifier).reset();
        ref.read(playlistSearchControllerProvider.notifier).reset();
      } else if (previous != next) {
        final currentTab = ref.read(searchTabProvider);
        if (currentTab == SearchTab.songs) {
          unawaited(
            ref
                .read(searchResultsControllerProvider.notifier)
                .start(next, ref.read(searchSourceIdProvider)),
          );
        } else {
          unawaited(
            ref
                .read(playlistSearchControllerProvider.notifier)
                .search(next, ref.read(searchSourceIdProvider)),
          );
        }
      }
    });

    ref.listen<String>(searchSourceIdProvider, (previous, next) {
      if (previous != null && previous != next) {
        final query = ref.read(searchQueryProvider);
        if (query.isNotEmpty) {
          final currentTab = ref.read(searchTabProvider);
          if (currentTab == SearchTab.songs) {
            unawaited(
              ref
                  .read(searchResultsControllerProvider.notifier)
                  .start(query, next, force: true),
            );
          } else {
            unawaited(
              ref
                  .read(playlistSearchControllerProvider.notifier)
                  .search(query, next),
            );
          }
        }
      }
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
                          child: searchTab == SearchTab.songs || selecting
                              ? _buildSearchResults(
                                  colors,
                                  searchState,
                                  currentSongId: currentSongId,
                                )
                              : _buildPlaylistResults(
                                  colors,
                                  playlistSearchState,
                                ),
                        ),
                      ],
                    ],
                  ),
                ),
                // 底部迷你播放器（键盘弹出时隐藏）
                MediaQuery.of(context).viewInsets.bottom > 0
                    ? const SizedBox.shrink()
                    : Positioned(
                        left: 0,
                        right: 0,
                        bottom: 20,
                        child: RepaintBoundary(child: const MiniPlayer()),
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
              child: currentSource != null && currentSource.id != 'all'
                  ? _buildSourceIcon(
                      // 同名插件的变体 id 需要还原成平台 id 才能取到对应图标。
                      SourceInfo.baseIdOf(currentSource.id),
                      size: _searchFieldHeight,
                      label: currentSource.name,
                    )
                  : _buildSourceIcon('all', size: _searchFieldHeight),
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
                        style: TextStyle(fontSize: 13, color: colors.textHint),
                      ),
                    ),
                  ),
                ),
              ),
            ],
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
              source.id != 'all'
                  ? _buildSourceIcon(
                      // 同名插件的变体 id 需要还原成平台 id 才能取到对应图标。
                      SourceInfo.baseIdOf(source.id),
                      size: 18,
                      label: source.name,
                    )
                  : _buildSourceIcon('all', size: 18),
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
      if (selectedId != null) {
        ref.read(searchSourceIdProvider.notifier).state = selectedId;
        // 用户最后切换的音源即成为默认音源。
        if (selectedId != 'all') {
          unawaited(
            persistDefaultSourceId(
              ProviderScope.containerOf(context),
              selectedId,
            ),
          );
        }
        ref.read(searchPageProvider.notifier).state = 1;
        final query = ref.read(searchQueryProvider);
        if (query.isNotEmpty) {
          final currentTab = ref.read(searchTabProvider);
          if (currentTab == SearchTab.songs) {
            unawaited(
              ref
                  .read(searchResultsControllerProvider.notifier)
                  .start(query, selectedId, force: true),
            );
          } else {
            unawaited(
              ref
                  .read(playlistSearchControllerProvider.notifier)
                  .search(query, selectedId),
            );
          }
          ref.invalidate(searchSuggestResultsProvider);
        }
      }
    });
  }

  Widget _buildSourceIcon(
    String sourceId, {
    double size = 20,
    String? label,
  }) {
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

  Widget _buildAggregatedResults(
    ThemeColors colors,
    AsyncValue<List<Song>> asyncResults,
  ) {
    final interleavedAsync = ref.watch(interleavedAggregatedProvider);

    return interleavedAsync.when(
      data: (songs) {
        if (songs.isEmpty) return _buildEmptyResult(colors);

        return ListView.builder(
          padding: const EdgeInsets.only(bottom: AppSpacing.xxxl),
          itemCount: songs.length,
          itemExtent: SongListItem.itemExtent,
          cacheExtent: 360,
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: true,
          itemBuilder: (context, index) {
            final song = songs[index];
            final currentSongId = ref.watch(
              playbackControllerProvider.select((s) => s.currentSong?.id),
            );
            return SongListItem(
              song: song,
              index: index,
              showIndex: true,
              showSource: true,
              showCover: true,
              showQuality: true,
              showDuration: true,
              showMenuButton: true,
              // 正在播放的歌曲高亮显示。
              isPlaying: currentSongId != null && currentSongId == song.id,
              // 主操作为「下一首播放」：插到当前播放歌曲之后，
              // 不会把播放队列替换成全部搜索结果。
              onMenuTap: () => SongActionSheet.show(
                context,
                song: song,
                showPlayNextInsteadOfPlay: true,
              ),
              onPlayTap: () async {
                final now = DateTime.now();
                final lastTap = _globalLastTapTime;
                final diff = lastTap != null
                    ? now.difference(lastTap).inMilliseconds
                    : null;
                if (lastTap != null && diff! < _tapDebounceMs) {
                  return;
                }
                _globalLastTapTime = now;
                final controller = ref.read(
                  playbackControllerProvider.notifier,
                );
                await controller.setQueue(songs, startIndex: index);
              },
            );
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => Center(
        child: Text(context.tr('搜索失败'), style: TextStyle(color: colors.textHint)),
      ),
    );
  }

  Widget _buildSingleSourceResults(ThemeColors colors, List<Song> songs) {
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: AppSpacing.xxxl),
      itemCount: songs.length,
      itemExtent: SongListItem.itemExtent,
      cacheExtent: 360,
      addAutomaticKeepAlives: false,
      addRepaintBoundaries: true,
      itemBuilder: (context, index) {
        final song = songs[index];
        final currentSongId = ref.watch(
          playbackControllerProvider.select((s) => s.currentSong?.id),
        );
        return SongListItem(
          song: song,
          index: index,
          showSource: false,
          // 正在播放的歌曲高亮显示。
          isPlaying: currentSongId != null && currentSongId == song.id,
          onPlayTap: () async {
            final now = DateTime.now();
            final lastTap = _globalLastTapTime;
            final diff = lastTap != null
                ? now.difference(lastTap).inMilliseconds
                : null;
            if (lastTap != null && diff! < _tapDebounceMs) {
              return;
            }
            _globalLastTapTime = now;
            final controller = ref.read(playbackControllerProvider.notifier);
            await controller.setQueue(songs, startIndex: index);
          },
        );
      },
    );
  }

  Widget _buildSearchResults(
    ThemeColors colors,
    SearchResultsState state, {
    String? currentSongId,
  }) {
    if (state.isLoading && state.songs.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null && state.songs.isEmpty) {
      return Center(
        child: Text(context.tr('搜索失败'), style: TextStyle(color: colors.textHint)),
      );
    }
    if (state.songs.isEmpty) return _buildEmptyResult(colors);

    final songs = state.songs;
    final showLoadingRow = state.isLoadingMore;
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
      itemCount: songs.length + (showLoadingRow ? 1 : 0),
      cacheExtent: 360,
      addAutomaticKeepAlives: false,
      addRepaintBoundaries: true,
      itemBuilder: (context, index) {
        if (index >= songs.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final song = songs[index];
        return SongListItem(
          song: song,
          index: index,
          showIndex: true,
          showSource: true,
          showCover: true,
          showQuality: true,
          showDuration: true,
          showMenuButton: true,
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
            await controller.setQueue(songs, startIndex: index);
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
                      .start(query, ref.read(searchSourceIdProvider), force: true),
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
        ],
      ),
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

  Widget _buildPlaylistResults(ThemeColors colors, PlaylistSearchState state) {
    if (state.isLoading && state.playlists.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null && state.playlists.isEmpty) {
      return Center(
        child: Text(context.tr('搜索失败'), style: TextStyle(color: colors.textHint)),
      );
    }
    if (state.playlists.isEmpty) return _buildEmptyPlaylistResult(colors);

    // 与「发现 - 歌单」使用同一套网格参数，歌单封面宽度保持一致，
    // 同时随窗口宽度自适应列数（不再固定两列导致封面过宽）。
    final crossAxisCount = ResponsiveLayout.gridCrossAxisCount(context);
    final isTablet = ResponsiveLayout.isTablet(context);

    return GridView.builder(
      padding: EdgeInsets.symmetric(
        horizontal: ResponsiveLayout.horizontalPadding(context),
        vertical: AppSpacing.lg,
      ),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        mainAxisSpacing: isTablet ? 16 : AppSpacing.md,
        crossAxisSpacing: isTablet ? 16 : AppSpacing.md,
        childAspectRatio: isTablet ? 0.88 : 0.82,
      ),
      itemCount: state.playlists.length,
      itemBuilder: (context, index) {
        final playlist = state.playlists[index];
        return _buildPlaylistSearchCard(colors, playlist, index);
      },
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
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(AppRadius.xs),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.play_arrow,
                              size: 10,
                              color: colors.textOnPrimary,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              playlist.playCount!,
                              style: TextStyle(
                                fontSize: 10,
                                color: colors.textOnPrimary,
                              ),
                            ),
                          ],
                        ),
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
