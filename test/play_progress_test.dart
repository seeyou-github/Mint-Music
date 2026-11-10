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
    test('只在进度变大时保存（重复播放 / 往回拖不覆盖）', () async {
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

        // 只要进度更大就更新（记录发生在暂停 / 切歌等节点，不会很频繁）。
        notifier.record(songId: 's1', positionMs: 40000, durationMs: 300000);
        expect(notifier.state['s1'], closeTo(0.1333, 0.001));

        // 播完 = 100%。
        notifier.record(songId: 's1', positionMs: 300000, durationMs: 300000);
        expect(playedProgressLabel(notifier.state['s1']), '已听');

        // 45.7% → 46% → 46.4%：只要变大就记录。
        notifier.record(songId: 's2', positionMs: 45700, durationMs: 100000);
        expect(notifier.state['s2'], closeTo(0.457, 0.0001));
        notifier.record(songId: 's2', positionMs: 46000, durationMs: 100000);
        expect(notifier.state['s2'], closeTo(0.46, 0.0001));
        notifier.record(songId: 's2', positionMs: 46400, durationMs: 100000);
        expect(notifier.state['s2'], closeTo(0.464, 0.0001));

        notifier.dispose();
      } finally {
        AppPaths.debugRootOverride = null;
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });
  });

  group('续播位置（复用「已听」数据）', () {
    test('按最远进度折算：往回拖不影响续播点', () async {
      final dir = Directory.systemTemp.createTempSync('mintmusic_resume_test');
      AppPaths.debugRootOverride = dir.path;
      try {
        final notifier = PlayedProgressNotifier(PlayProgressStore());
        await notifier.ready.timeout(const Duration(seconds: 5));

        notifier.record(songId: 's1', positionMs: 60000, durationMs: 300000);
        expect(
          notifier.resumePositionFor('s1', durationMs: 300000),
          const Duration(minutes: 1),
        );

        // 往回拖进度条不会把「已听」降下去，续播点仍是最远的那里。
        notifier.record(songId: 's1', positionMs: 30000, durationMs: 300000);
        expect(
          notifier.resumePositionFor('s1', durationMs: 300000),
          const Duration(minutes: 1),
        );

        // 继续往后听到 80%：续播点跟着更新。
        notifier.record(songId: 's1', positionMs: 240000, durationMs: 300000);
        expect(
          notifier.resumePositionFor('s1', durationMs: 300000),
          const Duration(minutes: 4),
        );

        notifier.dispose();
      } finally {
        AppPaths.debugRootOverride = null;
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('没记录 / 太靠前 / 听完 / 接近结尾都返回 0（从头播）', () async {
      final dir = Directory.systemTemp.createTempSync('mintmusic_resume_q');
      AppPaths.debugRootOverride = dir.path;
      try {
        final notifier = PlayedProgressNotifier(PlayProgressStore());
        await notifier.ready.timeout(const Duration(seconds: 5));

        // 没有记录 → 从头播。
        expect(
          notifier.resumePositionFor('missing', durationMs: 300000),
          Duration.zero,
        );

        // 几乎没有进展（不足 3 秒）→ 从头播。
        notifier.record(songId: 'tiny', positionMs: 2000, durationMs: 300000);
        expect(
          notifier.resumePositionFor('tiny', durationMs: 300000),
          Duration.zero,
        );

        // 完整听完（100%）→ 从头播，进度条也归 0。
        notifier.record(songId: 'done', positionMs: 300000, durationMs: 300000);
        expect(notifier.state['done'], closeTo(1.0, 0.0001));
        expect(
          notifier.resumePositionFor('done', durationMs: 300000),
          Duration.zero,
        );

        // 停在 99%（离结尾只剩几秒）→ 也从头播，避免一点就到末尾。
        notifier.record(songId: 'near', positionMs: 297000, durationMs: 300000);
        expect(
          notifier.resumePositionFor('near', durationMs: 300000),
          Duration.zero,
        );

        // 时长未知（元数据没有时长）→ 无从折算，从头播。
        expect(notifier.resumePositionFor('s1', durationMs: 0), Duration.zero);

        notifier.dispose();
      } finally {
        AppPaths.debugRootOverride = null;
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });
  });

  test('还原备份后 reload 以数据库为准（旧进度不残留）', () async {
    final dir = Directory.systemTemp.createTempSync('mintmusic_reload_test');
    AppPaths.debugRootOverride = dir.path;
    try {
      final store = PlayProgressStore();
      final notifier = PlayedProgressNotifier(store);
      await notifier.ready.timeout(const Duration(seconds: 5));

      notifier.record(songId: 'old', positionMs: 50000, durationMs: 100000);
      await store.flush();
      expect(notifier.state['old'], closeTo(0.5, 0.0001));

      // 模拟还原：备份快照整体覆盖数据库。
      await PlayProgressStore.importSnapshot({
        'progress': [
          {
            'songId': 'restored',
            'ratio': 0.8,
            'positionMs': 80000,
            'durationMs': 100000,
          },
        ],
      });
      await notifier.reload();

      // 还原是整体覆盖：内存里还原前的进度不能再被合并回来。
      expect(notifier.state.keys, ['restored']);
      expect(notifier.state['restored'], closeTo(0.8, 0.0001));
      expect(
        notifier.resumePositionFor('restored', durationMs: 100000),
        const Duration(milliseconds: 80000),
      );

      notifier.dispose();
    } finally {
      AppPaths.debugRootOverride = null;
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
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
