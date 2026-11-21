import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/storage/app_database.dart';

void main() {
  group('DeferredWriter', () {
    test('schedule 后 flush 真正落盘', () async {
      var writes = 0;
      final writer = DeferredWriter(() async => writes++);

      writer.schedule();
      await writer.flush();

      expect(writes, 1);
    });

    test('没有变更时 flush 不写入', () async {
      var writes = 0;
      final writer = DeferredWriter(() async => writes++);

      await writer.flush();

      expect(writes, 0);
    });

    test('多次 schedule 只在 flush 时合并写一次', () async {
      var writes = 0;
      final writer = DeferredWriter(() async => writes++);

      writer.schedule();
      writer.schedule();
      writer.schedule();
      await writer.flush();

      expect(writes, 1);
    });

    test('writeNow 立即写入', () async {
      var writes = 0;
      final writer = DeferredWriter(
        () async => writes++,
        interval: const Duration(minutes: 10),
      );

      await writer.writeNow();

      expect(writes, 1);
    });

    test('写入期间产生的新变更会被再写一轮', () async {
      var writes = 0;
      late DeferredWriter writer;
      writer = DeferredWriter(() async {
        writes++;
        if (writes == 1) writer.schedule();
      });

      writer.schedule();
      await writer.flush();

      expect(writes, 2);
    });

    test('写入期间的并发 flush 共享同一次写入', () async {
      var writes = 0;
      final gate = Completer<void>();
      final writer = DeferredWriter(() async {
        writes++;
        await gate.future;
      });

      writer.schedule();
      final first = writer.flush();
      final second = writer.flush();
      gate.complete();
      await Future.wait([first, second]);

      expect(writes, 1);
    });
  });
}
