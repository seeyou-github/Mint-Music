import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/theme/theme_provider.dart';
import 'package:mintmusic/features/player/application/playback_controller.dart';
import 'package:mintmusic/features/player/domain/models/playback_state.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';
import 'package:mintmusic/features/player/presentation/mini_player.dart';
import 'package:mintmusic/features/radio/application/radio_session.dart';

const _songs = [
  Song(id: 'a', title: '上一首歌', artist: '歌手甲', album: '', duration: 180),
  Song(id: 'b', title: '当前歌曲', artist: '歌手乙', album: '', duration: 180),
  Song(id: 'c', title: '下一首歌', artist: '歌手丙', album: '', duration: 180),
];

class _DeferredController extends StateNotifier<PlaybackState>
    implements PlaybackController {
  _DeferredController()
    : super(
        PlaybackState(queue: _songs, currentIndex: 1, currentSong: _songs[1]),
      );

  final requests = <({bool next, int? target})>[];
  final pending = <Completer<void>>[];
  int? nextTarget;

  @override
  PlaybackState get playbackState => state;

  @override
  int? skipTargetIndex({required bool next}) => next && nextTarget != null
      ? nextTarget
      : (state.currentIndex + (next ? 1 : -1)) % state.queue.length;

  @override
  Future<void> next({bool auto = false, int? targetIndex}) {
    requests.add((next: true, target: targetIndex));
    final completer = Completer<void>();
    pending.add(completer);
    return completer.future;
  }

  @override
  Future<void> previous({int? targetIndex}) {
    requests.add((next: false, target: targetIndex));
    final completer = Completer<void>();
    pending.add(completer);
    return completer.future;
  }

  void select(int index) {
    state = state.copyWith(
      currentIndex: index,
      currentSong: state.queue[index],
    );
  }

  void completeRequests() {
    for (final completer in pending) {
      if (!completer.isCompleted) completer.complete();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<_DeferredController> _buildPlayer(
  WidgetTester tester, {
  bool radio = false,
}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = _DeferredController();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playbackControllerProvider.overrideWith((ref) => controller),
        themeColorsProvider.overrideWithValue(ThemeColors.light),
        radioModeProvider.overrideWithValue(radio),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: Align(alignment: Alignment.bottomCenter, child: MiniPlayer()),
        ),
      ),
    ),
  );
  addTearDown(() async {
    controller.completeRequests();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });
  return controller;
}

Finder get _titles => find
    .descendant(of: find.byType(MiniPlayer), matching: find.byType(ClipRect))
    .first;

bool _isVisible(WidgetTester tester, String title) {
  final viewport = tester.getRect(_titles);
  return find.text(title).evaluate().any((element) {
    final box = element.renderObject! as RenderBox;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    return rect.intersect(viewport).width > 1;
  });
}

Future<TestGesture> _dragTitle(WidgetTester tester, double dx) async {
  final gesture = await tester.startGesture(tester.getCenter(_titles));
  await gesture.moveBy(Offset(dx.sign * 24, 0));
  await tester.pump();
  await gesture.moveBy(Offset(dx, 0));
  await tester.pump();
  return gesture;
}

