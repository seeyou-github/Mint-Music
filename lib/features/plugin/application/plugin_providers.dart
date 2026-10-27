import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/plugin_types.dart';
import '../domain/plugin_source_states.dart';
import '../data/plugin_service.dart';
import 'music_source_manager.dart';
import 'plugin_test_service.dart';

final pluginServiceProvider = Provider<PluginService>((ref) {
  final service = PluginService();
  ref.onDispose(() => service.dispose());
  return service;
});

final pluginInitializedProvider = FutureProvider<void>((ref) async {
  final pluginService = ref.watch(pluginServiceProvider);
  final manager = ref.watch(musicSourceManagerProvider);
  print('[PluginProviders] 开始初始化插件系统...');
  // 插件自带音源的开关要先加载，否则插件刚启用时状态还是空的。
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
/// 没有任何插件音源时返回空字符串，由调用方提示「请先安装音源」。
final firstEnabledSourceIdProvider = Provider<String>((ref) {
  ref.watch(pluginInitializedProvider);
  final manager = ref.watch(musicSourceManagerProvider);
  final sources = manager.getPluginSupportedSources();
  if (sources.isNotEmpty) return sources.first.id;
  return '';
});

final searchSupportedSourcesProvider = Provider<List<SourceInfo>>((ref) {
  ref.watch(pluginInitializedProvider);
  // 插件自带音源的开关变化后需要重算音源列表。
  ref.watch(pluginSourceStateProvider);

  final manager = ref.watch(musicSourceManagerProvider);
  final sources = manager.getSearchSupportedSources();
  print('[PluginProviders] 获取支持搜索的源数量: ${sources.length}');
  for (final source in sources) {
    print('[PluginProviders]   - ${source.id}: ${source.name}');
  }
  return sources;
});

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
