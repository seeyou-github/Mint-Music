import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/utils/scroll_locate.dart';

const _itemExtent = 60.0;
const _itemCount = 100;

Widget _buildList(ScrollController controller, {double viewportHeight = 600}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        height: viewportHeight,
        child: ListView.builder(
          controller: controller,
          itemCount: _itemCount,
          itemExtent: _itemExtent,
          itemBuilder: (context, index) =>
              SizedBox(height: _itemExtent, child: Text('song-$index')),
        ),
      ),
    ),
  );
}

void main() {
  for (final index in [0, 8, 30, 85, _itemCount - 1]) {
    testWidgets('零时长定位第 $index 项直接到最终落点且不启动动画', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_buildList(controller));
      controller.jumpTo(index == 0 ? 1200 : 0);
      final offsets = <double>[];
      controller.addListener(() => offsets.add(controller.offset));
      final position = controller.position;
      final target =
          (index * _itemExtent -
                  (position.viewportDimension - _itemExtent) * 0.5)
              .clamp(position.minScrollExtent, position.maxScrollExtent);

      await scrollToItemIndex(
        controller,
        index: index,
        itemExtent: _itemExtent,
        alignment: 0.5,
        duration: Duration.zero,
      );

      expect(controller.offset, target);
      expect(offsets, [target]);
      expect(position.isScrollingNotifier.value, isFalse);
      await tester.pump();
      final viewport = tester.getRect(find.byType(ListView));
      final item = tester.getRect(find.text('song-$index'));
      expect(item.top, greaterThanOrEqualTo(viewport.top));
      expect(item.bottom, lessThanOrEqualTo(viewport.bottom));
    });
  }

  testWidgets('定位到很远的条目时最终偏移正确且目标仍在可视区内', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(_buildList(controller));
    await tester.pumpAndSettle();

    const index = 85;
    // 不能 await：动画需要 tester.pump 推进帧，await 会死锁。
    unawaited(
      scrollToItemIndex(controller, index: index, itemExtent: _itemExtent),
    );
    await tester.pumpAndSettle();

    // 目标行顶端在内容坐标系中的位置
    final itemTop = index * _itemExtent; // 5100
    final viewport = controller.position.viewportDimension; // 600
    // 目标应落在可视区内，而不是被推出屏幕
    expect(itemTop - controller.offset, greaterThanOrEqualTo(0.0));
    expect(
      itemTop + _itemExtent - controller.offset,
      lessThanOrEqualTo(viewport),
    );

    // 具体落点：alignment = 0.25
    final expected = itemTop - (viewport - _itemExtent) * 0.25;
    expect(controller.offset, closeTo(expected, 1.0));
    // 未超出可滚动范围
    expect(
      controller.offset,
      lessThanOrEqualTo(controller.position.maxScrollExtent),
    );
  });

  testWidgets('目标接近末尾时偏移被正确夹紧', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(_buildList(controller));
    await tester.pumpAndSettle();

    unawaited(
      scrollToItemIndex(
        controller,
        index: _itemCount - 1,
        itemExtent: _itemExtent,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      controller.offset,
      closeTo(controller.position.maxScrollExtent, 1.0),
    );
  });

  testWidgets('定位到第 0 项时回到列表顶部', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(_buildList(controller));
    await tester.pumpAndSettle();

    unawaited(scrollToItemIndex(controller, index: 0, itemExtent: _itemExtent));
    await tester.pumpAndSettle();

    expect(controller.offset, closeTo(0.0, 1.0));
  });

  testWidgets('长距离定位只构建一屏左右的条目（不逐项构建整段距离）', (tester) async {
    final controller = ScrollController();
    final built = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 600,
            child: ListView.builder(
              controller: controller,
              itemCount: _itemCount,
              itemExtent: _itemExtent,
              itemBuilder: (context, index) {
                built.add(index);
                return SizedBox(
                  height: _itemExtent,
                  child: Text('song-$index'),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    built.clear();
    unawaited(
      scrollToItemIndex(controller, index: 85, itemExtent: _itemExtent),
    );
    await tester.pumpAndSettle();

    // 若逐帧走完整段距离，这里会有上千次构建；两段式（先 jumpTo 再短动画）
    // 保证只涉及目标附近的一屏。
    expect(built.length, lessThan(_itemCount));
    expect(built.any((i) => i >= 80 && i <= 90), isTrue);
  });
}
