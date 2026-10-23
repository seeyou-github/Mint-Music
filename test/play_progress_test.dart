import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/platform/app_paths.dart';
import 'package:mintmusic/features/player/application/play_progress_providers.dart';
import 'package:mintmusic/features/player/data/play_progress_store.dart';

void main() {
  group('playedProgressLabel', () {
    test('没听过 / 不足 1% 不显示标签', () {
      expect(playedProgressLabel(null), isNull);
      expect(playedProgressLabel(0), isNull);
      expect(playedProgressLabel(0.004), isNull);
    });

    test('按百分比显示，四舍五入前先向下取整', () {
      expect(playedProgressLabel(0.01), '已听1%');
      expect(playedProgressLabel(0.10), '已听10%');
      expect(playedProgressLabel(0.105), '已听10%');
      expect(playedProgressLabel(0.99), '已听99%');
    });

    test('听完显示「已听」', () {
      expect(playedProgressLabel(0.999), '已听');
      expect(playedProgressLabel(1.0), '已听');
    });
  });

  group('PlayedProgressNotifier', () {
    test('只增不减，且按 1% 粒度节流', () async {
      final dir = Directory.systemTemp.createTempSync('mintmusic_played_test');
      AppPaths.debugRootOverride = dir.path;
      try {
        final notifier = PlayedProgressNotifier(PlayProgressStore());
        await Future<void>.delayed(const Duration(milliseconds: 200));

        notifier.record(songId: 's1', positionMs: 30000, durationMs: 300000);
        expect(notifier.state['s1'], closeTo(0.1, 0.0001));

        // 往回拖进度条不会把已听进度降下去。
        notifier.record(songId: 's1', positionMs: 10000, durationMs: 300000);
        expect(notifier.state['s1'], closeTo(0.1, 0.0001));

        // 不足 1% 的变化先不记录（避免列表被频繁重建）。
        notifier.record(songId: 's1', positionMs: 32000, durationMs: 300000);
        expect(notifier.state['s1'], closeTo(0.1, 0.0001));

        // 跨过下一个百分点就更新。
        notifier.record(songId: 's1', positionMs: 40000, durationMs: 300000);
        expect(notifier.state['s1'], closeTo(0.1333, 0.001));

        // 播完 = 100%。
        notifier.record(songId: 's1', positionMs: 300000, durationMs: 300000);
        expect(playedProgressLabel(notifier.state['s1']), '已听');

        // 按「百分点」比较：45.7% → 46% 差值不足 1% 也要记，
        // 否则播放器每跨一个百分点上报一次时会被这里漏掉一半。
        notifier.record(songId: 's2', positionMs: 45700, durationMs: 100000);
        expect(notifier.state['s2'], closeTo(0.457, 0.0001));
        notifier.record(songId: 's2', positionMs: 46000, durationMs: 100000);
        expect(notifier.state['s2'], closeTo(0.46, 0.0001));
        // 同一个百分点内（46.4%）不再刷新界面。
        notifier.record(songId: 's2', positionMs: 46400, durationMs: 100000);
        expect(notifier.state['s2'], closeTo(0.46, 0.0001));

        notifier.dispose();
      } finally {
        AppPaths.debugRootOverride = null;
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });
  });

  test('播放进度写入临时库并能读回', () async {
    final dir = Directory.systemTemp.createTempSync('mintmusic_played_db');
    AppPaths.debugRootOverride = dir.path;
    try {
      final store = PlayProgressStore();
      store.enqueue(
        'song-a',
        const PlayedProgress(
          ratio: 0.42,
          positionMs: 42000,
          durationMs: 100000,
        ),
      );
      await store.flush();

      final loaded = await PlayProgressStore().loadAll();
      expect(loaded['song-a'], isNotNull);
      expect(loaded['song-a']!.ratio, closeTo(0.42, 0.0001));
      expect(loaded['song-a']!.durationMs, 100000);

      await store.clear();
      expect(await PlayProgressStore().loadAll(), isEmpty);
    } finally {
      AppPaths.debugRootOverride = null;
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });
}
