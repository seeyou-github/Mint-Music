import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../application/recently_played_providers.dart';
import '../domain/models/recently_played.dart';
import '../../player/application/playback_context.dart';
import '../../player/application/playback_controller.dart';
import '../../player/domain/models/song.dart';

/// 最近播放：歌曲 / 歌单 / 排行 / 统计。
class RecentlyPlayedPage extends ConsumerStatefulWidget {
  const RecentlyPlayedPage({super.key});

  @override
  ConsumerState<RecentlyPlayedPage> createState() => _RecentlyPlayedPageState();
}

class _RecentlyPlayedPageState extends ConsumerState<RecentlyPlayedPage> {
  int _tab = 0;

  static const _tabs = ['歌曲', '歌单', '排行', '统计'];

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
              onTap: () => setState(() => _tab = i),
            ),
          ],
        ],
      ),
    );
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
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.xxxl,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _gridColumns(context),
            mainAxisSpacing: AppSpacing.md,
            crossAxisSpacing: AppSpacing.md,
            mainAxisExtent: 150,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) => _SongCard(
            item: items[index],
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

  /// 网格列数：Android 固定 3 列，其它平台按窗口宽度自适应。
  int _gridColumns(BuildContext context) {
    if (Platform.isAndroid) return 3;
    final width = MediaQuery.sizeOf(context).width;
    return math.max(2, (width / 300).ceil());
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
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.xxxl,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _gridColumns(context),
            mainAxisSpacing: AppSpacing.md,
            crossAxisSpacing: AppSpacing.md,
            mainAxisExtent: 220,
          ),
          itemCount: playlists.length,
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
                        onTap: () => ref
                            .read(playbackStatsGranularityProvider.notifier)
                            .state = g,
                      ),
                      if (g != PlaybackStatsGranularity.values.last)
                        const SizedBox(width: 6),
                    ],
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                SizedBox(
                  height: 220,
                  child: _StatsBarChart(
                    buckets: stats.buckets,
                    colors: colors,
                  ),
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
          border: Border.all(
            color: selected ? colors.primary : colors.divider,
          ),
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

/// 来源标签（歌单 / 榜单 / 专辑 / 搜索）。
class _SourceBadge extends StatelessWidget {
  const _SourceBadge({
    required this.type,
    required this.colors,
    this.onTap,
    this.dense = false,
  });

  final PlaybackSourceType type;
  final ThemeColors colors;
  final VoidCallback? onTap;
  final bool dense;

  Color get _color => switch (type) {
    PlaybackSourceType.playlist => const Color(0xFFE0913C),
    PlaybackSourceType.rank => const Color(0xFFE05B5B),
    PlaybackSourceType.album => const Color(0xFFD9B44A),
    PlaybackSourceType.local => colors.primary,
    _ => colors.textHint,
  };

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: dense ? 6 : 10,
          vertical: dense ? 2 : 4,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: _color.withValues(alpha: 0.7)),
          color: _color.withValues(alpha: 0.08),
        ),
        child: Text(
          context.tr(type.label),
          style: TextStyle(
            fontSize: dense ? 10 : 12,
            fontWeight: FontWeight.w500,
            color: _color,
          ),
        ),
      ),
    );
  }
}

/// 歌曲网格卡片：封面 + 来源标签 + 歌名 + 歌手。
class _SongCard extends ConsumerWidget {
  const _SongCard({
    required this.item,
    required this.queue,
    required this.index,
  });

  final RecentlyPlayedItem item;
  final List<Song> queue;
  final int index;

  void _play(WidgetRef ref) {
    // 从最近播放里再播一次，仍然沿用这首歌原来的来源。
    PlaybackContext.instance.set(
      item.sourceType,
      id: item.sourceId,
      name: item.sourceName,
    );
    ref
        .read(playbackControllerProvider.notifier)
        .setQueue(queue, startIndex: index);
  }

