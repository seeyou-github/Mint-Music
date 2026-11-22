import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/player/domain/models/lyric_line.dart';
import 'package:mintmusic/features/player/presentation/widgets/lyric_scroll_view.dart';

/// 切歌时歌词排版（native Paragraph）必须被释放，且不能在还画着的行上释放。
///
/// 背景：每行歌词排一次版就会创建 2 个（逐字歌词是几十个）[TextPainter]，
/// 底层是 native Paragraph。以前缓存满了只从 Map 里 `remove`、从不 dispose，
/// 切歌时每首都会新建一整份排版，旧的只能等 GC finalizer，长听 RSS 从
/// 300MB 一路涨到 700MB。
void main() {
  LyricLine plainLine(String text) => LyricLine(
    startTimeMs: 0,
    endTimeMs: 4000,
    words: [LyricWord(word: text, startTimeMs: 0, endTimeMs: 4000)],
  );

  /// 逐字歌词：一行 40 个字 → 一行就是 80 个 TextPainter，最能放大问题。
  LyricLine yrcLine(String tag) {
    final words = <LyricWord>[];
    for (var i = 0; i < 40; i++) {
      words.add(
        LyricWord(
          word: '$tag$i',
          startTimeMs: i * 100,
          endTimeMs: i * 100 + 100,
        ),
      );
    }
    return LyricLine(startTimeMs: 0, endTimeMs: 4000, words: words);
  }

  Future<void> pumpLyric(
    WidgetTester tester,
    List<LyricLine> lines, {
    required bool hasYrc,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 600,
              height: 600,
              child: LyricScrollView(
                lines: lines,
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
  }

  testWidgets('连续切歌：排版被释放，且不会在绘制中释放', (tester) async {
    await pumpLyric(
      tester,
      [plainLine('第一首歌词')],
      hasYrc: false,
    );
    final before = debugLyricLayoutDisposedCount();

    // 模拟不断播放下一首：普通歌词 / 逐字歌词交替。
    for (var i = 0; i < 10; i++) {
      if (i.isEven) {
        await pumpLyric(
          tester,
          [plainLine('第 $i 首普通歌词，内容要够长才能在超宽时横向滚动')],
          hasYrc: false,
        );
      } else {
        await pumpLyric(tester, [yrcLine('词$i')], hasYrc: true);
      }
      expect(tester.takeException(), isNull, reason: '第 $i 次切歌后不应有异常');
    }

    final after = debugLyricLayoutDisposedCount();
    expect(
      after,
      greaterThan(before),
      reason: '切歌后旧排版必须被 dispose，而不是等 GC',
    );

    // 最后再画一帧：确认延迟释放没有把仍在用的排版弄坏。
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.byType(LyricScrollView), findsOneWidget);
  });

  testWidgets('两个歌词视图同时存在：切其中一个不会释放另一个的排版', (tester) async {
    Widget twoViews(List<LyricLine> aLines, List<LyricLine> bLines) {
      return MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 300,
                height: 300,
                child: LyricScrollView(
                  key: const ValueKey('a'),
                  lines: aLines,
                  currentTimeMs: 1200,
                  hasYrc: false,
                  mainFontSize: 20,
                  enableScale: false,
                ),
              ),
              SizedBox(
                width: 300,
                height: 300,
                child: LyricScrollView(
                  key: const ValueKey('b'),
                  lines: bLines,
                  currentTimeMs: 1200,
                  hasYrc: false,
                  mainFontSize: 20,
                  enableScale: false,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final bLines = [plainLine('B 视图的歌词')];
    await tester.pumpWidget(twoViews([plainLine('A 第一首')], bLines));
    await tester.pump();

    // A 切歌。旧实现会 clear 全局缓存，把 B 正在绘制的 TextPainter 一起
    // dispose，B 下一帧 paint 会抛 StateError。
    await tester.pumpWidget(twoViews([plainLine('A 第二首')], bLines));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(find.byType(LyricScrollView), findsNWidgets(2));
  });

  testWidgets('歌词没变时不重复重建排版', (tester) async {
    final lines = [plainLine('同一份歌词')];
    await pumpLyric(tester, lines, hasYrc: false);
    final before = debugLyricLayoutDisposedCount();

    await tester.pump();
    await tester.pump();
    expect(debugLyricLayoutDisposedCount(), before);
  });
}
