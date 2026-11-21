import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/download/domain/services/download_speed_meter.dart';

void main() {
  // 固定时钟，避免测试依赖真实时间。
  final t0 = DateTime(2026, 1, 1);

  group('DownloadSpeedMeter', () {
    test('按 1 秒窗口取平均：分片密集回调不会掉到 0，也不会算出尖峰', () {
      const chunk = 8 * 1024;
      final meter = DownloadSpeedMeter(startBytes: 0, startedAt: t0);
      final speeds = <double>[];
      var bytes = 0;

      // 5 MB/s：约每 1.6ms 一个 8KB 分片，持续 3 秒（dio 的真实回调密度）。
      for (var i = 1; i <= 1875; i++) {
        bytes += chunk;
        speeds.add(
          meter.sample(bytes, t0.add(Duration(microseconds: i * 1600))),
        );
      }

      final sampled = speeds.skipWhile((s) => s == 0).toList();
      expect(sampled, isNotEmpty, reason: '应该至少产生一次速度读数');
      // 出过读数之后不能再回到 0（回到 0 就是界面上的「速度闪成 -」）。
      expect(sampled.every((s) => s > 0), isTrue);
      // 1 秒窗口的均值应稳定在真实的 5.12 MB/s 附近。
      expect(sampled.first, closeTo(5120000, 512000));
      expect(sampled.every((s) => s < 6000000), isTrue);
      // 前 1 秒还没到窗口，不应该有读数。
      expect(speeds.first, 0);
    });

    test('同一毫秒内的重复回调不会把速度清零', () {
      const chunk = 8 * 1024;
      final meter = DownloadSpeedMeter(startBytes: 0, startedAt: t0);
      final speeds = <double>[];
      var bytes = 0;
      var ms = 0;

      // 每 3 个分片才推进 5ms，制造「同一毫秒内多次回调」。
      for (var i = 0; i < 900; i++) {
        bytes += chunk;
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
      meter.sample(1024 * 1024, t0.add(const Duration(milliseconds: 1200)));
      expect(meter.speed, greaterThan(0));

      // 再过 1.2 秒字节数没变 → 真的卡住。
      final stalled = meter.sample(
        1024 * 1024,
        t0.add(const Duration(milliseconds: 2400)),
      );
      expect(stalled, 0);
    });

    test('断点续传：起点字节不计入本窗口流量', () {
      const startBytes = 10 * 1024 * 1024;
      final meter = DownloadSpeedMeter(startBytes: startBytes, startedAt: t0);

      // 1 秒内只新增 1MB（1 MB/s），不能算成 (10MB + 1MB) / 1s。
      final speed = meter.sample(
        startBytes + 1024 * 1024,
        t0.add(const Duration(seconds: 1)),
      );
      expect(speed, closeTo(1048576, 104857));
      expect(speed, lessThan(2000000));
    });
  });
}
