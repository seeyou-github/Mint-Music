import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../../shared/widgets/song_action_sheet.dart';
import '../../../shared/widgets/song_list_item.dart';
import '../../discover/domain/models/search_collection.dart';
import '../../player/application/playback_context.dart';
import '../../player/application/playback_controller.dart';
import '../../player/domain/models/song.dart';
import '../../player/presentation/mini_player.dart';
import '../../plugin/application/plugin_providers.dart';
import '../application/playlist_providers.dart';
import '../domain/models/playlist.dart';
import '../domain/models/recently_played.dart';
import '../utils/favorite_playlist.dart';

/// 作者收藏的「更新」页：逐页拉取作者作品，和本地收藏对比后补进歌单。
class ArtistUpdatePage extends ConsumerStatefulWidget {
  const ArtistUpdatePage({super.key, required this.playlistId});

  final String playlistId;

  @override
  ConsumerState<ArtistUpdatePage> createState() => _ArtistUpdatePageState();
}

/// 已经请求过（或正在请求）的一页作者作品。
class _WorkPage {
  _WorkPage(this.number);

  final int number;
  List<Song> songs = const [];
  bool loading = false;
  bool loaded = false;
  bool isEnd = false;
  String? error;
}

class _ArtistUpdatePageState extends ConsumerState<ArtistUpdatePage> {
  final ScrollController _tabScrollController = ScrollController();
  final List<_WorkPage> _pages = [];

