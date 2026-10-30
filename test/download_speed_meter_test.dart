import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/download/domain/services/download_speed_meter.dart';

void main() {
  // 固定时钟，避免测试依赖真实时间。
  final t0 = DateTime(2026, 1, 1);

  group('DownloadSpeedMeter', () {
    test('分片密集回调时速度不会掉到 0，也不会算成几十 MB/s', () {
      const chunk = 8 * 1024;
      final meter = DownloadSpeedMeter(startBytes: 0, startedAt: t0);
      final speeds = <double>[];
      var bytes = 0;

      // 5 MB/s：约每 1.6ms 一个 8KB 分片，持续 1 秒（dio 的真实回调密度）。
      for (var i = 1; i <= 625; i++) {
        bytes += chunk;
        speeds.add(
          meter.sample(bytes, t0.add(Duration(microseconds: i * 1600))),
        );
      }

      final sampled = speeds.skipWhile((s) => s == 0).toList();
      expect(sampled, isNotEmpty, reason: '应该至少产生一次速度读数');
      // 出过读数之后不能再回到 0（回到 0 就是界面上的「速度闪成 -」）。
      expect(sampled.every((s) => s > 0), isTrue);
      // 窗口均值应接近真实的 5.12 MB/s，不会出现几十 MB/s 的尖峰。
      expect(sampled.first, closeTo(5120000, 512000));
      expect(sampled.every((s) => s < 7000000), isTrue);
    });

    test('同一毫秒内的重复回调不会把速度清零', () {
      const chunk = 8 * 1024;
      final meter = DownloadSpeedMeter(startBytes: 0, startedAt: t0);
      final speeds = <double>[];
      var bytes = 0;
      var ms = 0;

      for (var i = 0; i < 200; i++) {
        bytes += chunk;
        // 每 3 个分片才推进 5ms，制造「同一毫秒内多次回调」。
        if (i % 3 == 0) ms += 5;
        speeds.add(meter.sample(bytes, t0.add(Duration(milliseconds: ms))));
      }

      final sampled = speeds.skipWhile((s) => s == 0).toList();
      expect(sampled, isNotEmpty);
      expect(sampled.every((s) => s > 0), isTrue);
      expect(sampled.every((s) => s < 20000000), isTrue);
    });

    test('窗口内没有新数据才算卡住（速度归零）', () {
      final meter = DownloadSpeedMeter(startBytes: 0, startedAt: t0);
      meter.sample(1024 * 1024, t0.add(const Duration(milliseconds: 200)));
      expect(meter.speed, greaterThan(0));

      // 600ms 后字节数没变 → 真的卡住。
      final stalled = meter.sample(
        1024 * 1024,
        t0.add(const Duration(milliseconds: 800)),
      );
      expect(stalled, 0);
    });

    test('断点续传：起点字节不计入本窗口流量', () {
      const startBytes = 10 * 1024 * 1024;
      final meter = DownloadSpeedMeter(startBytes: startBytes, startedAt: t0);

      // 200ms 内只新增了 1MB（5 MB/s），不能算成 (10MB + 1MB) / 0.2s。
      final speed = meter.sample(
        startBytes + 1024 * 1024,
        t0.add(const Duration(milliseconds: 200)),
      );
      expect(speed, closeTo(5242880, 524288));
      expect(speed, lessThan(7000000));
    });
  });
}
