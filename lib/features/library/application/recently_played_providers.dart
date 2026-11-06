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

/// 最近播放的歌曲（按最近播放时间倒序，只保留最近一个月）。
final recentlyPlayedProvider =
    AsyncNotifierProvider<RecentlyPlayedNotifier, List<RecentlyPlayedItem>>(
      RecentlyPlayedNotifier.new,
    );

class RecentlyPlayedNotifier extends AsyncNotifier<List<RecentlyPlayedItem>> {
  @override
  Future<List<RecentlyPlayedItem>> build() async {
    return ref.read(recentlyPlayedRepositoryProvider).loadHistory();
  }

  Future<void> recordPlay(Song song) async {
    await ref.read(recentlyPlayedRepositoryProvider).recordPlay(song);
    ref.invalidateSelf();
  }

  Future<void> clearAll() async {
    await ref.read(recentlyPlayedRepositoryProvider).clearAll();
    // 「已听 N%」进度也跟着清：用户点「清除数据」要的是把这些记录一起抹掉，
    // 否则清完历史，列表里的「已听」标签还在。
    await ref.read(playedProgressProvider.notifier).clearAll();
    ref.invalidateSelf();
  }

  Future<void> removeFromHistory(String songId) async {
    await ref.read(recentlyPlayedRepositoryProvider).removeFromHistory(songId);
    ref.invalidateSelf();
  }
}