  Playlist? _playlist;
  SearchCollection? _artist;
  Set<String> _localIds = <String>{};
  int _currentPage = 0;
  bool _preparing = true;
  bool _adding = false;
  String? _prepareError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_prepare());
    });
  }

  @override
  void dispose() {
    _tabScrollController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- 数据加载

  /// 找到收藏歌单，重新搜索作者，然后自动加载第一页作品。
  ///
  /// 作者作品接口需要搜索结果的 [SearchCollection]，所以每次都先搜一次作者。
  Future<void> _prepare() async {
    if (!mounted) return;
    setState(() {
      _preparing = true;
      _prepareError = null;
      _pages.clear();
      _currentPage = 0;
      _artist = null;
    });
    try {
      final playlists = await ref.read(playlistsProvider.future);
      if (!mounted) return;
      final playlist = playlists
          .where((item) => item.id == widget.playlistId)
          .firstOrNull;
      if (playlist == null) throw const _UpdateException('歌单未找到');
      final source = playlist.favoriteSource;
      final artistId = playlist.favoriteCollectionId;
      if (playlist.favoriteType != PlaybackSourceType.artist ||
          source == null ||
          artistId == null) {
        throw const _UpdateException('该歌单不是作者收藏，无法更新');
      }

      final manager = ref.read(musicSourceManagerProvider);
      final search = await manager.searchCollections(
        playlist.displayName,
        sourceId: source,
        type: CollectionType.artist,
        page: 1,
      );
      if (!mounted) return;
      if (search.items.isEmpty) throw const _UpdateException('没有搜到该作者');
      final artist = search.items.firstWhere(
        (item) => item.id == artistId,
        orElse: () => search.items.first,
      );

      _playlist = playlist;
      _artist = artist;
      _localIds = playlist.songs.map((song) => song.id).toSet();
      _pages.add(_WorkPage(1));
      _currentPage = 0;
      setState(() => _preparing = false);
      await _loadPage(0);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _preparing = false;
        _prepareError = _messageOf(error);
      });
    }
  }

  Future<void> _loadPage(int index) async {
    final artist = _artist;
    if (artist == null || index < 0 || index >= _pages.length) return;
    final page = _pages[index];
    if (page.loading) return;

    setState(() {
      page.loading = true;
      page.error = null;
    });
    try {
      final detail = await ref
          .read(musicSourceManagerProvider)
          .getCollectionDetail(artist, page: page.number);
      if (!mounted) return;
      setState(() {
        page.songs = detail.songs;
        page.isEnd = detail.isEnd || detail.songs.isEmpty;
        page.loaded = true;
        page.loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        page.loading = false;
        page.error = _messageOf(error);
      });
    }
  }

  void _loadNextPage() {
    if (!_canLoadNext) return;
    setState(() {
      _pages.add(_WorkPage(_pages.length + 1));
      _currentPage = _pages.length - 1;
    });
    unawaited(_loadPage(_pages.length - 1));
    // 新标签可能在可视区域外，滚到最右侧让它可见。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_tabScrollController.hasClients) return;
      _tabScrollController.animateTo(
        _tabScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  bool get _canLoadNext {
    if (_preparing || _prepareError != null || _pages.isEmpty) return false;
    final last = _pages.last;
    return last.loaded && !last.loading && !last.isEnd;
  }

  /// 已经拉取到的全部作品（跨页去重，保持先后顺序）。
  List<Song> get _fetchedSongs {
    final seen = <String>{};
    return [
      for (final page in _pages)
        ...page.songs.where((song) => seen.add(song.id)),
    ];
  }

  /// 本地收藏里还没有的作品。
  List<Song> get _newSongs =>
      _fetchedSongs.where((song) => !_localIds.contains(song.id)).toList();

  // ---------------------------------------------------------------- 添加新增

  Future<void> _showAddNewDialog() async {
    final missing = _newSongs;
    if (missing.isEmpty) {
      _toast('没有新增作品');
      return;
    }
    final colors = ref.read(themeColorsProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: colors.surface,
        title: Row(
          children: [
            Icon(Icons.playlist_add, size: 20, color: colors.primary),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                context.tr('新增作品（${missing.length} 首）'),
                style: TextStyle(fontSize: 16, color: colors.textPrimary),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: missing.length,
              separatorBuilder: (_, _) =>
                  Divider(height: 1, color: colors.divider),
              itemBuilder: (context, index) {
                final song = missing[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 24,
                        child: Text(
                          '${index + 1}',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.textHint,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              song.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: colors.textPrimary,
                              ),
                            ),
                            if (song.artist.isNotEmpty)
                              Text(
                                song.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colors.textHint,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(
              context.tr('取消'),
              style: TextStyle(color: colors.textHint),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              context.tr('添加'),
              style: TextStyle(
                color: colors.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _appendSongs(missing);
  }

  Future<void> _appendSongs(List<Song> songs) async {
    final playlists =
        ref.read(playlistsProvider).valueOrNull ?? const <Playlist>[];
    final current = playlists
        .where((item) => item.id == widget.playlistId)
        .firstOrNull;
    if (current == null) {
      _toast('歌单未找到');
      return;
    }
    // 一次性写盘，避免逐首 addSongsToPlaylist 反复读写整个歌单文件。
    final existing = current.songs.map((song) => song.id).toSet();
    final toAdd = songs.where((song) => existing.add(song.id)).toList();
    if (toAdd.isEmpty) {
      if (mounted) setState(() => _localIds = existing);
      return;
    }

    setState(() => _adding = true);
    try {
      await ref
          .read(playlistsProvider.notifier)
          .updatePlaylist(
            current.copyWith(songs: [...toAdd, ...current.songs]),
          );
      if (!mounted) return;
      setState(() => _localIds = existing);
      _toast('已添加 ${toAdd.length} 首作品');
    } catch (error) {
      if (!mounted) return;
      _toast('添加失败：${_messageOf(error)}');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final playlist =
        ref
            .watch(playlistsProvider)
            .valueOrNull
            ?.where((item) => item.id == widget.playlistId)
            .firstOrNull ??
        _playlist;
    final fetchedCount = _fetchedSongs.length;
    final newCount = _newSongs.length;

    return Scaffold(
      backgroundColor: colors.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: SafeArea(
              child: Column(
                children: [
                  _buildHeader(colors, playlist, fetchedCount, newCount),
                  _buildPageBar(colors),
                  Expanded(child: _buildBody(colors)),
                ],
              ),
            ),
          ),
          MediaQuery.of(context).viewInsets.bottom > 0
              ? const SizedBox.shrink()
              : Positioned(
                  left: 0,
                  right: 0,
                  bottom: 20,
                  child: RepaintBoundary(child: const MiniPlayer()),
                ),
        ],
      ),
    );
  }

  Widget _buildHeader(
    ThemeColors colors,
    Playlist? playlist,
    int fetchedCount,
    int newCount,
  ) {
    final coverSize = ResponsiveLayout.isTablet(context) ? 80.0 : 64.0;
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
      child: Row(
        children: [
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
          ClipOval(
            child: SizedBox(
              width: coverSize,
              height: coverSize,
              child: _buildCover(colors, playlist?.coverImgUrl ?? ''),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  playlist?.name ?? context.tr('更新作者作品'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  _preparing
                      ? context.tr('正在获取作品…')
                      : context.tr('已获取 $fetchedCount 首 · 新增 $newCount 首'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: colors.textHint),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          _buildAddNewButton(colors),
        ],
      ),
    );
  }

  Widget _buildCover(ThemeColors colors, String url) {
    if (url.isEmpty) return _coverFallback(colors);
    return MusicCoverImage(
      url: url,
      fit: BoxFit.cover,
      useDiscoveryCache: true,
      errorWidget: _coverFallback(colors),
    );
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
      child: Icon(Icons.person, size: 28, color: colors.textOnPrimary),
    );
  }

  Widget _buildAddNewButton(ThemeColors colors) {
    final enabled =
        !_preparing &&
        _prepareError == null &&
        !_adding &&
        _pages.any((page) => page.loaded);
    final contentColor = enabled ? colors.textOnPrimary : colors.textHint;
    return GestureDetector(
      onTap: enabled ? () => unawaited(_showAddNewDialog()) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: enabled ? colors.primary : colors.surfaceVariant,
          borderRadius: BorderRadius.circular(AppRadius.full),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_adding)
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.primary,
                ),
              )
            else
              Icon(Icons.playlist_add, size: 16, color: contentColor),
            const SizedBox(width: AppSpacing.xs),
            Text(
              context.tr('添加新增'),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: contentColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPageBar(ThemeColors colors) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.divider, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _pages.isEmpty
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      context.tr('暂无分页'),
                      style: TextStyle(fontSize: 12, color: colors.textHint),
                    ),
                  )
                : ScrollConfiguration(
                    behavior: const _DragScrollBehavior(),
                    child: SingleChildScrollView(
                      controller: _tabScrollController,
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (var i = 0; i < _pages.length; i++) ...[
                            if (i > 0) const SizedBox(width: AppSpacing.sm),
                            _buildPageTab(colors, i),
                          ],
                        ],
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: AppSpacing.md),
          _buildLoadNextButton(colors),
        ],
      ),
    );
  }

  Widget _buildPageTab(ThemeColors colors, int index) {
    final selected = index == _currentPage;
    final page = _pages[index];
    final failed = page.error != null;
    final borderColor = selected
        ? colors.primary
        : failed
        ? colors.error.withValues(alpha: 0.5)
        : colors.divider;
    return GestureDetector(
      onTap: () => setState(() => _currentPage = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 44,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? colors.primary.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: borderColor),
        ),
        child: page.loading
            ? SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.primary,
                ),
              )
            : Text(
                '${page.number}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: failed
                      ? colors.error
                      : selected
                      ? colors.primary
                      : colors.textSecondary,
                ),
              ),
      ),
    );
  }

  Widget _buildLoadNextButton(ThemeColors colors) {
    final enabled = _canLoadNext;
    return GestureDetector(
      onTap: enabled ? _loadNextPage : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(color: enabled ? colors.primary : colors.divider),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.expand_more,
              size: 16,
              color: enabled ? colors.primary : colors.textHint,
            ),
            const SizedBox(width: 2),
            Text(
              context.tr('加载下一页'),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: enabled ? colors.primary : colors.textHint,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ThemeColors colors) {
    if (_preparing) return const Center(child: CircularProgressIndicator());
    if (_prepareError != null) {
      return _buildErrorView(
        colors,
        _prepareError!,
        () => unawaited(_prepare()),
      );
    }
    if (_pages.isEmpty) return const SizedBox.shrink();

    final page = _pages[_currentPage.clamp(0, _pages.length - 1)];
    if (page.loading && !page.loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    if (page.error != null) {
      return _buildErrorView(
        colors,
        page.error!,
        () => unawaited(_loadPage(_currentPage)),
      );
    }
    if (page.songs.isEmpty) {
      return Center(
        child: Text(
          context.tr('这一页没有作品'),
          style: TextStyle(color: colors.textHint),
        ),
      );
    }
    return _buildSongList(colors, page);
  }

  Widget _buildErrorView(
    ThemeColors colors,
    String message,
    VoidCallback onRetry,
  ) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off,
              size: 44,
              color: colors.textHint.withValues(alpha: 0.5),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: colors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.lg),
            GestureDetector(
              onTap: onRetry,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius: BorderRadius.circular(AppRadius.full),
                ),
                child: Text(
                  context.tr('重试'),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: colors.textOnPrimary,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSongList(ThemeColors colors, _WorkPage page) {
    final bottomInset = ResponsiveLayout.hasBottomMiniPlayer(context)
        ? AppSpacing.miniPlayerHeight + AppSpacing.xxxl
        : AppSpacing.xxxl;
    return ListView.builder(
      key: PageStorageKey('artist_update_${page.number}'),
      padding: EdgeInsets.only(bottom: bottomInset),
      itemExtent: SongListItem.itemExtent,
      itemCount: page.songs.length,
      itemBuilder: (context, index) {
        final song = page.songs[index];
        final isNew = !_localIds.contains(song.id);
        return SongListItem(
          song: song,
          index: index,
          showPlayedTag: true,
          trailingBadge: isNew ? _buildNewTag(colors) : null,
          onPlayTap: () => _playSong(page, index),
          onMenuTap: () => SongActionSheet.show(
            context,
            song: song,
            playlistSongs: page.songs,
          ),
        );
      },
    );
  }

  Widget _buildNewTag(ThemeColors colors) {
    return Container(
      margin: const EdgeInsets.only(right: AppSpacing.sm),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: colors.primary.withValues(alpha: 0.5)),
      ),
      child: Text(
        context.tr('新增'),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: colors.primary,
        ),
      ),
    );
  }

  void _playSong(_WorkPage page, int index) {
    final artist = _artist;
    if (artist != null) {
      PlaybackContext.instance.set(
        PlaybackSourceType.artist,
        id: artist.id,
        name: artist.title,
      );
    }
    final songs = applyFavoriteSource(page.songs, _playlist?.favoriteSource);
    ref
        .read(playbackControllerProvider.notifier)
        .setQueue(songs, startIndex: index);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.tr(message)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _messageOf(Object error) {
    final text = error is _UpdateException ? error.message : error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }
}

class _UpdateException implements Exception {
  const _UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 分页标签超出宽度时允许触屏 / 鼠标 / 触控板拖动。
class _DragScrollBehavior extends MaterialScrollBehavior {
  const _DragScrollBehavior();

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
