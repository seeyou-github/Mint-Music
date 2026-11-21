import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/backup/playlist_sync_status.dart';

void main() {
  group('启动自动同步写入的底部提示状态', () {
    testWidgets('开始 → 成功 → 2 秒后自动隐藏', (tester) async {
      final notifier = PlaylistSyncStatusNotifier();
      addTearDown(notifier.dispose);

      notifier.start();
      expect(notifier.state.phase, PlaylistSyncPhase.syncing);
      expect(notifier.state.isVisible, isTrue);
      expect(notifier.state.kind, PlaylistSyncKind.playlist);

      notifier.succeed();
      expect(notifier.state.phase, PlaylistSyncPhase.success);
      await tester.pump(const Duration(seconds: 2));
      expect(notifier.state.phase, PlaylistSyncPhase.idle);
      expect(notifier.state.isVisible, isFalse);
    });

    testWidgets('失败时带具体原因，4 秒后自动隐藏', (tester) async {
      final notifier = PlaylistSyncStatusNotifier();
      addTearDown(notifier.dispose);

      notifier.start();
      notifier.fail('网络超时：2 分钟内没有完成');
      expect(notifier.state.phase, PlaylistSyncPhase.failed);
      expect(notifier.state.message, '网络超时：2 分钟内没有完成');
      await tester.pump(const Duration(seconds: 4));
      expect(notifier.state.phase, PlaylistSyncPhase.idle);
    });

    testWidgets('点「重新同步」后旧定时器不会把新提示隐藏', (tester) async {
      final notifier = PlaylistSyncStatusNotifier();
      addTearDown(notifier.dispose);

      notifier.start();
      notifier.fail('上一次失败');
      notifier.start();
      expect(notifier.state.phase, PlaylistSyncPhase.syncing);
      await tester.pump(const Duration(seconds: 4));
      expect(notifier.state.phase, PlaylistSyncPhase.syncing);
    });

    test('dismiss 立即隐藏', () {
      final notifier = PlaylistSyncStatusNotifier();
      addTearDown(notifier.dispose);

      notifier.start();
      notifier.dismiss();
      expect(notifier.state.phase, PlaylistSyncPhase.idle);
    });
  });
}
