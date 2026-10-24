import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_routes.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../../shared/widgets/source_badge.dart';
import '../../discover/domain/models/search_collection.dart';
import '../../player/application/playback_context.dart';
import '../../player/application/playback_controller.dart';
import '../../player/domain/models/song.dart';
import '../application/playlist_providers.dart';
import '../application/recently_played_providers.dart';
import '../domain/models/playlist.dart';
import '../domain/models/recently_played.dart';

/// 最近播放：歌曲 / 歌单 / 排行 / 统计。
class RecentlyPlayedPage extends ConsumerStatefulWidget {
  const RecentlyPlayedPage({super.key});

  @override
  ConsumerState<RecentlyPlayedPage> createState() => _RecentlyPlayedPageState();
}

class _RecentlyPlayedPageState extends ConsumerState<RecentlyPlayedPage> {
  int _tab = 0;

  static const _tabs = ['歌曲', '歌单', '排行', '统计'];

  /// 卡片内边距（封面左右各留这么多）。
  static const double _cardPadding = AppSpacing.sm;

  /// 卡片底部内边距（封面下方的文字离卡片下沿的距离）。
  static const double _cardBottomPadding = 6;

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(colors),
            _buildTabRow(colors),
            const SizedBox(height: AppSpacing.sm),
            Expanded(child: _buildBody(colors)),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => context.pop(),
            child: Icon(Icons.arrow_back, size: 24, color: colors.textPrimary),
          ),
          const SizedBox(width: AppSpacing.md),
          Text(
            context.tr('最近播放'),
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: colors.textPrimary,
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: _confirmClear,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: 6,
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.full),
                border: Border.all(color: colors.divider),
              ),
              child: Text(
                context.tr('清除数据'),
                style: TextStyle(fontSize: 12, color: colors.textPrimary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabRow(ThemeColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Row(
        children: [
          for (var i = 0; i < _tabs.length; i++) ...[
            if (i > 0) const SizedBox(width: AppSpacing.sm),
            _TabPill(
              label: context.tr(_tabs[i]),
              selected: _tab == i,
              colors: colors,
              onTap: () => _selectTab(i),
            ),
          ],
        ],
      ),
    );
  }

  void _selectTab(int index) {
    if (_tab == index) return;
    setState(() => _tab = index);
    if (index == 3) {
      // 刚听完歌就切到统计：播放事件可能还在内存待写队列里，
      // 重新读一次，保证看到的是最新数据。
      ref.invalidate(playbackStatsProvider);
    }
  }

  Widget _buildBody(ThemeColors colors) {
    switch (_tab) {
      case 0:
        return _buildSongsTab(colors);
      case 1:
        return _buildPlaylistsTab(colors);
      case 2:
        return _buildRankTab(colors);
      default:
        return _buildStatsTab(colors);
    }
  }

  // ---------------------------------------------------------------- 歌曲

  Widget _buildSongsTab(ThemeColors colors) {
    final async = ref.watch(recentlyPlayedProvider);
    return async.when(
      data: (items) {
        if (items.isEmpty) {
          return _EmptyState(
            icon: Icons.history,
            title: context.tr('暂无播放记录'),
            subtitle: context.tr('播放歌曲后将自动记录'),
            colors: colors,
          );
        }
        final queue = items.map((e) => e.song).toList(growable: false);
        return _CardGrid(
          columns: _gridColumns(context),
          itemCount: items.length,
          extraHeight: _songExtraHeight(context),
          itemBuilder: (context, index) =>
              _SongCard(item: items[index], queue: queue, index: index),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => _EmptyState(
        icon: Icons.error_outline,
        title: context.tr('加载失败'),
        colors: colors,
      ),
    );
  }

  /// 网格列数：Android 固定 3 列，其它平台至少 3 列，宽窗口按 300px 递增。
  ///
  /// 横屏 / 窗口被拉窄时不能再掉到 2 列：宁可把卡片（封面）缩小，也要保证
  /// 一屏至少排得下 3 列，宽度够大时自动涨到 4 列及以上。
  int _gridColumns(BuildContext context) {
    if (Platform.isAndroid) return 3;
    final width = MediaQuery.sizeOf(context).width;
    return math.max(3, (width / 300).ceil());
  }

  /// 歌曲卡片封面之外的高度（标题 + 歌手 + 间距 + 上下内边距）。
  ///
  /// 以前用「基准值 + 固定行高 × 缩放」估，估大了就会在歌手名下面留一条
  /// 空白（卡片底部那块多余间距）。这里直接按当前字体 / 字号缩放量一遍，
  /// 卡片高度刚好贴住文字，紧凑且不会溢出。
  double _songExtraHeight(BuildContext context) {
    final titleH = _lineHeight(
      context,
      const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
    );
    final artistH = _lineHeight(context, const TextStyle(fontSize: 12));
    // 上内边距 + 封面与标题间距 + 标题 + 标题与歌手间距 + 歌手 + 下内边距
    return _cardPadding + 6 + titleH + 2 + artistH + _cardBottomPadding;
  }

  /// 单行文本在当前主题字体 / 系统字号缩放下的实际高度。
  double _lineHeight(BuildContext context, TextStyle style) {
    final base = Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    final painter = TextPainter(
      text: TextSpan(text: '国', style: base.merge(style)),
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final height = painter.height;
    painter.dispose();
    return height;
  }

  // ---------------------------------------------------------------- 歌单

  Widget _buildPlaylistsTab(ThemeColors colors) {
    final async = ref.watch(recentlyPlayedPlaylistsProvider);
    return async.when(
      data: (playlists) {
        if (playlists.isEmpty) {
          return _EmptyState(
            icon: Icons.queue_music,
            title: context.tr('暂无打开过的歌单'),
            subtitle: context.tr('打开歌单后会记录在这里'),
            colors: colors,
          );
        }
        return _CardGrid(
          columns: _gridColumns(context),
          itemCount: playlists.length,
          extraHeight: _playlistExtraHeight(context),
          itemBuilder: (context, index) =>
              _PlaylistCard(playlist: playlists[index]),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => _EmptyState(
        icon: Icons.error_outline,
        title: context.tr('加载失败'),
        colors: colors,
      ),
    );
  }

  /// 歌单卡片封面之外的高度（两行名称 + 间距 + 上下内边距）。
  double _playlistExtraHeight(BuildContext context) {
    final nameH = _lineHeight(
      context,
      const TextStyle(fontSize: 14, height: 1.25, fontWeight: FontWeight.w500),
    );
    // 上内边距 + 封面与名称间距 + 两行名称 + 下内边距
    return _cardPadding + 6 + nameH * 2 + _cardBottomPadding;
  }

  // ---------------------------------------------------------------- 排行

  Widget _buildRankTab(ThemeColors colors) {
    final async = ref.watch(recentlyPlayedProvider);
    return async.when(
      data: (items) {
        final ranked = List<RecentlyPlayedItem>.of(items)
          ..sort((a, b) => b.playCount.compareTo(a.playCount));
        final top = ranked.take(100).toList(growable: false);
        if (top.isEmpty) {
          return _EmptyState(
            icon: Icons.bar_chart,
            title: context.tr('暂无播放统计'),
            colors: colors,
          );
        }
        final maxCount = top.first.playCount;
        final queue = top.map((e) => e.song).toList(growable: false);
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.xxxl,
          ),
          itemCount: top.length,
          itemBuilder: (context, index) => _RankRow(
            item: top[index],
            rank: index + 1,
            maxCount: maxCount,
            queue: queue,
            index: index,
          ),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => _EmptyState(
        icon: Icons.error_outline,
        title: context.tr('加载失败'),
        colors: colors,
      ),
    );
  }

  // ---------------------------------------------------------------- 统计

  Widget _buildStatsTab(ThemeColors colors) {
    final granularity = ref.watch(playbackStatsGranularityProvider);
    final async = ref.watch(playbackStatsProvider(granularity));

    return async.when(
      data: (stats) => ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.sm,
          AppSpacing.lg,
          AppSpacing.xxxl,
        ),
        children: [
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  icon: Icons.timer_outlined,
                  label: context.tr('总时长'),
                  value: _formatDuration(stats.totalListenedMs),
                  colors: colors,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: _StatCard(
                  icon: Icons.music_note,
                  label: context.tr('听过的歌'),
                  value: context.tr('${stats.songCount} 首'),
                  colors: colors,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: _StatCard(
                  icon: Icons.play_circle_outline,
                  label: context.tr('播放次数'),
                  value: context.tr('${stats.totalPlays} 次'),
                  colors: colors,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Container(
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: colors.divider.withValues(alpha: 0.5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      context.tr('听歌时长'),
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                    const Spacer(),
                    for (final g in PlaybackStatsGranularity.values) ...[
                      _TabPill(
                        label: context.tr(g.label),
                        selected: g == granularity,
                        colors: colors,
                        dense: true,
                        onTap: () =>
                            ref
                                    .read(
                                      playbackStatsGranularityProvider.notifier,
                                    )
                                    .state =
                                g,
                      ),
                      if (g != PlaybackStatsGranularity.values.last)
                        const SizedBox(width: 6),
                    ],
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                SizedBox(
                  height: 220,
                  child: _StatsBarChart(buckets: stats.buckets, colors: colors),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            context.tr('统计来自本地播放记录，数据只保存在本机'),
            style: TextStyle(fontSize: 11, color: colors.textHint),
          ),
        ],
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => _EmptyState(
        icon: Icons.error_outline,
        title: context.tr('加载失败'),
        colors: colors,
      ),
    );
  }

  // ---------------------------------------------------------------- 清空

  Future<void> _confirmClear() async {
    final colors = ref.read(themeColorsProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(
          context.tr('清除最近播放'),
          style: TextStyle(color: colors.textPrimary),
        ),
        content: Text(
          context.tr('将删除播放记录、最近打开的歌单与听歌统计，无法恢复。'),
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
              context.tr('清除'),
              style: TextStyle(color: colors.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(recentlyPlayedProvider.notifier).clearAll();
  }
}

// ---------------------------------------------------------------- 组件

/// 等宽卡片网格：卡片高度 = 正方形封面 + [extraHeight]，避免字体缩放时溢出。
class _CardGrid extends StatelessWidget {
  const _CardGrid({
    required this.columns,
    required this.itemCount,
    required this.extraHeight,
    required this.itemBuilder,
  });

  final int columns;
  final int itemCount;

  /// 封面下方还需要的高度（标题 / 歌手 / 两行歌单名 + 内边距）。
  final double extraHeight;

  final Widget Function(BuildContext context, int index) itemBuilder;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = AppSpacing.md;
        final available =
            constraints.maxWidth - AppSpacing.lg * 2 - spacing * (columns - 1);
        final itemWidth = math.max(96.0, available / columns);
        final coverSize = math.max(
          80.0,
          itemWidth - _RecentlyPlayedPageState._cardPadding * 2,
        );
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.xxxl,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            mainAxisExtent: coverSize + extraHeight,
          ),
          itemCount: itemCount,
          itemBuilder: itemBuilder,
        );
      },
    );
  }
}

class _TabPill extends StatelessWidget {
  const _TabPill({
    required this.label,
    required this.selected,
    required this.colors,
    required this.onTap,
    this.dense = false,
  });

  final String label;
  final bool selected;
  final ThemeColors colors;
  final VoidCallback onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: EdgeInsets.symmetric(
          horizontal: dense ? AppSpacing.md : AppSpacing.lg,
          vertical: dense ? 4 : 7,
        ),
        decoration: BoxDecoration(
          color: selected ? colors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(color: selected ? colors.primary : colors.divider),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: dense ? 12 : 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            color: selected ? colors.textOnPrimary : colors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.colors,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final ThemeColors colors;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: colors.textHint.withValues(alpha: 0.3)),
          const SizedBox(height: AppSpacing.md),
          Text(title, style: TextStyle(fontSize: 15, color: colors.textHint)),
          if (subtitle != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              subtitle!,
              style: TextStyle(
                fontSize: 12,
                color: colors.textHint.withValues(alpha: 0.7),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 歌曲网格卡片：正方形封面 + 右上角来源标签 + 封面下方的歌名 / 歌手。
class _SongCard extends ConsumerWidget {
  const _SongCard({
    required this.item,
    required this.queue,
    required this.index,
  });

  final RecentlyPlayedItem item;
  final List<Song> queue;
  final int index;

  bool get _sourceClickable => switch (item.sourceType) {
    PlaybackSourceType.playlist ||
    PlaybackSourceType.rank ||
    PlaybackSourceType.album ||
    PlaybackSourceType.artist => true,
    _ => false,
  };

  void _play(WidgetRef ref) {
    // 从最近播放里再播一次，仍然沿用这首歌原来的来源。
    PlaybackContext.instance.set(
      item.sourceType,
      id: item.sourceId,
      name: item.sourceName,
      sourceMeta: item.sourceMeta,
    );
    ref
        .read(playbackControllerProvider.notifier)
        .setQueue(queue, startIndex: index);
  }

  Future<void> _openSource(BuildContext context, WidgetRef ref) async {
    final id = item.sourceId;
    if (id == null || id.isEmpty) return;
    switch (item.sourceType) {
      case PlaybackSourceType.playlist:
        // 本地歌单（含「我的收藏」）和远端歌单是不同的路由。
        var local = false;
        try {
          final playlists = await ref.read(playlistsProvider.future);
          local = playlists.any((p) => p.id == id);
        } catch (_) {
          // 本地歌单读取失败就按远端歌单打开。
        }
        if (!context.mounted) return;
        context.push(
          local
              ? '/library/playlist/${Uri.encodeComponent(id)}'
              : '/playlist/${Uri.encodeComponent(id)}',
        );
      case PlaybackSourceType.rank:
        context.push('/playlist/${Uri.encodeComponent(id)}?type=rank');
      case PlaybackSourceType.album:
        context.push(
          AppRoutes.collectionDetail,
          extra: _collectionOf(CollectionType.album),
        );
      case PlaybackSourceType.artist:
        context.push(
          AppRoutes.collectionDetail,
          extra: _collectionOf(CollectionType.artist),
        );
      case PlaybackSourceType.search:
      case PlaybackSourceType.local:
      case PlaybackSourceType.unknown:
        break;
    }
  }

  /// 打开专辑 / 作者主页用的信息。
  ///
  /// 新版记录里存了完整主页信息（[RecentlyPlayedItem.sourceMeta]）；
  /// 老记录没有，只能根据歌曲字段拼一个。
  SearchCollection _collectionOf(CollectionType type) {
    final meta = item.sourceMeta;
    if (meta != null) return SearchCollection.fromJson(meta, type: type);

    final song = item.song;
    final isArtist = type == CollectionType.artist;
    final id = item.sourceId ?? '';
    final title = item.sourceName ?? (isArtist ? song.artist : song.album);
    return SearchCollection(
      id: id,
      title: title,
      type: type,
      source: song.source ?? '',
      coverUrl: song.coverUrl,
      artist: isArtist ? null : song.artist,
      raw: {
        'id': id,
        'name': title,
        if (isArtist) 'avatar': song.coverUrl ?? '',
        if (!isArtist) 'artist': song.artist,
        if (!isArtist) 'picUrl': song.coverUrl ?? '',
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(themeColorsProvider);
    final song = item.song;

    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(AppRadius.md),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _play(ref),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            _RecentlyPlayedPageState._cardPadding,
            _RecentlyPlayedPageState._cardPadding,
            _RecentlyPlayedPageState._cardPadding,
            _RecentlyPlayedPageState._cardBottomPadding,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        child: MusicCoverImage(
                          url: song.coverUrl,
                          songId: song.id,
                          mediaStoreId: song.mediaStoreId,
                          fit: BoxFit.cover,
                          errorWidget: Container(
                            color: colors.surfaceVariant,
                            child: Icon(
                              Icons.music_note,
                              color: colors.textHint,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (item.hasSourceLabel)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: SourceBadge(
                          type: item.sourceType,
                          colors: colors,
                          onTap: _sourceClickable
                              ? () => _openSource(context, ref)
                              : null,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                song.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: colors.textHint),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 歌单网格卡片：封面 + 右上角歌曲数量 + 两行歌单名。
class _PlaylistCard extends ConsumerWidget {
  const _PlaylistCard({required this.playlist});

  final RecentlyPlayedPlaylist playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(themeColorsProvider);

    Playlist? localPlaylist;
    final localPlaylists = ref.watch(playlistsProvider).valueOrNull;
    if (localPlaylists != null) {
      for (final p in localPlaylists) {
        if (p.id == playlist.id) {
          localPlaylist = p;
          break;
        }
      }
    }
    final isLocal = localPlaylist != null || playlist.source == 'local';
    final favoriteType = playlist.favoriteType;

    var coverUrl = playlist.coverUrl;
    Song? coverSong;
    if (coverUrl.isEmpty && localPlaylist != null) {
      coverUrl = localPlaylist.coverImgUrl;
      if (coverUrl.isEmpty && localPlaylist.songs.isNotEmpty) {
        coverSong = localPlaylist.songs.first;
      }
    }

    final route = isLocal
        ? '/library/playlist/${Uri.encodeComponent(playlist.id)}'
        : '/playlist/${Uri.encodeComponent(playlist.id)}';

    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(AppRadius.md),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push(route),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            _RecentlyPlayedPageState._cardPadding,
            _RecentlyPlayedPageState._cardPadding,
            _RecentlyPlayedPageState._cardPadding,
            _RecentlyPlayedPageState._cardBottomPadding,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        child: MusicCoverImage(
                          url: coverUrl.isNotEmpty
                              ? coverUrl
                              : coverSong?.coverUrl,
                          songId: coverSong?.id,
                          mediaStoreId: coverSong?.mediaStoreId,
                          fit: BoxFit.cover,
                          useDiscoveryCache: true,
                          errorWidget: Container(
                            color: colors.surfaceVariant,
                            child: Icon(
                              Icons.queue_music,
                              color: colors.textHint,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (favoriteType != null || playlist.songCount > 0)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            if (favoriteType != null)
                              SourceBadge(type: favoriteType, colors: colors),
                            if (favoriteType != null && playlist.songCount > 0)
                              const SizedBox(height: 4),
                            if (playlist.songCount > 0)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  context.tr('${playlist.songCount}首'),
                                  style: const TextStyle(
                                    fontSize: 11,
                                    height: 1.1,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                playlist.displayName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.25,
                  fontWeight: FontWeight.w500,
                  color: colors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 排行列表项：名次 + 封面 + 按播放次数伸缩的柱形（歌名 / 歌手叠在柱形上）+ 次数。
class _RankRow extends ConsumerStatefulWidget {
  const _RankRow({
    required this.item,
    required this.rank,
    required this.maxCount,
    required this.queue,
    required this.index,
  });

  final RecentlyPlayedItem item;
  final int rank;
  final int maxCount;
  final List<Song> queue;
  final int index;

  @override
  ConsumerState<_RankRow> createState() => _RankRowState();
}

class _RankRowState extends ConsumerState<_RankRow> {
  bool _hovered = false;

  void _play() {
    PlaybackContext.instance.set(
      widget.item.sourceType,
      id: widget.item.sourceId,
      name: widget.item.sourceName,
      sourceMeta: widget.item.sourceMeta,
    );
    ref
        .read(playbackControllerProvider.notifier)
        .setQueue(widget.queue, startIndex: widget.index);
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final item = widget.item;
    final song = item.song;
    final scale = MediaQuery.textScalerOf(context).scale(1);

    final rowHeight = math.max(52.0, 36 * scale + 16);
    final ratio = widget.maxCount > 0
        ? (item.playCount / widget.maxCount).clamp(0.0, 1.0)
        : 0.0;
    final isDark =
        ThemeData.estimateBrightnessForColor(colors.background) ==
        Brightness.dark;
    // 柱形颜色：深色主题比背景浅一点，浅色主题比背景深一点。
    final barColor = isDark
        ? Color.alphaBlend(
            Colors.white.withValues(alpha: 0.07),
            colors.background,
          )
        : Color.alphaBlend(
            Colors.black.withValues(alpha: 0.06),
            colors.background,
          );
    final hoverColor = isDark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.black.withValues(alpha: 0.04);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _play,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: _hovered ? hoverColor : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 30,
                child: Text(
                  '${widget.rank}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: widget.rank <= 3 ? colors.primary : colors.textHint,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                child: MusicCoverImage(
                  url: song.coverUrl,
                  songId: song.id,
                  mediaStoreId: song.mediaStoreId,
                  width: 48,
                  height: 48,
                  fit: BoxFit.cover,
                  errorWidget: Container(
                    width: 48,
                    height: 48,
                    color: colors.surfaceVariant,
                    child: Icon(
                      Icons.music_note,
                      size: 20,
                      color: colors.textHint,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final barWidth = math.max(
                      56.0,
                      constraints.maxWidth * ratio,
                    );
                    return SizedBox(
                      height: rowHeight,
                      child: Stack(
                        alignment: Alignment.centerLeft,
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 140),
                            width: barWidth,
                            height: rowHeight,
                            decoration: BoxDecoration(
                              color: _hovered
                                  ? Color.alphaBlend(hoverColor, barColor)
                                  : barColor,
                              borderRadius: BorderRadius.circular(AppRadius.xs),
                            ),
                          ),
                          Positioned.fill(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    song.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: colors.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    song.artist,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: colors.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              SizedBox(
                width: 56,
                child: Text(
                  context.tr('${item.playCount} 次'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 12, color: colors.textSecondary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.colors,
  });

  final IconData icon;
  final String label;
  final String value;
  final ThemeColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: colors.divider.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: colors.primary),
          const SizedBox(height: AppSpacing.sm),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 11, color: colors.textHint)),
        ],
      ),
    );
  }
}

/// 听歌时长柱状图（自定义绘制，带渐变与数值标签）。
class _StatsBarChart extends StatelessWidget {
  const _StatsBarChart({required this.buckets, required this.colors});

  final List<PlaybackStatBucket> buckets;
  final ThemeColors colors;

  @override
  Widget build(BuildContext context) {
    if (buckets.isEmpty) {
      return Center(
        child: Text(
          context.tr('暂无数据'),
          style: TextStyle(fontSize: 13, color: colors.textHint),
        ),
      );
    }
    return CustomPaint(
      painter: _StatsBarPainter(
        buckets: buckets,
        primary: colors.primary,
        labelColor: colors.textHint,
        gridColor: colors.divider.withValues(alpha: 0.5),
      ),
      size: Size.infinite,
    );
  }
}

class _StatsBarPainter extends CustomPainter {
  _StatsBarPainter({
    required this.buckets,
    required this.primary,
    required this.labelColor,
    required this.gridColor,
  });

  final List<PlaybackStatBucket> buckets;
  final Color primary;
  final Color labelColor;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    const labelHeight = 20.0;
    const valueHeight = 14.0;
    final chartHeight = math.max(10.0, size.height - labelHeight - valueHeight);
    final maxValue = buckets.fold<int>(
      1,
      (prev, b) => math.max(prev, b.listenedMs),
    );
    final slot = size.width / buckets.length;
    final barWidth = math.min(slot * 0.5, 36.0);

    // 背景网格线
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = valueHeight + chartHeight * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    for (var i = 0; i < buckets.length; i++) {
      final bucket = buckets[i];
      final ratio = bucket.listenedMs / maxValue;
      final barHeight = chartHeight * ratio;
      final left = slot * i + (slot - barWidth) / 2;
      final top = valueHeight + chartHeight - barHeight;

      if (barHeight > 0.5) {
        final rect = Rect.fromLTWH(left, top, barWidth, barHeight);
        final rrect = RRect.fromRectAndCorners(
          rect,
          topLeft: const Radius.circular(6),
          topRight: const Radius.circular(6),
        );
        final paint = Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [primary, primary.withValues(alpha: 0.25)],
          ).createShader(rect);
        canvas.drawRRect(rrect, paint);

        // 柱顶数值
        _drawText(
          canvas,
          _formatDuration(bucket.listenedMs),
          Offset(left + barWidth / 2, top - valueHeight + 1),
          maxWidth: slot,
          color: primary,
          fontSize: 10,
          bold: true,
        );
      }

      // 横轴标签
      _drawText(
        canvas,
        bucket.label,
        Offset(left + barWidth / 2, size.height - labelHeight + 3),
        maxWidth: slot,
        color: labelColor,
        fontSize: 10,
      );
    }
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset center, {
    required double maxWidth,
    required Color color,
    required double fontSize,
    bool bold = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          color: color,
          fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: math.max(10, maxWidth));
    painter.paint(canvas, Offset(center.dx - painter.width / 2, center.dy));
  }

  @override
  bool shouldRepaint(covariant _StatsBarPainter oldDelegate) {
    return oldDelegate.buckets != buckets || oldDelegate.primary != primary;
  }
}

String _formatDuration(int ms) {
  if (ms <= 0) return '0';
  final totalMinutes = ms ~/ 60000;
  if (totalMinutes < 1) return '${ms ~/ 1000}秒';
  final hours = totalMinutes ~/ 60;
  final minutes = totalMinutes % 60;
  if (hours <= 0) return '$minutes分';
  if (minutes == 0) return '$hours小时';
  return '$hours小时$minutes分';
}
