import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';
import '../../../core/utils/scroll_locate.dart';
import '../../../shared/services/playlist_cmpl_codec.dart';
import '../../../shared/widgets/song_action_sheet.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../../shared/widgets/song_list_item.dart';
import '../../../shared/widgets/song_selection.dart';
import '../application/playlist_providers.dart';
import '../application/recently_played_providers.dart';
import '../domain/models/playlist.dart';
import '../domain/models/recently_played.dart';
import '../../player/application/playback_context.dart';
import '../../player/application/playback_controller.dart';
import '../../player/domain/models/song.dart';
import '../../discover/domain/models/search_collection.dart';
import '../../plugin/application/plugin_providers.dart';
import '../../player/presentation/mini_player.dart';

enum SongSortMode { addedTime, title, artist, custom }

class LocalPlaylistDetailPage extends ConsumerStatefulWidget {
  const LocalPlaylistDetailPage({super.key, required this.playlistId});

  final String playlistId;

  @override
  ConsumerState<LocalPlaylistDetailPage> createState() =>
      _LocalPlaylistDetailPageState();
}

class _LocalPlaylistDetailPageState
    extends ConsumerState<LocalPlaylistDetailPage> {
  SongSortMode _sortMode = SongSortMode.addedTime;
  bool _sortAscending = true;
  List<Song> _sortedSongs = [];
  List<Song> _originalSongs = [];
  bool _isCustomSortMode = false;
  final ScrollController _scrollController = ScrollController();

  /// 批量选择控制器（长按歌曲或右上角菜单进入）。
  final SongSelectionController _selection = SongSelectionController();

  /// 已经记录过「最近打开」的歌单 id，避免每帧 rebuild 都写一次。
  String? _recordedOpenedId;

  /// 正在拉取作者最新作品。
  bool _updatingArtist = false;

  @override
  void dispose() {
    _scrollController.dispose();
    _selection.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- 批量选择

  /// 长按歌曲进入批量选择模式并选中该首。
  void _enterSelection(Song song) {
    if (_selection.isActive) {
      _selection.toggle(song.id);
    } else {
      _selection.enter(song.id);
    }
  }

  void _toggleMultiSelectMode() {
    if (_selection.isActive) {
      _selection.exit();
    } else {
      _selection.enter();
    }
  }

  List<Song> _selectedSongs() => _selection.selectedSongs(_sortedSongs);

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

  /// 批量从歌单移除：一次性写盘（逐首 removeSongFromPlaylist 会写 N 次）。
  Future<void> _confirmRemoveSelected(Playlist playlist) async {
    final selected = _selectedSongs();
    if (selected.isEmpty) return;
    final colors = ref.read(themeColorsProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(
          context.tr('从歌单移除'),
          style: TextStyle(color: colors.textPrimary),
        ),
        content: Text(
          context.tr('确定要从歌单中移除选中的 ${selected.length} 首歌曲吗？'),
          style: TextStyle(color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              context.tr('取消'),
              style: TextStyle(color: colors.textHint),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              context.tr('移除'),
              style: TextStyle(color: colors.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final ids = selected.map((s) => s.id).toSet();
    // 按原始顺序过滤，避免把当前排序结果固化成歌单存储顺序。
    final remaining = _originalSongs.where((s) => !ids.contains(s.id)).toList();
    await ref
        .read(playlistsProvider.notifier)
        .updatePlaylist(
          playlist.copyWith(
            songs: remaining,
            // 歌单封面跟随当前第一首歌
            coverImgUrl: remaining.isEmpty
                ? ''
                : (remaining.first.coverUrl ?? ''),
          ),
        );
    if (!mounted) return;
    _selection.exit();
    _showMessage('已从歌单移除 ${ids.length} 首歌曲');
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

  List<Song> _applySort(List<Song> songs) {
    final list = List<Song>.from(songs);
    switch (_sortMode) {
      case SongSortMode.addedTime:
        if (!_sortAscending) {
          list.sort((a, b) => songs.indexOf(b).compareTo(songs.indexOf(a)));
        }
        break;
      case SongSortMode.title:
        list.sort((a, b) {
          final cmp = a.title.toLowerCase().compareTo(b.title.toLowerCase());
          return _sortAscending ? cmp : -cmp;
        });
        break;
      case SongSortMode.artist:
        list.sort((a, b) {
          final cmp = a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
          return _sortAscending ? cmp : -cmp;
        });
        break;
      case SongSortMode.custom:
        break;
    }
    return list;
  }

  void _updateSortedSongs(List<Song> songs) {
    _originalSongs = List<Song>.from(songs);
    _sortedSongs = _isCustomSortMode
        ? List<Song>.from(songs)
        : _applySort(songs);
  }

  void _onSortModeChanged(SongSortMode mode) {
    setState(() {
      _sortMode = mode;
      _isCustomSortMode = mode == SongSortMode.custom;
      _sortedSongs = _isCustomSortMode
          ? List<Song>.from(_originalSongs)
          : _applySort(_originalSongs);
    });
    Navigator.pop(context);
  }

  void _onCustomReorder(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) newIndex--;
    setState(() {
      final song = _sortedSongs.removeAt(oldIndex);
      _sortedSongs.insert(newIndex, song);
    });
  }

  void _saveCustomSort() {
    final playlistsAsync = ref.read(playlistsProvider);
    playlistsAsync.whenData((playlists) {
      final playlist = playlists
          .where((p) => p.id == widget.playlistId)
          .firstOrNull;
      if (playlist != null) {
        ref
            .read(playlistsProvider.notifier)
            .updatePlaylist(playlist.copyWith(songs: _sortedSongs));
      }
    });
    setState(() {
      _originalSongs = List<Song>.from(_sortedSongs);
      _isCustomSortMode = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.tr('排序已保存')),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  void _cancelCustomSort() {
    setState(() {
      _sortedSongs = List<Song>.from(_originalSongs);
      _isCustomSortMode = false;
      _sortMode = SongSortMode.addedTime;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final playlistsAsync = ref.watch(playlistsProvider);

    return ListenableBuilder(
      listenable: _selection,
      builder: (context, _) {
        final selecting = _selection.isActive;
        final currentPlaylist = _currentPlaylist(playlistsAsync);
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
                  child: SafeArea(
                    child: playlistsAsync.when(
                      data: (playlists) {
                        final playlist = playlists
                            .where((p) => p.id == widget.playlistId)
                            .firstOrNull;
                        if (playlist == null) {
                          return Center(
                            child: Text(
                              context.tr('歌单未找到'),
                              style: TextStyle(color: colors.textHint),
                            ),
                          );
                        }
                        if (_recordedOpenedId != playlist.id) {
                          _recordedOpenedId = playlist.id;
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (!mounted) return;
                            unawaited(
                              ref
                                  .read(
                                    recentlyPlayedPlaylistsProvider.notifier,
                                  )
                                  .recordOpened(
                                    id: playlist.id,
                                    name: playlist.name,
                                    coverUrl: playlist.coverImgUrl,
                                    songCount: playlist.songCount,
                                    source: 'local',
                                  ),
                            );
                          });
                        }
                        if (_originalSongs.length != playlist.songs.length ||
                            !_listEquals(_originalSongs, playlist.songs)) {
                          _updateSortedSongs(playlist.songs);
                        }
                        return Column(
                          children: [
                            _buildHeader(context, ref, colors, playlist),
                            if (selecting)
                              SongSelectionBar(
                                colors: colors,
                                controller: _selection,
                                songs: _sortedSongs,
                              )
                            else if (_isCustomSortMode)
                              _buildCustomSortBar(colors),
                            Expanded(
                              // 多选优先：避免「选择栏 + 可拖拽列表」同时生效
                              child: _isCustomSortMode && !selecting
                                  ? _buildReorderableSongList(
                                      ref,
                                      colors,
                                      playlist,
                                    )
                                  : _buildSongList(
                                      context,
                                      ref,
                                      colors,
                                      playlist,
                                    ),
                            ),
                          ],
                        );
                      },
                      loading: () =>
                          const Center(child: CircularProgressIndicator()),
                      error: (_, __) => Center(
                        child: Text(
                          context.tr('加载失败'),
                          style: TextStyle(color: colors.textHint),
                        ),
                      ),
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
                      onRemove: currentPlaylist == null
                          ? null
                          : () => _confirmRemoveSelected(currentPlaylist),
                      removeLabel: '从歌单移除',
                      removeIcon: Icons.remove_circle_outline,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Playlist? _currentPlaylist(AsyncValue<List<Playlist>> playlistsAsync) {
    return playlistsAsync.valueOrNull
        ?.where((p) => p.id == widget.playlistId)
        .firstOrNull;
  }

  bool _listEquals(List<Song> a, List<Song> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  Widget _buildCustomSortBar(ThemeColors colors) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: 0.08),
        border: Border(bottom: BorderSide(color: colors.divider, width: 0.5)),
      ),
      child: Row(
        children: [
          Icon(Icons.drag_handle, size: 18, color: colors.primary),
          const SizedBox(width: AppSpacing.sm),
          Text(
            context.tr('拖拽歌曲调整顺序'),
            style: TextStyle(fontSize: 13, color: colors.primary),
          ),
          const Spacer(),
          TextButton(
            onPressed: _cancelCustomSort,
            child: Text(
              context.tr('取消'),
              style: TextStyle(color: colors.textHint, fontSize: 13),
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          TextButton(
            onPressed: _saveCustomSort,
            child: Text(
              context.tr('保存'),
              style: TextStyle(
                color: colors.primary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 歌单页顶部：返回按钮 + 封面 + 名称 / 歌曲数量 + 操作按钮。
  ///
  /// 不显示歌单描述；名称 + 歌曲数量 + 按钮这一列的高度与歌单封面保持一致。
  Widget _buildHeader(
    BuildContext context,
    WidgetRef ref,
    ThemeColors colors,
    Playlist playlist,
  ) {
    // 与歌单封面同高，去掉描述后顶部不会跳动
    final headerHeight = ResponsiveLayout.isTablet(context) ? 96.0 : 72.0;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [colors.primary.withValues(alpha: 0.15), colors.background],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: SizedBox(
        height: headerHeight,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 返回按钮
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
            // 歌单封面（没有封面时用第一首歌的封面）
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: SizedBox(
                width: headerHeight,
                height: headerHeight,
                child: _buildPlaylistCoverWidget(colors, playlist),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            // 名称 + 歌曲数量 + 操作按钮
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text(
                          playlist.name,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: colors.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        context.tr('${playlist.songCount}首歌曲'),
                        style: TextStyle(fontSize: 12, color: colors.textHint),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    children: [
                      _buildActionButton(
                        colors,
                        Icons.play_arrow,
                        context.tr('播放全部'),
                        () {
                          if (_sortedSongs.isNotEmpty) {
                            PlaybackContext.instance.set(
                              PlaybackSourceType.playlist,
                              id: playlist.id,
                              name: playlist.name,
                            );
                            final controller = ref.read(
                              playbackControllerProvider.notifier,
                            );
                            controller.setQueue(_sortedSongs);
                          }
                        },
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      _buildActionButton(
                        colors,
                        Icons.shuffle,
                        context.tr('随机播放'),
                        () {
                          if (_sortedSongs.isNotEmpty) {
                            PlaybackContext.instance.set(
                              PlaybackSourceType.playlist,
                              id: playlist.id,
                              name: playlist.name,
                            );
                            final songs = [..._sortedSongs]..shuffle();
                            final controller = ref.read(
                              playbackControllerProvider.notifier,
                            );
                            controller.setQueue(songs);
                          }
                        },
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      _buildSortButton(colors),
                    ],
                  ),
                ],
              ),
            ),
            // 作者收藏歌单：拉取该作者最新作品并补进收藏
            if (_artistCollectionOf(playlist) != null)
              _buildUpdateButton(colors, playlist),
            // 更多操作
            PopupMenuButton<String>(
              icon: Icon(
                Icons.more_horiz,
                size: 24,
                color: colors.textSecondary,
              ),
              color: colors.surface,
              onSelected: (value) {
                if (value == 'export') {
                  _exportPlaylist(context, ref, colors, playlist);
                } else if (value == 'edit') {
                  _editPlaylist(context, ref, colors, playlist);
                } else if (value == 'multiselect') {
                  _toggleMultiSelectMode();
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'multiselect',
                  child: Row(
                    children: [
                      Icon(
                        Icons.select_all,
                        size: 18,
                        color: colors.textSecondary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        context.tr(_selection.isActive ? '取消批量选择' : '批量选择'),
                        style: TextStyle(color: colors.textPrimary),
                      ),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'edit',
                  child: Text(
                    context.tr('编辑歌单'),
                    style: TextStyle(color: colors.textPrimary),
                  ),
                ),
                PopupMenuItem(
                  value: 'export',
                  child: Text(
                    context.tr('导出歌单'),
                    style: TextStyle(color: colors.textPrimary),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 作者收藏

  /// 解析「作者：xxx」收藏歌单里保存的来源信息。
  ///
  /// 收藏专辑 / 作者时会把 `mintmusic:artist:<source>:<id>` 写进歌单描述，
  /// 只有带这个标记的歌单才显示「更新」按钮（搜索结果里打开的作者主页没有）。
  ({String source, String id, String name})? _artistCollectionOf(
    Playlist playlist,
  ) {
    const prefix = 'mintmusic:artist:';
    final description = playlist.description.trim();
    if (!description.startsWith(prefix)) return null;
    final rest = description.substring(prefix.length);
    final separator = rest.indexOf(':');
    if (separator <= 0) return null;
    final source = rest.substring(0, separator).trim();
    final id = rest.substring(separator + 1).trim();
    if (source.isEmpty || id.isEmpty) return null;
    final name = playlist.name.startsWith('作者：')
        ? playlist.name.substring(3)
        : playlist.name;
    return (source: source, id: id, name: name);
  }

  /// 作者收藏歌单右上角的「更新」按钮（图标样式，避免挤爆窄屏的操作行）。
  Widget _buildUpdateButton(ThemeColors colors, Playlist playlist) {
    return Tooltip(
      message: context.tr('更新作者作品'),
      child: GestureDetector(
        onTap: _updatingArtist
            ? null
            : () => unawaited(_updateArtistCollection(playlist)),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xs),
          child: _updatingArtist
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.primary,
                  ),
                )
              : Icon(Icons.refresh, size: 22, color: colors.primary),
        ),
      ),
    );
  }

  /// 拉取作者最新作品，把收藏里还没有的歌曲补进去。
  ///
  /// 流程：重新搜一次作者（插件查作品需要搜索返回的 artistItem）→ 逐页拉作品
  /// → 和收藏里的歌曲比对 → 只把新增的加进去 → 弹框显示明细 / 异常信息。
  Future<void> _updateArtistCollection(Playlist playlist) async {
    final info = _artistCollectionOf(playlist);
    if (info == null || _updatingArtist) return;
    setState(() => _updatingArtist = true);
    final manager = ref.read(musicSourceManagerProvider);
    final details = <String>[];
    try {
      details.add('音源：${info.source}');
      final search = await manager.searchCollections(
        info.name,
        sourceId: info.source,
        type: CollectionType.artist,
        page: 1,
      );
      details.add('搜索「${info.name}」：返回 ${search.items.length} 个作者');
      if (search.items.isEmpty) {
        await _showUpdateResult(
          success: false,
          title: context.tr('没有搜到该作者'),
          details: details,
          playlist: playlist,
        );
        return;
      }
      final artist = search.items.firstWhere(
        (item) => item.id == info.id,
        orElse: () => search.items.first,
      );
      details.add('使用作者：${artist.title}（id=${artist.id}）');

      final works = <Song>[];
      var page = 1;
      var isEnd = false;
      // 最多 10 页（作者作品一般每页 30 首），避免异常音源无限翻页。
      while (!isEnd && page <= 10) {
        final detail = await manager.getCollectionDetail(artist, page: page);
        details.add('第 $page 页：${detail.songs.length} 首');
        works.addAll(detail.songs);
        isEnd = detail.isEnd;
        if (detail.songs.isEmpty) break;
        page++;
      }
      if (works.isEmpty) {
        await _showUpdateResult(
          success: false,
          title: context.tr('没有获取到作品'),
          details: details,
          playlist: playlist,
        );
        return;
      }

      final existing = playlist.songs.map((song) => song.id).toSet();
      final added = <Song>[];
      for (final song in works) {
        if (existing.add(song.id)) added.add(song);
      }
      details.add('最新作品 ${works.length} 首，收藏里已有 ${playlist.songs.length} 首');
      if (added.isEmpty) {
        await _showUpdateResult(
          success: true,
          title: context.tr('没有新增作品'),
          details: details,
          playlist: playlist,
        );
        return;
      }
      await ref
          .read(playlistsProvider.notifier)
          .addSongsToPlaylist(playlist.id, added);
      final preview = added.take(10).map((song) => song.title).join('、');
      details.add('新增作品：$preview${added.length > 10 ? ' 等' : ''}');
      if (mounted) {
        await _showUpdateResult(
          success: true,
          title: context.tr('已新增 ${added.length} 首作品'),
          details: details,
          playlist: playlist,
        );
      }
    } catch (e) {
      details.add('异常：$e');
      if (mounted) {
        await _showUpdateResult(
          success: false,
          title: context.tr('更新失败'),
          details: details,
          playlist: playlist,
        );
      }
    } finally {
      if (mounted) setState(() => _updatingArtist = false);
    }
  }

  /// 更新结果弹框：标题 + 详细过程 / 异常信息，失败时可直接重试。
  Future<void> _showUpdateResult({
    required bool success,
    required String title,
    required List<String> details,
    required Playlist playlist,
  }) async {
    if (!mounted) return;
    final colors = ref.read(themeColorsProvider);
    final retry = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: colors.surface,
        title: Row(
          children: [
            Icon(
              success ? Icons.check_circle_outline : Icons.error_outline,
              size: 20,
              color: success ? colors.primary : colors.error,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: TextStyle(fontSize: 16, color: colors.textPrimary),
              ),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: SingleChildScrollView(
            child: SelectableText(
              details.join('\n'),
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(context.tr('关闭')),
          ),
          if (!success)
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(context.tr('重试')),
            ),
        ],
      ),
    );
    if (retry == true && mounted) {
      await _updateArtistCollection(playlist);
    }
  }

  Widget _buildSortButton(ThemeColors colors) {
    return GestureDetector(
      onTap: () => _showSortBottomSheet(colors),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: colors.primary,
          borderRadius: BorderRadius.circular(AppRadius.full),
        ),
        child: Icon(Icons.sort, size: 14, color: colors.textOnPrimary),
      ),
    );
  }

  void _showSortBottomSheet(ThemeColors colors) {
    showModalBottomSheet(
      context: context,
      backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg,
                    ),
                    child: Row(
                      children: [
                        Text(
                          context.tr('排序方式'),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: colors.textPrimary,
                          ),
                        ),
                        const Spacer(),
                        GestureDetector(
                          onTap: () {
                            setModalState(() {
                              _sortAscending = !_sortAscending;
                            });
                            setState(() {
                              _sortedSongs = _applySort(_originalSongs);
                            });
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: colors.surfaceVariant,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _sortAscending
                                      ? Icons.arrow_upward
                                      : Icons.arrow_downward,
                                  size: 14,
                                  color: colors.textSecondary,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  context.tr(_sortAscending ? '升序' : '降序'),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _buildSortOption(
                    colors: colors,
                    icon: Icons.access_time,
                    label: context.tr('按添加时间'),
                    mode: SongSortMode.addedTime,
                    setModalState: setModalState,
                  ),
                  _buildSortOption(
                    colors: colors,
                    icon: Icons.music_note,
                    label: context.tr('按歌曲名'),
                    mode: SongSortMode.title,
                    setModalState: setModalState,
                  ),
                  _buildSortOption(
                    colors: colors,
                    icon: Icons.person,
                    label: context.tr('按歌手名'),
                    mode: SongSortMode.artist,
                    setModalState: setModalState,
                  ),
                  _buildSortOption(
                    colors: colors,
                    icon: Icons.drag_handle,
                    label: context.tr('自定义排序'),
                    mode: SongSortMode.custom,
                    setModalState: setModalState,
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSortOption({
    required ThemeColors colors,
    required IconData icon,
    required String label,
    required SongSortMode mode,
    required StateSetter setModalState,
  }) {
    final isActive = _sortMode == mode;
    return ListTile(
      leading: Icon(
        icon,
        size: 20,
        color: isActive ? colors.primary : colors.textSecondary,
      ),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 14,
          color: isActive ? colors.primary : colors.textPrimary,
          fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      trailing: isActive
          ? Icon(Icons.check, size: 18, color: colors.primary)
          : null,
      onTap: () {
        setModalState(() {
          _sortMode = mode;
        });
        _onSortModeChanged(mode);
      },
    );
  }

  /// 歌单封面：优先用歌单自己的封面，没有则用第一首歌的封面。
  Widget _buildPlaylistCoverWidget(ThemeColors colors, Playlist playlist) {
    if (playlist.coverImgUrl.isNotEmpty) {
      return MusicCoverImage(
        url: playlist.coverImgUrl,
        fit: BoxFit.cover,
        useDiscoveryCache: true,
        errorWidget: _coverFallback(colors),
      );
    }

    final firstSong = playlist.songs.isNotEmpty ? playlist.songs.first : null;
    if (firstSong == null) {
      return _coverFallback(colors);
    }

    if (firstSong.mediaStoreId != null || firstSong.isLocal) {
      return MusicCoverImage(
        key: ValueKey('lp_cover_${firstSong.id}'),
        songId: firstSong.id,
        mediaStoreId: firstSong.mediaStoreId,
        fit: BoxFit.cover,
        errorWidget: _coverFallback(colors),
      );
    }

    if (firstSong.coverUrl != null && firstSong.coverUrl!.isNotEmpty) {
      return MusicCoverImage(
        key: ValueKey('lp_cover_url_${firstSong.id}'),
        url: firstSong.coverUrl,
        fit: BoxFit.cover,
        errorWidget: _coverFallback(colors),
      );
    }

    return _coverFallback(colors);
  }

  Widget _coverFallback(ThemeColors colors) {
    return Container(
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
    );
  }

  Widget _buildSongCover(ThemeColors colors, Song song) {
    if (song.mediaStoreId != null || song.isLocal) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: MusicCoverImage(
          key: ValueKey('lps_cover_${song.id}'),
          songId: song.id,
          mediaStoreId: song.mediaStoreId,
          fit: BoxFit.cover,
          errorWidget: Icon(Icons.music_note, size: 20, color: colors.primary),
        ),
      );
    }

    if (song.coverUrl != null && song.coverUrl!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: MusicCoverImage(
          url: song.coverUrl,
          fit: BoxFit.cover,
          errorWidget: Icon(Icons.music_note, size: 20, color: colors.primary),
        ),
      );
    }

    return Icon(Icons.music_note, size: 20, color: colors.primary);
  }

  Widget _buildActionButton(
    ThemeColors colors,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: colors.primary,
          borderRadius: BorderRadius.circular(AppRadius.full),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: colors.textOnPrimary),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(fontSize: 11, color: colors.textOnPrimary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReorderableSongList(
    WidgetRef ref,
    ThemeColors colors,
    Playlist playlist,
  ) {
    if (_sortedSongs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.music_off,
              size: 48,
              color: colors.textHint.withValues(alpha: 0.3),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(context.tr('歌单为空'), style: TextStyle(color: colors.textHint)),
          ],
        ),
      );
    }

    return ReorderableListView.builder(
      // 预留迷你播放器高度（56px + 底部 20px 间距），保证最后一首歌曲
      // 能滚动到迷你播放器上方而不被遮挡。
      padding: const EdgeInsets.only(
        bottom: AppSpacing.miniPlayerHeight + AppSpacing.lg,
      ),
      itemCount: _sortedSongs.length,
      onReorder: _onCustomReorder,
      proxyDecorator: (child, index, animation) {
        return AnimatedBuilder(
          animation: animation,
          builder: (context, child) {
            final double elevation = animation.value * 6;
            return Material(
              elevation: elevation,
              color: colors.surface,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: child,
            );
          },
          child: child,
        );
      },
      itemBuilder: (context, index) {
        final song = _sortedSongs[index];
        return ListTile(
          key: Key('${playlist.id}_${song.id}_$index'),
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.drag_handle, size: 20, color: colors.textHint),
              const SizedBox(width: AppSpacing.xs),
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: colors.surfaceVariant,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: _buildSongCover(colors, song),
              ),
            ],
          ),
          title: Text(
            song.title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: colors.textPrimary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${song.artist} - ${song.album}',
            style: TextStyle(fontSize: 12, color: colors.textHint),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        );
      },
    );
  }

  Widget _buildSongList(
    BuildContext context,
    WidgetRef ref,
    ThemeColors colors,
    Playlist playlist,
  ) {
    if (_sortedSongs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.music_off,
              size: 48,
              color: colors.textHint.withValues(alpha: 0.3),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(context.tr('歌单为空'), style: TextStyle(color: colors.textHint)),
            const SizedBox(height: AppSpacing.sm),
            Text(
              context.tr('在发现页搜索歌曲并添加到歌单'),
              style: TextStyle(
                fontSize: 12,
                color: colors.textHint.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      );
    }

    final selecting = _selection.isActive;
    // 宽屏下内容区没有迷你播放器，列表底部只需避开批量操作栏。
    final bottomInset = ResponsiveLayout.hasBottomMiniPlayer(context)
        ? AppSpacing.miniPlayerHeight + AppSpacing.xxxl
        : AppSpacing.xxxl;
    return Stack(
      children: [
        ListView.builder(
          controller: _scrollController,
          // 预留迷你播放器高度（56px + 底部 20px 间距），保证最后一首歌曲
          // 能滚动到迷你播放器上方而不被遮挡；多选模式下还要避开批量操作栏。
          padding: EdgeInsets.only(
            bottom: bottomInset + (selecting ? SongBatchActionBar.height : 0),
          ),
          itemCount: _sortedSongs.length,
          // 与定位用的行高常量一致，避免估算误差累积
          itemExtent: SongListItem.itemExtent,
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: true,
          itemBuilder: (context, index) {
            final song = _sortedSongs[index];
            // 高亮当前正在播放的歌曲，与本地音乐页面保持一致
            final item = Builder(
              builder: (context) {
                final playbackState = ref.read(playbackControllerProvider);
                final isPlaying = playbackState.currentSong?.id == song.id;
                return SongListItem(
                  song: song,
                  index: index,
                  isPlaying: isPlaying,
                  showPlayedTag: true,
                  selectionMode: selecting,
                  selected: _selection.isSelected(song.id),
                  onSelectionToggle: (s) => _selection.toggle(s.id),
                  // 长按进入批量选择模式
                  onLongPress: () => _enterSelection(song),
                  onPlayTap: () {
                    PlaybackContext.instance.set(
                      PlaybackSourceType.playlist,
                      id: playlist.id,
                      name: playlist.name,
                    );
                    final controller = ref.read(
                      playbackControllerProvider.notifier,
                    );
                    controller.setQueue(_sortedSongs, startIndex: index);
                  },
                  onMenuTap: () => SongActionSheet.show(
                    context,
                    song: song,
                    playlistSongs: _sortedSongs,
                  ),
                );
              },
            );
            // 多选模式下禁用右滑删除，避免与选择手势冲突
            if (selecting) return item;
            return Dismissible(
              key: Key('${playlist.id}_${song.id}'),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: AppSpacing.lg),
                color: colors.error,
                child: Icon(Icons.delete, color: colors.textOnPrimary),
              ),
              confirmDismiss: (_) =>
                  _confirmRemoveSong(context, colors, playlist, song),
              onDismissed: (_) {
                ref
                    .read(playlistsProvider.notifier)
                    .removeSongFromPlaylist(playlist.id, song.id);
              },
              child: item,
            );
          },
        ),
        // 定位当前播放歌曲的悬浮按钮（右下角，避开底部迷你播放器）
        if (!selecting) _buildLocateFab(colors),
      ],
    );
  }

  /// 悬浮定位按钮：仅当当前播放的歌曲在本歌单中时显示，
  /// 点击将歌曲列表滚动到正在播放的那一首。
  Widget _buildLocateFab(ThemeColors colors) {
    final currentSong = ref.watch(playbackControllerProvider).currentSong;
    if (currentSong == null) return const SizedBox.shrink();
    final index = _sortedSongs.indexWhere((s) => s.id == currentSong.id);
    if (index == -1) return const SizedBox.shrink();

    return Positioned(
      right: AppSpacing.lg,
      bottom: AppSpacing.miniPlayerHeight + AppSpacing.xxl,
      child: GestureDetector(
        onTap: () => _locateCurrentSong(),
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

  void _locateCurrentSong() {
    final currentSong = ref.read(playbackControllerProvider).currentSong;
    if (currentSong == null) return;
    final index = _sortedSongs.indexWhere((s) => s.id == currentSong.id);
    if (index == -1) return;
    if (!_scrollController.hasClients) return;

    unawaited(
      scrollToItemIndex(
        _scrollController,
        index: index,
        itemExtent: SongListItem.itemExtent,
      ),
    );
  }

  /// 右滑删除前的确认弹窗，避免误删
  Future<bool> _confirmRemoveSong(
    BuildContext context,
    ThemeColors colors,
    Playlist playlist,
    Song song,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        title: Text(
          context.tr('删除歌曲'),
          style: TextStyle(color: colors.textPrimary, fontSize: 16),
        ),
        content: Text(
          context.tr('确定要从歌单「${playlist.name}」中删除《${song.title}》吗？'),
          style: TextStyle(color: colors.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              context.tr('取消'),
              style: TextStyle(color: colors.textHint),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              context.tr('删除'),
              style: TextStyle(
                color: colors.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _exportPlaylist(
    BuildContext context,
    WidgetRef ref,
    ThemeColors colors,
    Playlist playlist,
  ) async {
    try {
      // Convert MintMusic songs to CeruMusic-compatible format
      final List<Map<String, dynamic>> ceruSongs = playlist.songs.map((s) {
        // Derive songmid: strip source prefix from id, or use hash
        String songmid = s.hash ?? s.id;
        if (songmid.startsWith('${s.source}_')) {
          songmid = songmid.substring(s.source!.length + 1);
        }

        return {
          'songmid': songmid,
          'name': s.title,
          'singer': s.artist,
          'albumName': s.album,
          'albumId': '',
          'source': s.source ?? 'local',
          'interval': s.displayDuration,
          'img': s.coverUrl ?? '',
          'lrc': s.lrc,
          'hash': s.hash ?? '',
          'types': <String>[],
          '_types': <String, dynamic>{},
          'typeUrl': <String, dynamic>{},
          'url': '',
        };
      }).toList();

      // Encode the array to .cmpl format (AES encrypt + gzip compress)
      final json = jsonEncode(ceruSongs);
      final cmplBytes = Uint8List.fromList(encodeCmpl(json));

      // 直接弹出系统「保存文件」对话框，让用户自己选保存位置
      // （Windows 是系统另存为对话框，Android 是系统文件选择界面）。
      final safeName = playlist.name.replaceAll(
        RegExp(r'[^\w\u4e00-\u9fff\- ]'),
        '_',
      );
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: context.tr('保存歌单'),
        fileName: '$safeName.cmpl',
        type: FileType.any,
        bytes: cmplBytes,
      );
      if (savedPath == null) {
        // 用户取消了保存
        return;
      }
      // 部分平台（返回的是 content URI）不会自动写内容，这里对真实路径再兜底写一次
      try {
        final file = File(savedPath);
        if (!await file.exists() || await file.length() != cmplBytes.length) {
          await file.writeAsBytes(cmplBytes, flush: true);
        }
      } catch (_) {
        // Android 返回的是 content URI，内容已由系统文件选择器写入
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.tr('歌单已保存')),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.tr('导出歌单失败：$e')),
            duration: const Duration(seconds: 3),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _editPlaylist(
    BuildContext context,
    WidgetRef ref,
    ThemeColors colors,
    Playlist playlist,
  ) {
    final nameController = TextEditingController(text: playlist.name);
    final descController = TextEditingController(text: playlist.description);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(
          context.tr('编辑歌单'),
          style: TextStyle(color: colors.textPrimary),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: InputDecoration(
                hintText: context.tr('歌单名称'),
                hintStyle: TextStyle(color: colors.textHint),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: colors.divider),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: colors.primary),
                ),
              ),
              style: TextStyle(color: colors.textPrimary),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: descController,
              decoration: InputDecoration(
                hintText: context.tr('歌单描述（可选）'),
                hintStyle: TextStyle(color: colors.textHint),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: colors.divider),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: colors.primary),
                ),
              ),
              style: TextStyle(color: colors.textPrimary),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              context.tr('取消'),
              style: TextStyle(color: colors.textHint),
            ),
          ),
          TextButton(
            onPressed: () {
              final name = nameController.text.trim();
              if (name.isNotEmpty) {
                ref
                    .read(playlistsProvider.notifier)
                    .updatePlaylist(
                      playlist.copyWith(
                        name: name,
                        description: descController.text.trim(),
                      ),
                    );
                Navigator.pop(ctx);
              }
            },
            child: Text(
              context.tr('保存'),
              style: TextStyle(color: colors.primary),
            ),
          ),
        ],
      ),
    );
  }
}
