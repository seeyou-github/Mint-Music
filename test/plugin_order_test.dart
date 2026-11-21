import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/discover/application/discover_providers.dart'
    show discoverSupportedSourcesProvider;
import 'package:mintmusic/features/discover/application/search_providers.dart'
    show searchAvailableSourcesProvider;
import 'package:mintmusic/features/plugin/application/music_source_manager.dart';
import 'package:mintmusic/features/plugin/application/plugin_providers.dart';
import 'package:mintmusic/features/plugin/data/plugin_host.dart';
import 'package:mintmusic/features/plugin/data/plugin_service.dart';
import 'package:mintmusic/features/plugin/domain/plugin_types.dart';
import 'package:mintmusic/features/settings/application/plugin_providers.dart'
    show PluginsNotifier, pluginRepositoryProvider, pluginsProvider;
import 'package:mintmusic/features/settings/data/plugin_repository.dart';
import 'package:mintmusic/features/settings/domain/models/plugin_info.dart';

class _MemoryStore {
  _MemoryStore(List<PluginInfo> plugins) : plugins = List.of(plugins);

  List<PluginInfo> plugins;
}

class _Host implements PluginHost {
  _Host(this.record);

  final PluginInfo record;

  @override
  bool get isDataSource => record.isDataSource;

  @override
  PluginMetadata get pluginInfo => PluginMetadata(
    name: record.name,
    version: record.version,
    author: record.author,
    isDataSource: isDataSource,
  );

  @override
  List<PluginSourceInfo> get sources => [
    for (final source in record.supportedSources)
      PluginSourceInfo(
        id: source.id,
        name: source.name,
        qualities: source.qualities,
      ),
  ];

  @override
  Map<String, List<String>> get sourceActions => {
    for (final source in record.supportedSources)
      source.id!: [isDataSource ? 'musicSearch' : 'musicUrl'],
  };

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Real reorder logic and an in-memory toggle boundary; no runtime I/O.
class _MemoryPluginService extends PluginService {
  _MemoryPluginService(this.store)
    : hosts = {for (final plugin in store.plugins) plugin.id: _Host(plugin)};

  final _MemoryStore store;
  final Map<String, _Host> hosts;
  int loadCalls = 0;
  int saveCalls = 0;
  int initializeCalls = 0;
  int toggleCalls = 0;
  Completer<void>? saveStarted;
  Future<void>? saveBarrier;
  Object? saveError;
  Completer<void>? toggleStarted;
  Future<void>? toggleBarrier;
  Object? toggleError;

  @override
  Future<List<PluginInfo>> loadPlugins() async {
    loadCalls++;
    return List.of(store.plugins);
  }

  @override
  Future<void> savePlugins(List<PluginInfo> plugins) async {
    saveCalls++;
    saveStarted?.complete();
    final barrier = saveBarrier;
    if (barrier != null) await barrier;
    final error = saveError;
    if (error != null) throw error;
    store.plugins = List.of(plugins);
  }

  @override
  Future<void> initializePlugins() async {
    initializeCalls++;
  }

  @override
  Future<void> togglePlugin(String id, bool isEnabled) async {
    toggleCalls++;
    toggleStarted?.complete();
    final barrier = toggleBarrier;
    if (barrier != null) await barrier;
    final error = toggleError;
    if (error != null) throw error;
    store.plugins = [
      for (final plugin in store.plugins)
        if (plugin.id == id) plugin.copyWith(isEnabled: isEnabled) else plugin,
    ];
  }

  @override
  List<PluginHost> get enabledPlugins => [
    for (final plugin in store.plugins)
      if (plugin.isEnabled && hosts.containsKey(plugin.id)) hosts[plugin.id]!,
  ];

  @override
  String? getPluginIdForHost(PluginHost host) => (host as _Host).record.id;
}

class _MemoryPluginRepository implements PluginRepository {
  _MemoryPluginRepository(this.store);

  final _MemoryStore store;
  int loadCalls = 0;

  @override
  Future<List<PluginInfo>> loadPlugins() async {
    loadCalls++;
    return List.of(store.plugins);
  }

