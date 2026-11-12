import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_page_background.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_surface.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../shared/pagination/page_slicer.dart';
import '../../../shared/widgets/load_more_footer.dart';
import '../../../shared/widgets/page_bar.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../../shared/widgets/source_name_tag.dart';
import '../../../shared/widgets/song_action_sheet.dart';
import '../../../shared/widgets/song_list_item.dart';
import '../../library/application/playlist_providers.dart';
import '../../library/domain/models/recently_played.dart';
import '../../player/application/playback_context.dart';
import '../../player/application/playback_controller.dart';
import '../../player/domain/models/song.dart';
import '../../plugin/application/plugin_providers.dart';
import '../domain/models/search_collection.dart';

/// 专辑 / 作者详情页。
///
/// 布局与歌单详情一致：顶部信息卡（封面 / 名称 / 播放全部 / 收藏），
/// 下面是歌曲列表。收藏时会在「收藏」页面生成一个歌单：
/// 「专辑：xxx」或「作者：xxx」。
///
/// 作者作品、部分专辑详情都是分页接口，所以这里按「首屏 + 加载更多」处理：
///   * 首屏失败 → 整页显示失败原因 + 重试；
///   * 下一页失败 → 列表底部显示「加载失败，点击重试」，已加载的内容保留。
class CollectionDetailPage extends ConsumerStatefulWidget {
  const CollectionDetailPage({super.key, required this.collection});

  final SearchCollection collection;

  @override
  ConsumerState<CollectionDetailPage> createState() =>
      _CollectionDetailPageState();
}

class _CollectionDetailPageState extends ConsumerState<CollectionDetailPage> {
  final ScrollController _scrollController = ScrollController();

  SearchCollection? _item;
  final List<Song> _songs = [];

  /// 已成功加载到的页码（0 表示还没加载过）。
  int _page = 0;
  bool _isEnd = false;
  int? _total;
  bool _loading = true;
  bool _loadingMore = false;

  /// 首屏失败原因。
  String? _error;

  /// 下一页失败原因。
  String? _loadMoreError;

  /// 歌曲列表分页：每页 50 首（接口多给的留在已加载列表里当缓冲）。
  final PageSlicer _pager = PageSlicer(pageSize: 50);

  /// 正在为某一页补齐数据。
  bool _pagingLoading = false;

  /// 正在后台拉取全部歌曲并收藏：收藏按钮显示转圈动画。
  bool _favoriting = false;

  bool get _isArtist => widget.collection.type == CollectionType.artist;

