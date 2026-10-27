import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/plugin_repository.dart';
import '../domain/models/plugin_info.dart';
import '../../plugin/application/plugin_providers.dart';
import '../../plugin/data/plugin_service.dart' show PluginTypeUnknownException;

export '../../plugin/application/plugin_providers.dart'
    show
        musicSourceManagerProvider,
        pluginServiceProvider,
        pluginInitializedProvider,
        pluginSourceStateProvider;

final pluginRepositoryProvider = Provider<PluginRepository>((ref) {
  return PluginRepository();
});

final pluginsProvider =
    AsyncNotifierProvider<PluginsNotifier, List<PluginInfo>>(
      PluginsNotifier.new,
    );

/// 插件图标的本地缓存路径（按插件 id 查）。
///
/// 图标在导入插件时下载并转成 PNG 缓存到插件目录的 `icons` 子目录
/// （站点 favicon 多是 .ico，Flutter 解不了，缓存前先转成 PNG）。
/// 文件不存在时返回 null，界面退回默认的平台圆标。
final pluginIconPathProvider = Provider.family<String?, String>((
  ref,
  pluginId,
) {
  final plugins = ref.watch(pluginsProvider).valueOrNull;
  if (plugins == null) return null;
  for (final plugin in plugins) {
    if (plugin.id != pluginId) continue;
    final path = plugin.iconPath;
    if (path == null || path.isEmpty) return null;
    return File(path).existsSync() ? path : null;
  }
  return null;
});

/// Holds the results of the latest plugin update check.
final pluginUpdateResultsProvider = StateProvider<List<PluginUpdateResult>>(
  (ref) => [],
);

/// Holds plugin-initiated update notices (from `lx.send('updateAlert', ...)`).
/// Each entry contains: pluginName, pluginVersion, pluginId, data (with log and updateUrl).
final pluginScriptUpdateNoticesProvider =
    StateProvider<List<Map<String, dynamic>>>((ref) => []);

class PluginsNotifier extends AsyncNotifier<List<PluginInfo>> {
  @override
  Future<List<PluginInfo>> build() async {
    // 等插件初始化完成再读列表：初始化时会补齐插件元数据（iconUrl）并下载
    // 图标缓存（iconPath），早于它读取会拿到没有图标的旧数据，
    // 界面上就表现为「插件都装了但一个图标都没有」。
    try {
      await ref.watch(pluginInitializedProvider.future);
    } catch (_) {
      // 初始化失败也要能打开插件管理页（至少能看列表 / 卸载）。
    }
    final repo = ref.read(pluginRepositoryProvider);
    return repo.loadPlugins();
  }

  /// 通过文件选择器添加插件；[type] 为 null 时自动识别类型。
  ///
  /// 识别失败抛出 [PluginTypeUnknownException]；用户在界面选好类型后调
  /// `resume` 续装，这里把 resume 包了一层，续装成功同样会刷新插件列表。
  Future<PluginInfo> selectAndAddPlugin({String? type}) async {
    final pluginService = ref.read(pluginServiceProvider);
    try {
      final plugin = await pluginService.selectAndAddPlugin(type: type);
      _afterPluginInstalled();
      return plugin;
    } on PluginTypeUnknownException catch (e) {
      throw PluginTypeUnknownException((chosen) async {
        final plugin = await e.resume(chosen);
        _afterPluginInstalled();
        return plugin;
      });
    }
  }

  /// 从 URL 下载并安装插件；[type] 为 null 时自动识别类型。
  Future<PluginInfo> downloadAndAddPlugin(String url, {String? type}) async {
    final pluginService = ref.read(pluginServiceProvider);
    try {
      final plugin = await pluginService.downloadAndAddPlugin(url, type: type);
      _afterPluginInstalled();
      return plugin;
    } on PluginTypeUnknownException catch (e) {
      throw PluginTypeUnknownException((chosen) async {
        final plugin = await e.resume(chosen);
        _afterPluginInstalled();
        return plugin;
      });
    }
  }

  void _afterPluginInstalled() {
    // 安装完成后刷新音源与插件列表：pluginInitializedProvider 重建会重新
    // 初始化**全部**插件引擎（每个都要建 JS 引擎并评估适配器 + 插件代码），
    // 全在 UI 主线程上。立即刷新会和添加插件弹框的关闭动画撞在一起导致
    // 掉帧，等动画播完再刷新。
    Future.delayed(const Duration(milliseconds: 350), () {
      try {
        ref.invalidate(pluginInitializedProvider);
        ref.invalidateSelf();
      } catch (_) {
        // notifier 已被其它操作重建（如连续安装）：新实例会自行读取
        // 最新的插件列表，这里无需再刷。
      }
    });
  }

  Future<void> uninstallPlugin(String id) async {
    final pluginService = ref.read(pluginServiceProvider);
    await pluginService.uninstallPlugin(id);
    ref.invalidate(pluginInitializedProvider);
    ref.invalidateSelf();
  }

  Future<void> togglePlugin(String id, bool isEnabled) async {
    final previousPlugins = state.asData?.value;
    if (previousPlugins != null) {
      // Update the settings page before the plugin engine is initialized.
      // The actual runtime switch and persistence continue below.
      // 多个插件可以同时启用：只翻转目标插件，其它插件保持原状态。
      final optimisticPlugins = previousPlugins.map((plugin) {
        final nextIsEnabled = plugin.id == id ? isEnabled : plugin.isEnabled;
        return plugin.copyWith(isEnabled: nextIsEnabled);
      }).toList();
      state = AsyncData(optimisticPlugins);
    }

    final pluginService = ref.read(pluginServiceProvider);
    try {
      await pluginService.togglePlugin(id, isEnabled);
      ref.invalidate(pluginInitializedProvider);
      final refreshedPlugins = await ref
          .read(pluginRepositoryProvider)
          .loadPlugins();
      state = AsyncData(refreshedPlugins);
    } catch (error, stackTrace) {
      if (previousPlugins != null) {
        state = AsyncData(previousPlugins);
      } else {
        state = AsyncError(error, stackTrace);
      }
      rethrow;
    }
  }

  /// Check all installed plugins for updates.
  Future<void> checkForUpdates() async {
    final repo = ref.read(pluginRepositoryProvider);
    final results = await repo.checkAllPluginUpdates();
    ref.read(pluginUpdateResultsProvider.notifier).state = results;
  }
}
