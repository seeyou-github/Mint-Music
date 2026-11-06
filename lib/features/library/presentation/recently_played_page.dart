import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../shared/pagination/page_slicer.dart';
import '../../../shared/widgets/page_bar.dart';
import '../../../shared/widgets/song_action_sheet.dart';
import '../../../shared/widgets/song_list_item.dart';
import '../../player/application/playback_context.dart';
import '../../player/application/playback_controller.dart';
import '../application/recently_played_providers.dart';

/// 最近播放：只列歌曲，按最近播放时间倒序（只保留最近一个月）。
///
/// 分类栏（歌单 / 排行 / 统计）已移除：最近播放只用来把听过的歌再播一遍，
/// 来源、次数、时长这些数据都不再记录，列表样式与歌单详情页的歌曲列表一致。
class RecentlyPlayedPage extends ConsumerStatefulWidget {
  const RecentlyPlayedPage({super.key});

  @override
  ConsumerState<RecentlyPlayedPage> createState() => _RecentlyPlayedPageState();
}

class _RecentlyPlayedPageState extends ConsumerState<RecentlyPlayedPage> {
  /// 每页多少首（与歌单详情页一致）。
  static const int _pageSize = 50;

  final PageSlicer _pager = PageSlicer(pageSize: _pageSize);
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

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
          // Android 靠系统返回手势 / 返回键，顶部不放返回箭头。
          if (!Platform.isAndroid) ...[
            GestureDetector(
              onTap: () => context.pop(),
              child: Icon(
                Icons.arrow_back,
                size: 24,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
          ],
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

  Widget _buildBody(ThemeColors colors) {
    final async = ref.watch(recentlyPlayedProvider);
    final currentSongId = ref.watch(
      playbackControllerProvider.select((state) => state.currentSong?.id),
    );
    return async.when(
      data: (items) {
        if (items.isEmpty) {
          return _EmptyState(
            icon: Icons.history,
            title: context.tr('暂无播放记录'),
            subtitle: context.tr('播放歌曲后将自动记录，只保留最近一个月'),
            colors: colors,
          );
        }
        final songs = items.map((item) => item.song).toList(growable: false);
        // 只渲染当前页（每页 50 首）；播放队列仍用完整列表。
        _pager.clampTo(songs.length, hasMore: false);
        final visible = _pager.slice(songs);
        return CustomScrollView(
          controller: _scrollController,
          slivers: [
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final song = visible[index];
                  // 序号按全局位置编号（第 2 页仍是 51~100）。
                  final displayIndex = _pager.absoluteStart + index;
                  // 播放队列用缓冲区内的下标，跳页后才不会越界。
                  final bufferIndex = _pager.start + index;
                  return SongListItem(
                    song: song,
                    index: displayIndex,
                    maxIndex: songs.length,
                    isPlaying:
                        currentSongId != null && currentSongId == song.id,
                    showPlayedTag: true,
                    onPlayTap: () async {
                      // 最近播放不记来源：播放上下文按「无来源」处理。
                      PlaybackContext.instance.clear();
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
                },
                childCount: visible.length,
                addAutomaticKeepAlives: false,
                addRepaintBoundaries: true,
              ),
            ),
            // 分页条：内容不满一屏时贴到底部，满一屏时跟在列表后面。
            PageBarFooterSliver(
              child: PageBar(
                docked: true,
                currentPage: _pager.page,
                pageCount: _pager.pageCount(songs.length, hasMore: false),
                onChanged: _goToPage,
              ),
            ),
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => _EmptyState(
        icon: Icons.error_outline,
        title: context.tr('加载失败'),
        colors: colors,
      ),
    );
  }

  /// 翻页后回到列表顶部（与歌单详情页一致）。
  void _goToPage(int page) {
    if (page == _pager.page) return;
    setState(() => _pager.jumpTo(page));
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

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
          context.tr('将删除最近一个月的播放记录与已听进度，无法恢复。'),
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

/// 空状态 / 加载失败的占位。
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
