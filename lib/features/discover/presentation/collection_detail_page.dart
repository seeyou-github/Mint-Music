import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../shared/widgets/load_more_footer.dart';
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
  bool _loading = true;
  bool _loadingMore = false;

  /// 首屏失败原因。
  String? _error;

  /// 下一页失败原因。
  String? _loadMoreError;

  bool get _isArtist => widget.collection.type == CollectionType.artist;

  /// 作者主页信息：播放作者作品时写进「最近播放」，之后可以从记录里点回主页。
  Map<String, dynamic>? get _artistMeta =>
      _isArtist ? (_item ?? widget.collection).toJson() : null;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadFirst());
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_loading || _loadingMore || _isEnd || _loadMoreError != null) return;
    final position = _scrollController.position;
    if (position.maxScrollExtent - position.pixels <= 480) {
      unawaited(_loadMore());
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
        _loading = false;
      });
      _scheduleAutoFill();
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
        _isEnd = detail.isEnd;
        _loadingMore = false;
        _loadMoreError = null;
      });
      // 一页全被去重（插件重复返回同一批）时继续往后翻，避免卡住。
      if (appended.isEmpty && !detail.isEnd) _scheduleAutoFill();
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
    await _loadMore();
  }

  /// 内容不足一屏时继续补齐，保证短列表也能翻页。
  void _scheduleAutoFill() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isEnd || _loadingMore) return;
      if (!_scrollController.hasClients) return;
      if (_scrollController.position.maxScrollExtent <= 0 &&
          _songs.length < 40) {
        unawaited(_loadMore());
      }
    });
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

  Future<void> _toggleFavorite(List<Song> songs) async {
    final name = (_item ?? widget.collection).favoriteName;
    final playlists = ref.read(playlistsProvider).valueOrNull ?? const [];
    final existing = playlists.where((p) => p.name == name).firstOrNull;
    final notifier = ref.read(playlistsProvider.notifier);
    if (existing != null) {
      await notifier.deletePlaylist(existing.id);
      if (!mounted) return;
      _toast(context.tr('已取消收藏'));
      return;
    }
    if (songs.isEmpty) return;
    final collection = _item ?? widget.collection;
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
    if (!mounted) return;
    _toast(context.tr('已收藏到「收藏」'));
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

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(colors, item, favorited),
            Expanded(child: _buildBody(colors)),
          ],
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

  Widget _buildHeader(
    ThemeColors colors,
    SearchCollection item,
    bool favorited,
  ) {
    final songs = _songs;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: () => context.pop(),
                child: Icon(
                  Icons.arrow_back,
                  size: 24,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.textHint,
                            ),
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
                          icon: favorited
                              ? Icons.favorite
                              : Icons.favorite_border,
                          label: favorited
                              ? context.tr('已收藏')
                              : context.tr('收藏'),
                          onTap: () => _toggleFavorite(songs),
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
  }) {
    final color = primary ? colors.textOnPrimary : colors.textPrimary;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 6,
        ),
        decoration: BoxDecoration(
          color: primary ? colors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(color: primary ? colors.primary : colors.divider),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 12, color: color)),
          ],
        ),
      ),
    );
  }

  Widget _buildSongList(ThemeColors colors, List<Song> songs) {
    final currentSongId = ref.watch(
      playbackControllerProvider.select((s) => s.currentSong?.id),
    );
    final footer = _footer(colors);
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sm,
        0,
        AppSpacing.sm,
        AppSpacing.xxxl,
      ),
      itemCount: songs.length + (footer != null ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= songs.length) return footer!;
        final song = songs[index];
        return SongListItem(
          song: song,
          index: index,
          isPlaying: currentSongId == song.id,
          showPlayedTag: true,
          onPlayTap: () async {
            PlaybackContext.instance.set(
              _isArtist ? PlaybackSourceType.artist : PlaybackSourceType.album,
              id: widget.collection.id,
              name: widget.collection.title,
              sourceMeta: _artistMeta,
            );
            await ref
                .read(playbackControllerProvider.notifier)
                .setQueue(songs, startIndex: index);
          },
          onMenuTap: () =>
              SongActionSheet.show(context, song: song, playlistSongs: songs),
        );
      },
    );
  }

  Widget? _footer(ThemeColors colors) {
    if (_loadingMore) {
      return LoadMoreFooter(status: LoadMoreStatus.loading, colors: colors);
    }
    if (_loadMoreError != null) {
      return LoadMoreFooter(
        status: LoadMoreStatus.error,
        colors: colors,
        message: _loadMoreError,
        onRetry: () => unawaited(_retryLoadMore()),
      );
    }
    if (!_isEnd) return null;
    return LoadMoreFooter(status: LoadMoreStatus.noMore, colors: colors);
  }
}
