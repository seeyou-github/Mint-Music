import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';
import '../../../shared/widgets/cover_badge.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../../shared/widgets/playlist_sync_button.dart';
import '../application/playlist_providers.dart';
import '../../player/application/playback_context.dart';
import '../../player/application/playback_controller.dart';
import '../../plugin/application/plugin_providers.dart';
import '../domain/models/playlist.dart' as local_playlist;
import '../domain/models/recently_played.dart';
import '../../discover/domain/models/playlist.dart' as discover_playlist;
import '../utils/cerumusic_playlist_importer.dart';
import '../utils/favorite_playlist.dart';

class LibraryPage extends ConsumerWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(themeColorsProvider);
    final playlistsAsync = ref.watch(playlistsProvider);

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildHeader(context, colors, ref),
            const SizedBox(height: AppSpacing.md),
            Expanded(
              child: playlistsAsync.when(
                data: (playlists) => playlists.isEmpty
                    ? _buildEmptyState(context, colors)
                    : _buildPlaylistGrid(context, colors, playlists, ref),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(
                  child: Text(context.tr('加载失败'), style: TextStyle(color: colors.textHint)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    ThemeColors colors,
    WidgetRef ref,
  ) {
    final isTablet = ResponsiveLayout.isTablet(context);
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: ResponsiveLayout.horizontalPadding(context),
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              context.tr('我的收藏'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: isTablet ? 26 : 22,
                fontWeight: FontWeight.bold,
                color: colors.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          _buildActionButtons(context, colors, ref),
        ],
      ),
    );
  }

  Widget _buildActionButtons(
    BuildContext context,
    ThemeColors colors,
    WidgetRef ref,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () => _showCreateDialog(context, colors, ref),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              color: colors.primary,
              borderRadius: BorderRadius.circular(AppRadius.full),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add, size: 14, color: colors.textOnPrimary),
                const SizedBox(width: AppSpacing.xs),
                Text(
                  context.tr('新建歌单'),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: colors.textOnPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        GestureDetector(
          onTap: () => _showImportDialog(context, colors, ref),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              border: Border.all(color: colors.divider),
              borderRadius: BorderRadius.circular(AppRadius.full),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.file_download,
                  size: 14,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: AppSpacing.xs),
                Text(
                  context.tr('导入'),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        const PlaylistSyncButton(),
      ],
    );
  }

  Widget _buildEmptyState(BuildContext context, ThemeColors colors) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.library_music,
            size: 64,
            color: colors.textHint.withValues(alpha: 0.3),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(context.tr('还没有歌单'), style: TextStyle(fontSize: 16, color: colors.textHint)),
          const SizedBox(height: AppSpacing.sm),
          Text(
            context.tr('点击上方"新建歌单"开始创建'),
            style: TextStyle(
              fontSize: 13,
              color: colors.textHint.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaylistGrid(
    BuildContext context,
    ThemeColors colors,
    List<local_playlist.Playlist> playlists,
    WidgetRef ref,
  ) {
    final isTablet = ResponsiveLayout.isTablet(context);
    final crossAxisCount = ResponsiveLayout.gridCrossAxisCount(context);

    return GridView.builder(
      // AppShell 将迷你播放器叠放在页面内容之上。为列表底部预留空间，
      // 使最后一行歌单能够完整滚动到播放器上方。
      padding: EdgeInsets.fromLTRB(
        ResponsiveLayout.horizontalPadding(context),
        0,
        ResponsiveLayout.horizontalPadding(context),
        AppSpacing.miniPlayerHeight + AppSpacing.lg,
      ),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: isTablet ? 0.85 : 0.8,
        crossAxisSpacing: isTablet ? 16 : AppSpacing.md,
        mainAxisSpacing: isTablet ? 16 : AppSpacing.md,
      ),
      itemCount: playlists.length,
      addAutomaticKeepAlives: false,
      addRepaintBoundaries: true,
      itemBuilder: (context, index) {
        final playlist = playlists[index];
        return _buildPlaylistCard(context, colors, playlist, index, ref);
      },
    );
  }

  Widget _buildPlaylistCard(
    BuildContext context,
    ThemeColors colors,
    local_playlist.Playlist playlist,
    int index,
    WidgetRef ref,
  ) {
    final favoriteType = playlist.favoriteType;
    return GestureDetector(
      // 歌单 id 可能带 `/`、`?`（插件来源的榜单是 `mf:board:<源>:<原始 id>`，
      // 例如 bilibili 的 `popular/series/one?number=396`），不编码会让
      // go_router 把 id 切成多段，报 no routes for location。
      onTap: () => context.push(
        '/library/playlist/${Uri.encodeComponent(playlist.id)}',
      ),
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
                    color: colors.surfaceVariant,
                    child: _buildPlaylistCover(colors, playlist),
                  ),
                  if (favoriteType != null)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: CoverBadge(
                        label: context.tr(
                          favoriteType == PlaybackSourceType.artist
                              ? '作者'
                              : '专辑',
                        ),
                        color: favoriteType == PlaybackSourceType.artist
                            ? const Color(0xFFB07CFF)
                            : const Color(0xFFD9B44A),
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
                    playlist.displayName,
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
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _PlaylistAction(
                        icon: Icons.play_arrow,
                        label: context.tr('播放'),
                        color: colors.primary,
                        onTap: () {
                          if (playlist.songs.isNotEmpty) {
                            PlaybackContext.instance.set(
                              PlaybackSourceType.playlist,
                              id: playlist.id,
                              name: playlist.name,
                            );
                            ref
                                .read(playbackControllerProvider.notifier)
                                .setQueue(
                                  playlist.playbackSongs,
                                  startIndex: 0,
                                );
                          }
                        },
                      ),
                      _PlaylistAction(
                        icon: Icons.edit,
                        label: context.tr('编辑'),
                        color: colors.textHint,
                        onTap: () =>
                            _showEditDialog(context, colors, ref, playlist),
                      ),
                      _PlaylistAction(
                        icon: Icons.delete,
                        label: context.tr('删除'),
                        color: colors.textHint,
                        onTap: () =>
                            _confirmDelete(context, colors, ref, playlist),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaylistCover(
    ThemeColors colors,
    local_playlist.Playlist playlist,
  ) {
    // 「我的收藏」没有原始歌单封面，用当前第一首歌的封面；
    // 其它歌单展示歌单自身的原始封面。
    final isFavorites = playlist.id == '__favorites__';
    if (isFavorites) {
      final firstSong = playlist.songs.isNotEmpty ? playlist.songs.first : null;
      if (firstSong != null) {
        if (firstSong.mediaStoreId != null || firstSong.isLocal) {
          return SizedBox.expand(
            child: MusicCoverImage(
              key: ValueKey('lib_cover_${firstSong.id}'),
              songId: firstSong.id,
              mediaStoreId: firstSong.mediaStoreId,
              fit: BoxFit.cover,
              errorWidget: Center(
                child: Icon(Icons.music_note, size: 40, color: colors.textHint),
              ),
            ),
          );
        }

        if (firstSong.coverUrl != null && firstSong.coverUrl!.isNotEmpty) {
          return SizedBox.expand(
            child: MusicCoverImage(
              // 带上歌曲 id：第一首歌变化时强制重建，避免沿用上一首的封面
              key: ValueKey('lib_cover_url_${firstSong.id}'),
              url: firstSong.coverUrl,
              fit: BoxFit.cover,
              errorWidget: Center(
                child: Icon(Icons.music_note, size: 40, color: colors.textHint),
              ),
            ),
          );
        }
      }
    }

    // 歌单自身的原始封面
    if (playlist.coverImgUrl.isNotEmpty) {
      return SizedBox.expand(
        child: MusicCoverImage(
          url: playlist.coverImgUrl,
          fit: BoxFit.cover,
          useDiscoveryCache: true,
          errorWidget: Center(
            child: Icon(Icons.music_note, size: 40, color: colors.textHint),
          ),
        ),
      );
    }

    // 歌单没有原始封面时退回第一首歌的封面
    final firstSong = playlist.songs.isNotEmpty ? playlist.songs.first : null;
    if (firstSong != null) {
      if (firstSong.mediaStoreId != null || firstSong.isLocal) {
        return SizedBox.expand(
          child: MusicCoverImage(
            key: ValueKey('lib_cover_${firstSong.id}'),
            songId: firstSong.id,
            mediaStoreId: firstSong.mediaStoreId,
            fit: BoxFit.cover,
            errorWidget: Center(
              child: Icon(Icons.music_note, size: 40, color: colors.textHint),
            ),
          ),
        );
      }
      if (firstSong.coverUrl != null && firstSong.coverUrl!.isNotEmpty) {
        return SizedBox.expand(
          child: MusicCoverImage(
            key: ValueKey('lib_cover_url_${firstSong.id}'),
            url: firstSong.coverUrl,
            fit: BoxFit.cover,
            errorWidget: Center(
              child: Icon(Icons.music_note, size: 40, color: colors.textHint),
            ),
          ),
        );
      }
    }

    return Center(
      child: Icon(Icons.music_note, size: 40, color: colors.textHint),
    );
  }

  void _showCreateDialog(
    BuildContext context,
    ThemeColors colors,
    WidgetRef ref,
  ) {
    final controller = TextEditingController();
    final descController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(context.tr('新建歌单'), style: TextStyle(color: colors.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
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
            child: Text(context.tr('取消'), style: TextStyle(color: colors.textHint)),
          ),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                ref
                    .read(playlistsProvider.notifier)
                    .createPlaylist(
                      name,
                      description: descController.text.trim(),
                    );
                Navigator.pop(ctx);
              }
            },
            child: Text(context.tr('创建'), style: TextStyle(color: colors.primary)),
          ),
        ],
      ),
    );
  }

  void _showEditDialog(
    BuildContext context,
    ThemeColors colors,
    WidgetRef ref,
    local_playlist.Playlist playlist,
  ) {
    final controller = TextEditingController(text: playlist.name);
    final descController = TextEditingController(text: playlist.description);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(context.tr('编辑歌单'), style: TextStyle(color: colors.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
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
            child: Text(context.tr('取消'), style: TextStyle(color: colors.textHint)),
          ),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
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
            child: Text(context.tr('保存'), style: TextStyle(color: colors.primary)),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(
    BuildContext context,
    ThemeColors colors,
    WidgetRef ref,
    local_playlist.Playlist playlist,
  ) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(context.tr('删除歌单'), style: TextStyle(color: colors.textPrimary)),
        content: Text(
          context.tr('确定要删除"${playlist.name}"吗？此操作不可撤销。'),
          style: TextStyle(color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.tr('取消'), style: TextStyle(color: colors.textHint)),
          ),
          TextButton(
            onPressed: () {
              ref.read(playlistsProvider.notifier).deletePlaylist(playlist.id);
              Navigator.pop(ctx);
            },
            child: Text(context.tr('删除'), style: TextStyle(color: colors.error)),
          ),
        ],
      ),
    );
  }

  void _showImportDialog(
    BuildContext context,
    ThemeColors colors,
    WidgetRef ref,
  ) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.tr('选择导入方式'),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              _buildImportOption(
                colors,
                Icons.queue_music,
                context.tr('从当前播放列表'),
                context.tr('将当前播放列表保存为歌单'),
                onTap: () {
                  Navigator.pop(ctx);
                  _importFromCurrentPlaylist(context, colors, ref);
                },
              ),
              const SizedBox(height: AppSpacing.sm),
              _buildImportOption(
                colors,
                Icons.folder_open,
                context.tr('从本地歌单文件'),
                context.tr('导入 .cmpl/.cpl/.json 歌单文件'),
                onTap: () {
                  Navigator.pop(ctx);
                  _importFromLocalFile(context, colors, ref);
                },
              ),
              const SizedBox(height: AppSpacing.sm),
              _buildImportOption(
                colors,
                Icons.language,
                context.tr('从网络歌单'),
                context.tr('导入网易云音乐、QQ音乐等平台歌单'),
                subtitle: context.tr('实验性功能'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showNetworkImportDialog(context, colors, ref);
                },
              ),
              const SizedBox(height: AppSpacing.lg),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(context.tr('取消'), style: TextStyle(color: colors.textHint)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImportOption(
    ThemeColors colors,
    IconData icon,
    String title,
    String description, {
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          border: Border.all(color: colors.divider),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Icon(icon, size: 20, color: colors.primary),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: colors.textPrimary,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(width: AppSpacing.xs),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: colors.warning.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(AppRadius.xs),
                          ),
                          child: Text(
                            subtitle,
                            style: TextStyle(
                              fontSize: 10,
                              color: colors.warning,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: TextStyle(fontSize: 12, color: colors.textHint),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 20, color: colors.textHint),
          ],
        ),
      ),
    );
  }

  void _importFromCurrentPlaylist(
    BuildContext context,
    ThemeColors colors,
    WidgetRef ref,
  ) {
    final playbackState = ref.read(playbackControllerProvider);
    final queue = playbackState.queue;

    if (queue.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr('当前播放列表为空'),
            style: TextStyle(color: colors.textOnPrimary),
          ),
          backgroundColor: colors.warning,
        ),
      );
      return;
    }

    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.tr('从播放列表导入'),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                context.tr('共 ${queue.length} 首歌曲'),
                style: TextStyle(fontSize: 13, color: colors.textHint),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: context.tr('输入歌单名称'),
                  hintStyle: TextStyle(color: colors.textHint),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    borderSide: BorderSide(color: colors.divider),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    borderSide: BorderSide(color: colors.divider),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    borderSide: BorderSide(color: colors.primary),
                  ),
                ),
                style: TextStyle(color: colors.textPrimary),
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(context.tr('取消'), style: TextStyle(color: colors.textHint)),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  TextButton(
                    onPressed: () {
                      final name = controller.text.trim();
                      if (name.isEmpty) return;
                      Navigator.pop(ctx);

                      final localPlaylist = local_playlist.Playlist(
                        id: DateTime.now().millisecondsSinceEpoch.toString(),
                        name: name,
                        description: '从播放列表导入，共 ${queue.length} 首歌曲',
                        source: 'local',
                        createTime: DateTime.now(),
                        updateTime: DateTime.now(),
                        songs: queue,
                      );

                      ref
                          .read(playlistsProvider.notifier)
                          .updatePlaylist(localPlaylist);

                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            context.tr('成功从播放列表导入 ${queue.length} 首歌曲'),
                            style: TextStyle(color: colors.textOnPrimary),
                          ),
                          backgroundColor: colors.primary,
                        ),
                      );
                    },
                    child: Text(context.tr('导入'), style: TextStyle(color: colors.primary)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _importFromLocalFile(
    BuildContext context,
    ThemeColors colors,
    WidgetRef ref,
  ) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowCompression: false,
      );

      if (result == null || result.files.isEmpty) {
        return;
      }

      final file = result.files.first;

      if (file.path == null) {
        return;
      }

      final ext = file.path!.split('.').last.toLowerCase();

      List<Map<String, dynamic>> playlistData;
      // 歌单名：导出的文件名就是歌单名（xxx.cmpl），JSON 文件里也可能带
      // name 字段；都取不到时才用「导入歌单 + 日期」兜底。
      String? playlistName;

      if (ext == 'cmpl' || ext == 'cpl') {
        playlistData = await CeruMusicPlaylistImporter.importFromFileAsync(
          file.path!,
        );

        if (!CeruMusicPlaylistImporter.validateImportedPlaylist(playlistData)) {
          throw Exception('歌单数据格式不正确或缺少必要字段');
        }

        playlistName = _playlistNameFromFilePath(file.path!);
      } else {
        final fileBytes = await File(file.path!).readAsBytes();
        final content = utf8.decode(fileBytes);
        playlistData = _parseJsonPlaylist(content);
        playlistName =
            _playlistNameFromJson(content) ?? _playlistNameFromFilePath(file.path!);
      }

      final songs = _convertCeruMusicPlaylistToSongs(playlistData);

      if (songs.isEmpty) {
        throw Exception('歌单中没有有效的歌曲');
      }

      final name =
          playlistName ??
          '导入歌单 ${DateTime.now().toString().substring(0, 10)}';

      await ref
          .read(playlistsProvider.notifier)
          .createPlaylistWithSongs(name, songs);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr('导入成功！共导入 ${songs.length} 首歌曲'),
              style: TextStyle(color: colors.textOnPrimary),
            ),
            backgroundColor: colors.primary,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr('导入失败：${e.toString()}'),
              style: TextStyle(color: colors.textOnPrimary),
            ),
            backgroundColor: colors.error,
          ),
        );
      }
    }
  }

  /// 从文件名里取歌单名。
  ///
  /// 导出的歌单文件名就是歌单名（`我的歌单.cmpl`），导入时直接拿文件名当
  /// 歌单名，才能把名字还原回来。
  String? _playlistNameFromFilePath(String path) {
    final name = p.basenameWithoutExtension(path).trim();
    if (name.isEmpty) return null;
    return name;
  }

  /// 从 JSON 歌单文件里取歌单名（文件里有 name / playlistName / title 时）。
  String? _playlistNameFromJson(String jsonText) {
    try {
      final data = jsonDecode(jsonText);
      if (data is Map) {
        for (final key in const ['name', 'playlistName', 'title']) {
          final value = data[key];
          if (value is String && value.trim().isNotEmpty) {
            return value.trim();
          }
        }
      }
    } catch (_) {
      // 解析失败就当没有名字，继续用文件名兜底。
    }
    return null;
  }

  List<Map<String, dynamic>> _parseJsonPlaylist(String jsonText) {
    try {
      final data = jsonDecode(jsonText);
      if (data is List) {
        return data.cast<Map<String, dynamic>>();
      } else if (data is Map) {
        if (data.containsKey('songs')) {
          return (data['songs'] as List).cast<Map<String, dynamic>>();
        }
        return [data.cast<String, dynamic>()];
      }
      throw Exception('JSON 格式不正确');
    } catch (e) {
      throw Exception('解析 JSON 失败: $e');
    }
  }

  List<Map<String, dynamic>> _convertCeruMusicPlaylistToSongs(
    List<Map<String, dynamic>> ceruMusicPlaylist,
  ) {
    return ceruMusicPlaylist.map((item) {
      final source = item['source']?.toString() ?? '';
      final songmid = item['songmid']?.toString() ?? '';
      final hash = item['hash']?.toString() ?? '';

      final effectiveId = hash.isNotEmpty
          ? '${source}_$hash'
          : (source.isNotEmpty && songmid.isNotEmpty
                ? '${source}_$songmid'
                : songmid);

      return {
        'id': effectiveId,
        'title': item['name']?.toString() ?? '未知歌曲',
        'artist': item['singer']?.toString() ?? '未知歌手',
        'album': item['albumName']?.toString() ?? '未知专辑',
        'duration': _parseDuration(item['interval']?.toString() ?? '0:00'),
        'coverUrl': item['img']?.toString() ?? '',
        'source': source,
        'sourceUrl': '',
        'lrc': item['lrc']?.toString() ?? '',
        'hash': hash.isNotEmpty ? hash : null,
      };
    }).toList();
  }

  int _parseDuration(String interval) {
    if (interval.isEmpty) return 0;

    try {
      final parts = interval.split(':');
      if (parts.length == 2) {
        final minutes = int.tryParse(parts[0]) ?? 0;
        final seconds = int.tryParse(parts[1]) ?? 0;
        return minutes * 60 + seconds;
      }
      return 0;
    } catch (_) {
      return 0;
    }
  }

  void _showNetworkImportDialog(
    BuildContext context,
    ThemeColors colors,
    WidgetRef ref,
  ) {
    String selectedPlatform = 'wy';
    final urlController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          String placeholderText;
          switch (selectedPlatform) {
            case 'wy':
              placeholderText =
                  context.tr('支持链接或ID：https://music.163.com/playlist?id=123456789 或 123456789');
              break;
            case 'tx':
              placeholderText =
                  context.tr('支持链接或ID：https://y.qq.com/n/ryqq/playlist/123456789 或 123456789');
              break;
            case 'kw':
              placeholderText =
                  context.tr('支持链接或ID：http://www.kuwo.cn/playlist_detail/123456789 或 123456789');
              break;
            case 'kg':
              placeholderText =
                  context.tr('支持链接或酷狗码：https://www.kugou.com/yy/special/single/123456789、m.kugou.com/songlist/gcid_xxx 或 酷狗码 123456789');
              break;
            case 'mg':
              placeholderText =
                  context.tr('支持链接或ID：https://music.migu.cn/v3/music/playlist/123456789 或 123456789');
              break;
            default:
              placeholderText = context.tr('请输入歌单链接或ID');
          }

          return Dialog(
            backgroundColor: colors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.tr('导入网络歌单'),
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Text(
                      context.tr('选择导入平台'),
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.sm,
                      children: [
                        _buildPlatformChip(
                          colors,
                          context.tr('网易云音乐'),
                          'wy',
                          selectedPlatform,
                          () {
                            setState(() => selectedPlatform = 'wy');
                          },
                        ),
                        _buildPlatformChip(
                          colors,
                          context.tr('QQ音乐'),
                          'tx',
                          selectedPlatform,
                          () {
                            setState(() => selectedPlatform = 'tx');
                          },
                        ),
                        _buildPlatformChip(
                          colors,
                          context.tr('酷我音乐'),
                          'kw',
                          selectedPlatform,
                          () {
                            setState(() => selectedPlatform = 'kw');
                          },
                        ),
                        _buildPlatformChip(
                          colors,
                          context.tr('酷狗音乐'),
                          'kg',
                          selectedPlatform,
                          () {
                            setState(() => selectedPlatform = 'kg');
                          },
                        ),
                        _buildPlatformChip(
                          colors,
                          context.tr('咪咕音乐'),
                          'mg',
                          selectedPlatform,
                          () {
                            setState(() => selectedPlatform = 'mg');
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Text(
                      selectedPlatform == 'kg'
                          ? context.tr('请输入酷狗音乐歌单链接、手机版链接或酷狗码，系统将自动识别格式并导入歌单中的所有歌曲到本地歌单。')
                          : context.tr('请输入${_getPlatformName(selectedPlatform)}歌单链接或歌单ID，系统将自动识别格式并导入歌单中的所有歌曲到本地歌单。'),
                      style: TextStyle(fontSize: 12, color: colors.textHint),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextField(
                      controller: urlController,
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: placeholderText,
                        hintStyle: TextStyle(
                          color: colors.textHint,
                          fontSize: 12,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          borderSide: BorderSide(color: colors.divider),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          borderSide: BorderSide(color: colors.divider),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          borderSide: BorderSide(color: colors.primary),
                        ),
                      ),
                      style: TextStyle(color: colors.textPrimary, fontSize: 13),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        GestureDetector(
                          onTap: () => Navigator.pop(ctx),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Text(
                              context.tr('取消'),
                              style: TextStyle(
                                color: colors.textSecondary,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        TextButton(
                          onPressed: () async {
                            final url = urlController.text.trim();
                            if (url.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    context.tr('请输入有效的歌单链接'),
                                    style: TextStyle(
                                      color: colors.textOnPrimary,
                                    ),
                                  ),
                                  backgroundColor: colors.error,
                                ),
                              );
                              return;
                            }
                            // 先关闭对话框，然后执行导入
                            if (context.mounted) {
                              Navigator.of(ctx).pop();
                              // 等待一帧确保对话框完全关闭
                              await Future.delayed(
                                const Duration(milliseconds: 50),
                              );
                              if (context.mounted) {
                                await _handleNetworkImport(
                                  context,
                                  colors,
                                  ref,
                                  selectedPlatform,
                                  url,
                                );
                              }
                            }
                          },
                          child: Text(
                            context.tr('开始导入'),
                            style: TextStyle(color: colors.primary),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPlatformChip(
    ThemeColors colors,
    String label,
    String value,
    String selected,
    VoidCallback onTap,
  ) {
    final isSelected = value == selected;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? colors.primary : colors.surfaceVariant,
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(
            color: isSelected ? colors.primary : colors.divider,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: isSelected ? colors.textOnPrimary : colors.textSecondary,
          ),
        ),
      ),
    );
  }

  String _getPlatformName(String platform) {
    switch (platform) {
      case 'wy':
        return '网易云音乐';
      case 'tx':
        return 'QQ音乐';
      case 'kw':
        return '酷我音乐';
      case 'kg':
        return '酷狗音乐';
      case 'mg':
        return '咪咕音乐';
      default:
        return '音乐平台';
    }
  }

  Future<void> _handleNetworkImport(
    BuildContext context,
    ThemeColors colors,
    WidgetRef ref,
    String platform,
    String input,
  ) async {
    final playlistId = _parsePlaylistId(platform, input);
    if (playlistId == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr('无法识别的${_getPlatformName(platform)}歌单链接'),
              style: TextStyle(color: colors.textOnPrimary),
            ),
            backgroundColor: colors.error,
          ),
        );
      }
      return;
    }

    if (!context.mounted) return;

    discover_playlist.Playlist? discoverPlaylist;
    String? errorMessage;

    try {
      final manager = ref.read(musicSourceManagerProvider);
      discoverPlaylist = await manager.getPlaylistDetail(
        '${platform}_$playlistId',
        sourceId: platform,
      );
    } catch (e) {
      errorMessage = e.toString();
      print('[导入歌单] 错误: $e');
    }

    if (!context.mounted) return;

    if (errorMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr('导入失败：$errorMessage'),
            style: TextStyle(color: colors.textOnPrimary),
          ),
          backgroundColor: colors.error,
        ),
      );
      return;
    }

    if (discoverPlaylist == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr('获取歌单失败，请检查链接是否正确'),
            style: TextStyle(color: colors.textOnPrimary),
          ),
          backgroundColor: colors.error,
        ),
      );
      return;
    }

    final songs = discoverPlaylist.songs;
    if (songs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr('歌单中没有歌曲'),
            style: TextStyle(color: colors.textOnPrimary),
          ),
          backgroundColor: colors.warning,
        ),
      );
      return;
    }

    final platformName = _getPlatformName(platform);
    final localPlaylist = local_playlist.Playlist(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: '${discoverPlaylist.title} (导入)',
      description: discoverPlaylist.description.isNotEmpty
          ? discoverPlaylist.description
          : '从$platformName导入 - 原歌单：${discoverPlaylist.title}',
      coverImgUrl: discoverPlaylist.coverUrl ?? '',
      source: platform,
      createTime: DateTime.now(),
      updateTime: DateTime.now(),
      songs: songs,
      meta: {'discoverId': '${platform}_$playlistId', 'importSource': platform},
    );

    await ref
        .read(playlistsProvider.notifier)
        .createPlaylistFromModel(localPlaylist);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr('从$platformName导入完成！成功导入 ${songs.length} 首歌曲'),
            style: TextStyle(color: colors.textOnPrimary),
          ),
          backgroundColor: colors.primary,
        ),
      );
    }
  }

  String? _parsePlaylistId(String platform, String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    switch (platform) {
      case 'wy':
        final wyMatch = RegExp(
          r'(?:music\.163\.com\/.*[?&]id=|playlist\?id=|playlist\/|id=)(\d+)',
          caseSensitive: false,
        ).firstMatch(trimmed);
        if (wyMatch != null) return wyMatch.group(1);
        if (RegExp(r'^\d+$').hasMatch(trimmed)) return trimmed;
        return null;

      case 'tx':
        final txRegexes = [
          RegExp(
            r'(?:y\.qq\.com\/n\/ryqq\/playlist\/|music\.qq\.com\/.*[?&]id=|playlist[?&]id=)(\d+)',
            caseSensitive: false,
          ),
          RegExp(
            r'(?:i\.y\.qq\.com\/n2\/m\/share\/details\/taoge\.html.*[?&]id=)(\d+)',
            caseSensitive: false,
          ),
          RegExp(
            r'(?:i\.y\.qq\.com\/v8\/playsquare\/playlist\.html.*[?&]id=)(\d+)',
            caseSensitive: false,
          ),
          RegExp(r'(?:y\.qq\.com.*[?&]disstid=)(\d+)', caseSensitive: false),
          RegExp(r'[?&]id=(\d+)', caseSensitive: false),
          RegExp(r'[?&]disstid=(\d+)', caseSensitive: false),
          RegExp(r'playlist\/(\d+)', caseSensitive: false),
        ];
        for (final regex in txRegexes) {
          final match = regex.firstMatch(trimmed);
          if (match != null) return match.group(1);
        }
        if (RegExp(r'^\d+$').hasMatch(trimmed)) return trimmed;
        return null;

      case 'kw':
        final kwRegexes = [
          RegExp(
            r'(?:kuwo\.cn\/playlist_detail\/|kuwo\.cn\/.*[?&]pid=)(\d+)',
            caseSensitive: false,
          ),
          RegExp(
            r'(?:m\.kuwo\.cn\/h5app\/playlist\/|kuwo\.cn\/.*[?&]id=)(\d+)',
            caseSensitive: false,
          ),
          RegExp(
            r'm\.kuwo\.cn\/newh5app\/playlist_detail\/(\d+)',
            caseSensitive: false,
          ),
          RegExp(r'[?&](?:pid|id)=(\d+)', caseSensitive: false),
        ];
        for (final regex in kwRegexes) {
          final match = regex.firstMatch(trimmed);
          if (match != null) return match.group(1);
        }
        if (RegExp(r'^\d+$').hasMatch(trimmed)) return trimmed;
        return null;

      case 'kg':
        final kgRegexes = [
          RegExp(
            r'kugou\.com\/yy\/special\/single\/(\d+)',
            caseSensitive: false,
          ),
          RegExp(
            r'm\.kugou\.com\/songlist\/gcid_([a-zA-Z0-9]+)',
            caseSensitive: false,
          ),
          RegExp(r'[?&](?:specialid|id)=(\d+)', caseSensitive: false),
        ];
        for (final regex in kgRegexes) {
          final match = regex.firstMatch(trimmed);
          if (match != null) return match.group(1);
        }
        if (RegExp(r'^\d+$').hasMatch(trimmed)) return trimmed;
        return null;

      case 'mg':
        final mgRegexes = [
          RegExp(
            r'(?:music\.migu\.cn\/v3\/music\/playlist\/)(\d+)',
            caseSensitive: false,
          ),
          RegExp(r'(?:music\.migu\.cn\/.*[?&]id=)(\d+)', caseSensitive: false),
          RegExp(r'[?&]id=(\d+)', caseSensitive: false),
        ];
        for (final regex in mgRegexes) {
          final match = regex.firstMatch(trimmed);
          if (match != null) return match.group(1);
        }
        if (RegExp(r'^\d+$').hasMatch(trimmed)) return trimmed;
        return null;

      default:
        if (RegExp(r'^\d+$').hasMatch(trimmed)) return trimmed;
        return null;
    }
  }
}

class _PlaylistAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _PlaylistAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 2),
          Text(label, style: TextStyle(fontSize: 11, color: color)),
        ],
      ),
    );
  }
}