  @override
  Future<void> savePlugins(List<PluginInfo> plugins) async {
    store.plugins = List.of(plugins);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Keep the real manager and initialization provider, but never load preferences.
class _MemorySourceManager extends MusicSourceManager {
  _MemorySourceManager(super.pluginService);

  int loadSourceStateCalls = 0;

  @override
  Future<void> loadPluginSourceStates() async {
    loadSourceStateCalls++;
  }
}

class _Harness {
  _Harness(this.store)
    : service = _MemoryPluginService(store),
      repository = _MemoryPluginRepository(store) {
    manager = _MemorySourceManager(service);
    container = ProviderContainer(
      overrides: [
        pluginServiceProvider.overrideWithValue(service),
        musicSourceManagerProvider.overrideWithValue(manager),
        pluginRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(() {
      container.dispose();
      manager.dispose();
      service.dispose();
    });
  }

  final _MemoryStore store;
  final _MemoryPluginService service;
  final _MemoryPluginRepository repository;
  late final _MemorySourceManager manager;
  late final ProviderContainer container;

  Future<PluginsNotifier> ready() async {
    await container.read(pluginsProvider.future);
    await container.pump();
    return container.read(pluginsProvider.notifier);
  }

  List<PluginInfo> get state => container.read(pluginsProvider).requireValue;
}

PluginInfo _plugin(
  String id, {
  bool isDataSource = false,
  bool isEnabled = true,
}) => PluginInfo(
  id: id,
  // Deliberately identical metadata: only the plugin ID distinguishes sources.
  name: '同平台插件',
  version: '1.2.3',
  author: '同名作者',
  description: 'metadata for $id',
  type: isDataSource ? 'mf' : 'lx',
  isEnabled: isEnabled,
  installTime: DateTime.utc(2026, 1, 2, 3, 4, 5),
  supportedSources: const [
    PluginSource(id: 'wy', name: '网易云音乐', qualities: ['128k', 'flac']),
  ],
  // Metadata only: none of these paths or URLs may be accessed by the fakes.
  filePath: 'memory://plugins/$id.js',
  updateUrl: 'https://example.invalid/$id.js',
  iconUrl: 'https://example.invalid/$id.png',
  iconPath: 'memory://icons/$id.png',
  isDataSource: isDataSource,
);

List<PluginInfo> _mixedPlugins() => [
  _plugin('n1'),
  _plugin('d1', isDataSource: true),
  _plugin('n2'),
  _plugin('d2', isDataSource: true),
  _plugin('n3'),
  _plugin('d3', isDataSource: true),
];

List<String> _ids(Iterable<PluginInfo> plugins) =>
    plugins.map((plugin) => plugin.id).toList();

List<String> _sourceIds(Iterable<SourceInfo> sources) =>
    sources.map((source) => source.id).toList();

final _menuProviders = [
  pluginSupportedSourcesProvider,
  discoverSupportedSourcesProvider,
  searchSupportedSourcesProvider,
  searchAvailableSourcesProvider,
];

List<List<SourceInfo>> _menus(ProviderContainer container) => [
  for (final provider in _menuProviders) container.read(provider),
];

const _initialMenuIds = ['wy@d1', 'wy@d2', 'wy@d3', 'wy@n1', 'wy@n2', 'wy@n3'];

void main() {
  group('MusicSourceManager source order', () {
    test('stable data-source partition preserves same-platform unique IDs', () {
      final plugins = _mixedPlugins();
      final store = _MemoryStore([
        plugins[4],
        plugins[5],
        _plugin('disabled-data', isDataSource: true, isEnabled: false),
        plugins[0],
        plugins[1],
        _plugin('disabled-normal', isEnabled: false),
        plugins[2],
        plugins[3],
      ]);
      final harness = _Harness(store);
      final before = List.of(store.plugins);
      const expected = ['wy@d3', 'wy@d1', 'wy@d2', 'wy@n3', 'wy@n1', 'wy@n2'];

      for (var repeat = 0; repeat < 2; repeat++) {
        final sources = harness.manager.getPluginSupportedSources();
        expect(_sourceIds(sources), expected);
        expect(sources.map((source) => source.id).toSet(), hasLength(6));
        expect(sources.map((source) => source.name), [
          '网易云音乐（数据源）',
          '网易云音乐（数据源）',
          '网易云音乐（数据源）',
          '网易云音乐',
          '网易云音乐',
          '网易云音乐',
        ]);
        expect(
          _sourceIds(harness.manager.getDiscoverSupportedSources()),
          expected,
        );
        expect(
          _sourceIds(harness.manager.getSearchSupportedSources()),
          expected,
        );
      }
      expect(
        store.plugins,
        before,
        reason: 'Menu grouping must not mutate storage',
      );
      expect(harness.service.saveCalls, 0);
      expect(harness.service.initializeCalls, 0);
      expect(harness.manager.loadSourceStateCalls, 0);
    });

    test(
      'multi-source plugins keep their declared source order within groups',
      () {
        final multi = _plugin('multi', isDataSource: true).copyWith(
          supportedSources: const [
            PluginSource(id: 'tx', name: 'QQ音乐', qualities: ['320k']),
            PluginSource(id: 'wy', name: '网易云音乐', qualities: ['flac']),
          ],
        );
        final harness = _Harness(
          _MemoryStore([
            _plugin('normal'),
            multi,
            _plugin('data', isDataSource: true),
          ]),
        );
        final sources = harness.manager.getPluginSupportedSources();
        expect(_sourceIds(sources), [
          'tx@multi',
          'wy@multi',
          'wy@data',
          'wy@normal',
        ]);
        expect(sources.take(2).map((source) => source.name), [
          'QQ音乐-同平台插件（数据源）',
          '网易云音乐-同平台插件（数据源）',
        ]);
      },
    );
  });

  group('PluginService.reorderPlugins (real method, memory storage)', () {
    test(
      'uses latest records, skips missing/duplicate IDs, keeps new metadata',
      () async {
        final old = [
          _plugin('n1'),
          _plugin('d1', isDataSource: true),
          _plugin('deleted'),
        ];
        final store = _MemoryStore(old);
        final service = _MemoryPluginService(store);
        addTearDown(service.dispose);
        final updated = old.first.copyWith(
          version: '2.0.0',
          isEnabled: false,
          description: 'metadata changed after management page loaded',
          iconPath: 'memory://icons/new.png',
        );
        final addedFirst = _plugin('added-first', isDataSource: true);
        final addedLast = _plugin('added-last', isEnabled: false);
        store.plugins = [updated, addedFirst, old[1], addedLast];
        final latest = {for (final plugin in store.plugins) plugin.id: plugin};
        final metadata = {
          for (final plugin in store.plugins) plugin.id: plugin.toJson(),
        };
        final orderedIds = ['d1', 'deleted', 'd1', 'n1', 'missing', 'n1'];
        final inputBefore = List.of(orderedIds);

        final saved = await service.reorderPlugins(orderedIds);

        expect(_ids(saved), ['d1', 'n1', 'added-first', 'added-last']);
        expect(_ids(store.plugins), _ids(saved));
        expect(orderedIds, inputBefore);
        expect(_ids(old), ['n1', 'd1', 'deleted']);
        for (final plugin in saved) {
          expect(plugin, same(latest[plugin.id]));
          expect(plugin.toJson(), metadata[plugin.id]);
        }
        expect(service.loadCalls, 1);
        expect(service.saveCalls, 1);
        expect(service.initializeCalls, 0);
      },
    );

    for (final requested in <List<String>>[
      [],
      ['deleted', 'deleted'],
    ]) {
      test(
        'keeps all current records when requested IDs are $requested',
        () async {
          final before = _mixedPlugins();
          final store = _MemoryStore(before);
          final service = _MemoryPluginService(store);
          addTearDown(service.dispose);

          expect(await service.reorderPlugins(requested), before);
          expect(store.plugins, before);
          expect(service.saveCalls, 1);
          expect(service.initializeCalls, 0);
        },
      );
    }

    test('propagates save failure without changing stored records', () async {
      final store = _MemoryStore(_mixedPlugins());
      final service = _MemoryPluginService(store);
      addTearDown(service.dispose);
      final before = store.plugins;
      final failure = StateError('save failed');
      service.saveError = failure;

      await expectLater(
        service.reorderPlugins(_ids(before.reversed)),
        throwsA(same(failure)),
      );
      expect(store.plugins, same(before));
      expect(service.loadCalls, 1);
      expect(service.saveCalls, 1);
      expect(service.initializeCalls, 0);
    });
  });

  group('PluginsNotifier group reorder', () {
    for (final isDataSource in [true, false]) {
      final groupName = isDataSource ? 'data sources' : 'normal plugins';
      for (final move in [
        (name: 'up', oldIndex: 2, newIndex: 0, order: [3, 1, 2]),
        (name: 'down', oldIndex: 0, newIndex: 2, order: [2, 1, 3]),
        (name: 'to end', oldIndex: 0, newIndex: 3, order: [2, 3, 1]),
      ]) {
        test(
          '$groupName move ${move.name} only replaces own group slots',
          () async {
            final harness = _Harness(_MemoryStore(_mixedPlugins()));
            final notifier = await harness.ready();
            final before = harness.state;
            final prefix = isDataSource ? 'd' : 'n';
            final moved = move.order.map((index) => '$prefix$index').toList();
            final expected = isDataSource
                ? ['n1', moved[0], 'n2', moved[1], 'n3', moved[2]]
                : [moved[0], 'd1', moved[1], 'd2', moved[2], 'd3'];

            await notifier.reorderPlugins(
              isDataSource: isDataSource,
              oldIndex: move.oldIndex,
              newIndex: move.newIndex,
            );

            expect(_ids(harness.state), expected);
            expect(_ids(harness.store.plugins), expected);
            expect(_ids(before), ['n1', 'd1', 'n2', 'd2', 'n3', 'd3']);
            for (var index = 0; index < before.length; index++) {
              if (before[index].isDataSource != isDataSource) {
                expect(harness.state[index], same(before[index]));
              }
            }
            expect(harness.service.loadCalls, 1);
            expect(harness.service.saveCalls, 1);
            expect(harness.service.initializeCalls, 1);
          },
        );
      }

      test(
        '$groupName no-op drops do not load/save or invalidate menus',
        () async {
          final harness = _Harness(_MemoryStore(_mixedPlugins()));
          final notifier = await harness.ready();
          final before = harness.state;
          final menusBefore = _menus(harness.container);

          for (final (oldIndex, newIndex) in [(0, 0), (1, 1), (1, 2), (2, 3)]) {
            await notifier.reorderPlugins(
              isDataSource: isDataSource,
              oldIndex: oldIndex,
              newIndex: newIndex,
            );
            await harness.container.pump();
            expect(harness.state, same(before));
            final menusAfter = _menus(harness.container);
            for (var index = 0; index < menusBefore.length; index++) {
              expect(menusAfter[index], same(menusBefore[index]));
            }
          }
          expect(harness.service.loadCalls, 0);
          expect(harness.service.saveCalls, 0);
          expect(harness.service.initializeCalls, 1);
        },
      );

      test(
        '$groupName save failure rolls optimistic state back without menu refresh',
        () async {
          final harness = _Harness(_MemoryStore(_mixedPlugins()));
          final notifier = await harness.ready();
          final before = harness.state;
          final storedBefore = harness.store.plugins;
          final menusBefore = _menus(harness.container);
          final expected = isDataSource
              ? ['n1', 'd2', 'n2', 'd3', 'n3', 'd1']
              : ['n2', 'd1', 'n3', 'd2', 'n1', 'd3'];
          final gate = Completer<void>();
          final started = Completer<void>();
          final failure = StateError('save failed');
          harness.service
            ..saveBarrier = gate.future
            ..saveStarted = started
            ..saveError = failure;
          final observed = <List<String>>[];
          harness.container.listen(pluginsProvider, (_, next) {
            if (next.hasValue) observed.add(_ids(next.requireValue));
          });

          final pending = notifier.reorderPlugins(
            isDataSource: isDataSource,
            oldIndex: 0,
            newIndex: 3,
          );
          final failed = expectLater(pending, throwsA(same(failure)));
          expect(
            _ids(harness.state),
            expected,
            reason: 'State updates before saving',
          );
          await started.future;
          expect(harness.store.plugins, same(storedBefore));
          gate.complete();
          await failed;
          await harness.container.pump();

          expect(harness.state, same(before));
          expect(harness.container.read(pluginsProvider).hasError, isFalse);
          expect(observed, [expected, _ids(before)]);
          expect(harness.store.plugins, same(storedBefore));
          final menusAfter = _menus(harness.container);
          for (var index = 0; index < menusBefore.length; index++) {
            expect(menusAfter[index], same(menusBefore[index]));
          }
          expect(harness.service.saveCalls, 1);
          expect(harness.service.initializeCalls, 1);
          expect(harness.manager.loadSourceStateCalls, 1);
        },
      );
    }

    test('disabled plugins still move inside their own group', () async {
      final plugins = _mixedPlugins();
      plugins[3] = plugins[3].copyWith(isEnabled: false);
      final harness = _Harness(_MemoryStore(plugins));
      final notifier = await harness.ready();

      await notifier.reorderPlugins(
        isDataSource: true,
        oldIndex: 1,
        newIndex: 0,
      );

      expect(_ids(harness.state), ['n1', 'd2', 'n2', 'd1', 'n3', 'd3']);
      expect(harness.state[1].isEnabled, isFalse);
      expect(harness.state[1].toJson(), plugins[3].toJson());
      expect(_sourceIds(harness.manager.getPluginSupportedSources()), [
        'wy@d1',
        'wy@d3',
        'wy@n1',
        'wy@n2',
        'wy@n3',
      ]);
    });

    test(
      'saved state reconciles newer metadata, removals and additions',
      () async {
        final harness = _Harness(_MemoryStore(_mixedPlugins()));
        final notifier = await harness.ready();
        final updated = harness.store.plugins[3].copyWith(
          version: '9.0.0',
          isEnabled: false,
        );
        final added = _plugin('new');
        harness.store.plugins = [
          harness.store.plugins[0],
          harness.store.plugins[1],
          harness.store.plugins[2],
          updated,
          harness.store.plugins[5],
          added,
        ];

        await notifier.reorderPlugins(
          isDataSource: true,
          oldIndex: 2,
          newIndex: 0,
        );

        expect(_ids(harness.state), ['n1', 'd3', 'n2', 'd1', 'd2', 'new']);
        expect(harness.state[4], same(updated));
        expect(harness.state.last, same(added));
        expect(harness.state, harness.store.plugins);
      },
    );

    test(
      'a new notifier and service read both saved group orders from repository',
      () async {
        final store = _MemoryStore(_mixedPlugins());
        final first = _Harness(store);
        final firstNotifier = await first.ready();
        await firstNotifier.reorderPlugins(
          isDataSource: true,
          oldIndex: 0,
          newIndex: 3,
        );
        await firstNotifier.reorderPlugins(
          isDataSource: false,
          oldIndex: 2,
          newIndex: 0,
        );
        const expected = ['n3', 'd2', 'n1', 'd3', 'n2', 'd1'];
        expect(_ids(store.plugins), expected);

        final second = _Harness(store);
        final secondNotifier = await second.ready();

        expect(secondNotifier, isNot(same(firstNotifier)));
        expect(second.service, isNot(same(first.service)));
        expect(_ids(second.state), expected);
        expect(
          second.state.map((plugin) => plugin.toJson()),
          first.state.map((plugin) => plugin.toJson()),
        );
        expect(second.repository.loadCalls, 1);
        expect(second.service.saveCalls, 0);
        for (final sources in _menus(second.container)) {
          expect(_sourceIds(sources), [
            'wy@d2',
            'wy@d3',
            'wy@d1',
            'wy@n3',
            'wy@n1',
            'wy@n2',
          ]);
        }
      },
    );
  });

  group('PluginsNotifier toggle without reinitialization', () {
    for (final target in ['d2', 'n2']) {
      for (final isEnabled in [false, true]) {
        final action = isEnabled ? 'enable' : 'disable';
        final plugins = _mixedPlugins().map((plugin) {
          return plugin.copyWith(
            isEnabled: plugin.id == target ? !isEnabled : plugin.id != 'd3',
          );
        }).toList();
        final menuWithTarget = _initialMenuIds
            .where((id) => id != 'wy@d3')
            .toList();
        final menuWithoutTarget = menuWithTarget
            .where((id) => id != 'wy@$target')
            .toList();
        final initialMenu = isEnabled ? menuWithoutTarget : menuWithTarget;
        final expectedMenu = isEnabled ? menuWithTarget : menuWithoutTarget;
        final expectedRecords = plugins.map((plugin) {
          return (plugin.id == target
                  ? plugin.copyWith(isEnabled: isEnabled)
                  : plugin)
              .toJson();
        }).toList();

        test(
          '$action $target keeps AsyncData and refreshes source menus',
          () async {
            final harness = _Harness(_MemoryStore(plugins));
            final notifier = await harness.ready();
            final storedBefore = harness.store.plugins;
            final originalHosts = Map.of(harness.service.hosts);
            final initialization = harness.container.read(
              pluginInitializedProvider.future,
            );
            final states = <AsyncValue<List<PluginInfo>>>[];
            harness.container.listen(
              pluginsProvider,
              (_, next) => states.add(next),
            );
            final menus = [for (final _ in _menuProviders) <List<String>>[]];
            for (var index = 0; index < _menuProviders.length; index++) {
              final events = menus[index];
              harness.container.listen(
                _menuProviders[index],
                (_, sources) => events.add(_sourceIds(sources)),
                fireImmediately: true,
              );
            }
            expect(menus, everyElement([initialMenu]));
            final gate = Completer<void>();
            final started = Completer<void>();
            harness.service
              ..toggleBarrier = gate.future
              ..toggleStarted = started;

            final pending = notifier.togglePlugin(target, isEnabled);
            expect(
              harness.state.map((plugin) => plugin.toJson()),
              expectedRecords,
              reason:
                  'Only the target flag changes before the service completes',
            );
            await started.future;
            await harness.container.pump();
            expect(harness.store.plugins, same(storedBefore));
            expect(menus, everyElement([initialMenu]));
            expect(states, hasLength(1));
            expect(harness.service.initializeCalls, 1);
            expect(harness.repository.loadCalls, 1);

            gate.complete();
            await pending;
            await harness.container.pump();

            expect(
              harness.state.map((plugin) => plugin.toJson()),
              expectedRecords,
            );
            expect(
              harness.store.plugins.map((plugin) => plugin.toJson()),
              expectedRecords,
            );
            expect(_ids(harness.state), _ids(plugins));
            for (var index = 0; index < plugins.length; index++) {
              expect(harness.state[index], same(harness.store.plugins[index]));
              if (plugins[index].id != target) {
                expect(harness.store.plugins[index], same(storedBefore[index]));
              }
            }
            expect(states, hasLength(2));
            expect(states, everyElement(isA<AsyncData<List<PluginInfo>>>()));
            expect(
              states.map((state) => state.isLoading),
              everyElement(isFalse),
            );
            expect(menus, everyElement([initialMenu, expectedMenu]));
            for (final sources in _menus(harness.container)) {
              expect(_sourceIds(sources), expectedMenu);
            }
            expect(harness.service.toggleCalls, 1);
            expect(harness.service.initializeCalls, 1);
            expect(harness.manager.loadSourceStateCalls, 1);
            expect(harness.repository.loadCalls, 2);
            expect(
              harness.container.read(pluginInitializedProvider.future),
              same(initialization),
            );
            expect(
              harness.container.read(pluginsProvider.notifier),
              same(notifier),
            );
            expect(
              harness.service.enabledPlugins.map(
                harness.service.getPluginIdForHost,
              ),
              plugins
                  .where(
                    (plugin) =>
                        plugin.id == target ? isEnabled : plugin.isEnabled,
                  )
                  .map((plugin) => plugin.id),
            );
            for (final host in harness.service.enabledPlugins) {
              expect(
                host,
                same(originalHosts[harness.service.getPluginIdForHost(host)]),
              );
            }
          },
        );

        test(
          '$action $target failure rolls back without affecting other plugins',
          () async {
            final harness = _Harness(_MemoryStore(plugins));
            final notifier = await harness.ready();
            final before = harness.state;
            final storedBefore = harness.store.plugins;
            final enabledBefore = harness.service.enabledPlugins;
            final menusBefore = _menus(harness.container);
            for (final sources in menusBefore) {
              expect(_sourceIds(sources), initialMenu);
            }
            final states = <AsyncValue<List<PluginInfo>>>[];
            harness.container.listen(
              pluginsProvider,
              (_, next) => states.add(next),
            );
            final menus = [for (final _ in _menuProviders) <List<String>>[]];
            for (var index = 0; index < _menuProviders.length; index++) {
              final events = menus[index];
              harness.container.listen(
                _menuProviders[index],
                (_, sources) => events.add(_sourceIds(sources)),
                fireImmediately: true,
              );
            }
            final gate = Completer<void>();
            final started = Completer<void>();
            final failure = StateError('toggle failed');
            harness.service
              ..toggleBarrier = gate.future
              ..toggleStarted = started
              ..toggleError = failure;

            final pending = notifier.togglePlugin(target, isEnabled);
            final failed = expectLater(pending, throwsA(same(failure)));
            expect(
              harness.state.map((plugin) => plugin.toJson()),
              expectedRecords,
            );
            await started.future;
            await harness.container.pump();
            expect(harness.store.plugins, same(storedBefore));
            expect(menus, everyElement([initialMenu]));
            expect(states, hasLength(1));

            gate.complete();
            await failed;
            await harness.container.pump();

            expect(harness.state, same(before));
            expect(harness.store.plugins, same(storedBefore));
            expect(harness.service.enabledPlugins, enabledBefore);
            expect(_ids(harness.state), _ids(plugins));
            expect(states, hasLength(2));
            expect(states.last.requireValue, same(before));
            expect(states, everyElement(isA<AsyncData<List<PluginInfo>>>()));
            expect(
              states.map((state) => state.isLoading),
              everyElement(isFalse),
            );
            expect(menus, everyElement([initialMenu]));
            final menusAfter = _menus(harness.container);
            for (var index = 0; index < menusBefore.length; index++) {
              expect(menusAfter[index], same(menusBefore[index]));
              expect(_sourceIds(menusAfter[index]), initialMenu);
            }
            expect(harness.service.toggleCalls, 1);
            expect(harness.service.initializeCalls, 1);
            expect(harness.manager.loadSourceStateCalls, 1);
            expect(harness.repository.loadCalls, 1);
            expect(
              harness.container.read(pluginsProvider.notifier),
              same(notifier),
            );
          },
        );
      }
    }
  });

  group('menu provider reorder propagation', () {
    for (final isDataSource in [true, false]) {
      test(
        '${isDataSource ? 'data' : 'normal'} reorder refreshes all menus only after save, without initialization',
        () async {
          final harness = _Harness(_MemoryStore(_mixedPlugins()));
          final notifier = await harness.ready();
          final before = harness.state;
          final originalHosts = Map.of(harness.service.hosts);
          final observed = [for (final _ in _menuProviders) <List<String>>[]];
          for (var index = 0; index < _menuProviders.length; index++) {
            final events = observed[index];
            harness.container.listen(
              _menuProviders[index],
              (_, sources) => events.add(_sourceIds(sources)),
              fireImmediately: true,
            );
          }
          expect(observed, everyElement([_initialMenuIds]));
          final gate = Completer<void>();
          final started = Completer<void>();
          harness.service
            ..saveBarrier = gate.future
            ..saveStarted = started;

          final pending = notifier.reorderPlugins(
            isDataSource: isDataSource,
            oldIndex: 0,
            newIndex: 3,
          );
          await started.future;
          await harness.container.pump();
          expect(
            _ids(harness.state),
            isDataSource
                ? ['n1', 'd2', 'n2', 'd3', 'n3', 'd1']
                : ['n2', 'd1', 'n3', 'd2', 'n1', 'd3'],
          );
          expect(harness.store.plugins, before);
          expect(observed, everyElement([_initialMenuIds]));
          for (final sources in _menus(harness.container)) {
            expect(_sourceIds(sources), _initialMenuIds);
          }

          gate.complete();
          await pending;
          await harness.container.pump();

          final expected = isDataSource
              ? ['wy@d2', 'wy@d3', 'wy@d1', 'wy@n1', 'wy@n2', 'wy@n3']
              : ['wy@d1', 'wy@d2', 'wy@d3', 'wy@n2', 'wy@n3', 'wy@n1'];
          expect(observed, everyElement([_initialMenuIds, expected]));
          for (final sources in _menus(harness.container)) {
            expect(_sourceIds(sources), expected);
          }
          expect(
            harness.container.read(firstEnabledSourceIdProvider),
            expected.first,
          );
          expect(harness.service.saveCalls, 1);
          expect(
            harness.service.initializeCalls,
            1,
            reason: 'Reorder must not invalidate pluginInitializedProvider',
          );
          expect(harness.manager.loadSourceStateCalls, 1);
          expect(harness.repository.loadCalls, 1);
          expect(
            harness.container.read(musicSourceManagerProvider),
            same(harness.manager),
          );
          for (final host in harness.service.enabledPlugins) {
            expect(
              host,
              same(originalHosts[harness.service.getPluginIdForHost(host)]),
            );
          }
        },
      );
    }
  });
}
