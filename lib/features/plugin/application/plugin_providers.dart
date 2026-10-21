import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/music_source_provider.dart';
import '../domain/plugin_types.dart';
import '../domain/builtin_source_states.dart';
import '../domain/plugin_source_states.dart';
import '../data/plugin_service.dart';
import '../data/netease_music_source.dart';
import '../data/kugou_music_source.dart';
import 'music_source_manager.dart';
import 'plugin_test_service.dart';

final neteaseMusicSourceProvider = Provider<NeteaseMusicSource>((ref) {
  final source = NeteaseMusicSource();
  ref.onDispose(() => source.dispose());
  return source;
});

final kugouMusicSourceProvider = Provider<KugouMusicSource>((ref) {
  final source = KugouMusicSource();
  ref.onDispose(() => source.dispose());
  return source;
});

final musicSourceProvider = Provider<MusicSourceProvider>((ref) {
  return ref.watch(neteaseMusicSourceProvider);
});

final pluginServiceProvider = Provider<PluginService>((ref) {
  final service = PluginService();
  ref.onDispose(() => service.dispose());
  return service;
});

final pluginInitializedProvider = FutureProvider<void>((ref) async {
  final pluginService = ref.watch(pluginServiceProvider);
  final manager = ref.watch(musicSourceManagerProvider);
  print('[PluginProviders] 开始初始化插件系统...');
  // 内置音源的启用 / 卸载状态必须先于任何音源枚举读取。
  await manager.loadBuiltInSourceStates();
  // 插件自带音源的开关同样要先加载，否则插件刚启用时状态还是空的。
  await manager.loadPluginSourceStates();
  await pluginService.initializePlugins();
  print('[PluginProviders] 插件系统初始化完成');
  print('[PluginProviders] 已加载插件数量: ${pluginService.enabledPlugins.length}');
  for (final plugin in pluginService.enabledPlugins) {
    print('[PluginProviders] - 插件: ${plugin.pluginInfo?.name ?? "未知"}');
    print('[PluginProviders]   源数量: ${plugin.sources.length}');
    for (final source in plugin.sources) {
      print('[PluginProviders]     - ${source.name}');
    }
    print('[PluginProviders]   源操作:');
    for (final entry in plugin.sourceActions.entries) {
      print('[PluginProviders]     - ${entry.key}: ${entry.value}');
    }
  }
});

final musicSourceManagerProvider = Provider<MusicSourceManager>((ref) {
  final pluginService = ref.watch(pluginServiceProvider);
  final manager = MusicSourceManager(pluginService);
  ref.onDispose(() => manager.dispose());
  return manager;
});

final pluginTestServiceProvider = Provider<PluginTestService>((ref) {
  return PluginTestService(
    manager: ref.watch(musicSourceManagerProvider),
    pluginService: ref.watch(pluginServiceProvider),
  );
});

final pluginSupportedSourcesProvider = Provider<List<SourceInfo>>((ref) {
  ref.watch(pluginInitializedProvider);

  final manager = ref.watch(musicSourceManagerProvider);
  final sources = manager.getPluginSupportedSources();
  print('[PluginProviders] 获取插件支持的源数量: ${sources.length}');
  for (final source in sources) {
    print('[PluginProviders]   - ${source.id}: ${source.name}');
  }
  return sources;
});

/// 插件管理里第一个启用的音源 id。
///
/// 没有记录时使用第一个可用的内置音源（内置源与插件音源完全独立，默认用
/// 内置源更稳妥；插件音源可以在切换音源里手动选择）。
final firstEnabledSourceIdProvider = Provider<String>((ref) {
  ref.watch(pluginInitializedProvider);
  final manager = ref.watch(musicSourceManagerProvider);
  final builtIns = manager.enabledBuiltInSourceInfos;
  if (builtIns.isNotEmpty) return builtIns.first.id;
  final sources = manager.getPluginSupportedSources();
  if (sources.isNotEmpty) return sources.first.id;
  return 'wy';
});

final searchSupportedSourcesProvider = Provider<List<SourceInfo>>((ref) {
  ref.watch(pluginInitializedProvider);
  // 内置音源的启用 / 卸载状态变化后需要重算音源列表。
  ref.watch(builtInSourceStateProvider);
  // 插件自带音源的开关变化后同样需要重算。
  ref.watch(pluginSourceStateProvider);

  final manager = ref.watch(musicSourceManagerProvider);
  final sources = manager.getSearchSupportedSources();
  print('[PluginProviders] 获取支持搜索的源数量: ${sources.length}');
  for (final source in sources) {
    print('[PluginProviders]   - ${source.id}: ${source.name}');
  }
  return sources;
});

/// 内置音源（网易云 / 酷狗 / 酷我 / QQ / 咪咕）的启用 / 卸载状态。
///
/// 真正的状态保存在 [MusicSourceManager]（它同时被非 UI 代码使用），这里只做
/// 一个 Riverpod 侧的可观察快照：状态变化后刷新依赖它的音源列表。
final builtInSourceStateProvider =
    NotifierProvider<BuiltInSourceStateNotifier, BuiltInSourceStates>(
      BuiltInSourceStateNotifier.new,
    );

class BuiltInSourceStateNotifier extends Notifier<BuiltInSourceStates> {
  @override
  BuiltInSourceStates build() {
    // 初始化完成后才有持久化状态可读；Future 完成时会重新执行 build()。
    ref.watch(pluginInitializedProvider);
    final manager = ref.watch(musicSourceManagerProvider);
    return manager.builtInSourceStates;
  }

  MusicSourceManager get _manager => ref.read(musicSourceManagerProvider);

  Future<void> setEnabled(String sourceId, bool enabled) async {
    await _manager.setBuiltInSourceEnabled(sourceId, enabled);
    _sync();
  }

  Future<void> remove(String sourceId) async {
    await _manager.removeBuiltInSource(sourceId);
    _sync();
  }

  Future<void> restoreAll() async {
    await _manager.restoreBuiltInSources();
    _sync();
  }

  void _sync() {
    // 依赖 builtInSourceStateProvider 的音源列表会自动重算。
    state = _manager.builtInSourceStates;
  }
}

/// 插件自带音源的启用 / 关闭状态。
///
/// 一个插件文件可能同时提供多个音源（落雪脚本常有五六个），用户可以在
/// 插件管理页逐个开关。真正的状态保存在 [MusicSourceManager]，这里只做
/// 一个 Riverpod 侧的可观察快照。
final pluginSourceStateProvider =
    NotifierProvider<PluginSourceStateNotifier, PluginSourceStates>(
  PluginSourceStateNotifier.new,
);

class PluginSourceStateNotifier extends Notifier<PluginSourceStates> {
  @override
  PluginSourceStates build() {
    // 初始化完成后才有持久化状态可读；Future 完成时会重新执行 build()。
    ref.watch(pluginInitializedProvider);
    final manager = ref.watch(musicSourceManagerProvider);
    return manager.pluginSourceStates;
  }

  MusicSourceManager get _manager => ref.read(musicSourceManagerProvider);

  Future<void> setEnabled(
    String pluginId,
    String sourceId,
    bool enabled,
  ) async {
    await _manager.setPluginSourceEnabled(pluginId, sourceId, enabled);
    _sync();
  }

  Future<void> resetPlugin(String pluginId) async {
    await _manager.resetPluginSources(pluginId);
    _sync();
  }

  void _sync() {
    // 依赖 pluginSourceStateProvider 的音源列表会自动重算。
    state = _manager.pluginSourceStates;
  }
}
