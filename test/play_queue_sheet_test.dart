import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/l10n/app_locale.dart';
import 'package:mintmusic/core/l10n/l10n.dart';
import 'package:mintmusic/features/blacklist/application/blacklist_providers.dart';
import 'package:mintmusic/features/player/application/playback_controller.dart';
import 'package:mintmusic/features/player/domain/models/playback_state.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';
import 'package:mintmusic/features/player/presentation/widgets/play_queue_sheet.dart';
import 'package:mintmusic/shared/services/cache_paths.dart';

class _QueueController extends StateNotifier<PlaybackState>
    implements PlaybackController {
  _QueueController(super.state);

  @override
  PlaybackState get playbackState => state;

  void selectSong(int index) {
    state = state.copyWith(
      currentIndex: index,
      currentSong: state.queue[index],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _EmptyBlacklist extends BlacklistNotifier {
  @override
  BlacklistData build() => const BlacklistData();
}

Future<_QueueController> _openQueue(
  WidgetTester tester, {
  required int index,
  int count = 54,
  Size size = const Size(1120, 720),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final queue = List.generate(
    count,
    (i) => Song(
      id: 'queue-test-$i',
      title: '歌曲 ${i + 1}',
      artist: '歌手',
      album: '专辑',
      duration: 180,
    ),
  );
  final controller = _QueueController(
    PlaybackState(
      queue: queue,
      currentIndex: index,
      currentSong: index < 0 ? null : queue[index],
    ),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playbackControllerProvider.overrideWith((ref) => controller),
        blacklistProvider.overrideWith(_EmptyBlacklist.new),
      ],
      child: L10n(
        locale: AppLocale.zhCn,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              padding: const EdgeInsets.only(top: 24, bottom: 20),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => unawaited(
                  showPlayQueueSheet(
                    context,
                    playbackState: controller.playbackState,
                    controller: controller,
                  ),
                ),
                child: const Text('打开队列'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开队列'));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  addTearDown(() async {
    PlayQueueSheetController.hideIfVisible();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });
  return controller;
}

void _expectCurrentSongPosition(
  WidgetTester tester,
  int index, {
  bool centered = true,
}) {
  final list = find.byType(ListView);
  final listRect = tester.getRect(list);
  final tile = find.ancestor(
    of: find.text('歌曲 ${index + 1}'),
    matching: find.byType(ListTile),
  );
  expect(tile, findsOneWidget);
  final tileRect = tester.getRect(tile);
  expect(tileRect.top, greaterThanOrEqualTo(listRect.top - 0.01));
  expect(tileRect.bottom, lessThanOrEqualTo(listRect.bottom + 0.01));
  expect(
    find.descendant(of: tile, matching: find.byIcon(Icons.volume_up)),
    findsOneWidget,
  );
  if (centered) {
    expect(tileRect.center.dy, closeTo(listRect.center.dy, 0.01));
  }
}

void main() {
  late Directory cacheDirectory;
  String? previousCacheRoot;
  setUpAll(() async {
    previousCacheRoot = CachePaths.root;
    cacheDirectory = await Directory.systemTemp.createTemp('queue_sheet_test_');
    CachePaths.configure(cacheDirectory.path);
  });
  tearDownAll(() async {
    CachePaths.configure(previousCacheRoot);
    await cacheDirectory.delete(recursive: true);
  });

  for (final size in [const Size(1120, 720), const Size(400, 800)]) {
    testWidgets('打开54首队列时第31首居中：$size', (tester) async {
      await _openQueue(tester, index: 30, size: size);
      _expectCurrentSongPosition(tester, 30);
    });
  }

  testWidgets('低矮窗口和放大文字下第32首仍居中', (tester) async {
    await _openQueue(
      tester,
      index: 31,
      size: const Size(1120, 450),
      textScale: 1.3,
    );
    _expectCurrentSongPosition(tester, 31);
  });

  for (final index in [0, 1, 52, 53]) {
    testWidgets('队列首尾第${index + 1}首保持可见且自然限位', (tester) async {
      await _openQueue(tester, index: index);
      _expectCurrentSongPosition(tester, index, centered: false);
      final controller = tester
          .widget<ListView>(find.byType(ListView))
          .controller!;
      expect(
        controller.offset,
        index < 2
            ? controller.position.minScrollExtent
            : controller.position.maxScrollExtent,
      );
    });
  }

  testWidgets('不足一屏的队列不强制居中或产生额外滚动', (tester) async {
    await _openQueue(tester, index: 1, count: 3);
    _expectCurrentSongPosition(tester, 1, centered: false);
    final controller = tester
        .widget<ListView>(find.byType(ListView))
        .controller!;
    expect(controller.offset, 0);
    expect(controller.position.maxScrollExtent, 0);
  });

  testWidgets('手动定位、外部切歌和重新打开均定位到当前歌曲中部', (tester) async {
    final controller = await _openQueue(tester, index: 30);
    final scroll = tester.widget<ListView>(find.byType(ListView)).controller!;
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.my_location));
    await tester.pumpAndSettle();
    _expectCurrentSongPosition(tester, 30);

    controller.selectSong(45);
    await tester.pumpAndSettle();
    _expectCurrentSongPosition(tester, 45);

    PlayQueueSheetController.hideIfVisible();
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开队列'));
    await tester.pumpAndSettle();
    _expectCurrentSongPosition(tester, 45);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空队列不触发定位', (tester) async {
    await _openQueue(tester, index: -1, count: 0);
    expect(find.text('播放队列为空'), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
    expect(find.byIcon(Icons.my_location), findsNothing);
  });
}
