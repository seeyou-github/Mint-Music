import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../platform/app_paths.dart';

/// Android 上 `shared_prefs/` 里遗留文件的清理。
///
/// 应用的设置（主题、播放、**音频均衡器、高级音效处理**、歌词、下载等）现在
/// 统一存在配置目录的 `settings.json` 里（见 `AppPreferences`），
/// `shared_prefs/` 下只剩两类没人再读的文件：
///
/// * `FlutterSharedPreferences.xml`：旧版 shared_preferences 的存储文件，
///   内容已经在升级后的第一次启动时整体搬进 `settings.json`，留着只会让人
///   以为「设置还在 prefs 里」；
/// * `audio_service_preferences.xml`：`audio_service` 插件以前写在这里的**通知渠道
///   配置**（渠道 id / 名称 / 图标 / 是否常驻通知），和均衡器、音效设置无关。
///   现在已经不会再产生：构建时给插件的 `AudioServiceConfig.save()` 打了补丁
///   （见 `android/build.gradle.kts`），配置不再落盘；这里只是把老版本留下的
///   文件清掉。
///
/// 两者都不是配置的唯一副本，所以启动流程跑完后清掉即可，数据目录里不会再
/// 留一堆「看起来像设置」的旧文件。
class LegacySharedPrefs {
  LegacySharedPrefs._();

  /// 需要清理的遗留文件（只在 Android 的 `shared_prefs/` 目录里存在）。
  static const _legacyFiles = <String>[
    'FlutterSharedPreferences.xml',
    'audio_service_preferences.xml',
  ];

  /// 删除上面这些遗留文件；非 Android 平台直接返回。
  ///
  /// 必须等到「设置初始化」之后调用：`settings.json` 要先写出来，否则删掉
  /// `FlutterSharedPreferences.xml` 就再没有迁移来源了。
  ///
  /// 新版本已经不会再产生这两个文件（插件写盘已由 `android/build.gradle.kts`
  /// 的构建期补丁去掉），这里主要是给老版本升级上来的设备收尾。
  static Future<void> cleanup() async {
    if (!Platform.isAndroid) return;
    try {
      final configDir = await AppPaths.configDirectory();
      // Android 的配置目录是 `<应用数据>/files`，shared_prefs 与它同级。
      final prefsDir = Directory(
        p.join(p.dirname(configDir.path), 'shared_prefs'),
      );
      if (!await prefsDir.exists()) return;

      // 迁移没成功（settings.json 不存在）时不要删：那时旧文件仍是用户
      // 设置里唯一的一份，留着下次启动还能再迁一次。
      final settingsFile = File(p.join(configDir.path, 'settings.json'));
      if (!await settingsFile.exists() || await settingsFile.length() <= 2) {
        return;
      }

      for (final name in _legacyFiles) {
        final file = File(p.join(prefsDir.path, name));
        if (!await file.exists()) continue;
        await file.delete();
        debugPrint('[LegacySharedPrefs] 已删除遗留文件 $name');
      }

      // 整个目录都空了就一起删掉，Android 需要时会自己重建。
      if (await prefsDir.list().isEmpty) {
        await prefsDir.delete();
        debugPrint('[LegacySharedPrefs] shared_prefs 目录已清空并删除');
      }
    } catch (e) {
      // 清理失败不影响功能，最多是旧文件继续留在磁盘上。
      debugPrint('[LegacySharedPrefs] 清理失败: $e');
    }
  }
}
