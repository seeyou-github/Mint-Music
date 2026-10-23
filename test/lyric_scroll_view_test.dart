import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/player/domain/models/lyric_line.dart';
import 'package:mintmusic/features/player/presentation/widgets/lyric_scroll_view.dart';

void main() {
  LyricLine plainLine() => LyricLine(
    startTimeMs: 0,
    endTimeMs: 4000,
    words: [
      LyricWord(word: '我听到传来的谁的声音', startTimeMs: 0, endTimeMs: 4000),
    ],
  );

  Future<Size> pumpLyric(
    WidgetTester tester, {
    required LyricLine line,
    required bool hasYrc,
    required double textScale,
  }) async {
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 600,
              height: 600,
              child: LyricScrollView(
                lines: [line],
                currentTimeMs: 1200,
                hasYrc: hasYrc,
                mainFontSize: 30,
                enableBlur: false,
                enableScale: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final paint = find.descendant(
      of: find.byType(LyricScrollView),
      matching: find.byWidgetPredicate((w) => w is CustomPaint && w.painter != null),
    );
    return tester.getSize(paint.first);
  }

  testWidgets('歌词字号不跟随系统字体缩放（普通 LRC / 逐字歌词一致）', (tester) async {
    final plainNormal = await pumpLyric(
      tester,
      line: plainLine(),
      hasYrc: false,
      textScale: 1.0,
    );
    final plainScaled = await pumpLyric(
      tester,
      line: plainLine(),
      hasYrc: false,
      textScale: 1.5,
    );
    expect(plainScaled.height, plainNormal.height);

    final yrc = LyricLine(
      startTimeMs: 0,
      endTimeMs: 4000,
      words: const [
        LyricWord(word: '我听到', startTimeMs: 0, endTimeMs: 1000),
        LyricWord(word: '传来的', startTimeMs: 1000, endTimeMs: 2000),
        LyricWord(word: '谁的声音', startTimeMs: 2000, endTimeMs: 4000),
      ],
    );
    final yrcNormal = await pumpLyric(
      tester,
      line: yrc,
      hasYrc: true,
      textScale: 1.0,
    );
    final yrcScaled = await pumpLyric(
      tester,
      line: yrc,
      hasYrc: true,
      textScale: 1.5,
    );
    expect(yrcScaled.height, yrcNormal.height);
    // 普通 LRC 与逐字歌词的行高一致。
    expect(plainNormal.height, yrcNormal.height);
  });
}