  /// 作者主页信息：播放作者作品时写进「最近播放」，之后可以从记录里点回主页。
  Map<String, dynamic>? get _artistMeta =>
      _isArtist ? (_item ?? widget.collection).toJson() : null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadFirst());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 当前页数据不够时继续向接口取（接口每页条数可能比 50 少）。
  void _scheduleEnsurePage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_ensurePageLoaded());
    });
  }

  /// 切到第 [page] 页并补齐数据。
  Future<void> _goToPage(int page) async {
    if (page < 1 || _pagingLoading) return;
    final previousPage = _pager.page;
    setState(() => _pager.jumpTo(page));
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    if (_beyondBuffer(page)) {
      await _jumpToPageDirect(page, fallbackPage: previousPage);
    } else {
      await _ensurePageLoaded();
    }
  }

  /// 目标页是否超出「缓冲区 + 下一页」的连续范围。
  ///
  /// 超出（或往回翻出缓冲区）时走跳页直达——只取目标页，不把中间页
  /// 逐页拉一遍；范围内仍走追加补齐，缓冲可以继续复用。
  bool _beyondBuffer(int page) {
    final contiguousEnd =
        _pager.bufferBase - 1 + (_songs.length / _pager.pageSize).ceil();
    return page < _pager.bufferBase || page > contiguousEnd + 1;
  }

  /// 跳页直达：只请求目标页并替换缓冲区。
  ///
  /// 作者作品动辄几十页，逐页补齐在点「最后一页」时要发几十个请求。
  /// 失败时退回原页码并提示，已加载的内容保留。
  Future<void> _jumpToPageDirect(int page, {required int fallbackPage}) async {
    setState(() => _pagingLoading = true);
    try {
      final detail = await _fetch(page);
      if (!mounted) return;
      setState(() {
        _item = detail.item;
        _songs
          ..clear()
          ..addAll(detail.songs);
        _page = page;
        _isEnd = detail.isEnd;
        _total = detail.total ?? _total;
        _loadMoreError = null;
        _pager.rebase(page);
      });
    } catch (e) {
      if (!mounted) return;
      final message = _messageOf(e);
      setState(() => _pager.jumpTo(fallbackPage));
      _toast(context.tr('加载第 $page 页失败：$message'));
    } finally {
      if (mounted) setState(() => _pagingLoading = false);
    }
  }

  Future<void> _ensurePageLoaded() async {
    if (_pagingLoading) return;
    setState(() => _pagingLoading = true);
    try {
      while (mounted) {
        final missing = _pager.missing(_songs.length, hasMore: !_isEnd);
        if (missing == 0) break;
        if (_loadMoreError != null) break;
        final before = _songs.length;
        await _loadMore();
        if (!mounted) return;
        if (_songs.length == before) break;
      }
    } finally {
      if (mounted) {
        setState(() {
          _pagingLoading = false;
          _pager.clampTo(_songs.length, hasMore: !_isEnd, total: _total);
        });
      }
    }
  }

  Future<void> _loadFirst() async {
    setState(() {
      _loading = true;
      _error = null;
      _loadMoreError = null;
    });
    try {
      final detail = await _fetch(1);
      if (!mounted) return;
      setState(() {
        _item = detail.item;
        _songs
          ..clear()
          ..addAll(detail.songs);
        _page = 1;
        _isEnd = detail.isEnd;
        _total = detail.total;
        _loading = false;
      });
      _pager.reset();
      _scheduleEnsurePage();
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
      final seen = _songs.map((s) => s.id).toSet();
      final appended = detail.songs.where((s) => seen.add(s.id)).toList();
      setState(() {
        _songs.addAll(appended);
        _page += 1;
        _total = detail.total ?? _total;
        _isEnd =
            detail.isEnd ||
            appended.isEmpty ||
            (_total != null && _songs.length >= _total!);
        _loadingMore = false;
        _loadMoreError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _loadMoreError = _messageOf(e);
      });
    }
  }

  /// 底部「加载失败，点击重试」。
  Future<void> _retryLoadMore() async {
    setState(() => _loadMoreError = null);
    await _ensurePageLoaded();
  }

  Future<CollectionDetail> _fetch(int page) {
    return ref
        .read(musicSourceManagerProvider)
        .getCollectionDetail(widget.collection, page: page);
  }

  static String _messageOf(Object error) {
    if (error is CollectionDetailException) return error.message;
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }

  Future<void> _playAll(List<Song> songs) async {
    if (songs.isEmpty) return;
    PlaybackContext.instance.set(
      _isArtist ? PlaybackSourceType.artist : PlaybackSourceType.album,
      id: widget.collection.id,
      name: widget.collection.title,
      sourceMeta: _artistMeta,
    );
    await ref
        .read(playbackControllerProvider.notifier)
        .setQueue(songs, startIndex: 0);
  }

  Future<void> _toggleFavorite() async {
    if (_favoriting) return;
    final name = (_item ?? widget.collection).favoriteName;
    final playlists = ref.read(playlistsProvider).valueOrNull ?? const [];
    final existing = playlists.where((p) => p.name == name).firstOrNull;
    final notifier = ref.read(playlistsProvider.notifier);
    if (existing != null) {
      await notifier.deletePlaylist(existing.id);
      return;
    }

    setState(() => _favoriting = true);
    final List<Song> songs;
    try {
      songs = await _fetchAllSongsForFavorite();
    } catch (e) {
      debugPrint('[CollectionDetailPage] 收藏前获取全部歌曲失败: $e');
      if (!mounted) return;
      setState(() => _favoriting = false);
      _toast(context.tr('获取歌曲失败：${_messageOf(e)}'));
      return;
    }
    if (!mounted) return;
    if (songs.isEmpty) {
      setState(() => _favoriting = false);
      _toast(context.tr('没有获取到歌曲，无法收藏'));
      return;
    }

    final collection = _item ?? widget.collection;
    try {
      await notifier.createPlaylistWithSongs(
        name,
        songs.map((s) => s.toJson()).toList(),
        description:
            'mintmusic:${collection.type.id}:'
            '${collection.source}:${collection.id}',
        // 记录收藏时所在的音源，之后从收藏里播放优先使用它。
        source: collection.source,
        // 收藏页展示专辑封面 / 作者头像，而不是第一首歌的封面。
        coverImgUrl: collection.coverUrl,
      );
    } catch (e) {
      debugPrint('[CollectionDetailPage] 收藏失败: $e');
      if (!mounted) return;
      setState(() => _favoriting = false);
      _toast(context.tr('收藏失败：${_messageOf(e)}'));
      return;
    }
    if (!mounted) return;
    setState(() => _favoriting = false);
  }

  /// 收藏前把其余歌曲页全部取回来：收藏里存的是完整专辑 / 作者作品。
  ///
  /// 已加载的歌曲直接用，只补取缓冲区前面缺的页和 [_page] 之后的页，
  /// 直到插件表示到底。
  Future<List<Song>> _fetchAllSongsForFavorite() async {
    final seen = <String>{};
    final all = <Song>[];
    var emptyStreak = 0;

    // 跳页直达后缓冲区从中间页开始，前面的页没有加载过：先按顺序补回来，
    // 否则收藏出来的歌单会缺歌、顺序也会乱。
    final bufferedFirst = _pager.bufferBase;
    var page = 0;
    while (page < bufferedFirst - 1) {
      page += 1;
      final detail = await _fetch(page);
      for (final song in detail.songs) {
        if (seen.add(song.id)) all.add(song);
      }
      if (detail.isEnd) break;
      if (detail.songs.isEmpty) {
        if (++emptyStreak >= 5) break;
      } else {
        emptyStreak = 0;
      }
    }

    for (final song in _songs) {
      if (seen.add(song.id)) all.add(song);
    }

    page = _page;
    var isEnd = _isEnd;
    while (!isEnd) {
      page += 1;
      final detail = await _fetch(page);
      var added = 0;
      for (final song in detail.songs) {
        if (seen.add(song.id)) {
          all.add(song);
          added += 1;
        }
      }
      isEnd =
          detail.isEnd || (detail.total != null && all.length >= detail.total!);
      if (added == 0) {
        // 插件可能把整页不可播放的歌曲过滤成空页；连续几页没新歌就当作到底。
        if (++emptyStreak >= 5) break;
      } else {
        emptyStreak = 0;
      }
    }
    return all;
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final item = _item ?? widget.collection;
    final favoriteName = item.favoriteName;
    final favorited = (ref.watch(playlistsProvider).valueOrNull ?? const [])
        .any((p) => p.name == favoriteName);

    return AppPageBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          // 顶部不避让：头部渐变要一直铺到状态栏（和歌单详情页一致），
          // 状态栏高度由 _buildHeader 自己加进内边距。
          top: false,
          child: Column(
            children: [
              _buildHeader(colors, item, favorited),
              Expanded(child: _buildBody(colors)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ThemeColors colors) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return LoadErrorView(
        colors: colors,
        title: context.tr('加载失败'),
        message: _error,
        onRetry: () => unawaited(_loadFirst()),
      );
    }
    if (_songs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.tr('没有获取到歌曲'),
              style: TextStyle(color: colors.textHint),
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
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.refresh, size: 14, color: colors.primary),
                    const SizedBox(width: 4),
                    Text(
                      context.tr('重试'),
                      style: TextStyle(fontSize: 12, color: colors.primary),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    return _buildSongList(colors, _songs);
  }

  /// 专辑 / 作者页顶部：返回按钮 + 封面 + 名称 / 音源 / 操作按钮。
  ///
  /// 布局与歌单详情页保持一致：不再单独占一行放「箭头 + 名称」（那一行会和
  /// 下面封面旁的名字重复），返回箭头贴在封面左侧；顶部同样是一块跟随页面
  /// 背景色的悬浮面板。
  /// Android 靠系统返回手势 / 返回键，不显示箭头。
  Widget _buildHeader(
    ThemeColors colors,
    SearchCollection item,
    bool favorited,
  ) {
    final songs = _songs;
    return Container(
      // 顶栏是贴着页面顶部的一条半透明栏：不要圆角、不要阴影，也不留外边距，
      // 宽度铺满、颜色一直铺到状态栏。
      // 底色的取法见 detailPageHeaderSurfaceProvider：跟着背景渐变顶部色走，
      // 只做半透明处理，让页面背景直接透上来，顶栏和列表是同一片背景。
      padding: EdgeInsets.fromLTRB(
        AppSpacing.md + AppSpacing.sm,
        // 状态栏沉浸：色块铺到屏幕顶端，状态栏高度算进内边距，
        // 内容位置与原来「外边距 + 内边距」时保持一致。
        MediaQuery.paddingOf(context).top + AppSpacing.md + AppSpacing.sm,
        AppSpacing.md + AppSpacing.lg,
        AppSpacing.sm + AppSpacing.sm,
      ),
      color: ref.watch(detailPageHeaderSurfaceProvider),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Android 靠系统返回手势 / 返回键，顶部不放返回箭头。
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
              url: item.coverUrl,
              width: 120,
              height: 120,
              fit: BoxFit.cover,
              errorWidget: Container(
                width: 120,
                height: 120,
                color: colors.surfaceVariant,
                child: Icon(
                  _isArtist ? Icons.person : Icons.album,
                  size: 36,
                  color: colors.textHint,
                ),
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
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                // 音源标签 + 副标题（歌手 / 发行时间 / 歌曲数）同一行。
                Row(
                  children: [
                    _buildSourceNameTag(colors, item),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        _subtitle(item, songs.length),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: colors.textHint),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    _actionChip(
                      colors,
                      icon: Icons.play_arrow,
                      label: context.tr('播放全部'),
                      primary: true,
                      onTap: songs.isEmpty ? null : () => _playAll(songs),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    _actionChip(
                      colors,
                      icon: favorited ? Icons.favorite : Icons.favorite_border,
                      label: _favoriting
                          ? context.tr('收藏中...')
                          : favorited
                          ? context.tr('已收藏')
                          : context.tr('收藏'),
                      loading: _favoriting,
                      onTap: () => unawaited(_toggleFavorite()),
                    ),
                    // 「更新」按钮只在收藏页打开『作者：xxx』时出现
                    // （见 local_playlist_detail_page），这里不再提供。
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 头部音源标签：显示专辑 / 作者所属的音源（本地来源不显示）。
  Widget _buildSourceNameTag(ThemeColors colors, SearchCollection item) {
    final source = item.source.trim();
    if (source.isEmpty || source == 'local') return const SizedBox.shrink();
    final label = ref
        .read(musicSourceManagerProvider)
        .sourceDisplayName(source);
    if (label.isEmpty) return const SizedBox.shrink();
    return SourceNameTag(label: label, colors: colors, fontSize: 10);
  }

  String _subtitle(SearchCollection item, int songCount) {
    final parts = <String>[];
    if (!_isArtist && (item.artist ?? '').isNotEmpty) {
      parts.add(item.artist!);
    }
    if ((item.date ?? '').isNotEmpty) parts.add(item.date!);
    if (item.worksNum > 0) {
      parts.add(context.tr('${item.worksNum} 首'));
    } else if (songCount > 0) {
      parts.add(context.tr('$songCount 首'));
    }
    return parts.isEmpty ? context.tr('暂无简介') : parts.join(' · ');
  }

  Widget _actionChip(
    ThemeColors colors, {
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool primary = false,
    bool loading = false,
  }) {
    // 「播放全部」与侧栏「发现」的激活态一致：底色把主题色调暗一档，文字用主题色。
    final color = primary ? colors.primary : colors.textPrimary;
    return GestureDetector(
      onTap: loading ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 6,
        ),
        decoration: primary
            ? activeChipDecoration(
                colors,
                radius: AppRadius.full,
                withBorder: true,
              )
            : floatingSurfaceDecoration(
                colors,
                radius: AppRadius.full,
                subtle: true,
              ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.primary,
                ),
              )
            else
              Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: loading ? colors.primary : color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSongList(ThemeColors colors, List<Song> songs) {
    final currentSongId = ref.watch(
      playbackControllerProvider.select((s) => s.currentSong?.id),
    );
    // 只渲染当前页（每页 50 首）；播放用的是完整列表。
    _pager.clampTo(songs.length, hasMore: !_isEnd, total: _total);
    final visible = _pager.slice(songs);
    final pageCount = _pager.pageCount(
      songs.length,
      hasMore: !_isEnd,
      total: _total,
    );
    final list = Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sm,
        0,
        AppSpacing.sm,
        AppSpacing.sm,
      ),
      child: CustomScrollView(
        controller: _scrollController,
        slivers: [
          SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              final song = visible[index];
              // 序号按全局位置编号（跳页直达后缓冲区从当前页起，也要接续页码）；
              // 播放队列用的是缓冲区内的下标。
              final displayIndex = _pager.absoluteStart + index;
              final bufferIndex = _pager.start + index;
              return SongListItem(
                song: song,
                index: displayIndex,
                // 序号列按「全局最大序号」算：跳页直达后缓冲区只剩一页数据，
                // 只按 songs.length 算会把三位序号裁成两位宽度。
                maxIndex: math.max(
                  _total ?? 0,
                  _pager.absoluteStart + visible.length,
                ),
                isPlaying: currentSongId == song.id,
                showPlayedTag: true,
                onPlayTap: () async {
                  PlaybackContext.instance.set(
                    _isArtist
                        ? PlaybackSourceType.artist
                        : PlaybackSourceType.album,
                    id: widget.collection.id,
                    name: widget.collection.title,
                    sourceMeta: _artistMeta,
                  );
                  await ref
                      .read(playbackControllerProvider.notifier)
                      .setQueue(songs, startIndex: bufferIndex);
                },
                onMenuTap: () => SongActionSheet.show(
                  context,
                  song: song,
                  playlistSongs: songs,
                ),
              );
            }, childCount: visible.length),
          ),
          // 分页条单独做成最后一个 sliver：内容不满一屏时贴到底部，
          // 满一屏时正常跟在列表后面（见 PageBarFooterSliver）。
          PageBarFooterSliver(child: _pageFooter(colors, pageCount)),
        ],
      ),
    );
    return list;
  }

  /// 列表末尾的分页条（上面可带一行翻页状态，不再显示「没有更多了」）。
  Widget _pageFooter(ThemeColors colors, int pageCount) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_loadingMore)
          LoadMoreFooter(status: LoadMoreStatus.loading, colors: colors)
        else if (_loadMoreError != null)
          LoadMoreFooter(
            status: LoadMoreStatus.error,
            colors: colors,
            message: _loadMoreError,
            onRetry: () => unawaited(_retryLoadMore()),
          ),
        PageBar(
          currentPage: _pager.page,
          pageCount: pageCount,
          loading: _loadingMore || _pagingLoading,
          docked: true,
          // 没拿到总数、也还没翻到末尾：最后一页是猜的，不写成具体页码。
          lastPageKnown: _isEnd || _total != null,
          onChanged: (page) => unawaited(_goToPage(page)),
        ),
      ],
    );
  }
}
