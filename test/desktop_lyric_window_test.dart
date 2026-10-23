import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/l10n/app_locale.dart';
import 'package:mintmusic/core/l10n/l10n.dart';
import 'package:mintmusic/features/player/domain/models/desktop_lyric_settings.dart';
import 'package:mintmusic/features/player/domain/models/lyric_line.dart';
import 'package:mintmusic/features/player/presentation/desktop_lyric_window.dart';

/// 面板高度按默认字号推算：两个槽位 × (正文 + 译文/音译) 还要留余量。
/// 写死数值会在默认字号调整（42 → 50）后让面板溢出，这里跟着字号走。
double get _panelHeight => DesktopLyricSettings.defaults.fontSize * 6;

Widget _host(Widget child) {
  return MaterialApp(
    home: L10n(
      locale: AppLocale.zhCn,
      child: Scaffold(
        body: SizedBox.expand(
          child: Stack(
            children: [
              Positioned(
                left: 0,
                top: 0,
                width: 360,
                height: _panelHeight,
                child: child,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

List<LyricLine> _sampleLines() => [
  LyricLine(
    startTimeMs: 0,
    endTimeMs: 1000,
    words: const [LyricWord(word: '第一行歌词', startTimeMs: 0, endTimeMs: 500)],
    translatedLyric: 'the first line',
  ),
  LyricLine(
    startTimeMs: 1000,
    endTimeMs: 2000,
    words: const [LyricWord(word: '第二行歌词', startTimeMs: 1000, endTimeMs: 1500)],
  ),
  LyricLine(
    startTimeMs: 2000,
    endTimeMs: 3000,
    words: const [LyricWord(word: '第三行歌词', startTimeMs: 2000, endTimeMs: 2500)],
  ),
];

void main() {
  testWidgets('固定两个槽位渲染当前行、译文和下一行', (tester) async {
    await tester.pumpWidget(
      _host(
        DesktopLyricPanel(
          settings: DesktopLyricSettings.defaults,
          lines: _sampleLines(),
          activeIndex: 0,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('第一行歌词'), findsOneWidget);
    expect(find.text('the first line'), findsOneWidget);
    expect(find.text('第二行歌词'), findsOneWidget);
    expect(find.text('第三行歌词'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切到第二行时槽位位置不变，下一行预载到第一槽位', (tester) async {
    await tester.pumpWidget(
      _host(
        DesktopLyricPanel(
          settings: DesktopLyricSettings.defaults,
          lines: _sampleLines(),
          activeIndex: 1,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 第二行仍在第二槽位（下方），第三行预载到第一槽位（上方）。
    expect(find.text('第一行歌词'), findsNothing);
    expect(find.text('第二行歌词'), findsOneWidget);
    expect(find.text('第三行歌词'), findsOneWidget);
    final secondTop = tester.getTopLeft(find.text('第二行歌词')).dy;
    final thirdTop = tester.getTopLeft(find.text('第三行歌词')).dy;
    expect(thirdTop, lessThan(secondTop));
    expect(tester.takeException(), isNull);
  });

  testWidgets('播放到最后一行时另一个槽位保持为空', (tester) async {
    await tester.pumpWidget(
      _host(
        DesktopLyricPanel(
          settings: DesktopLyricSettings.defaults,
          lines: _sampleLines(),
          activeIndex: 2,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('第一行歌词'), findsNothing);
    expect(find.text('第二行歌词'), findsNothing);
    expect(find.text('第三行歌词'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('使用歌词设置里的字体、字重与字号缩放', (tester) async {
    await tester.pumpWidget(
      _host(
        DesktopLyricPanel(
          settings: DesktopLyricSettings.defaults,
          lines: _sampleLines(),
          activeIndex: 0,
          fontFamily: 'FZLantingHei',
          fontWeight: FontWeight.w800,
          fontSizeScale: 1.2,
        ),
      ),
    );
    await tester.pump();

    final text = tester.widget<Text>(find.text('第一行歌词'));
    expect(text.style?.fontFamily, 'FZLantingHei');
    expect(text.style?.fontWeight, FontWeight.w800);
    expect(
      text.style?.fontSize,
      closeTo(DesktopLyricSettings.defaults.fontSize * 1.2, 0.01),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('面板不再自带拖动把手', (tester) async {
    await tester.pumpWidget(
      _host(
        DesktopLyricPanel(
          settings: DesktopLyricSettings.defaults,
          lines: _sampleLines(),
          activeIndex: 0,
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.drag_indicator), findsNothing);
    expect(find.text('第一行歌词'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖动把手渲染拖拽图标', (tester) async {
    await tester.pumpWidget(_host(const DesktopLyricHandle()));
    await tester.pump();

    expect(find.byIcon(Icons.drag_indicator), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌词区不吞掉下层页面的点击，把手区可用于拖动', (tester) async {
    var tappedBehind = false;
    await tester.pumpWidget(
      MaterialApp(
        home: L10n(
          locale: AppLocale.zhCn,
          child: Scaffold(
            body: SizedBox.expand(
              child: Stack(
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => tappedBehind = true,
                    child: const SizedBox.expand(
                      child: ColoredBox(color: Colors.blue),
                    ),
                  ),
                  // 与 DesktopLyricWindow 相同的命中测试结构:
                  // 背景+歌词整体 IgnorePointer,只有顶部把手可交互。
                  Positioned(
                    left: 0,
                    top: 0,
                    width: 360,
                    height: _panelHeight,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: IgnorePointer(
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const SizedBox(
                                    height: DesktopLyricHandle.height,
                                  ),
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: DesktopLyricPanel.padding,
                                        vertical: 4,
                                      ),
                                      child: DesktopLyricPanel(
                                        settings: DesktopLyricSettings.defaults,
                                        lines: _sampleLines(),
                                        activeIndex: 0,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          height: DesktopLyricHandle.height,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {},
                            child: const DesktopLyricHandle(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 歌词区:点击应穿透到下层。
    await tester.tapAt(const Offset(180, 120));
    await tester.pump();
    expect(tappedBehind, isTrue);

    // 把手区:点击被把手消费,不会穿透。
    tappedBehind = false;
    await tester.tapAt(const Offset(180, 8));
    await tester.pump();
    expect(tappedBehind, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有歌词时显示占位文案', (tester) async {
    await tester.pumpWidget(
      _host(
        DesktopLyricPanel(
          settings: DesktopLyricSettings.defaults,
          lines: const [],
          activeIndex: -1,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('暂无歌词'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
