import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../application/discover_providers.dart';
import '../domain/models/playlist.dart';
import '../domain/models/leaderboard.dart';
import '../../plugin/application/plugin_providers.dart';
import '../../plugin/domain/plugin_types.dart';
import '../../settings/application/settings_providers.dart';

class DiscoverPage extends ConsumerStatefulWidget {
  const DiscoverPage({super.key});

  @override
  ConsumerState<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends ConsumerState<DiscoverPage> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _sourceButtonKey = GlobalKey();
  bool _hasInitialized = false;

  @override
  void initState() {
    super.initState();
    _requestNotificationPermission();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      final notifier = ref.read(categoryPlaylistsProvider.notifier);
      if (!notifier.noMore && !notifier.loadingMore) {
        final tagId = ref.read(activeTagIdProvider);
        final srcId = ref.read(discoverSourceIdProvider);
        notifier.fetchPlaylists(sortId: 'hot', tagId: tagId, sourceId: srcId);
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

    // 监听源切换，自动重新加载歌单
    ref.listen<String>(discoverSourceIdProvider, (previous, next) {
      if (previous != null && previous != next) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ref.read(activeTagIdProvider.notifier).state = '';
            ref.read(activeCategoryNameProvider.notifier).state = '热门';
            ref
                .read(categoryPlaylistsProvider.notifier)
                .fetchPlaylists(
                  sortId: 'hot',
                  tagId: '',
                  sourceId: next,
                  reset: true,
                );
          }
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
              child: tab == DiscoverTab.playlists
                  ? _buildPlaylistsTab(colors)
                  : _buildLeaderboardsTab(colors),
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
          // 切换音源（插件）按钮：放在搜索框右侧
          GestureDetector(
            key: _sourceButtonKey,
            onTap: () => _showSourceMenu(context, colors, sources, sourceId),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: colors.surface,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: currentSource != null
                    ? _buildSourceIcon(
                        // 同名插件的变体 id 需要还原成平台 id 才能取到对应图标。
                        SourceInfo.baseIdOf(currentSource.id),
                        size: 20,
                        label: currentSource.name,
                      )
                    : Icon(
                        Icons.music_note,
                        size: 20,
                        color: colors.textSecondary,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(BuildContext context, ThemeColors colors) {
    return GestureDetector(
      onTap: () => context.push('/search'),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
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
                      // 同名插件的变体 id 需要还原成平台 id 才能取到对应图标。
                      SourceInfo.baseIdOf(source.id),
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
        ref
            .read(categoryPlaylistsProvider.notifier)
            .fetchPlaylists(
              sortId: 'hot',
              tagId: '',
              sourceId: selectedId,
              reset: true,
            );
      }
    });
  }

  Widget _buildSourceIcon(
    String sourceId, {
    double size = 20,
    String? label,
  }) {
    switch (sourceId) {
      case 'wy':
        return Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
            color: Color(0xFFE60026),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              '网',
              style: TextStyle(
                color: Colors.white,
                fontSize: size * 0.55,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        );
      case 'kg':
        return Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
            color: Color(0xFF2EADFB),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              '狗',
              style: TextStyle(
                color: Colors.white,
                fontSize: size * 0.55,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        );
      case 'kw':
        return Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
            color: Color(0xFFFF8500),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              '我',
              style: TextStyle(
                color: Colors.white,
                fontSize: size * 0.55,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        );
      case 'tx':
        return Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
            color: Color(0xFF31C27C),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              'Q',
              style: TextStyle(
                color: Colors.white,
                fontSize: size * 0.55,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        );
      case 'mg':
        return Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
            color: Color(0xFFFF7E00),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              '咪',
              style: TextStyle(
                color: Colors.white,
                fontSize: size * 0.55,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        );
      default:
        // 插件音源（例如 MusicFree 的「bilibili」）没有内置图标，用名称首字
        // 生成一个中性色圆标，避免和其它内置源混在一起看不出区别。
        final glyph = (label ?? '').trim();
        if (glyph.isEmpty) {
          return Icon(Icons.music_note, size: size, color: Colors.grey);
        }
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Colors.blueGrey.shade500,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              glyph.substring(0, 1).toUpperCase(),
              style: TextStyle(
                color: Colors.white,
                fontSize: size * 0.55,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        );
    }
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
                      Text(context.tr('暂无歌单数据'), style: TextStyle(color: colors.textHint)),
                      const SizedBox(height: AppSpacing.md),
                      TextButton(
                        onPressed: () => _loadPlaylists(),
                        child: Text(context.tr('重试')),
                      ),
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
                  Text(context.tr('加载失败'), style: TextStyle(color: colors.textHint)),
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
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        children: [
          _buildTagChip(
            label: context.tr('热门'),
            isActive: activeTagId.isEmpty,
            colors: colors,
            onTap: () => _onSelectTag('', '热门'),
          ),
          hotTagsAsync.when(
            data: (hotTags) => Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: hotTags.map((tag) {
                return Padding(
                  padding: const EdgeInsets.only(left: AppSpacing.sm),
                  child: _buildTagChip(
                    label: tag.name,
                    isActive: activeTagId == tag.id,
                    colors: colors,
                    onTap: () => _onSelectTag(tag.id, tag.name),
                  ),
                );
              }).toList(),
            ),
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),
          const SizedBox(width: AppSpacing.sm),
          _buildMoreCategoryButton(colors, tagsAsync, activeTagId),
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.tr('更多分类'),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.arrow_drop_down, size: 16, color: colors.textSecondary),
          ],
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

  void _onSelectTag(String tagId, String name) {
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
              final playlist = playlists[index];
              return RepaintBoundary(
                child: _buildPlaylistCard(colors, playlist, index),
              );
            }, childCount: playlists.length),
          ),
        ),
        if (notifier.loadingMore)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
        if (notifier.noMore && playlists.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: Center(
                child: Text(
                  context.tr('没有更多内容'),
                  style: TextStyle(fontSize: 12, color: colors.textHint),
                ),
              ),
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

  Widget _buildLeaderboardsTab(ThemeColors colors) {
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
                Text(context.tr('暂无榜单数据'), style: TextStyle(color: colors.textHint)),
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

    return GridView.builder(
      padding: EdgeInsets.only(
        left: ResponsiveLayout.horizontalPadding(context),
        right: ResponsiveLayout.horizontalPadding(context),
        bottom: AppSpacing.xxxl,
      ),
      cacheExtent: 360,
      addAutomaticKeepAlives: false,
      addRepaintBoundaries: true,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        mainAxisSpacing: isTablet ? 16 : AppSpacing.md,
        crossAxisSpacing: isTablet ? 16 : AppSpacing.md,
        childAspectRatio: isTablet ? 0.88 : 0.82,
      ),
      itemCount: leaderboards.length,
      itemBuilder: (context, index) {
        final board = leaderboards[index];
        return _buildLeaderboardCard(colors, board, index);
      },
    );
  }

  Widget _buildLeaderboardCard(
    ThemeColors colors,
    Leaderboard board,
    int index,
  ) {
    return GestureDetector(
      onTap: () {
        context.push('/playlist/${board.id}');
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
                              board.playCount!,
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
              Divider(
                height: 1,
                color: colors.divider.withValues(alpha: 0.4),
              ),
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
