import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/recently_played_repository.dart';
import '../domain/models/recently_played.dart';
import '../../player/application/play_progress_providers.dart';
import '../../player/domain/models/song.dart';

final recentlyPlayedRepositoryProvider = Provider<RecentlyPlayedRepository>((
  ref,
) {
  return RecentlyPlayedRepository();
});

/// 最近播放的歌曲（按最近播放时间倒序）。
final recentlyPlayedProvider =
    AsyncNotifierProvider<RecentlyPlayedNotifier, List<RecentlyPlayedItem>>(
      RecentlyPlayedNotifier.new,
    );

class RecentlyPlayedNotifier extends AsyncNotifier<List<RecentlyPlayedItem>> {
  @override
  Future<List<RecentlyPlayedItem>> build() async {
    return ref.read(recentlyPlayedRepositoryProvider).loadHistory();
  }

  Future<void> recordPlay(
    Song song, {
    PlaybackSourceType sourceType = PlaybackSourceType.unknown,
    String? sourceId,
    String? sourceName,
    Map<String, dynamic>? sourceMeta,
  }) async {
    await ref
        .read(recentlyPlayedRepositoryProvider)
        .recordPlay(
          song,
          sourceType: sourceType,
          sourceId: sourceId,
          sourceName: sourceName,
          sourceMeta: sourceMeta,
        );
    ref.invalidateSelf();
    // 排行 / 统计按播放次数与时长的累计值展示，播放一次就要重新读。
    ref.invalidate(playRankingProvider);
  }

  Future<void> clearAll() async {
    await ref.read(recentlyPlayedRepositoryProvider).clearAll();
    // 「已听 N%」进度也在重要库，跟统计一起清（用户的「清除」= 把这些数据
    // 全部抹掉，而不是只清一半）。
    await ref.read(playedProgressProvider.notifier).clearAll();
    ref.invalidateSelf();
    ref.invalidate(recentlyPlayedPlaylistsProvider);
    ref.invalidate(playbackStatsProvider);
    ref.invalidate(playRankingProvider);
  }

  Future<void> removeFromHistory(String songId) async {
    await ref.read(recentlyPlayedRepositoryProvider).removeFromHistory(songId);
    ref.invalidateSelf();
  }
}

/// 打开过的歌单（最近打开在前）。
final recentlyPlayedPlaylistsProvider =
    AsyncNotifierProvider<
      RecentlyPlayedPlaylistsNotifier,
      List<RecentlyPlayedPlaylist>
    >(RecentlyPlayedPlaylistsNotifier.new);

class RecentlyPlayedPlaylistsNotifier
    extends AsyncNotifier<List<RecentlyPlayedPlaylist>> {
  @override
  Future<List<RecentlyPlayedPlaylist>> build() async {
    return ref.read(recentlyPlayedRepositoryProvider).loadPlaylists();
  }

  Future<void> recordOpened({
    required String id,
    required String name,
    String coverUrl = '',
    int songCount = 0,
    String source = '',
    PlaybackSourceType? collectionType,
  }) async {
    await ref
        .read(recentlyPlayedRepositoryProvider)
        .recordPlaylistOpened(
          id: id,
          name: name,
          coverUrl: coverUrl,
          songCount: songCount,
          source: source,
          collectionType: collectionType,
        );
    ref.invalidateSelf();
  }
}

/// 「统计」页当前选择的粒度。
final playbackStatsGranularityProvider =
    StateProvider<PlaybackStatsGranularity>(
      (ref) => PlaybackStatsGranularity.day,
    );

/// 听歌排行（重要库里的全量历史，不受「最近播放 500 首」上限限制）。
final playRankingProvider = FutureProvider<List<RecentlyPlayedItem>>((ref) {
  return ref.read(recentlyPlayedRepositoryProvider).loadRanking();
});

/// 听歌统计（按粒度聚合）。
final playbackStatsProvider =
    FutureProvider.family<PlaybackStats, PlaybackStatsGranularity>((
      ref,
      granularity,
    ) {
      return ref
          .read(recentlyPlayedRepositoryProvider)
          .loadStats(granularity: granularity);
    });
