import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_page_background.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_surface.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';
import '../../../shared/widgets/collection_card.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../plugin/application/plugin_providers.dart';
import '../../player/application/mini_player_visibility.dart';
import '../../plugin/domain/plugin_types.dart';
import '../domain/models/search_collection.dart';

/// 作者的全部专辑。
///
/// 顶部沿用歌单 / 专辑详情页的版式（封面 + 标题 + 副标题 + 胶囊按钮），
/// 下面是专辑网格（卡片样式与「搜索 - 专辑」一致）。
///
/// 排序按钮只在插件声明 [ArtistCapabilities.albumSort] 时可用：各音源的
/// 排序参数实测差别很大（网易没有参数、酷我的 sortby 无效），不支持的
/// 就置灰，**不会**为了排序把全部专辑拉下来手动排。
class ArtistAlbumsPage extends ConsumerStatefulWidget {
  const ArtistAlbumsPage({super.key, required this.artist});

  final SearchCollection artist;

  @override
  ConsumerState<ArtistAlbumsPage> createState() => _ArtistAlbumsPageState();
}

class _ArtistAlbumsPageState extends ConsumerState<ArtistAlbumsPage> {
  final List<SearchCollection> _albums = [];
  final ScrollController _scroll = ScrollController();

  int _page = 1;
  bool _isEnd = false;
  int? _total;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  CollectionSort _sort = CollectionSort.timeDesc;
  ArtistCapabilities _caps = ArtistCapabilities.none;
  bool _capsResolved = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resolveCapabilities();
      unawaited(_loadFirst());
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _resolveCapabilities() {
    if (_capsResolved) return;
    final caps = ref
        .read(musicSourceManagerProvider)
        .artistCapabilitiesOf(widget.artist);
    if (!mounted) return;
    // 插件还没加载完时拿到的是全 false，不能当成「不支持排序」，
    // 等首屏数据回来后再试一次。
    if (!caps.albumList) return;
    _capsResolved = true;
    setState(() => _caps = caps);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.pixels >= position.maxScrollExtent - 400) {
      unawaited(_loadMore());
    }
  }

  Future<ArtistAlbumPage> _fetch(int page) {
    return ref
        .read(musicSourceManagerProvider)
        .getArtistAlbums(widget.artist, page: page, order: _sort.id);
  }

  Future<void> _loadFirst() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await _fetch(1);
      if (!mounted) return;
      setState(() {
        _albums
          ..clear()
          ..addAll(detail.items);
        _page = 1;
        _isEnd = detail.isEnd;
        _total = detail.total;
        _loading = false;
      });
      _resolveCapabilities();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _messageOf(e);
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || _isEnd) return;
    setState(() => _loadingMore = true);
    try {
      final detail = await _fetch(_page + 1);
      if (!mounted) return;
      final seen = _albums.map((a) => a.id).toSet();
      final appended = detail.items.where((a) => seen.add(a.id)).toList();
      setState(() {
        _albums.addAll(appended);
        _page += 1;
        _isEnd = detail.isEnd || appended.isEmpty;
        if (detail.total != null) _total = detail.total;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  Future<void> _changeSort(CollectionSort sort) async {
    if (sort == _sort) return;
    setState(() => _sort = sort);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    await _loadFirst();
  }

  static String _messageOf(Object error) {
    if (error is CollectionDetailException) return error.message;
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    return AppPageBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              _buildHeader(colors),
              Expanded(child: _buildBody(colors)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeColors colors) {
    final subtitle = _total != null && _total! > 0
        ? context.tr('共 $_total 张专辑')
        : context.tr('${_albums.length} 张专辑');
    return Container(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.md + AppSpacing.sm,
        MediaQuery.paddingOf(context).top + AppSpacing.md + AppSpacing.sm,
        AppSpacing.md + AppSpacing.lg,
        AppSpacing.sm + AppSpacing.sm,
      ),
      color: ref.watch(detailPageHeaderSurfaceProvider),
      child: Row(
        children: [
          if (!Platform.isAndroid) ...[
            GestureDetector(
              onTap: () => context.pop(),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.xs),
                child: Icon(
                  Icons.arrow_back,
                  size: 24,
                  color: colors.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
          ],
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: MusicCoverImage(
              url: widget.artist.coverUrl,
              width: 96,
              height: 96,
              fit: BoxFit.cover,
              errorWidget: Container(
                width: 96,
                height: 96,
                color: colors.surfaceVariant,
                child: Icon(Icons.person, size: 32, color: colors.textHint),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  widget.artist.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: colors.textHint),
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    _sortChip(colors),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 排序按钮：插件不支持排序时置灰（不点、也不发请求）。
  Widget _sortChip(ThemeColors colors) {
    final enabled = _caps.albumSort;
    final color = enabled ? colors.textPrimary : colors.textHint;
    return GestureDetector(
      onTap: enabled ? () => unawaited(_showSortSheet(colors)) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 6,
        ),
        decoration: floatingSurfaceDecoration(
          colors,
          radius: AppRadius.full,
          subtle: true,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.swap_vert, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              context.tr(_sort.label),
              style: TextStyle(fontSize: 12, color: color),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSortSheet(ThemeColors colors) async {
    // Android 弹层在页面导航器里，底部会被迷你播放器压住，整块内容抬高避让。
    final miniPlayerInset =
        Platform.isAndroid && ref.read(miniPlayerVisibleProvider)
        ? ResponsiveLayout.miniPlayerReservedHeight(context)
        : 0.0;
    final picked = await showModalBottomSheet<CollectionSort>(
      context: context,
      backgroundColor: colors.dialogSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.only(bottom: miniPlayerInset),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.md,
                  AppSpacing.lg,
                  AppSpacing.xs,
                ),
                child: Text(
                  context.tr('排序方式'),
                  style: TextStyle(fontSize: 13, color: colors.textSecondary),
                ),
              ),
              for (final sort in CollectionSort.values)
                ListTile(
                  dense: true,
                  title: Text(
                    context.tr(sort.label),
                    style: TextStyle(fontSize: 14, color: colors.textPrimary),
                  ),
                  trailing: sort == _sort
                      ? Icon(Icons.check, size: 18, color: colors.primary)
                      : null,
                  onTap: () => Navigator.of(ctx).pop(sort),
                ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ),
        ),
      ),
    );
    if (picked != null) await _changeSort(picked);
  }

  Widget _buildBody(ThemeColors colors) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.tr('加载失败'),
              style: TextStyle(color: colors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: colors.textHint),
            ),
            const SizedBox(height: AppSpacing.md),
            GestureDetector(
              onTap: () => unawaited(_loadFirst()),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.full),
                  border: Border.all(color: colors.divider),
                ),
                child: Text(
                  context.tr('重试'),
                  style: TextStyle(fontSize: 12, color: colors.primary),
                ),
              ),
            ),
          ],
        ),
      );
    }
    if (_albums.isEmpty) {
      return Center(
        child: Text(
          context.tr('没有获取到专辑'),
          style: TextStyle(color: colors.textHint),
        ),
      );
    }
    final columns = ResponsiveLayout.gridCrossAxisCount(context);
    final isTablet = ResponsiveLayout.isTablet(context);
    // Android 上播放栏浮在内容之上：网格底部额外让出它的高度。
    final miniPlayerInset =
        Platform.isAndroid && ref.watch(miniPlayerVisibleProvider)
        ? ResponsiveLayout.miniPlayerReservedHeight(context)
        : 0.0;
    // 网格参数与「搜索 - 专辑」完全一致（见 search_page 的专辑结果）。
    return GridView.builder(
      controller: _scroll,
      padding: EdgeInsets.fromLTRB(
        ResponsiveLayout.horizontalPadding(context),
        AppSpacing.lg,
        ResponsiveLayout.horizontalPadding(context),
        AppSpacing.xxxl + miniPlayerInset,
      ),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: isTablet ? 16 : AppSpacing.md,
        crossAxisSpacing: isTablet ? 16 : AppSpacing.md,
        childAspectRatio: isTablet ? 0.88 : 0.82,
      ),
      itemCount: _albums.length + (_loadingMore || !_isEnd ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _albums.length) {
          return const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        return floatingCard(
          colors: colors,
          radius: AppRadius.md,
          child: CollectionCard(colors: colors, item: _albums[index]),
        );
      },
    );
  }
}
