import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/l10n/app_locale.dart';
import 'package:mintmusic/core/l10n/l10n.dart';
import 'package:mintmusic/core/theme/theme_provider.dart';
import 'package:mintmusic/features/settings/application/plugin_providers.dart';
import 'package:mintmusic/features/settings/data/plugin_repository.dart';
import 'package:mintmusic/features/settings/domain/models/plugin_info.dart';
import 'package:mintmusic/features/settings/presentation/plugin_management_page.dart';
import 'package:mintmusic/features/plugin/data/plugin_service.dart';

class _MemoryService extends PluginService {
  _MemoryService(this.plugins);

  List<PluginInfo> plugins;
  bool failSave = false;
  Completer<void>? pendingSave;
  int toggleCount = 0;

  @override
  Future<List<PluginInfo>> loadPlugins() async => [...plugins];

  @override
  Future<void> savePlugins(List<PluginInfo> plugins) async {
    await pendingSave?.future;
    if (failSave) throw Exception('排序保存失败');
    this.plugins = [...plugins];
  }

  @override
  Future<void> togglePlugin(String id, bool isEnabled) async {
    toggleCount++;
    plugins = [
      for (final plugin in plugins)
        if (plugin.id == id) plugin.copyWith(isEnabled: isEnabled) else plugin,
    ];
  }
}

class _MemoryRepository extends PluginRepository {
  _MemoryRepository(this.service);

  final _MemoryService service;

  @override
  Future<List<PluginInfo>> loadPlugins() => service.loadPlugins();
}

PluginInfo _plugin(String id, {bool isDataSource = false}) => PluginInfo(
  id: id,
  name: '插件 $id',
  version: '1.0.0',
  author: 'Test',
  installTime: DateTime(2026, 10, 28),
  isDataSource: isDataSource,
);

Future<ProviderContainer> _pumpPage(
  WidgetTester tester,
  _MemoryService service, {
  Size size = const Size(420, 1000),
  bool dark = false,
  bool embedded = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      pluginServiceProvider.overrideWithValue(service),
      pluginRepositoryProvider.overrideWithValue(_MemoryRepository(service)),
      pluginInitializedProvider.overrideWith((ref) async {}),
      themeColorsProvider.overrideWithValue(
        dark ? ThemeColors.dark : ThemeColors.light,
      ),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(service.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: L10n(
        locale: AppLocale.zhCn,
        child: MaterialApp(
          theme: dark ? ThemeData.dark() : ThemeData.light(),
          home: Scaffold(body: PluginManagementPage(embedded: embedded)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Finder _handle(String id) => find.descendant(
  of: find.byKey(ValueKey(id)),
  matching: find.byType(ReorderableDragStartListener),
);

Future<void> _dragDown(
  WidgetTester tester,
  String id, {
  PointerDeviceKind kind = PointerDeviceKind.touch,
}) async {
  final card = find.byKey(ValueKey(id));
  await tester.ensureVisible(_handle(id));
  await tester.pumpAndSettle();
  final height = tester.getSize(card).height;
  final gesture = await tester.startGesture(
    tester.getCenter(_handle(id)),
    kind: kind,
  );
  await gesture.moveBy(const Offset(0, 30));
  await tester.pump();
  for (var step = 0; step < 10; step++) {
    await gesture.moveBy(Offset(0, (height + 20) / 10));
    await tester.pump(const Duration(milliseconds: 30));
  }
  await tester.pump(const Duration(milliseconds: 400));
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('手机触摸拖动数据源，普通插件顺序不变', (tester) async {
    final service = _MemoryService([
      _plugin('d1', isDataSource: true),
      _plugin('n1'),
      _plugin('d2', isDataSource: true),
    ]);
    final container = await _pumpPage(tester, service);

    await _dragDown(tester, 'd1');

    expect(service.plugins.map((plugin) => plugin.id), ['d2', 'n1', 'd1']);
    expect(
      container.read(pluginsProvider).requireValue.map((plugin) => plugin.id),
      ['d2', 'n1', 'd1'],
    );
    expect(service.toggleCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面深色嵌入页可鼠标拖动普通插件，开关仍可点击', (tester) async {
    final service = _MemoryService([_plugin('n1'), _plugin('n2')]);
    await _pumpPage(
      tester,
      service,
      size: const Size(1100, 900),
      dark: true,
      embedded: true,
    );

    await _dragDown(tester, 'n1', kind: PointerDeviceKind.mouse);
    expect(service.plugins.map((plugin) => plugin.id), ['n2', 'n1']);
    final toggle = find.descendant(
      of: find.byKey(const ValueKey('n2')),
      matching: find.byType(Switch),
    );
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(service.plugins.first.isEnabled, isFalse);
    expect(service.toggleCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('排序保存失败提示错误并恢复原顺序', (tester) async {
    final service = _MemoryService([_plugin('n1'), _plugin('n2')])
      ..failSave = true;
    final container = await _pumpPage(tester, service);

    await _dragDown(tester, 'n1');

    expect(service.plugins.map((plugin) => plugin.id), ['n1', 'n2']);
    expect(
      container.read(pluginsProvider).requireValue.map((plugin) => plugin.id),
      ['n1', 'n2'],
    );
    expect(find.textContaining('排序保存失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存过程中暂时禁用拖动手柄，完成后恢复', (tester) async {
    final service = _MemoryService([_plugin('n1'), _plugin('n2')])
      ..pendingSave = Completer<void>();
    await _pumpPage(tester, service);

    await _dragDown(tester, 'n1');
    final handles = tester.widgetList<ReorderableDragStartListener>(
      find.byType(ReorderableDragStartListener),
    );
    expect(handles.every((handle) => !handle.enabled), isTrue);

    service.pendingSave!.complete();
    await tester.pumpAndSettle();
    expect(service.plugins.map((plugin) => plugin.id), ['n2', 'n1']);
    expect(
      tester
          .widgetList<ReorderableDragStartListener>(
            find.byType(ReorderableDragStartListener),
          )
          .every((handle) => handle.enabled),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('空列表和窄屏不显示无效拖动手柄', (tester) async {
    final service = _MemoryService([]);
    await _pumpPage(tester, service, size: const Size(360, 760));

    expect(find.byType(ReorderableDragStartListener), findsNothing);
    expect(find.text('数据源'), findsOneWidget);
    expect(find.text('插件音源（0）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖动到长列表边缘时外层页面自动滚动', (tester) async {
    final service = _MemoryService([
      for (var index = 0; index < 12; index++) _plugin('n$index'),
    ]);
    await _pumpPage(tester, service, size: const Size(420, 800));
    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(_handle('n0'));
    final before = scrollable.position.pixels;
    final gesture = await tester.startGesture(tester.getCenter(_handle('n0')));
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    await gesture.moveTo(const Offset(390, 780));
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(scrollable.position.pixels, greaterThan(before));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(service.plugins.first.id, isNot('n0'));
    expect(tester.takeException(), isNull);
  });
}
