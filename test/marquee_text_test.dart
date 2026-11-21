import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/shared/widgets/marquee_text.dart';

void main() {
  Future<void> pumpMarquee(
    WidgetTester tester, {
    required bool allowScroll,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 80,
            child: MarqueeText(
              text: '一个非常非常非常长的歌曲标题',
              style: const TextStyle(fontSize: 14),
              allowScroll: allowScroll,
            ),
          ),
        ),
      ),
    );
    // 跑滚动是在首帧之后才启动的。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('allowScroll=false：超长部分省略号截断，不启动滚动', (tester) async {
    await pumpMarquee(tester, allowScroll: false);

    final text = tester.widget<Text>(find.byType(Text).first);
    expect(text.maxLines, 1);
    expect(text.softWrap, isFalse);
    expect(text.overflow, TextOverflow.ellipsis);
    // 没有逐帧回调 = 不会让引擎一直出帧（Windows 侧栏曲名走这条）。
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('allowScroll=true：溢出时来回滚动（有逐帧回调）', (tester) async {
    await pumpMarquee(tester, allowScroll: true);

    expect(tester.binding.transientCallbackCount, greaterThan(0));
    final text = tester.widget<Text>(find.byType(Text).first);
    expect(text.overflow, TextOverflow.visible);
  });
}
