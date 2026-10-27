import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/l10n/app_locale.dart';
import 'package:mintmusic/core/l10n/l10n.dart';
import 'package:mintmusic/core/theme/theme_provider.dart';
import 'package:mintmusic/shared/widgets/page_bar.dart';

Future<void> _pumpBar(
  WidgetTester tester, {
  int current = 1,
  int count = 20,
  bool totalKnown = true,
  bool loading = false,
  double width = 1200,
  double textScale = 1,
  Brightness brightness = Brightness.light,
  AppLocale locale = AppLocale.zhCn,
  ValueChanged<int>? onChanged,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        themeColorsProvider.overrideWithValue(
          brightness == Brightness.light ? ThemeColors.light : ThemeColors.dark,
        ),
      ],
      child: L10n(
        locale: locale,
        child: MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: PageBar(
                  currentPage: current,
                  pageCount: count,
                  totalKnown: totalKnown,
                  loading: loading,
                  onChanged: onChanged ?? (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

List<String> _pageTokens(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(
        of: find.byType(SingleChildScrollView).first,
        matching: find.byType(Text),
      ),
    )
    .map((text) => text.data!)
    .toList();

Finder _button(String label) => find.widgetWithText(OutlinedButton, label);

bool _enabled(WidgetTester tester, String label) =>
    tester.widget<OutlinedButton>(_button(label)).onPressed != null;

void main() {
  test('旧调用默认总页数已知', () {
    final bar = PageBar(currentPage: 1, pageCount: 21, onChanged: (_) {});
    expect(bar.totalKnown, isTrue);
  });

  group('页码窗口', () {
    for (var count = 1; count <= 10; count++) {
      testWidgets('$count 页时显示全部页码', (tester) async {
        await _pumpBar(tester, count: count);
        expect(_pageTokens(tester), [
          for (var page = 1; page <= count; page++) '$page',
        ]);
        expect(find.text('共 $count 页'), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
      });
    }

    testWidgets('截图首页：1 至 8、省略号和 20', (tester) async {
      await _pumpBar(tester);
      expect(_pageTokens(tester), [
        '1',
        '2',
        '3',
        '4',
        '5',
        '6',
        '7',
        '8',
        '…',
        '20',
      ]);
    });

    testWidgets('截图中间：当前 8，首尾和前后各 3 页', (tester) async {
      await _pumpBar(tester, current: 8);
      expect(_pageTokens(tester), [
        '1',
        '…',
        '5',
        '6',
        '7',
        '8',
        '9',
        '10',
        '11',
        '…',
        '20',
      ]);
    });

    testWidgets('截图末端：1、省略号和 13 至 20', (tester) async {
      await _pumpBar(tester, current: 20);
      expect(_pageTokens(tester), [
        '1',
        '…',
        '13',
        '14',
        '15',
        '16',
        '17',
        '18',
        '19',
        '20',
      ]);
      expect(_enabled(tester, '下一页'), isFalse);
    });

    testWidgets('11 页阈值、单页空隙补齐及去重', (tester) async {
      await _pumpBar(tester, count: 11);
      expect(_pageTokens(tester), [
        '1',
        '2',
        '3',
        '4',
        '5',
        '6',
        '7',
        '8',
        '…',
        '11',
      ]);
      await _pumpBar(tester, count: 11, current: 6);
      expect(_pageTokens(tester), [for (var i = 1; i <= 11; i++) '$i']);
      expect(find.byType(TextField), findsNothing);
      await _pumpBar(tester, current: 6);
      expect(_pageTokens(tester), [
        for (var i = 1; i <= 9; i++) '$i',
        '…',
        '20',
      ]);
      await _pumpBar(tester, current: 15);
      expect(_pageTokens(tester), [
        '1',
        '…',
        for (var i = 12; i <= 20; i++) '$i',
      ]);
    });

    testWidgets('前后窗口包含边界 current=5 和 current=count-4', (tester) async {
      await _pumpBar(tester, current: 5);
      expect(_pageTokens(tester), [
        for (var i = 1; i <= 8; i++) '$i',
        '…',
        '20',
      ]);
      await _pumpBar(tester, current: 16);
      expect(_pageTokens(tester), [
        '1',
        '…',
        for (var i = 13; i <= 20; i++) '$i',
      ]);
    });

    testWidgets('仅已知总数大于 20 才有跳页框', (tester) async {
      await _pumpBar(tester, count: 20);
      expect(find.byType(TextField), findsNothing);
      await _pumpBar(tester, count: 21);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('共 21 页'), findsOneWidget);
      expect(_pageTokens(tester).last, '21');
    });
  });

  group('导航与输入校验', () {
    testWidgets('一页时前后禁用，正常页码和前后触发正确页数', (tester) async {
      final changes = <int>[];
      await _pumpBar(tester, count: 1, onChanged: changes.add);
      expect(_enabled(tester, '上一页'), isFalse);
      expect(_enabled(tester, '下一页'), isFalse);
      await tester.tap(_button('上一页'));
      await tester.tap(_button('下一页'));
      expect(changes, isEmpty);
      await _pumpBar(tester, current: 8, onChanged: changes.add);
      expect(_enabled(tester, '8'), isFalse);
      await tester.tap(_button('上一页'));
      await tester.tap(_button('下一页'));
      await tester.tap(_button('10'));
      expect(changes, [7, 9, 10]);
    });

    testWidgets('无效输入禁用确定，提交不触发且不崩溃', (tester) async {
      final changes = <int>[];
      await _pumpBar(tester, count: 21, onChanged: changes.add);
      for (final value in [
        '',
        ' ',
        'abc',
        '2a',
        '1.5',
        '0',
        '-2',
        '22',
        '+2',
        '0x10',
        '999999999999999999999999999999999999',
        '1',
      ]) {
        await tester.enterText(find.byType(TextField), value);
        await tester.pump();
        expect(_enabled(tester, '确定'), isFalse, reason: value);
        await tester.tap(_button('确定'));
        await tester.testTextInput.receiveAction(TextInputAction.go);
        await tester.pump();
        expect(changes, isEmpty, reason: value);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('有效输入通过确定、键盘动作及 Enter 跳页', (tester) async {
      final changes = <int>[];
      await _pumpBar(tester, count: 21, onChanged: changes.add);
      await tester.enterText(find.byType(TextField), '21');
      await tester.pump();
      expect(_enabled(tester, '确定'), isTrue);
      await tester.tap(_button('确定'));
      await tester.enterText(find.byType(TextField), ' 8 ');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pump();
      await tester.enterText(find.byType(TextField), '12');
      // TextField 的 Enter 由引擎转换成提交动作；原始测试按键不经过引擎。
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pump();
      expect(changes, [21, 8, 12]);
    });

    testWidgets('loading 禁用所有导航，结束后重新校验输入', (tester) async {
      final changes = <int>[];
      await _pumpBar(tester, count: 21, current: 8, onChanged: changes.add);
      await tester.enterText(find.byType(TextField), '15');
      await _pumpBar(
        tester,
        count: 21,
        current: 8,
        loading: true,
        onChanged: changes.add,
      );
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(
        tester
            .widgetList<OutlinedButton>(find.byType(OutlinedButton))
            .every((button) => button.onPressed == null),
        isTrue,
      );
      // 即使提交回调在加载期间到达，也不能导航。
      tester.widget<TextField>(find.byType(TextField)).onSubmitted!('15');
      expect(changes, isEmpty);
      await _pumpBar(tester, count: 21, current: 8, onChanged: changes.add);
      expect(_enabled(tester, '确定'), isTrue);
      await tester.tap(_button('确定'));
      expect(changes, [15]);
    });

    testWidgets('current、count 更新后输入及有效范围保持同步', (tester) async {
      final changes = <int>[];
      await _pumpBar(tester, count: 30, onChanged: changes.add);
      await tester.enterText(find.byType(TextField), '28');
      await _pumpBar(tester, count: 21, onChanged: changes.add);
      expect(_enabled(tester, '确定'), isFalse);
      await _pumpBar(tester, count: 40, onChanged: changes.add);
      expect(_enabled(tester, '确定'), isTrue);
      await tester.tap(_button('确定'));
      expect(changes, [28]);
      await _pumpBar(tester, count: 40, current: 28, onChanged: changes.add);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '28',
      );
      expect(_enabled(tester, '确定'), isFalse);
      await _pumpBar(tester, count: 20, current: 20, onChanged: changes.add);
      expect(find.byType(TextField), findsNothing);
      expect(_enabled(tester, '下一页'), isFalse);
    });
  });

  group('未知总页数', () {
    testWidgets('只显示可达窗口，不把 count 当末页锚点', (tester) async {
      final changes = <int>[];
      await _pumpBar(
        tester,
        count: 50,
        current: 8,
        totalKnown: false,
        onChanged: changes.add,
      );
      expect(_pageTokens(tester), [
        '1',
        '…',
        '5',
        '6',
        '7',
        '8',
        '9',
        '10',
        '11',
      ]);
      expect(find.text('50'), findsNothing);
      expect(find.textContaining('共 '), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('确定'), findsNothing);
      expect(find.text('尾页'), findsNothing);
      await tester.tap(_button('下一页'));
      expect(changes, [9]);
      await _pumpBar(tester, count: 50, totalKnown: false);
      expect(_pageTokens(tester), [for (var i = 1; i <= 8; i++) '$i']);
    });

    testWidgets('附近的下一页入口可达，不越过 pageCount', (tester) async {
      final changes = <int>[];
      await _pumpBar(
        tester,
        count: 4,
        current: 3,
        totalKnown: false,
        onChanged: changes.add,
      );
      expect(_pageTokens(tester), ['1', '2', '3', '4']);
      await tester.tap(_button('4'));
      expect(changes, [4]);
      await _pumpBar(tester, count: 4, current: 4, totalKnown: false);
      expect(_enabled(tester, '下一页'), isFalse);
    });

    testWidgets('调用方结束加载后切换已知布局，也可重新切回未知', (tester) async {
      await _pumpBar(tester, count: 50, current: 8, totalKnown: false);
      await _pumpBar(tester, count: 30, current: 8);
      expect(_pageTokens(tester).last, '30');
      expect(find.text('共 30 页'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), '25');
      await _pumpBar(tester, count: 30, current: 8, totalKnown: false);
      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('共 '), findsNothing);
      expect(find.text('30'), findsNothing);
      await _pumpBar(tester, count: 20, current: 8);
      expect(find.text('共 20 页'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });
  });

  group('尾页直达', () {
    testWidgets('总数已知时显示尾页，点击直达最后一页', (tester) async {
      final changes = <int>[];
      await _pumpBar(tester, count: 12, current: 1, onChanged: changes.add);
      expect(_enabled(tester, '尾页'), isTrue);
      await tester.tap(_button('尾页'));
      expect(changes, [12]);
      await _pumpBar(tester, count: 12, current: 12, onChanged: changes.add);
      expect(_enabled(tester, '尾页'), isFalse, reason: '已在末页');
      await tester.tap(_button('尾页'));
      expect(changes, [12]);
    });

    testWidgets('单页与加载中不提供尾页', (tester) async {
      await _pumpBar(tester, count: 1);
      expect(find.text('尾页'), findsNothing);
      await _pumpBar(tester, count: 12, current: 1, loading: true);
      expect(_enabled(tester, '尾页'), isFalse);
    });
  });

  group('布局、主题和无障碍', () {
    for (final width in [320.0, 1200.0]) {
      for (final brightness in Brightness.values) {
        testWidgets('$width px / $brightness 无溢出且输入在下一页左侧', (tester) async {
          for (final count in [1, 10, 11, 20, 21, 200]) {
            await _pumpBar(
              tester,
              width: width,
              brightness: brightness,
              count: count,
            );
            expect(tester.takeException(), isNull, reason: 'count=$count');
            final bar = tester.getRect(find.byType(PageBar));
            expect(bar.left, greaterThanOrEqualTo(0));
            expect(bar.right, lessThanOrEqualTo(width));
            if (count > 20) {
              final input = tester.getRect(find.byType(TextField));
              final confirm = tester.getRect(_button('确定'));
              final next = tester.getRect(_button('下一页'));
              expect(input.right, lessThanOrEqualTo(confirm.left));
              expect(confirm.right, lessThan(next.left));
              expect((confirm.center.dy - next.center.dy).abs(), lessThan(1));
              expect((input.center.dy - next.center.dy).abs(), lessThan(4));
              expect(next.right, lessThanOrEqualTo(width));
            }
            final colors = brightness == Brightness.light
                ? ThemeColors.light
                : ThemeColors.dark;
            final selected = tester.widget<OutlinedButton>(_button('1'));
            expect(
              selected.style!.backgroundColor!.resolve({WidgetState.disabled}),
              colors.primary,
            );
            expect(
              selected.style!.foregroundColor!.resolve({WidgetState.disabled}),
              colors.textOnPrimary,
            );
          }
          await _pumpBar(
            tester,
            width: width,
            brightness: brightness,
            count: 50,
            current: 8,
            totalKnown: false,
          );
          expect(tester.takeException(), isNull);
          await _pumpBar(
            tester,
            width: width,
            brightness: brightness,
            count: 21,
            textScale: 2,
          );
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('320px 页码可横滚并点击，跳页控件保持可见', (tester) async {
      final changes = <int>[];
      await _pumpBar(tester, count: 21, width: 320, onChanged: changes.add);
      await tester.drag(
        find.byType(SingleChildScrollView).first,
        const Offset(-600, 0),
      );
      await tester.pumpAndSettle();
      await tester.tap(_button('21'));
      expect(changes, [21]);
      expect(_button('确定').hitTestable(), findsOneWidget);
      expect(_button('下一页').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('按钮支持 Tab / Enter，页码提供选中语义', (tester) async {
      final changes = <int>[];
      final semantics = tester.ensureSemantics();
      try {
        await _pumpBar(tester, count: 3, onChanged: changes.add);
        final selected = tester
            .getSemantics(find.bySemanticsLabel('第 1 页'))
            .getSemanticsData();
        expect(selected.flagsCollection.isSelected, Tristate.isTrue);
        expect(selected.flagsCollection.isButton, isTrue);
        expect(selected.flagsCollection.isEnabled, Tristate.isFalse);
        final second = tester
            .getSemantics(find.bySemanticsLabel('第 2 页'))
            .getSemanticsData();
        expect(second.flagsCollection.isEnabled, Tristate.isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(changes, [2]);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('中文标签经过 context.tr，繁体显示正确', (tester) async {
      await _pumpBar(tester, count: 21, locale: AppLocale.zhTw);
      expect(find.text('上一頁'), findsOneWidget);
      expect(find.text('下一頁'), findsOneWidget);
      expect(find.text('共 21 頁'), findsOneWidget);
      expect(find.text('頁碼'), findsOneWidget);
      expect(find.text('確定'), findsOneWidget);
    });
  });
}
