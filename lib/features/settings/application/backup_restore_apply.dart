import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_font_manager.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../shared/services/app_image_cache.dart';
import '../../../shared/services/cache_paths.dart';
import '../../blacklist/application/blacklist_providers.dart';
import '../../custom_sheet/application/custom_sheet_providers.dart';
import '../../library/application/playlist_providers.dart';
import '../../local/application/local_providers.dart';
import '../../player/application/play_progress_providers.dart';
import '../../player/application/playback_controller.dart';
import '../../radio/application/radio_providers.dart';
import 'appearance_providers.dart';
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

/// 重新加载插件允许的最长时间。
///
/// 插件多、JS 引擎慢的时候 `initializePlugins` 可能要十几秒；但真卡住时不能
/// 让「还原完成」永远等下去（界面会一直停在「正在重新加载音源」）。
const Duration _pluginReloadTimeout = Duration(seconds: 90);

/// 还原备份后立刻把新内容应用到运行中的应用，免去重启。
///
/// `BackupService.restoreBackup` 已经负责写盘并重载 `AppPreferences`，但运行
/// 期的 provider / 插件引擎 / 字体 / 缓存目录都还是还原前的值，这里按启动
/// 时的顺序再跑一遍：
///
/// 1. 停播放：下面要整体重建插件引擎，旧实例解析出的播放地址不再可用；
/// 2. 设置（含音效）→ 缓存目录 → 应用字体；
/// 3. 歌单 / 已听进度；
/// 4. 电台 / 黑名单 / 自定义歌单 / 本地扫描目录 / 插件音源开关：这些数据都在
///    刚换掉的 settings.json 里，各自的 provider 却只在启动时读一次，必须显式
///    重读，否则界面要等重启才变成备份里的内容；
/// 5. 插件（最慢，放在最后）：卸载并按还原出的插件文件重新加载，再清掉按旧
///    音源集合缓存的歌单 / 搜索结果。
///
/// [onProgress] 在进入关键步骤时回调中文提示，界面用它更新进度浮层。
///
/// 返回插件是否重载成功：超时 / 失败时返回 false，调用方据此提示「音源要重启
/// 后才生效」，而不是假装一切正常。
Future<bool> applyRestoredBackup(
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

  // 高斯模糊背景图是设置目录里的一个文件：还原后它可能刚出现，也可能被换成
  // 了另一张（文件名相同）。这里重新解析路径，并按路径清掉旧的解码缓存，
  // 否则主界面还是还原前那张图（或者干脆还是渐变）。
  try {
    container.invalidate(blurBackgroundImagePathProvider);
    container.invalidate(blurBackgroundTintProvider);
    final backdrop =
        await container.read(blurBackgroundImagePathProvider.future);
    if (backdrop != null) {
      await FileImage(File(backdrop)).evict();
    }
  } catch (e) {
    debugPrint('[BackupRestore] 刷新模糊背景图失败: $e');
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
  } catch (e) {
    debugPrint('[BackupRestore] 重新读取歌单失败: $e');
  }
  try {
    await container.read(playedProgressProvider.notifier).reload();
  } catch (e) {
    debugPrint('[BackupRestore] 重新读取已听进度失败: $e');
  }

  // 存在 settings.json 里、但运行期只在启动时读一次的那几项。
  // 每一项单独 try：某项读失败不该连累其它项。
  onProgress?.call('正在应用还原的电台 / 黑名单 / 本地目录...');
  try {
    await container.read(radioProvider.notifier).reload();
  } catch (e) {
    debugPrint('[BackupRestore] 重新读取电台数据失败: $e');
  }
  try {
    await container.read(blacklistProvider.notifier).reload();
  } catch (e) {
    debugPrint('[BackupRestore] 重新读取黑名单失败: $e');
  }
  try {
    await container.read(customSheetProvider.notifier).reload();
  } catch (e) {
    debugPrint('[BackupRestore] 重新读取自定义歌单失败: $e');
  }
  try {
    // 扫描目录缓存在仓库内存里，光 invalidate provider 拿到的还是旧值。
    await container.read(localMusicRepositoryProvider).reloadDirectories();
    container.invalidate(scannedDirectoriesProvider);
  } catch (e) {
    debugPrint('[BackupRestore] 重新读取本地扫描目录失败: $e');
  }
  try {
    await container
        .read(musicSourceManagerProvider)
        .reloadPluginSourceStates();
  } catch (e) {
    debugPrint('[BackupRestore] 重新读取插件音源开关失败: $e');
  }

  // 插件：整体卸载后按还原出的插件文件重新加载。
  //
  // 这里直接调 service，而**不是** invalidate(pluginInitializedProvider) 再
  // await 它的 `.future`：那条路会让 provider 重新计算一次，而「invalidate
  // 之后立刻 read(.future)」在 provider 同时被界面监听 / 重建时的时序不稳，
  // 出现过永远不返回、界面一直停在「正在重新加载音源」的情况。直接重载一次
  // service，然后只让派生 provider 重建，行为最可预期。
  //
  // 再套一层超时兜底：真卡住时也要让「还原完成」走到头，不能把界面挂死。
  onProgress?.call('正在重新加载音源...');
  var pluginsReloaded = true;
  try {
    await container
        .read(pluginServiceProvider)
        .initializePlugins()
        .timeout(_pluginReloadTimeout);
    container.read(musicSourceManagerProvider).clearAllCaches();
    container.invalidate(pluginSourceStateProvider);
    container.invalidate(pluginSupportedSourcesProvider);
    container.invalidate(pluginsProvider);
  } on TimeoutException {
    pluginsReloaded = false;
    debugPrint('[BackupRestore] 重新加载插件超时，将在下次启动时生效');
  } catch (e) {
    pluginsReloaded = false;
    debugPrint('[BackupRestore] 重新加载插件失败: $e');
  }
  return pluginsReloaded;
}
