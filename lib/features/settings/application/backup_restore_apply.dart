import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_font_manager.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/services/app_image_cache.dart';
import '../../../shared/services/cache_paths.dart';
import '../../library/application/playlist_providers.dart';
import '../../player/application/play_progress_providers.dart';
import '../../player/application/playback_controller.dart';
import 'font_providers.dart';
import 'plugin_providers.dart';
import 'settings_providers.dart';

/// 还原前停止播放。
///
/// 提取 / 导入备份的过程中播放进度还在往库里写，会和还原出的快照混在一起，
/// 所以要在 `BackupService.restoreBackup` 之前停下来。
Future<void> stopPlaybackForRestore(ProviderContainer container) async {
  try {
    await container.read(playbackControllerProvider.notifier).stopPlayback();
  } catch (e) {
    debugPrint('[BackupRestore] 停止播放失败: $e');
  }
}

/// 还原备份后立刻把新内容应用到运行中的应用，免去重启。
///
/// `BackupService.restoreBackup` 已经负责写盘并重载 `AppPreferences`，但运行
/// 期的 provider / 插件引擎 / 字体 / 缓存目录都还是还原前的值，这里按启动
/// 时的顺序再跑一遍：
///
/// 1. 停播放：下面要整体重建插件引擎，旧实例解析出的播放地址不再可用；
/// 2. 设置（含音效）→ 缓存目录 → 应用字体；
/// 3. 歌单 / 已听进度；
/// 4. 插件（最慢，放在最后）：卸载并重新加载所有插件文件，再清掉按旧音源
///    集合缓存的歌单 / 搜索结果。
///
/// [onProgress] 在进入关键步骤时回调中文提示，界面用它更新进度浮层。
Future<void> applyRestoredBackup(
  ProviderContainer container, {
  void Function(String message)? onProgress,
}) async {
  onProgress?.call('正在应用还原的设置...');
  await stopPlaybackForRestore(container);

  // 设置：按刚还原的 settings.json 重新灌进各 provider（音效也会重新下发）。
  // 某一步读失败只影响那一项，不要因此把整个「还原完成」判成失败。
  try {
    container.invalidate(settingsInitProvider);
    await container.read(settingsInitProvider.future);
  } catch (e) {
    debugPrint('[BackupRestore] 重新读取设置失败: $e');
  }

  // 缓存目录 / 上限可能也变了：重新配置，并按新上限清一次。
  try {
    CachePaths.configure(container.read(cacheDirProvider));
    CachePaths.maxBytes = container.read(maxCacheSizeMbProvider) * 1024 * 1024;
    await AppImageCache.configure();
    unawaited(CachePaths.enforceLimit());
  } catch (e) {
    debugPrint('[BackupRestore] 重新配置缓存目录失败: $e');
  }

  // 字体：清单和选中项都可能变了，重新读文件并应用。
  try {
    await AppFontManager.instance.reload();
    final selected = AppFontManager.instance.selectedFamily;
    container.read(appFontSelectedProvider.notifier).state = selected;
    AppTypography.fontFamily = (selected == null || selected.isEmpty)
        ? AppTypography.defaultFontFamily
        : selected;
    container.invalidate(appFontsProvider);
  } catch (e) {
    debugPrint('[BackupRestore] 重新加载字体失败: $e');
  }

  // 歌单 / 已听进度：还原时已经写进数据库，让 provider 重新读一遍。
  try {
    container.invalidate(playlistsProvider);
    await container.read(playlistsProvider.future);
    await container.read(playedProgressProvider.notifier).reload();
  } catch (e) {
    debugPrint('[BackupRestore] 重新读取歌单 / 已听进度失败: $e');
  }

  // 插件：整体卸载后按还原出的插件文件重新加载。
  onProgress?.call('正在重新加载音源...');
  try {
    container.invalidate(pluginInitializedProvider);
    await container.read(pluginInitializedProvider.future);
    container.read(musicSourceManagerProvider).clearAllCaches();
    container.invalidate(pluginSourceStateProvider);
    container.invalidate(pluginSupportedSourcesProvider);
    container.invalidate(pluginsProvider);
  } catch (e) {
    debugPrint('[BackupRestore] 重新加载插件失败: $e');
  }
}
