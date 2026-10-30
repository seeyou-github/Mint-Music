import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';
import '../domain/plugin_types.dart';
import '../domain/plugin_source_states.dart';
import '../data/plugin_service.dart';
import '../data/source_health_store.dart';
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

/// 登录态变化信号（每次检测完成 +1）。
///
/// 登录态存在插件宿主里（不是 Riverpod 状态），界面靠这个流触发重建，
/// 从而让「已登录 / 未登录」徽标与高音质置灰状态实时更新。
final pluginLoginStateRevisionProvider = StreamProvider<void>((ref) {
  return ref.watch(pluginServiceProvider).loginStateChanges;
});

/// 音源健康状态（「失败 / 超时」红标）变化信号。
///
/// 标记存在 [SourceHealthStore]（内存 + 设置文件），不是 Riverpod 状态；
/// 插件管理页 watch 它来重建卡片。首次订阅时会先触发一次加载：加载完成
/// 前读到的是空标记，加载完成后 store 会再广播一次，界面自动补上。
final pluginSourceHealthRevisionProvider = StreamProvider<int>((ref) async* {
  yield SourceHealthStore.revision;
  unawaited(SourceHealthStore.ensureLoaded());
  yield* SourceHealthStore.changes;
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
  ref.watch(pluginSourceStateProvider);

  final manager = ref.watch(musicSourceManagerProvider);
  final sources = manager.getPluginSupportedSources();
  print('[PluginProviders] 获取插件支持的源数量: ${sources.length}');
  for (final source in sources) {
    print('[PluginProviders]   - ${source.id}: ${source.name}');
  }
  return sources;
});

/// 音源切换按钮里可以列出的音源（主页 / 搜索页 / 歌词搜索 / 在线搜索 /
/// 快速匹配都用它）。
///
/// 落雪（LX）格式插件只解析播放地址：没有歌单与榜单，多数也没有搜索，
/// 列进切换列表里用户选中它只会得到空结果，所以在这些入口统一不显示。
/// 播放地址解析不受影响（按歌曲自己记着的 source 走）。
///
/// 装的全是落雪格式插件时，这里就是空列表（界面显示「一个音源都没有」），
/// 不做「退回完整列表」的兜底——落雪音源本来就不能搜索 / 浏览。
final switchableSourcesProvider = Provider<List<SourceInfo>>((ref) {
  final sources = ref.watch(pluginSupportedSourcesProvider);
  final manager = ref.watch(musicSourceManagerProvider);
  return [
    for (final source in sources)
      if (!manager.isLxFormatSource(source.id)) source,
  ];
});

/// 插件管理里第一个启用的音源 id（跳过落雪格式）。
///
/// 没有任何插件音源时返回空字符串，由调用方提示「请先安装音源」。
final firstEnabledSourceIdProvider = Provider<String>((ref) {
  final sources = ref.watch(switchableSourcesProvider);
  if (sources.isNotEmpty) return sources.first.id;
  return '';
});

final searchSupportedSourcesProvider = Provider<List<SourceInfo>>((ref) {
  ref.watch(pluginSupportedSourcesProvider);

  final manager = ref.watch(musicSourceManagerProvider);
  final sources = [
    for (final source in manager.getSearchSupportedSources())
      if (!manager.isLxFormatSource(source.id)) source,
  ];
  print('[PluginProviders] 获取支持搜索的源数量: ${sources.length}');
  for (final source in sources) {
    print('[PluginProviders]   - ${source.id}: ${source.name}');
  }
  return sources;
});

/// 某个音源是否支持「自定义歌单」（插件声明 customSheets 后由 App 建歌单）。
final sourceSupportsCustomSheetsProvider = Provider.family<bool, String>((
  ref,
  sourceId,
) {
  ref.watch(pluginSupportedSourcesProvider);
  return ref
      .watch(musicSourceManagerProvider)
      .sourceSupportsCustomSheets(sourceId);
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
