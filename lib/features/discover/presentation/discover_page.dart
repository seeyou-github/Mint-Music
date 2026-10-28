import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';
import '../../../shared/widgets/cover_badge.dart';
import '../../radio/presentation/radio_panel.dart';
import '../../../shared/pagination/page_slicer.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../../shared/widgets/page_bar.dart';
import '../../../shared/widgets/load_more_footer.dart';
import '../../../shared/widgets/source_icon.dart';
import '../application/discover_providers.dart';
import '../application/hot_board_providers.dart';
import '../domain/models/hot_board.dart';
import '../domain/models/playlist.dart';
import '../domain/models/leaderboard.dart';
import '../../library/application/playlist_providers.dart';
import '../../library/domain/models/playlist.dart' as local;
import '../../library/domain/models/recently_played.dart';
import '../../player/application/playback_context.dart';
import '../../player/application/playback_controller.dart';
import '../../player/domain/models/song.dart';
import '../../plugin/application/plugin_providers.dart';
import '../../plugin/domain/plugin_types.dart';
import '../../settings/application/settings_providers.dart';

class DiscoverPage extends ConsumerStatefulWidget {
  const DiscoverPage({super.key});

  @override
  ConsumerState<DiscoverPage> createState() => _DiscoverPageState();
}

/// 分类标签栏的滚动行为：桌面端允许用鼠标拖动横向列表。
///
/// Material 默认的 [MaterialScrollBehavior] 只接受触摸 / 触控笔拖动，
/// 桌面端鼠标无法拖动，这里把鼠标与触摸板也加进来。
class _CategoryScrollBehavior extends MaterialScrollBehavior {
  const _CategoryScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.unknown,
  };
}

/// 榜单分类：热榜（自定义展示的榜单 TOP 10）/ 所有（音源榜单列表）。
enum _LeaderboardCategory { hot, all }