  void _openSource(BuildContext context) {
    final id = item.sourceId;
    if (id == null || id.isEmpty) return;
    switch (item.sourceType) {
      case PlaybackSourceType.playlist:
        context.push('/playlist/${Uri.encodeComponent(id)}');
      case PlaybackSourceType.rank:
        context.push('/playlist/${Uri.encodeComponent(id)}?type=rank');
      case PlaybackSourceType.album:
      case PlaybackSourceType.search:
      case PlaybackSourceType.local:
      case PlaybackSourceType.unknown:
        // 暂无专辑详情页，其余来源没有可跳转的页面。
        break;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(themeColorsProvider);
    final song = item.song;

    final coverImage = MusicCoverImage(
      url: song.coverUrl,
      songId: song.id,
      mediaStoreId: song.mediaStoreId,
      fit: BoxFit.cover,
      errorWidget: Container(
        color: colors.surfaceVariant,
        child: Icon(Icons.music_note, color: colors.textHint),
      ),
    );

    final title = Text(
      song.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: colors.textPrimary,
      ),
    );
    final artist = Text(
      song.artist,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 12, color: colors.textHint),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // 宽卡片：封面在左、来源标签在右（与截图一致）；
        // 窄卡片（Android 三列）：封面铺满、标签浮在右上角。
        final wide = constraints.maxWidth >= 170;
        return Material(
          color: colors.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _play(ref),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: wide
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(
                                AppRadius.sm,
                              ),
                              child: SizedBox(
                                width: 76,
                                height: 76,
                                child: coverImage,
                              ),
                            ),
                            const Spacer(),
                            if (item.hasSourceLabel)
                              _SourceBadge(
                                type: item.sourceType,
                                colors: colors,
                                onTap: () => _openSource(context),
                              ),
                          ],
                        ),
                        const Spacer(),
                        title,
                        const SizedBox(height: 2),
                        artist,
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(
                                    AppRadius.sm,
                                  ),
                                  child: coverImage,
                                ),
                              ),
                              if (item.hasSourceLabel)
                                Positioned(
                                  top: 4,
                                  right: 4,
                                  child: _SourceBadge(
                                    type: item.sourceType,
                                    colors: colors,
                                    dense: true,
                                    onTap: () => _openSource(context),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        title,
                        artist,
                      ],
                    ),
            ),
          ),
        );
      },
    );
  }
}

/// 歌单网格卡片。
class _PlaylistCard extends ConsumerWidget {
  const _PlaylistCard({required this.playlist});

  final RecentlyPlayedPlaylist playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(themeColorsProvider);
    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(AppRadius.md),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () =>
            context.push('/playlist/${Uri.encodeComponent(playlist.id)}'),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        child: MusicCoverImage(
                          url: playlist.coverUrl,
                          fit: BoxFit.cover,
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
                    if (playlist.songCount > 0)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                          ),
                          child: Text(
                            context.tr('${playlist.songCount}首'),
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                playlist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                context.tr('${playlist.songCount} 首歌曲'),
                maxLines: 1,
                style: TextStyle(fontSize: 11, color: colors.textHint),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 排行列表项：名次 + 封面 + 歌名/歌手 + 播放次数柱形。
class _RankRow extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(themeColorsProvider);
    final song = item.song;
    final ratio = maxCount > 0 ? item.playCount / maxCount : 0.0;

    return InkWell(
      onTap: () {
        PlaybackContext.instance.set(
          item.sourceType,
          id: item.sourceId,
          name: item.sourceName,
        );
        ref
            .read(playbackControllerProvider.notifier)
            .setQueue(queue, startIndex: index);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text(
                '$rank',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: rank <= 3 ? colors.primary : colors.textHint,
                ),
              ),
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: MusicCoverImage(
                url: song.coverUrl,
                songId: song.id,
                mediaStoreId: song.mediaStoreId,
                width: 44,
                height: 44,
                fit: BoxFit.cover,
                errorWidget: Container(
                  width: 44,
                  height: 44,
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: colors.textPrimary),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: Stack(
                            children: [
                              Container(
                                height: 6,
                                color: colors.surfaceVariant,
                              ),
                              FractionallySizedBox(
                                widthFactor: ratio.clamp(0.02, 1.0),
                                child: Container(
                                  height: 6,
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      colors: [
                                        colors.primary,
                                        colors.primary.withValues(alpha: 0.45),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        context.tr('${item.playCount} 次'),
                        style: TextStyle(fontSize: 11, color: colors.textHint),
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
