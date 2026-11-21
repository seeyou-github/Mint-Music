import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/player/domain/models/lyric_line.dart';
import 'package:mintmusic/features/player/presentation/widgets/lyric_scroll_view.dart';

void main() {
  LyricLine plainLine() => LyricLine(
    startTimeMs: 0,
    endTimeMs: 4000,
    words: [LyricWord(word: '我听到传来的谁的声音', startTimeMs: 0, endTimeMs: 4000)],
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
      matching: find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter != null,
      ),
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

  testWidgets('翻译颜色与所在行一致（当前行已播放色 / 其余行未播放色）', (tester) async {
    const activeColor = Color(0xFF00FF00);
    const inactiveColor = Color(0x40FFFFFF);

    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 600,
              height: 600,
              child: LyricScrollView(
                lines: [
                  LyricLine(
                    startTimeMs: 0,
                    endTimeMs: 4000,
                    words: [
                      LyricWord(word: '当前行', startTimeMs: 0, endTimeMs: 4000),
                    ],
                    translatedLyric: '当前行翻译',
                  ),
                  LyricLine(
                    startTimeMs: 4000,
                    endTimeMs: 8000,
                    words: [
                      LyricWord(
                        word: '其它行',
                        startTimeMs: 4000,
                        endTimeMs: 8000,
                      ),
                    ],
                    translatedLyric: '其它行翻译',
                  ),
                ],
                currentTimeMs: 1200,
                hasYrc: false,
                activeColor: activeColor,
                inactiveColor: inactiveColor,
                enableScale: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    Color? colorOf(String text) =>
        tester.widget<Text>(find.text(text)).style?.color;

    expect(colorOf('当前行翻译'), activeColor);
    expect(colorOf('其它行翻译'), inactiveColor);

    // 非当前行只降低 20% 亮度，整行保持 80% 不透明度。
    double opacityOf(String text) => tester
        .widget<AnimatedOpacity>(
          find
              .ancestor(
                of: find.text(text),
                matching: find.byType(AnimatedOpacity),
              )
              .first,
        )
        .opacity;
    expect(opacityOf('当前行翻译'), 1.0);
    expect(opacityOf('其它行翻译'), 0.8);
  });

  testWidgets('active=false 时冻结：停掉逐帧时钟，进度再走也不重绘', (tester) async {
    final lines = List<LyricLine>.generate(
      40,
      (i) => LyricLine(
        startTimeMs: i * 2000,
        endTimeMs: i * 2000 + 1800,
        words: [
          LyricWord(
            word: '第$i句',
            startTimeMs: i * 2000,
            endTimeMs: i * 2000 + 1800,
          ),
        ],
      ),
    );

    var active = true;
    var timeMs = 0;
    late StateSetter setLocal;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 400,
            height: 400,
            child: StatefulBuilder(
              builder: (context, setState) {
                setLocal = setState;
                return LyricScrollView(
                  lines: lines,
                  currentTimeMs: timeMs,
                  isPlaying: true,
                  active: active,
                  mainFontSize: 20,
                  enableScale: false,
                );
              },
            ),
          ),
        ),
      ),
    );
    // 播放中：内部逐帧时钟在跑（每帧都要合成，这是「看不见也在烧 CPU」的来源）。
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    // 页面不可见 / 窗口失焦：冻结。之后进度继续往前跑，也不应该再有帧回调。
    setLocal(() {
      active = false;
      timeMs = 60000;
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.binding.transientCallbackCount, 0);

    // 恢复可见：重新开始逐帧推进。
    setLocal(() => active = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
  });
}
