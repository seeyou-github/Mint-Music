import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/scroll_locate.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../../shared/widgets/song_action_sheet.dart';
import '../../../shared/widgets/song_list_item.dart';
import '../../../shared/widgets/song_selection.dart';
import '../application/discover_providers.dart';
import '../domain/models/playlist_page.dart';
import '../../library/application/playlist_providers.dart';
import '../../library/domain/models/playlist.dart' as local;
import '../../player/application/playback_controller.dart';
import '../../player/domain/models/song.dart';
import '../../player/presentation/mini_player.dart';

class PlaylistDetailPage extends ConsumerStatefulWidget {
  const PlaylistDetailPage({super.key, required this.playlistId});

  final String playlistId;

  @override
  ConsumerState<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends ConsumerState<PlaylistDetailPage> {
  /// 批量选择控制器（长按歌曲或「更多」菜单进入）。
  final SongSelectionController _selection = SongSelectionController();
  bool _isFavorited = false;
  final ScrollController _scrollController = ScrollController();

  // ---- 插件源歌单翻页状态 ----
  /// 已初始化翻页状态的歌单 id，避免每次 build 重复重置。
  String? _pagedPlaylistId;
  /// 首屏（第 1 页）歌曲。
  List<Song> _baseSongs = const [];
  /// 后续页追加的歌曲。
  final List<Song> _extraSongs = [];
  /// 当前已加载到的页码。
  int _page = 1;
  /// 是否已到末页（内置源一次给全，恒为 true）。
  bool _isEnd = true;
  bool _loadingMore = false;

  /// 连续多少页没有新歌后放弃翻页（兜底，防止插件异常时无限请求）。
  static const int _maxConsecutiveEmptyPages = 5;

  /// 完整歌曲列表（首屏 + 已加载的后续页）。
  List<Song> get _songs => [..._baseSongs, ..._extraSongs];

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _selection.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkIfFavorited();
    });
  }

  /// 首屏数据到达后同步翻页状态（同一歌单只初始化一次）。
  void _syncPagination(PlaylistPage page) {
    if (_pagedPlaylistId == widget.playlistId) return;
    _pagedPlaylistId = widget.playlistId;
    _baseSongs = page.playlist?.songs ?? const <Song>[];
    _extraSongs.clear();
    _page = 1;
    _isEnd = page.isEnd;
    _scheduleAutoFill();
  }

  void _onScroll() {
    if (!_scrollController.hasClients || _loadingMore || _isEnd) return;
    final position = _scrollController.position;
    if (position.maxScrollExtent - position.pixels <= 480) {
      unawaited(_loadMore());
    }
  }

  /// 内容不足一屏时继续补齐，保证短歌单 / 大窗口下也能翻页。
  void _scheduleAutoFill() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isEnd || _loadingMore) return;
      if (!_scrollController.hasClients) return;
      if (_scrollController.position.maxScrollExtent <= 0 && _songs.length < 40) {
        unawaited(_loadMore());
      }
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _isEnd || _pagedPlaylistId != widget.playlistId) return;

    _loadingMore = true;
    if (mounted) setState(() {});

    try {
      var page = _page;
      var emptyStreak = 0;
      var reachedEnd = false;

      // 插件可能把整页都是不可播放（VIP 等）的歌曲过滤掉，返回空页但
      // `isEnd` 仍为 false。此时继续往后翻，最多连续跳过
      // [_maxConsecutiveEmptyPages] 页，避免卡住或无限请求。
      while (!reachedEnd && emptyStreak < _maxConsecutiveEmptyPages) {
        page += 1;
        final result = await ref
            .read(discoverRepositoryProvider)
            .getPlaylistDetailPage(widget.playlistId, page: page);
        if (!mounted || _pagedPlaylistId != widget.playlistId) return;

        final newSongs = result.playlist?.songs ?? const <Song>[];
        final seen = <String>{
          for (final song in _baseSongs) song.id,
          for (final song in _extraSongs) song.id,
        };
        final appended = <Song>[
          for (final song in newSongs)
            if (seen.add(song.id)) song,
        ];

        if (appended.isNotEmpty) {
          final isEnd = result.isEnd;
          setState(() {
            _page = page;
            _extraSongs.addAll(appended);
            _isEnd = isEnd;
          });
          return;
        }

        reachedEnd = result.isEnd;
        emptyStreak++;
      }

      // 已到末页，或连续多页都没有新歌：停止翻页。
      if (mounted) {
        setState(() {
          _page = page;
          _isEnd = true;
        });
      }
    } catch (e) {
      debugPrint('[PlaylistDetailPage] 加载下一页失败: $e');
      if (mounted) setState(() => _isEnd = true);
    } finally {
      if (mounted) {
        setState(() => _loadingMore = false);
        _scheduleAutoFill();
      }
    }
  }

  void _checkIfFavorited() {
    final playlistsAsync = ref.read(playlistsProvider);
    final playlistAsync = ref.read(playlistDetailProvider(widget.playlistId));

    playlistAsync.whenData((page) {
      if (page.playlist == null) return;

      playlistsAsync.whenData((localPlaylists) {
        final exists = localPlaylists.any(
          (p) => p.meta['discoverId'] == widget.playlistId,
        );
        if (mounted) {
          setState(() {
            _isFavorited = exists;
          });
        }
      });
    });
  }

  // ---------------------------------------------------------------- 批量选择

  /// 长按歌曲进入批量选择模式并选中该首；已在选择模式则切换其选中态。
  void _enterSelection(Song song) {
    if (_selection.isActive) {
      _selection.toggle(song.id);
    } else {
      _selection.enter(song.id);
    }
  }

  /// 「更多」菜单里的「批量选择 / 取消批量选择」。
  void _toggleMultiSelectMode() {
    if (_selection.isActive) {
      _selection.exit();
    } else {
      _selection.enter();
    }
  }

  List<Song> _selectedSongs(List<Song> source) =>
      _selection.selectedSongs(source);

  void _batchPlayNext(List<Song> songs) {
    final selected = _selectedSongs(songs);
    if (selected.isEmpty) return;
    ref.read(playbackControllerProvider.notifier).insertNext(selected);
    _showMessage('已将 ${selected.length} 首插入到下一首播放');
  }

  void _batchAddToQueue(List<Song> songs) {
    final selected = _selectedSongs(songs);
    if (selected.isEmpty) return;
    ref.read(playbackControllerProvider.notifier).appendToQueue(selected);
    _showMessage('已将 ${selected.length} 首加入播放列表');
  }

  void _batchAddToPlaylist(List<Song> songs) {
    final selected = _selectedSongs(songs);
    if (selected.isEmpty) return;
    final colors = ref.read(themeColorsProvider);
    unawaited(showAddSongsToPlaylistSheet(context, ref, colors, selected));
  }

  Future<void> _batchFavorite(List<Song> songs) async {
    final selected = _selectedSongs(songs);
    if (selected.isEmpty) return;
    await ref
        .read(playlistsProvider.notifier)
        .addSongsToPlaylist('__favorites__', selected);
    if (mounted) _showMessage('已收藏 ${selected.length} 首');
  }

  void _batchDownload(List<Song> songs) {
    final selected = _selectedSongs(songs);
    if (selected.isEmpty) return;
    unawaited(showBatchDownloadSheet(context, ref, selected));
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

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final playlistAsync = ref.watch(playlistDetailProvider(widget.playlistId));
    final pageData = playlistAsync.valueOrNull;
    if (pageData != null) _syncPagination(pageData);

    // 提前计算当前播放歌曲在本歌单中的索引，用于定位按钮。
    // 在外层 Stack 中直接渲染 FAB，避免嵌套 Stack 裁剪导致按钮不可见。
    final currentSong = ref.watch(playbackControllerProvider).currentSong;
    final int currentSongIndex = currentSong == null
        ? -1
        : _songs.indexWhere((s) => s.id == currentSong.id);

    return ListenableBuilder(
      listenable: _selection,
      builder: (context, _) {
        final selecting = _selection.isActive;
        final currentSongs = _songs;
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
                Positioned.fill(
                  child: playlistAsync.when(
                    data: (page) {
                      final playlist = page.playlist;
                      if (playlist == null) {
                        return Center(
                          child: Text(context.tr('歌单未找到'), style: TextStyle(color: colors.textHint)),
                        );
                      }
                      return Column(
                        children: [
                          _buildHeader(context, ref, colors, playlist),
                          if (selecting)
                            SongSelectionBar(
                              colors: colors,
                              controller: _selection,
                              songs: currentSongs,
                            ),
                          Expanded(
                            child: _buildSongList(ref, colors, currentSongs),
                          ),
                        ],
                      );
                    },
                    loading: () => const Center(child: CircularProgressIndicator()),
                    error: (_, __) => Center(
                      child: Text(context.tr('加载失败'), style: TextStyle(color: colors.textHint)),
                    ),
                  ),
                ),
                // 底部迷你播放器（与搜索页面一致：键盘弹出时隐藏）
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
                    bottom: AppSpacing.miniPlayerHeight + AppSpacing.xl,
                    child: SongBatchActionBar(
                      colors: colors,
                      controller: _selection,
                      onPlayNext: () => _batchPlayNext(currentSongs),
                      onAddToQueue: () => _batchAddToQueue(currentSongs),
                      onAddToPlaylist: () => _batchAddToPlaylist(currentSongs),
                      onFavorite: () => _batchFavorite(currentSongs),
                      onDownload: () => _batchDownload(currentSongs),
                    ),
                  ),
                // 定位当前播放歌曲的悬浮按钮：放在外层 Stack 中避免被裁剪
                if (currentSongIndex >= 0 && !selecting)
                  _buildLocateFab(colors, currentSongIndex),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, WidgetRef ref, ThemeColors colors, playlist) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            colors.primary.withValues(alpha: 0.15),
            colors.background,
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: AppSpacing.xl),
          Row(
            children: [
              GestureDetector(
                onTap: () => context.pop(),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.xs),
                  child: Icon(Icons.arrow_back, size: 24, color: colors.textPrimary),
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => _showMoreActions(context, colors, playlist),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.xs),
                  child: Icon(Icons.more_horiz, size: 24, color: colors.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.lg),
                child: MusicCoverImage(
                  url: playlist.coverUrl,
                  width: 120,
                  height: 120,
                  fit: BoxFit.cover,
                  errorWidget: Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          colors.primary.withValues(alpha: 0.4),
                          colors.surfaceVariant,
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: Icon(Icons.music_note, size: 48, color: colors.textHint),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      playlist.title,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      playlist.description,
                      style: TextStyle(fontSize: 13, color: colors.textSecondary),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Row(
                      children: [
                        _buildActionButton(colors, Icons.play_arrow, context.tr('播放全部'), () {
                          _playAll(_songs);
                        }),
                        const SizedBox(width: AppSpacing.md),
                        _buildFavoriteButton(colors, playlist),
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

  Widget _buildActionButton(ThemeColors colors, IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
        decoration: BoxDecoration(
          color: colors.primary,
          borderRadius: BorderRadius.circular(AppRadius.full),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: colors.textOnPrimary),
            const SizedBox(width: AppSpacing.xs),
            Text(
              label,
              style: TextStyle(fontSize: 12, color: colors.textOnPrimary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFavoriteButton(ThemeColors colors, playlist) {
    return GestureDetector(
      onTap: () => _toggleFavorite(playlist),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
        decoration: BoxDecoration(
          color: _isFavorited ? colors.primary.withValues(alpha: 0.15) : colors.surfaceVariant,
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(
            color: _isFavorited ? colors.primary : colors.divider,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _isFavorited ? Icons.favorite : Icons.favorite_border,
              size: 16,
              color: _isFavorited ? colors.primary : colors.textSecondary,
            ),
            const SizedBox(width: AppSpacing.xs),
            Text(
              context.tr(_isFavorited ? '已收藏' : '收藏'),
              style: TextStyle(
                fontSize: 12,
                color: _isFavorited ? colors.primary : colors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSongList(WidgetRef ref, ThemeColors colors, List<Song> songs) {
    if (songs.isEmpty) {
      return Center(
        child: Text(context.tr('暂无歌曲'), style: TextStyle(color: colors.textHint)),
      );
    }

    final selecting = _selection.isActive;
    final list = ListView.builder(
      controller: _scrollController,
      // 预留迷你播放器高度（56px + 底部 20px 间距），保证最后一首歌曲
      // 能滚动到迷你播放器上方而不被遮挡；多选模式下还要避开批量操作栏。
      padding: EdgeInsets.only(
        bottom: AppSpacing.miniPlayerHeight +
            AppSpacing.lg +
            (selecting ? SongBatchActionBar.height : 0),
      ),
      itemCount: songs.length,
      // 与定位用的行高常量一致：既避免估算误差累积，也让列表布局从
      // "逐个测量子项"退化成 O(1) 的固定行高布局，长列表滚动更流畅。
      itemExtent: SongListItem.itemExtent,
      addAutomaticKeepAlives: false,
      addRepaintBoundaries: true,
      itemBuilder: (context, index) {
        final song = songs[index];

        // 高亮当前正在播放的歌曲，与本地音乐页面保持一致
        final currentSongId = ref
            .read(playbackControllerProvider)
            .currentSong
            ?.id;
        final isPlaying = currentSongId != null && currentSongId == song.id;

        return SongListItem(
          song: song,
          index: index,
          isPlaying: isPlaying,
          selectionMode: selecting,
          selected: _selection.isSelected(song.id),
          onSelectionToggle: (s) => _selection.toggle(s.id),
          // 长按进入批量选择模式
          onLongPress: () => _enterSelection(song),
          onPlayTap: () async {
            final controller = ref.read(playbackControllerProvider.notifier);
            await controller.setQueue(songs, startIndex: index);
          },
          onMenuTap: () => SongActionSheet.show(context, song: song, playlistSongs: songs),
        );
      },
    );

    return Stack(
      children: [
        list,
        if (_loadingMore)
          Positioned(
            left: 0,
            right: 0,
            bottom: AppSpacing.miniPlayerHeight + AppSpacing.lg,
            child: Center(child: _buildLoadingMoreIndicator(colors)),
          ),
      ],
    );
  }

  /// 翻页加载指示器（悬浮于列表底部，不占用列表项高度）。
  Widget _buildLoadingMoreIndicator(ThemeColors colors) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.full),
        border: Border.all(color: colors.divider),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors.primary,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            context.tr('加载更多...'),
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
        ],
      ),
    );
  }

  /// 悬浮定位按钮：仅当当前播放的歌曲在本歌单中时显示，
  /// 点击将歌曲列表滚动到正在播放的那一首。
  Widget _buildLocateFab(ThemeColors colors, int currentIndex) {
    if (currentIndex < 0) return const SizedBox.shrink();

    return Positioned(
      right: AppSpacing.lg,
      bottom: AppSpacing.miniPlayerHeight + AppSpacing.xxxl + AppSpacing.lg,
      child: GestureDetector(
        onTap: () => _locateCurrentSong(currentIndex),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: colors.surface,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: colors.shadow,
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(Icons.my_location, size: 18, color: colors.primary),
        ),
      ),
    );
  }

  void _locateCurrentSong(int currentIndex) {
    if (!_scrollController.hasClients) return;

    unawaited(
      scrollToItemIndex(
        _scrollController,
        index: currentIndex,
        itemExtent: SongListItem.itemExtent,
      ),
    );
  }

  void _showMoreActions(BuildContext context, ThemeColors colors, playlist) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.only(bottom: bottomPadding + 72),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: AppSpacing.md),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.divider,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                _buildMenuItem(
                  colors,
                  icon: Icons.select_all,
                  label: context.tr(_selection.isActive ? '取消批量选择' : '批量选择'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _toggleMultiSelectMode();
                  },
                ),
                _buildMenuItem(
                  colors,
                  icon: Icons.save_alt,
                  label: context.tr('保存到本地'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _saveToLocal(playlist);
                  },
                ),
                const SizedBox(height: AppSpacing.lg),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMenuItem(ThemeColors colors, {required IconData icon, required String label, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        child: Row(
          children: [
            Icon(icon, size: 22, color: colors.textSecondary),
            const SizedBox(width: AppSpacing.md),
            Text(label, style: TextStyle(fontSize: 15, color: colors.textPrimary)),
          ],
        ),
      ),
    );
  }

  Future<void> _playAll(List<Song> songs) async {
    if (songs.isEmpty) return;
    final controller = ref.read(playbackControllerProvider.notifier);
    await controller.setQueue(songs);
  }

  void _toggleFavorite(playlist) {
    if (_isFavorited) {
      _removeFromFavorites();
    } else {
      _addToFavorites(playlist);
    }
  }

  void _addToFavorites(playlist) async {
    final localPlaylist = local.Playlist(
      id: 'discover_${widget.playlistId}',
      name: playlist.title,
      description: playlist.description,
      coverImgUrl: playlist.coverUrl ?? '',
      source: playlist.source,
      createTime: DateTime.now(),
      updateTime: DateTime.now(),
      songs: _songs,
      meta: {
        'discoverId': widget.playlistId,
        'type': 'discover_playlist',
      },
    );

    await ref.read(playlistsProvider.notifier).createPlaylistFromModel(localPlaylist);

    setState(() {
      _isFavorited = true;
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.tr('已收藏到我的歌单')), duration: Duration(seconds: 2)),
      );
    }
  }

  void _removeFromFavorites() async {
    final playlistsAsync = ref.read(playlistsProvider);
    await playlistsAsync.whenData((localPlaylists) async {
      final existingPlaylist = localPlaylists.firstWhere(
        (p) => p.meta['discoverId'] == widget.playlistId,
        orElse: () => throw Exception('未找到收藏的歌单'),
      );
      await ref.read(playlistsProvider.notifier).deletePlaylist(existingPlaylist.id);
    });

    setState(() {
      _isFavorited = false;
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.tr('已取消收藏')), duration: Duration(seconds: 2)),
      );
    }
  }

  void _saveToLocal(playlist) async {
    final localPlaylist = local.Playlist(
      id: 'local_${DateTime.now().millisecondsSinceEpoch}',
      name: playlist.title,
      description: playlist.description,
      coverImgUrl: playlist.coverUrl ?? '',
      source: playlist.source,
      createTime: DateTime.now(),
      updateTime: DateTime.now(),
      songs: _songs,
      meta: {
        'discoverId': widget.playlistId,
        'type': 'saved_playlist',
      },
    );

    await ref.read(playlistsProvider.notifier).createPlaylistFromModel(localPlaylist);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr('已保存"${playlist.title}"到本地歌单')),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }
}
