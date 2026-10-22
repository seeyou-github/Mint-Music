import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../../shared/widgets/song_action_sheet.dart';
import '../../../shared/widgets/song_list_item.dart';
import '../../library/application/playlist_providers.dart';
import '../../player/application/playback_context.dart';
import '../../player/application/playback_controller.dart';
import '../../player/domain/models/song.dart';
import '../../plugin/application/plugin_providers.dart';
import '../domain/models/recently_played.dart';
import '../domain/models/search_collection.dart';

/// 专辑 / 作者详情页。
///
/// 布局与歌单详情一致：顶部信息卡（封面 / 名称 / 播放全部 / 收藏），
/// 下面是歌曲列表。收藏时会在「收藏」页面生成一个歌单：
/// 「专辑：xxx」或「作者：xxx」。
class CollectionDetailPage extends ConsumerStatefulWidget {
  const CollectionDetailPage({super.key, required this.collection});

  final SearchCollection collection;

  @override
  ConsumerState<CollectionDetailPage> createState() =>
      _CollectionDetailPageState();
}

class _CollectionDetailPageState extends ConsumerState<CollectionDetailPage> {
  CollectionDetail? _detail;
  bool _loading = true;
  bool _updating = false;

  bool get _isArtist => widget.collection.type == CollectionType.artist;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final manager = ref.read(musicSourceManagerProvider);
    try {
      final detail = await manager.getCollectionDetail(widget.collection);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
    } catch (e) {
      debugPrint('[CollectionDetail] 加载失败: $e');
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  /// 作者：重新拉取最新作品（收藏后可用它把新作品补进收藏）。
  Future<void> _refreshWorks() async {
    if (_updating) return;
    setState(() => _updating = true);
    try {
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr('已获取最新作品')),
          duration: const Duration(seconds: 2),
        ),
      );
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _playAll(List<Song> songs) async {
    if (songs.isEmpty) return;
    PlaybackContext.instance.set(
      _isArtist ? PlaybackSourceType.unknown : PlaybackSourceType.album,
      id: widget.collection.id,
      name: widget.collection.title,
    );
    await ref
        .read(playbackControllerProvider.notifier)
        .setQueue(songs, startIndex: 0);
  }

  Future<void> _toggleFavorite(List<Song> songs) async {
    final name = widget.collection.favoriteName;
    final playlists = ref.read(playlistsProvider).valueOrNull ?? const [];
    final existing = playlists.where((p) => p.title == name).firstOrNull;
    final notifier = ref.read(playlistsProvider.notifier);
    if (existing != null) {
      await notifier.deletePlaylist(existing.id);
      if (!mounted) return;
      _toast(context.tr('已取消收藏'));
      return;
    }
    if (songs.isEmpty) return;
    await notifier.createPlaylistWithSongs(
      name,
      songs.map((s) => s.toJson()).toList(),
      description: 'mintmusic:${widget.collection.type.id}:'
          '${widget.collection.source}:${widget.collection.id}',
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
    final detail = _detail;
    final item = detail?.item ?? widget.collection;
    final songs = detail?.songs ?? const <Song>[];
    final favoriteName = item.favoriteName;
    final favorited =
        (ref.watch(playlistsProvider).valueOrNull ?? const [])
            .any((p) => p.title == favoriteName);

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(colors, item, songs, favorited),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : songs.isEmpty
                  ? Center(
                      child: Text(
                        context.tr('没有获取到歌曲'),
                        style: TextStyle(color: colors.textHint),
                      ),
                    )
                  : _buildSongList(colors, songs),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(
    ThemeColors colors,
    SearchCollection item,
    List<Song> songs,
    bool favorited,
  ) {
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
                  children: [
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _subtitle(item, songs.length),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: colors.textHint),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Row(
                      children: [
                        _actionChip(
                          colors,
                          icon: Icons.play_arrow,
                          label: context.tr('播放全部'),
                          primary: true,
                          onTap: songs.isEmpty
                              ? null
                              : () => _playAll(songs),
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
                        if (_isArtist) ...[
                          const SizedBox(width: AppSpacing.sm),
                          _actionChip(
                            colors,
                            icon: Icons.refresh,
                            label: context.tr('更新'),
                            onTap: _updating ? null : _refreshWorks,
                          ),
                        ],
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
          border: Border.all(
            color: primary ? colors.primary : colors.divider,
          ),
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
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sm,
        0,
        AppSpacing.sm,
        AppSpacing.xxxl,
      ),
      itemCount: songs.length,
      itemBuilder: (context, index) {
        final song = songs[index];
        return SongListItem(
          song: song,
          index: index,
          isPlaying: currentSongId == song.id,
          onPlayTap: () async {
            PlaybackContext.instance.set(
              _isArtist ? PlaybackSourceType.unknown : PlaybackSourceType.album,
              id: widget.collection.id,
              name: widget.collection.title,
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
}