void main() {
  final android = TargetPlatformVariant.only(TargetPlatform.android);

  for (final next in [true, false]) {
    testWidgets('${next ? '左' : '右'}拖动中显示目标歌名且尚未切歌', (tester) async {
      final controller = await _buildPlayer(tester);
      final buttonPosition = tester.getCenter(find.byIcon(Icons.skip_next));
      final distance = tester.getSize(_titles).width * 0.8;
      final gesture = await _dragTitle(tester, next ? -distance : distance);
      expect(_isVisible(tester, next ? '下一首歌' : '上一首歌'), isTrue);
      expect(controller.requests, isEmpty);
      expect(tester.getCenter(find.byIcon(Icons.skip_next)), buttonPosition);
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(_isVisible(tester, '当前歌曲'), isTrue);
      expect(controller.requests, isEmpty);
    }, variant: android);
  }

  testWidgets('松手后保持目标歌名直到延迟的播放状态接上，不闪回旧歌名', (tester) async {
    final controller = await _buildPlayer(tester);
    final gesture = await _dragTitle(tester, -110);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.requests, [(next: true, target: 2)]);
    expect(controller.playbackState.currentSong?.id, 'b');
    expect(_isVisible(tester, '下一首歌'), isTrue);
    expect(_isVisible(tester, '当前歌曲'), isFalse);
    await tester.pump(const Duration(milliseconds: 600));
    expect(_isVisible(tester, '下一首歌'), isTrue);
    expect(_isVisible(tester, '当前歌曲'), isFalse);
    controller.select(2);
    await tester.pumpAndSettle();
    expect(_isVisible(tester, '下一首歌'), isTrue);
    expect(_isVisible(tester, '当前歌曲'), isFalse);
    controller.completeRequests();
    await tester.pumpAndSettle();
    expect(_isVisible(tester, '下一首歌'), isTrue);
  }, variant: android);

  testWidgets('短距离慢拖松手回弹，不切歌', (tester) async {
    final controller = await _buildPlayer(tester);
    final gesture = await _dragTitle(tester, -30);
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.requests, isEmpty);
    expect(_isVisible(tester, '当前歌曲'), isTrue);
    expect(_isVisible(tester, '下一首歌'), isFalse);
  }, variant: android);

  testWidgets('拖动中外部切歌会取消旧目标，松手不覆盖外部选择', (tester) async {
    final controller = await _buildPlayer(tester);
    final gesture = await _dragTitle(tester, -110);
    controller.select(0);
    await tester.pump();
    expect(_isVisible(tester, '上一首歌'), isTrue);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.requests, isEmpty);
    expect(_isVisible(tester, '下一首歌'), isFalse);
  }, variant: android);

  testWidgets('新歌已选中就能继续滑动，旧播放请求完成不重置新预览', (tester) async {
    final controller = await _buildPlayer(tester);
    final first = await _dragTitle(tester, -110);
    await first.up();
    await tester.pumpAndSettle();
    final ignored = await _dragTitle(tester, -110);
    await ignored.up();
    await tester.pumpAndSettle();
    expect(controller.requests, hasLength(1));

    controller.select(2);
    await tester.pumpAndSettle();
    final second = await _dragTitle(
      tester,
      tester.getSize(_titles).width * 0.8,
    );
    await second.up();
    await tester.pumpAndSettle();
    expect(controller.requests, [
      (next: true, target: 2),
      (next: false, target: 1),
    ]);
    expect(_isVisible(tester, '当前歌曲'), isTrue);
    expect(_isVisible(tester, '下一首歌'), isFalse);
    controller.pending.first.complete();
    await tester.pumpAndSettle();
    expect(_isVisible(tester, '当前歌曲'), isTrue);
    expect(_isVisible(tester, '下一首歌'), isFalse);
    controller.select(1);
    controller.completeRequests();
    await tester.pumpAndSettle();
    expect(_isVisible(tester, '当前歌曲'), isTrue);
  }, variant: android);

  testWidgets('回弹尚未结束时可反向拖动，不被旧动画清空', (tester) async {
    final controller = await _buildPlayer(tester);
    final first = await _dragTitle(tester, -30);
    await tester.pump(const Duration(milliseconds: 500));
    await first.up();
    await tester.pump(const Duration(milliseconds: 30));
    final second = await _dragTitle(
      tester,
      tester.getSize(_titles).width * 0.8,
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(_isVisible(tester, '上一首歌'), isTrue);
    expect(controller.requests, isEmpty);
    await second.up();
    await tester.pumpAndSettle();
    expect(controller.requests, [(next: false, target: 0)]);
    expect(_isVisible(tester, '上一首歌'), isTrue);
  }, variant: android);

  testWidgets('随机目标恰好是当前歌曲时，慢加载不阻塞后续滑动', (tester) async {
    final controller = await _buildPlayer(tester);
    controller.nextTarget = 1;
    final first = await _dragTitle(tester, -110);
    await first.up();
    await tester.pumpAndSettle();
    expect(controller.pending.single.isCompleted, isFalse);
    expect(_isVisible(tester, '当前歌曲'), isTrue);

    final second = await _dragTitle(
      tester,
      tester.getSize(_titles).width * 0.8,
    );
    await second.up();
    await tester.pumpAndSettle();
    expect(controller.requests, [
      (next: true, target: 1),
      (next: false, target: 0),
    ]);
    expect(_isVisible(tester, '上一首歌'), isTrue);
    controller.pending.first.complete();
    await tester.pumpAndSettle();
    expect(_isVisible(tester, '上一首歌'), isTrue);
  }, variant: android);

  testWidgets('未切换歌曲的失败请求结束后恢复原歌名', (tester) async {
    final controller = await _buildPlayer(tester);
    final gesture = await _dragTitle(tester, -110);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_isVisible(tester, '下一首歌'), isTrue);
    controller.completeRequests();
    await tester.pumpAndSettle();
    expect(_isVisible(tester, '当前歌曲'), isTrue);
    expect(_isVisible(tester, '下一首歌'), isFalse);
  }, variant: android);

  testWidgets('切歌动画中销毁播放器不会留下旧回调异常', (tester) async {
    final controller = await _buildPlayer(tester);
    final gesture = await _dragTitle(tester, -110);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pumpWidget(const SizedBox.shrink());
    controller.completeRequests();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }, variant: android);

  testWidgets('电台右滑不能预览或播放上一首', (tester) async {
    final controller = await _buildPlayer(tester, radio: true);
    final gesture = await _dragTitle(tester, 110);
    expect(_isVisible(tester, '上一首歌'), isFalse);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.requests, isEmpty);
    expect(_isVisible(tester, '当前歌曲'), isTrue);
  }, variant: android);
}
