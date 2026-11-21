import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/l10n/app_locale.dart';
import 'package:mintmusic/core/l10n/l10n.dart';
import 'package:mintmusic/features/download/presentation/widgets/download_progress_info.dart';

void main() {
  Future<double> labelX(
    WidgetTester tester, {
    required String speed,
    required String size,
  }) async {
    await tester.pumpWidget(
      L10n(
        locale: AppLocale.zhCn,
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 420,
              child: DownloadProgressInfo(
                progress: 0.42,
                speedLabel: speed,
                sizeLabel: size,
                color: const Color(0xFF999999),
              ),
            ),
          ),
        ),
      ),
    );
    return tester.getTopLeft(find.byKey(DownloadProgressInfo.labelKey)).dx;
  }

  testWidgets('「速度:」标签位置不随网速 / 文件大小变化', (tester) async {
    final base = await labelX(tester, speed: '-', size: '0 B');
    // 位数差异最大的几种组合：1 位小数 KB / 3 位整数 MB / 超长 KB。
    for (final pair in [
      ('1.2 MB/s', '5.3 MB'),
      ('1023.9 KB/s', '1023.9 KB'),
      ('99.9 MB/s', '9.99 GB'),
      ('8 B/s', '0 B'),
    ]) {
      final x = await labelX(tester, speed: pair.$1, size: pair.$2);
      expect(x, base, reason: '速度=${pair.$1} 大小时标签被推走了');
    }
  });

  testWidgets('数值再长也不会把行撑破', (tester) async {
    await labelX(tester, speed: '1023.9 KB/s', size: '1023.9 KB');
    expect(tester.takeException(), isNull);
  });
}