class _DiscoverPageState extends ConsumerState<DiscoverPage> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _sourceButtonKey = GlobalKey();
  bool _hasInitialized = false;

  /// 榜单分类，默认「热榜」；每次进入榜单页都会回到「热榜」。
  _LeaderboardCategory _leaderboardCategory = _LeaderboardCategory.hot;

  /// 正在挑选 / 获取热榜数据。
  bool _addingHotBoard = false;

  /// 正在拉取完整榜单并收藏的热榜（按榜单 id）。
  final Set<String> _favoritingHotBoards = {};

  /// 歌单列表分页：每页 10 行（每行多少列 × 10 就是每页条数）。
  static const int _playlistPageRows = 10;
  final PageSlicer _playlistPager = PageSlicer(pageSize: _playlistPageRows);
  final PageSlicer _leaderboardPager = PageSlicer(pageSize: _playlistPageRows);
  final ScrollController _leaderboardScrollController = ScrollController();

  /// 正在为某一页补数据。
  bool _pagingLoading = false;
  int _pagingGeneration = 0;

  @override
  void initState() {
    super.initState();
    _requestNotificationPermission();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _leaderboardScrollController.dispose();
    super.dispose();
  }

  /// 切到第 [page] 页；离缓冲区远的页只取该页，不把中间页逐页拉一遍。
  Future<void> _goToPlaylistPage(int page) async {
    if (page < 1 || _pagingLoading) return;
    final previousPage = _playlistPager.page;
    setState(() => _playlistPager.jumpTo(page));
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    final loaded = ref.read(categoryPlaylistsProvider).valueOrNull?.length ?? 0;
    if (_beyondPlaylistBuffer(page, loaded)) {
      await _jumpToPlaylistPageDirect(page, fallbackPage: previousPage);
    } else {
      await _ensurePlaylistPage();
    }
  }

  /// 目标页是否超出「缓冲区 + 下一页」的连续范围。
  ///
  /// 超出（或往回翻出缓冲区）时走跳页直达——只取目标页，不把中间页
  /// 逐页拉一遍；范围内仍走追加补齐，缓冲可以继续复用。
  bool _beyondPlaylistBuffer(int page, int loaded) {
    final contiguousEnd =
        _playlistPager.bufferBase -
        1 +
        (loaded / _playlistPager.pageSize).ceil();
    return page < _playlistPager.bufferBase || page > contiguousEnd + 1;
  }

  /// 跳页直达：只请求目标页并替换缓冲；失败时退回原页码并提示。
  Future<void> _jumpToPlaylistPageDirect(
    int page, {
    required int fallbackPage,
  }) async {
    final generation = _pagingGeneration;
    setState(() => _pagingLoading = true);
    int? effectivePage;
    try {
      effectivePage = await ref
          .read(categoryPlaylistsProvider.notifier)
          .goToPage(
            page: page,
            pageSize: _playlistPager.pageSize,
            sortId: 'hot',
            tagId: ref.read(activeTagIdProvider),
            sourceId: ref.read(discoverSourceIdProvider),
          );
    } catch (_) {
      effectivePage = null;
    } finally {
      if (mounted && generation == _pagingGeneration) {
        setState(() {
          _pagingLoading = false;
          if (effectivePage != null) {
            _playlistPager.rebase(effectivePage);
          } else {
            _playlistPager.jumpTo(fallbackPage);
          }
        });
      }
    }
    if (effectivePage == null && mounted && generation == _pagingGeneration) {
      _showMessage(context.tr('加载第 $page 页失败'));
    }
  }

  /// 补当前页数据：接口一次给的比一页少时继续取，多给的留着下次用。
  Future<void> _ensurePlaylistPage() async {
    if (_pagingLoading) return;
    final generation = _pagingGeneration;
    setState(() => _pagingLoading = true);
    final notifier = ref.read(categoryPlaylistsProvider.notifier);
    try {
      while (mounted && generation == _pagingGeneration) {
        final loaded =
            ref.read(categoryPlaylistsProvider).valueOrNull?.length ?? 0;
        if (_playlistPager.missing(loaded, hasMore: !notifier.noMore) == 0) {
          break;
        }
        if (notifier.loadingMore || notifier.loadMoreError != null) break;
        final before = loaded;
        await notifier.fetchPlaylists(
          sortId: 'hot',
          tagId: ref.read(activeTagIdProvider),
          sourceId: ref.read(discoverSourceIdProvider),
        );
        if (!mounted) return;
        final after =
            ref.read(categoryPlaylistsProvider).valueOrNull?.length ?? 0;
        if (after == before) break;
      }
    } finally {
      if (mounted && generation == _pagingGeneration) {
        final loaded =
            ref.read(categoryPlaylistsProvider).valueOrNull?.length ?? 0;
        setState(() {
          _pagingLoading = false;
          _playlistPager.clampTo(
            loaded,
            hasMore: !notifier.noMore,
            total: notifier.total,
          );
        });
      }
    }
  }

  Future<void> _requestNotificationPermission() async {
    if (Platform.isAndroid) {
      final status = await Permission.notification.request();
      if (!status.isGranted && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.tr('请开启通知权限以使用后台播放功能')),
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final tab = ref.watch(discoverTabProvider);

    ref.listen<String>(defaultSourceIdProvider, (previous, next) {
      if (previous != null && previous != next) {
        ref.read(discoverSourceIdProvider.notifier).state = next;
      }
    });

    // 每次进入「榜单」都默认打开「热榜」分类。
    ref.listen<DiscoverTab>(discoverTabProvider, (previous, next) {
      if (next == DiscoverTab.leaderboards &&
          previous != DiscoverTab.leaderboards) {
        _leaderboardCategory = _LeaderboardCategory.hot;
      }
    });

    // 监听源切换，自动重新加载歌单
    ref.listen<String>(discoverSourceIdProvider, (previous, next) {
      if (previous != null && previous != next) {
        _leaderboardPager.reset();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(_reloadAfterSourceChange(next));
        });
      }
    });

    // 初始化歌单
    if (!_hasInitialized) {
      _hasInitialized = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _loadPlaylists();
        }
      });
    }

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildHeader(context, colors),
            const SizedBox(height: AppSpacing.sm),
            Expanded(
              child: switch (tab) {
                DiscoverTab.playlists => _buildPlaylistsTab(colors),
                DiscoverTab.leaderboards => _buildLeaderboardsTab(colors),
                DiscoverTab.radio => const RadioPanel(),
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 加载歌单列表（带失败重试）。
  ///
  /// 插件音源（MusicFree 等）在插件系统加载完成前会返回空列表，表现为
  /// 「暂无歌单数据」。这里先等插件系统就绪再请求，若仍为空再补一次重试，
  /// 避免用户必须手动点「重试」才能看到内容。
  Future<void> _loadPlaylists() async {
    _pagingGeneration++;
    _pagingLoading = false;
    _playlistPager.reset();
    await _waitForPlugins();
    if (!mounted) return;

    // 插件自带「置顶分类」时优先选中它，而不是「热门」。
    await _applyDefaultTag();
    if (!mounted) return;

    await ref
        .read(categoryPlaylistsProvider.notifier)
        .fetchPlaylists(
          sortId: 'hot',
          tagId: ref.read(activeTagIdProvider),
          sourceId: ref.read(discoverSourceIdProvider),
          reset: true,
        );
    if (!mounted) return;

    final playlists = ref.read(categoryPlaylistsProvider).valueOrNull;
    if (playlists == null || playlists.isNotEmpty) return;

    // 空结果：再等一次插件加载并重试。
    await _waitForPlugins();
    if (!mounted) return;
    await ref
        .read(categoryPlaylistsProvider.notifier)
        .fetchPlaylists(
          sortId: 'hot',
          tagId: ref.read(activeTagIdProvider),
          sourceId: ref.read(discoverSourceIdProvider),
          reset: true,
        );
  }

  /// 等待插件系统初始化完成（最多等待 8 秒）。
  Future<void> _waitForPlugins() async {
    try {
      await ref
          .read(pluginInitializedProvider.future)
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
  }

  Widget _buildHeader(BuildContext context, ThemeColors colors) {
    final isTablet = ResponsiveLayout.isTablet(context);
    final tab = ref.watch(discoverTabProvider);
    final sourceId = ref.watch(discoverSourceIdProvider);
    final sources = ref.watch(discoverSupportedSourcesProvider);
    final currentSource = sources.where((s) => s.id == sourceId).firstOrNull;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: ResponsiveLayout.horizontalPadding(context),
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          // 「歌单 / 榜单」切换（原「发现音乐」标题的位置）
          _buildTabChip(
            label: context.tr('歌单'),
            isActive: tab == DiscoverTab.playlists,
            colors: colors,
            onTap: () => ref.read(discoverTabProvider.notifier).state =
                DiscoverTab.playlists,
          ),
          const SizedBox(width: AppSpacing.sm),
          _buildTabChip(
            label: context.tr('排行榜'),
            isActive: tab == DiscoverTab.leaderboards,
            colors: colors,
            onTap: () => ref.read(discoverTabProvider.notifier).state =
                DiscoverTab.leaderboards,
          ),
          const SizedBox(width: AppSpacing.sm),
          _buildTabChip(
            label: context.tr('电台'),
            isActive: tab == DiscoverTab.radio,
            colors: colors,
            onTap: () => ref.read(discoverTabProvider.notifier).state =
                DiscoverTab.radio,
          ),
          const SizedBox(width: AppSpacing.md),
          // 搜索框
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: 140,
                  maxWidth: isTablet ? 420 : 300,
                ),
                child: _buildSearchBar(context, colors),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          // 切换音源（插件）按钮：放在搜索框右侧，高度与搜索框一致，图标铺满圆形
          GestureDetector(
            key: _sourceButtonKey,
            onTap: () => _showSourceMenu(context, colors, sources, sourceId),
            child: Container(
              width: _searchBarHeight,
              height: _searchBarHeight,
              decoration: BoxDecoration(
                color: colors.surface,
                shape: BoxShape.circle,
              ),
              // 图标铺满圆形按钮，不留内边距
              clipBehavior: Clip.antiAlias,
              child: currentSource != null
                  ? _buildSourceIcon(
                      // 变体 id 也一起传进去：插件自带图标时优先显示它。
                      currentSource.id,
                      size: _searchBarHeight,
                      label: currentSource.name,
                    )
                  : Icon(
                      Icons.music_note,
                      size: _searchBarHeight,
                      color: colors.textSecondary,
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// 搜索框与切换音源按钮共用的高度（两者视觉高度保持一致）。
  static const double _searchBarHeight = 40;

  Widget _buildSearchBar(BuildContext context, ThemeColors colors) {
    return GestureDetector(
      onTap: () => context.push('/search'),
      child: Container(
        height: _searchBarHeight,
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
              child: Text(
                context.tr('搜索音乐、歌手...'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.textHint, fontSize: 14),
              ),
            ),
          ],
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
                      // 变体 id 也一起传进去：插件自带图标时优先显示它。
                      source.id,
                      size: 18,
                      label: source.name,
                    )
                  : _buildSourceIcon('all', size: 18),
              const SizedBox(width: 8),
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
      if (selectedId != null && selectedId != currentSourceId) {
        ref.read(discoverSourceIdProvider.notifier).state = selectedId;
        // 用户最后切换的音源即成为默认音源。
        unawaited(
          persistDefaultSourceId(
            ProviderScope.containerOf(context),
            selectedId,
          ),
        );
        ref.read(activeTagIdProvider.notifier).state = '';
        ref.read(activeCategoryNameProvider.notifier).state = '热门';
        // 分类与歌单交给 discoverSourceIdProvider 的监听统一处理（会自动选中
        // 置顶分类）。这里不要再发一次请求：两次请求会互相覆盖，导致
        // 「推荐」分类里显示成「热门」的内容。
      }
    });
  }

  Widget _buildSourceIcon(String sourceId, {double size = 20, String? label}) {
    return SourceIcon(sourceId: sourceId, size: size, label: label);
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
          vertical: AppSpacing.sm,
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

  Widget _buildPlaylistsTab(ThemeColors colors) {
    final tagsAsync = ref.watch(playlistTagsProvider);
    final hotTagsAsync = ref.watch(hotPlaylistTagsProvider);
    final activeTagId = ref.watch(activeTagIdProvider);
    final activeCategoryName = ref.watch(activeCategoryNameProvider);
    final playlistsAsync = ref.watch(categoryPlaylistsProvider);

    return Column(
      children: [
        _buildCategoryBar(
          colors,
          tagsAsync,
          hotTagsAsync,
          activeTagId,
          activeCategoryName,
        ),
        const SizedBox(height: AppSpacing.md),
        Expanded(
          child: playlistsAsync.when(
            data: (playlists) {
              if (playlists.isEmpty) {
                // 插件音源可能只提供搜索 / 播放地址，不提供歌单与榜单，
                // 这时给出说明，避免用户以为是加载失败。
                final sourceId = ref.read(discoverSourceIdProvider);
                final hasDiscoverContent = ref
                    .read(musicSourceManagerProvider)
                    .sourceHasDiscoverContent(sourceId);
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.library_music_outlined,
                        size: 48,
                        color: colors.textHint,
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        hasDiscoverContent
                            ? context.tr('暂无歌单数据')
                            : context.tr('该音源不提供歌单和榜单'),
                        style: TextStyle(color: colors.textHint),
                      ),
                      if (hasDiscoverContent) ...[
                        const SizedBox(height: AppSpacing.md),
                        TextButton(
                          onPressed: () => _loadPlaylists(),
                          child: Text(context.tr('重试')),
                        ),
                      ],
                    ],
                  ),
                );
              }
              return _buildPlaylistGrid(colors, playlists);
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, __) => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, size: 48, color: colors.textHint),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    context.tr('加载失败'),
                    style: TextStyle(color: colors.textHint),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextButton(
                    onPressed: () => _loadPlaylists(),
                    child: Text(context.tr('重试')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCategoryBar(
    ThemeColors colors,
    AsyncValue<List<PlaylistTagGroup>> tagsAsync,
    AsyncValue<List<PlaylistTag>> hotTagsAsync,
    String activeTagId,
    String activeCategoryName,
  ) {
    final hotTags = hotTagsAsync.valueOrNull ?? const <PlaylistTag>[];
    // 置顶分类（插件可用 `__pinned__` 前缀标记）排在「热门」之前。
    final pinnedTags = hotTags
        .where((tag) => tag.isPinned)
        .toList(growable: false);
    final normalTags = hotTags
        .where((tag) => !tag.isPinned)
        .toList(growable: false);
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          // 分类标签：数量多时支持鼠标拖动 / 触摸左右滑动。
          Expanded(
            child: ScrollConfiguration(
              behavior: const _CategoryScrollBehavior(),
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(left: AppSpacing.lg),
                children: [
                  for (final tag in pinnedTags)
                    Padding(
                      padding: const EdgeInsets.only(right: AppSpacing.sm),
                      child: _buildTagChip(
                        label: tag.name,
                        isActive: activeTagId == tag.id,
                        colors: colors,
                        onTap: () => _onSelectTag(tag.id, tag.name),
                      ),
                    ),
                  _buildTagChip(
                    label: context.tr('热门'),
                    isActive: activeTagId.isEmpty,
                    colors: colors,
                    onTap: () => _onSelectTag('', '热门'),
                  ),
                  for (final tag in normalTags)
                    Padding(
                      padding: const EdgeInsets.only(left: AppSpacing.sm),
                      child: _buildTagChip(
                        label: tag.name,
                        isActive: activeTagId == tag.id,
                        colors: colors,
                        onTap: () => _onSelectTag(tag.id, tag.name),
                      ),
                    ),
                ],
              ),
            ),
          ),
          // 「更多分类」固定在最右侧，分类过多时也不会被挤出可视区域。
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.sm,
              right: AppSpacing.lg,
            ),
            child: _buildMoreCategoryButton(colors, tagsAsync, activeTagId),
          ),
        ],
      ),
    );
  }

  Widget _buildTagChip({
    required String label,
    required bool isActive,
    required ThemeColors colors,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isActive
              ? colors.primary.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
            color: isActive ? colors.primary : colors.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildMoreCategoryButton(
    ThemeColors colors,
    AsyncValue<List<PlaylistTagGroup>> tagsAsync,
    String activeTagId,
  ) {
    return GestureDetector(
      onTap: () => _showCategoryBottomSheet(colors, tagsAsync, activeTagId),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          context.tr('更多分类'),
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w400,
            color: colors.textSecondary,
          ),
        ),
      ),
    );
  }

  /// 「更多分类」弹层：高度为窗口高度的 60%，分类按「语种 / 分类…」纵向平铺，
  /// 内容超出时可上下滚动，右侧显示滚动条。
  void _showCategoryBottomSheet(
    ThemeColors colors,
    AsyncValue<List<PlaylistTagGroup>> tagsAsync,
    String activeTagId,
  ) {
    final sheetHeight = MediaQuery.sizeOf(context).height * 0.6;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      sheetAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 220),
        reverseDuration: Duration(milliseconds: 180),
      ),
      backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      builder: (ctx) {
        return tagsAsync.when(
          data: (groups) {
            if (groups.isEmpty) {
              return SizedBox(
                height: sheetHeight,
                child: Center(child: Text(context.tr('暂无分类数据'))),
              );
            }
            return SizedBox(
              height: sheetHeight,
              child: _CategorySheetContent(
                groups: groups,
                activeTagId: activeTagId,
                colors: colors,
                onSelect: (tagId, name) {
                  _onSelectTag(tagId, name);
                  Navigator.pop(ctx);
                },
              ),
            );
          },
          loading: () => SizedBox(
            height: sheetHeight,
            child: const Center(child: CircularProgressIndicator()),
          ),
          error: (_, __) => SizedBox(
            height: sheetHeight,
            child: Center(child: Text(context.tr('加载分类失败'))),
          ),
        );
      },
    );
  }

  /// 切换音源后重新加载歌单。
  Future<void> _reloadAfterSourceChange(String sourceId) async {
    if (!mounted) return;
    _pagingGeneration++;
    _pagingLoading = false;
    _playlistPager.reset();
    ref.read(activeTagIdProvider.notifier).state = '';
    ref.read(activeCategoryNameProvider.notifier).state = '热门';
    // 插件自带「置顶分类」时优先选中它，而不是「热门」。
    await _applyDefaultTag();
    if (!mounted) return;
    ref
        .read(categoryPlaylistsProvider.notifier)
        .fetchPlaylists(
          sortId: 'hot',
          tagId: ref.read(activeTagIdProvider),
          sourceId: sourceId,
          reset: true,
        );
  }

  /// 选中默认分类。
  ///
  /// 插件可以在分类 id 上加 `__pinned__` 前缀声明「置顶分类」（例如网易云插件
  /// 的「推荐」歌单），这时优先选中它；没有置顶分类就保持「热门」。
  Future<void> _applyDefaultTag() async {
    // 切换音源后，分类 provider 的依赖变化是由 Riverpod 在微任务里失效的，
    // 直接读 future 可能拿到上一个音源的旧分类（于是置顶分类没被选中，
    // 列表显示成「热门」的内容）。这里先让出一次微任务再强制刷新，确保
    // 拿到的是当前音源的分类。
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    ref.invalidate(hotPlaylistTagsProvider);
    try {
      await ref.read(hotPlaylistTagsProvider.future);
    } catch (_) {}
    if (!mounted) return;
    final tags =
        ref.read(hotPlaylistTagsProvider).valueOrNull ?? const <PlaylistTag>[];
    final pinned = tags.where((tag) => tag.isPinned).toList();
    if (pinned.isEmpty) return;
    final tag = pinned.first;
    ref.read(activeTagIdProvider.notifier).state = tag.id;
    ref.read(activeCategoryNameProvider.notifier).state = tag.name;
  }

  void _onSelectTag(String tagId, String name) {
    _pagingGeneration++;
    _pagingLoading = false;
    _playlistPager.reset();
    ref.read(activeTagIdProvider.notifier).state = tagId;
    ref.read(activeCategoryNameProvider.notifier).state = name;
    final srcId = ref.read(discoverSourceIdProvider);
    ref
        .read(categoryPlaylistsProvider.notifier)
        .fetchPlaylists(
          sortId: 'hot',
          tagId: tagId,
          sourceId: srcId,
          reset: true,
        );
  }

  Widget _buildPlaylistGrid(ThemeColors colors, List<Playlist> playlists) {
    final notifier = ref.read(categoryPlaylistsProvider.notifier);
    final crossAxisCount = ResponsiveLayout.gridCrossAxisCount(context);
    final isTablet = ResponsiveLayout.isTablet(context);

    // 每页 10 行：每行 crossAxisCount 个，所以每页 10 × 列数 个。
    _playlistPager.updatePageSize(_playlistPageRows * crossAxisCount);
    _playlistPager.clampTo(
      playlists.length,
      hasMore: !notifier.noMore,
      total: notifier.total,
    );
    final visible = _playlistPager.slice(playlists);
    final pageCount = _playlistPager.pageCount(
      playlists.length,
      hasMore: !notifier.noMore,
      total: notifier.total,
    );
    if (_playlistPager.missing(playlists.length, hasMore: !notifier.noMore) >
            0 &&
        !notifier.loadingMore &&
        notifier.loadMoreError == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_ensurePlaylistPage());
      });
    }

    return CustomScrollView(
      controller: _scrollController,
      cacheExtent: 360,
      slivers: [
        SliverPadding(
          padding: EdgeInsets.only(
            left: ResponsiveLayout.horizontalPadding(context),
            right: ResponsiveLayout.horizontalPadding(context),
            top: 0,
            bottom: AppSpacing.xxxl,
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
              return RepaintBoundary(
                child: _buildPlaylistCard(colors, playlist, index),
              );
            }, childCount: visible.length),
          ),
        ),
        SliverToBoxAdapter(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (notifier.loadingMore || _pagingLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.xs),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              if (notifier.loadMoreError != null)
                LoadMoreFooter(
                  status: LoadMoreStatus.error,
                  colors: colors,
                  message: notifier.loadMoreError,
                  onRetry: () async {
                    await notifier.fetchPlaylists(
                      sortId: 'hot',
                      tagId: ref.read(activeTagIdProvider),
                      sourceId: ref.read(discoverSourceIdProvider),
                    );
                    if (mounted) await _ensurePlaylistPage();
                  },
                ),
              PageBar(
                currentPage: _playlistPager.page,
                pageCount: pageCount,
                totalKnown: notifier.total != null || notifier.noMore,
                loading: notifier.loadingMore || _pagingLoading,
                onChanged: (page) => unawaited(_goToPlaylistPage(page)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPlaylistCard(ThemeColors colors, Playlist playlist, int index) {
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
                      cacheWidth: 400,
                      cacheHeight: 400,
                      filterQuality: FilterQuality.high,
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

  Widget _buildLeaderboardsTab(ThemeColors colors) {
    final isHot = _leaderboardCategory == _LeaderboardCategory.hot;
    return Column(
      children: [
        SizedBox(
          height: 36,
          child: Row(
            children: [
              // 分类标签：数量增多时支持鼠标拖动 / 触摸左右滑动。
              Expanded(
                child: ScrollConfiguration(
                  behavior: const _CategoryScrollBehavior(),
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.only(left: AppSpacing.lg),
                    children: [
                      _buildTagChip(
                        label: context.tr('热榜'),
                        isActive: isHot,
                        colors: colors,
                        onTap: () => _selectLeaderboardCategory(
                          _LeaderboardCategory.hot,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(left: AppSpacing.sm),
                        child: _buildTagChip(
                          label: context.tr('所有'),
                          isActive: !isHot,
                          colors: colors,
                          onTap: () => _selectLeaderboardCategory(
                            _LeaderboardCategory.all,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // 「新增热榜数据」固定在最右侧，分类再长也不会被挤出去。
              Padding(
                padding: const EdgeInsets.only(
                  left: AppSpacing.sm,
                  right: AppSpacing.lg,
                ),
                child: _buildAddHotBoardButton(colors),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Expanded(
          child: isHot
              ? _buildHotBoardTab(colors)
              : _buildAllLeaderboardsTab(colors),
        ),
      ],
    );
  }

  void _selectLeaderboardCategory(_LeaderboardCategory category) {
    if (_leaderboardCategory == category) return;
    setState(() => _leaderboardCategory = category);
  }

  Widget _buildAddHotBoardButton(ThemeColors colors) {
    return Tooltip(
      message: context.tr('新增热榜数据'),
      child: MouseRegion(
        cursor: _addingHotBoard
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: _addingHotBoard ? null : () => unawaited(_addHotBoard()),
          child: Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colors.surface,
            ),
            child: _addingHotBoard
                ? Padding(
                    padding: const EdgeInsets.all(8),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.primary,
                    ),
                  )
                : Icon(Icons.add, size: 20, color: colors.textSecondary),
          ),
        ),
      ),
    );
  }

  /// 「热榜」分类：没有数据时给出引导，有数据时逐个展示榜单 TOP 10。
  Widget _buildHotBoardTab(ThemeColors colors) {
    return ref
        .watch(currentHotBoardsProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 48, color: colors.textHint),
                const SizedBox(height: AppSpacing.md),
                Text(
                  context.tr('热榜数据加载失败'),
                  style: TextStyle(color: colors.textHint),
                ),
                const SizedBox(height: AppSpacing.md),
                TextButton(
                  onPressed: () => ref.invalidate(hotBoardsProvider),
                  child: Text(context.tr('重试')),
                ),
              ],
            ),
          ),
          data: (boards) {
            final visible = [
              for (final board in boards)
                if (board.songs.isNotEmpty) board,
            ];
            if (visible.isEmpty) {
              return _buildHotBoardEmpty(colors);
            }
            return _buildHotBoardContent(colors, visible);
          },
        );
  }

  Widget _buildHotBoardEmpty(ThemeColors colors) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.local_fire_department_outlined,
            size: 48,
            color: colors.textHint,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            context.tr('当前音源还没有热榜数据'),
            style: TextStyle(color: colors.textHint),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            context.tr('点击右上角 + 选择要展示的榜单'),
            style: TextStyle(fontSize: 12, color: colors.textHint),
          ),
          const SizedBox(height: AppSpacing.md),
          OutlinedButton.icon(
            onPressed: _addingHotBoard ? null : () => unawaited(_addHotBoard()),
            icon: const Icon(Icons.add, size: 18),
            label: Text(context.tr('选择榜单')),
          ),
        ],
      ),
    );
  }

  Widget _buildHotBoardContent(ThemeColors colors, List<HotBoard> boards) {
    final horizontalPadding = ResponsiveLayout.horizontalPadding(context);
    return CustomScrollView(
      cacheExtent: 480,
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            AppSpacing.sm,
            horizontalPadding,
            AppSpacing.xxxl,
          ),
          sliver: SliverToBoxAdapter(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final columns = _hotBoardColumns(constraints.maxWidth);
                const spacing = AppSpacing.md;
                final width =
                    (constraints.maxWidth - spacing * (columns - 1)) / columns;
                return Wrap(
                  spacing: spacing,
                  runSpacing: spacing,
                  children: [
                    for (final board in boards)
                      SizedBox(
                        width: width,
                        child: _buildHotBoardCard(colors, board),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// 热榜列数：桌面一般 3 列、宽屏 4 列；手机竖屏 1 列，平板竖屏 2 列。
  int _hotBoardColumns(double width) {
    if (width >= 1680) return 4;
    if (width >= 1000) return 3;
    if (width >= 640) return 2;
    return 1;
  }

  Widget _buildHotBoardCard(ThemeColors colors, HotBoard board) {
    final favorited = _isHotBoardFavorited(board);
    final favoriting = _favoritingHotBoards.contains(board.id);
    return Container(
      decoration: BoxDecoration(
        // 与左侧栏同色：榜单卡片是内容区里的一块面板。
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: () => _openHotBoardDetail(board),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    child: SizedBox(
                      width: 86,
                      height: 86,
                      child: MusicCoverImage(
                        url: board.coverUrl,
                        fit: BoxFit.cover,
                        useDiscoveryCache: true,
                        errorWidget: Icon(
                          Icons.show_chart,
                          size: 32,
                          color: colors.textHint,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        board.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          height: 1.15,
                          color: colors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Row(
                        children: [
                          _buildHotBoardButton(
                            colors,
                            icon: Icons.play_arrow_rounded,
                            tooltip: context.tr('播放'),
                            onTap: () => unawaited(_playHotSong(board, 0)),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          _buildHotBoardButton(
                            colors,
                            icon: favorited
                                ? Icons.favorite
                                : Icons.favorite_border,
                            tooltip: context.tr(favorited ? '取消收藏' : '收藏'),
                            color: favorited ? colors.primary : null,
                            loading: favoriting,
                            onTap: () =>
                                unawaited(_toggleHotBoardFavorite(board)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          for (var i = 0; i < board.songs.length && i < 10; i++)
            _buildHotSongItem(colors, board, i),
          _buildHotBoardFooter(colors, board),
        ],
      ),
    );
  }

  Widget _buildHotBoardButton(
    ThemeColors colors, {
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    Color? color,
    bool loading = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colors.surfaceVariant,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: loading
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.primary,
                  ),
                )
              : Icon(icon, size: 20, color: color ?? colors.textPrimary),
        ),
      ),
    );
  }

  Widget _buildHotBoardFooter(ThemeColors colors, HotBoard board) {
    return InkWell(
      onTap: () => _openHotBoardDetail(board),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(
              context.tr('查看全部'),
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
            Icon(Icons.chevron_right, size: 16, color: colors.textSecondary),
            const SizedBox(width: AppSpacing.md),
          ],
        ),
      ),
    );
  }

  void _openHotBoardDetail(HotBoard board) {
    context.push('/playlist/${board.id}?type=rank');
  }

  bool _isHotBoardFavorited(HotBoard board) {
    final playlists = ref.watch(playlistsProvider).valueOrNull;
    return playlists?.any((item) => item.meta['discoverId'] == board.id) ??
        false;
  }

  /// 收藏整个榜单：先按页取回完整歌曲，再存进「我的歌单」。
  Future<void> _toggleHotBoardFavorite(HotBoard board) async {
    if (_favoritingHotBoards.contains(board.id)) return;
    final playlists =
        ref.read(playlistsProvider).valueOrNull ?? const <local.Playlist>[];
    final existing = playlists
        .where((item) => item.meta['discoverId'] == board.id)
        .firstOrNull;
    if (existing != null) {
      await ref.read(playlistsProvider.notifier).deletePlaylist(existing.id);
      return;
    }

    setState(() => _favoritingHotBoards.add(board.id));
    try {
      final songs = await _fetchAllHotBoardSongs(board);
      if (!mounted) return;
      if (songs.isEmpty) {
        _showMessage(context.tr('没有获取到榜单歌曲'));
        return;
      }
      await ref
          .read(playlistsProvider.notifier)
          .createPlaylistFromModel(
            local.Playlist(
              id: 'discover_${Uri.encodeComponent(board.id)}',
              name: board.name,
              coverImgUrl: board.coverUrl ?? '',
              source: board.source,
              createTime: DateTime.now(),
              updateTime: DateTime.now(),
              songs: songs,
              meta: {'discoverId': board.id, 'type': 'discover_playlist'},
            ),
          );
      if (mounted) _showMessage(context.tr('已收藏到我的歌单'));
    } catch (e) {
      if (mounted) {
        _showMessage(
          context.tr('收藏失败：${e.toString().replaceFirst('Exception: ', '')}'),
        );
      }
    } finally {
      if (mounted) setState(() => _favoritingHotBoards.remove(board.id));
    }
  }

  /// 热榜里只存了前 10 首，收藏时从第 1 页继续取到末页。
  Future<List<Song>> _fetchAllHotBoardSongs(HotBoard board) async {
    final seen = <String>{};
    final all = <Song>[];
    for (final song in board.songs) {
      if (seen.add(song.id)) all.add(song);
    }
    final repository = ref.read(discoverRepositoryProvider);
    var emptyStreak = 0;
    for (var page = 1; page <= 50; page++) {
      final result = await repository.getPlaylistDetailPage(
        board.id,
        page: page,
      );
      var added = 0;
      for (final song in result.playlist?.songs ?? const <Song>[]) {
        if (seen.add(song.id)) {
          all.add(song);
          added++;
        }
      }
      if (result.isEnd) break;
      if (result.total != null && all.length >= result.total!) break;
      // 插件可能把整页不可播放的歌曲过滤成空页，连续几页没新歌才停下。
      if (added == 0 && ++emptyStreak >= 5) break;
    }
    return all;
  }

  Widget _buildHotSongItem(ThemeColors colors, HotBoard board, int index) {
    final song = board.songs[index];
    final isTopThree = index < 3;
    final isCurrent =
        ref.watch(
          playbackControllerProvider.select((state) => state.currentSong?.id),
        ) ==
        song.id;
    // 歌曲行深浅交错：奇数行垫一层略亮的颜色。
    final background = index.isOdd
        ? colors.surfaceVariant.withValues(alpha: 0.55)
        : Colors.transparent;
    final title = Text(
      song.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: isTopThree ? 14 : 13,
        fontWeight: isTopThree ? FontWeight.w600 : FontWeight.w400,
        color: isCurrent ? colors.primary : colors.textPrimary,
      ),
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => unawaited(_playHotSong(board, index)),
      child: Container(
        height: isTopThree ? 58 : 44,
        color: background,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: Text(
                '${index + 1}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: isTopThree ? 16 : 13,
                  fontWeight: isTopThree ? FontWeight.w700 : FontWeight.w500,
                  color: isTopThree ? colors.error : colors.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            if (isTopThree) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.xs),
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: MusicCoverImage(
                    url: song.coverUrl,
                    songId: song.id,
                    fit: BoxFit.cover,
                    useDiscoveryCache: true,
                    errorWidget: Icon(
                      Icons.music_note,
                      size: 18,
                      color: colors.textHint,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              // 前三首只显示歌名，不显示歌手名。
              Expanded(child: title),
            ] else ...[
              // 第 4 首起不显示封面：标题与前三首的标题对齐。
              const SizedBox(width: 40 + AppSpacing.sm),
              Expanded(child: title),
            ],
            if (isCurrent) ...[
              const SizedBox(width: AppSpacing.xs),
              Icon(Icons.equalizer, size: 16, color: colors.primary),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _playHotSong(HotBoard board, int index) async {
    PlaybackContext.instance.set(
      PlaybackSourceType.rank,
      id: board.id,
      name: board.name,
    );
    await ref
        .read(playbackControllerProvider.notifier)
        .setQueue(board.songs, startIndex: index);
  }

  /// 选择当前音源下的榜单，把它的前 10 首歌存成「热榜」。
  ///
  /// 弹框里已添加的榜单置顶，可拖动排序、删除；新增的榜单追加在末尾。
  Future<void> _addHotBoard() async {
    if (_addingHotBoard) return;
    setState(() => _addingHotBoard = true);
    final colors = ref.read(themeColorsProvider);
    try {
      final sourceId = ref.read(discoverSourceIdProvider);
      final leaderboards = await ref.read(leaderboardsProvider.future);
      if (!mounted) return;
      // 只提供当前使用音源自己的榜单。
      final candidates = [
        for (final board in leaderboards)
          if (board.source == sourceId) board,
      ];
      if (candidates.isEmpty) {
        _showMessage(context.tr('当前音源暂无榜单数据'));
        return;
      }
      await _showHotBoardPicker(colors, candidates, sourceId);
      if (!mounted) return;
      setState(() => _leaderboardCategory = _LeaderboardCategory.hot);
    } catch (e) {
      if (mounted) {
        _showMessage(
          context.tr(
            '获取榜单歌曲失败：${e.toString().replaceFirst('Exception: ', '')}',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _addingHotBoard = false);
    }
  }

  Future<void> _showHotBoardPicker(
    ThemeColors colors,
    List<Leaderboard> boards,
    String sourceId,
  ) {
    final sheetHeight = MediaQuery.sizeOf(context).height * 0.72;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      sheetAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 220),
        reverseDuration: Duration(milliseconds: 180),
      ),
      backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      builder: (_) => _HotBoardPickerSheet(
        colors: colors,
        sourceId: sourceId,
        boards: boards,
        height: sheetHeight,
        onAdd: _addPickedHotBoard,
      ),
    );
  }

  /// 把选中的榜单前 10 首加入热榜；弹框保持打开，可以继续添加其它榜单。
  Future<void> _addPickedHotBoard(Leaderboard selected) async {
    try {
      final page = await ref
          .read(discoverRepositoryProvider)
          .getLeaderboardDetail(selected.id, sourceId: selected.source);
      if (!mounted) return;
      final songs = (page?.songs ?? const <Song>[])
          .take(10)
          .toList(growable: false);
      if (songs.isEmpty) {
        _showMessage(context.tr('没有获取到榜单歌曲'));
        return;
      }
      await ref
          .read(hotBoardsProvider.notifier)
          .add(
            HotBoard(
              id: selected.id,
              name: selected.name,
              source: selected.source,
              coverUrl: selected.coverUrl ?? page?.coverUrl,
              songs: songs,
            ),
          );
    } catch (e) {
      if (mounted) {
        _showMessage(
          context.tr(
            '获取榜单歌曲失败：${e.toString().replaceFirst('Exception: ', '')}',
          ),
        );
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  Widget _buildAllLeaderboardsTab(ThemeColors colors) {
    final leaderboardsAsync = ref.watch(leaderboardsProvider);

    return leaderboardsAsync.when(
      data: (leaderboards) {
        if (leaderboards.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.show_chart, size: 48, color: colors.textHint),
                const SizedBox(height: AppSpacing.md),
                Text(
                  context.tr('暂无榜单数据'),
                  style: TextStyle(color: colors.textHint),
                ),
              ],
            ),
          );
        }
        return _buildLeaderboardGrid(colors, leaderboards);
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: colors.textHint),
            const SizedBox(height: AppSpacing.md),
            Text(context.tr('加载失败'), style: TextStyle(color: colors.textHint)),
            const SizedBox(height: AppSpacing.md),
            TextButton(
              onPressed: () => ref.invalidate(leaderboardsProvider),
              child: Text(context.tr('重试')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLeaderboardGrid(
    ThemeColors colors,
    List<Leaderboard> leaderboards,
  ) {
    final crossAxisCount = ResponsiveLayout.gridCrossAxisCount(context);
    final isTablet = ResponsiveLayout.isTablet(context);

    _leaderboardPager.updatePageSize(_playlistPageRows * crossAxisCount);
    _leaderboardPager.clampTo(leaderboards.length, hasMore: false);
    final visible = _leaderboardPager.slice(leaderboards);
    return CustomScrollView(
      controller: _leaderboardScrollController,
      cacheExtent: 360,
      slivers: [
        SliverPadding(
          padding: EdgeInsets.only(
            left: ResponsiveLayout.horizontalPadding(context),
            right: ResponsiveLayout.horizontalPadding(context),
            bottom: AppSpacing.lg,
          ),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              mainAxisSpacing: isTablet ? 16 : AppSpacing.md,
              crossAxisSpacing: isTablet ? 16 : AppSpacing.md,
              childAspectRatio: isTablet ? 0.88 : 0.82,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) =>
                  _buildLeaderboardCard(colors, visible[index], index),
              childCount: visible.length,
              addAutomaticKeepAlives: false,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xxxl),
            child: PageBar(
              currentPage: _leaderboardPager.page,
              pageCount: _leaderboardPager.pageCount(
                leaderboards.length,
                hasMore: false,
              ),
              onChanged: (page) {
                setState(() => _leaderboardPager.jumpTo(page));
                if (_leaderboardScrollController.hasClients) {
                  _leaderboardScrollController.jumpTo(0);
                }
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLeaderboardCard(
    ThemeColors colors,
    Leaderboard board,
    int index,
  ) {
    return GestureDetector(
      onTap: () {
        context.push('/playlist/${board.id}?type=rank');
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
                      url: board.coverUrl,
                      fit: BoxFit.cover,
                      useDiscoveryCache: true,
                      errorWidget: Icon(
                        Icons.show_chart,
                        size: 40,
                        color: colors.textHint,
                      ),
                    ),
                  ),
                  if (board.playCount != null && board.playCount!.isNotEmpty)
                    Positioned(
                      top: AppSpacing.xs,
                      right: AppSpacing.xs,
                      child: CoverCountBadge(
                        label: board.playCount!,
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
                    board.name,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: colors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (board.updateFrequency != null)
                    Text(
                      board.updateFrequency!,
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
}

/// 「新增热榜数据」弹框：已添加的榜单置顶，可拖动排序 / 删除；
/// 下方是当前音源还能添加的榜单，新增的榜单追加在已添加列表末尾。
class _HotBoardPickerSheet extends ConsumerStatefulWidget {
  const _HotBoardPickerSheet({
    required this.colors,
    required this.sourceId,
    required this.boards,
    required this.height,
    required this.onAdd,
  });

  final ThemeColors colors;
  final String sourceId;
  final List<Leaderboard> boards;
  final double height;
  final Future<void> Function(Leaderboard board) onAdd;

  @override
  ConsumerState<_HotBoardPickerSheet> createState() =>
      _HotBoardPickerSheetState();
}

class _HotBoardPickerSheetState extends ConsumerState<_HotBoardPickerSheet> {
  String? _addingId;

  Future<void> _add(Leaderboard board) async {
    if (_addingId != null) return;
    setState(() => _addingId = board.id);
    try {
      await widget.onAdd(board);
    } finally {
      if (mounted) setState(() => _addingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final added = [
      for (final board
          in ref.watch(hotBoardsProvider).valueOrNull ?? const <HotBoard>[])
        if (board.source == widget.sourceId) board,
    ];
    final addedIds = {for (final board in added) board.id};
    final available = [
      for (final board in widget.boards)
        if (!addedIds.contains(board.id)) board,
    ];
    return SizedBox(
      height: widget.height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.tr('新增热榜数据'),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  context.tr('已添加的榜单可以拖动排序，新增的榜单排在下方'),
                  style: TextStyle(fontSize: 12, color: colors.textHint),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: colors.divider.withValues(alpha: 0.4)),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (added.isNotEmpty) ...[
                    _sectionLabel('已添加', '按住右侧图标拖动排序'),
                    ReorderableListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      buildDefaultDragHandles: false,
                      padding: EdgeInsets.zero,
                      itemCount: added.length,
                      onReorder: (oldIndex, newIndex) => ref
                          .read(hotBoardsProvider.notifier)
                          .reorderForSource(
                            widget.sourceId,
                            oldIndex,
                            newIndex,
                          ),
                      itemBuilder: (context, index) {
                        final board = added[index];
                        return _AddedHotBoardTile(
                          key: ValueKey('${board.source}:${board.id}'),
                          colors: colors,
                          board: board,
                          index: index,
                          onDelete: () => ref
                              .read(hotBoardsProvider.notifier)
                              .remove(board),
                        );
                      },
                    ),
                  ],
                  _sectionLabel('添加榜单', null),
                  if (available.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.lg,
                        vertical: AppSpacing.md,
                      ),
                      child: Text(
                        context.tr('当前音源的榜单都已添加'),
                        style: TextStyle(fontSize: 12, color: colors.textHint),
                      ),
                    )
                  else
                    for (final board in available) _availableTile(board),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String title, String? hint) {
    final colors = widget.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          Text(
            context.tr(title),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: colors.textSecondary,
            ),
          ),
          if (hint != null) ...[
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                context.tr(hint),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: colors.textHint),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _availableTile(Leaderboard board) {
    final colors = widget.colors;
    final adding = _addingId == board.id;
    return InkWell(
      onTap: adding ? null : () => _add(board),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: SizedBox(
                width: 44,
                height: 44,
                child: MusicCoverImage(
                  url: board.coverUrl,
                  fit: BoxFit.cover,
                  useDiscoveryCache: true,
                  errorWidget: Icon(
                    Icons.show_chart,
                    size: 20,
                    color: colors.textHint,
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    board.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: colors.textPrimary,
                    ),
                  ),
                  if (board.updateFrequency != null &&
                      board.updateFrequency!.isNotEmpty)
                    Text(
                      board.updateFrequency!,
                      style: TextStyle(fontSize: 11, color: colors.textHint),
                    ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            if (adding)
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.primary,
                ),
              )
            else
              Icon(Icons.add_circle_outline, size: 20, color: colors.textHint),
          ],
        ),
      ),
    );
  }
}

class _AddedHotBoardTile extends StatelessWidget {
  const _AddedHotBoardTile({
    super.key,
    required this.colors,
    required this.board,
    required this.index,
    required this.onDelete,
  });

  final ThemeColors colors;
  final HotBoard board;
  final int index;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      padding: const EdgeInsets.fromLTRB(AppSpacing.sm, 6, 2, 6),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.xs),
            child: SizedBox(
              width: 36,
              height: 36,
              child: MusicCoverImage(
                url: board.coverUrl,
                fit: BoxFit.cover,
                useDiscoveryCache: true,
                errorWidget: Icon(
                  Icons.show_chart,
                  size: 18,
                  color: colors.textHint,
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              board.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: colors.textPrimary,
              ),
            ),
          ),
          Tooltip(
            message: context.tr('删除'),
            child: InkWell(
              onTap: onDelete,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(
                  Icons.delete_outline,
                  size: 18,
                  color: colors.error,
                ),
              ),
            ),
          ),
          ReorderableDragStartListener(
            index: index,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(Icons.drag_handle, size: 20, color: colors.textHint),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「更多分类」弹层内容：分类纵向平铺，超出可滚动，右侧显示滚动条。
class _CategorySheetContent extends StatefulWidget {
  const _CategorySheetContent({
    required this.groups,
    required this.activeTagId,
    required this.colors,
    required this.onSelect,
  });

  final List<PlaylistTagGroup> groups;
  final String activeTagId;
  final ThemeColors colors;
  final void Function(String tagId, String name) onSelect;

  @override
  State<_CategorySheetContent> createState() => _CategorySheetContentState();
}

class _CategorySheetContentState extends State<_CategorySheetContent> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: true,
      child: ListView(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.xl,
        ),
        children: [
          for (var i = 0; i < widget.groups.length; i++) ...[
            _buildGroupTitle(context, widget.groups[i].name),
            const SizedBox(height: AppSpacing.sm),
            _buildTagWrap(context, widget.groups[i]),
            if (i != widget.groups.length - 1) ...[
              const SizedBox(height: AppSpacing.md),
              Divider(height: 1, color: colors.divider.withValues(alpha: 0.4)),
              const SizedBox(height: AppSpacing.md),
            ],
          ],
        ],
      ),
    );
  }

  /// 分类标题（如「语种」「分类」）。
  Widget _buildGroupTitle(BuildContext context, String name) {
    final colors = widget.colors;
    return Row(
      children: [
        Text(
          context.tr(name),
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Divider(
            height: 1,
            color: colors.divider.withValues(alpha: 0.35),
          ),
        ),
      ],
    );
  }

  /// 分类下的标签平铺（自动换行）。
  Widget _buildTagWrap(BuildContext context, PlaylistTagGroup group) {
    final colors = widget.colors;
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: group.tags.map((tag) {
        final isActive = widget.activeTagId == tag.id;
        return GestureDetector(
          onTap: () => widget.onSelect(tag.id, tag.name),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: isActive
                  ? colors.primary.withValues(alpha: 0.15)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: isActive
                    ? colors.primary.withValues(alpha: 0.5)
                    : colors.divider.withValues(alpha: 0.4),
              ),
            ),
            child: Text(
              tag.name,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                color: isActive ? colors.primary : colors.textSecondary,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
