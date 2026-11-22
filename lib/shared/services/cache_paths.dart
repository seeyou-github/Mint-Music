import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/platform/app_paths.dart';

/// 全局缓存目录。
///
/// **位置固定，不再提供设置项**：
/// * Windows：`<exe 同级>\AppData\temp`
/// * Android：`/data/data/<包名>/AppData/temp`
/// * 其它平台：应用缓存目录（保持系统惯例）
///
/// 以前「设置 - 存储管理」允许自定义缓存目录，用户一旦换盘 / 换目录，封面、
/// 媒体通知的封面路径都要重新生成，容易留下找不到的旧文件。
/// 现在统一由 [AppPaths.cacheRootDirectory] 决定，所有缓存写入都走本类。
class CachePaths {
  CachePaths._();

  /// 本地歌曲内嵌封面的磁盘缓存（原 `artwork_cache`，文件名 `<歌曲id>.jpg`）。
  ///
  /// 同时供列表 / 播放页显示和系统媒体通知（artUri）使用——通知栏只认文件
  /// 路径，这里存的就是那份文件，不再另外复制。
  static const String localSongsImageCache = 'local_songs_image_cache';

  /// 所有网络图片的统一缓存目录。
  ///
  /// 歌曲封面、歌单 / 榜单封面、搜索结果、听歌识曲等全部放在这里，由
  /// `flutter_cache_manager` 按「最多 2000 张 / 30 天未使用」自行淘汰。
  static const String imageCache = 'image_cache';

  /// 旧版本「我的收藏 / 自建歌单」离线音频缓存的目录名。
  ///
  /// 该功能已移除（代码与索引表都已删除），这里保留常量只是为了「清除本地
  /// 缓存」时把老版本留在 `AppData\temp\audio_cache` 里的文件一并删掉。
  static const String audioCache = 'audio_cache';

  /// 应用自己管理的缓存子目录（会创建 / 统计 / 清理）。
  static const List<String> managedSubDirectories = [
    localSongsImageCache,
    imageCache,
  ];

  /// 缓存根目录（固定：`AppData\temp`，其它平台走系统缓存目录）。
  static Future<Directory> rootDirectory() async {
    final dir = await AppPaths.cacheRootDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 缓存根目录下的子目录（会自动创建）。
  static Future<Directory> subDirectory(String name) async {
    final base = await rootDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}$name');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 把旧版缓存子目录迁到当前结构。
  ///
  /// * `artwork_cache` → [localSongsImageCache]（只是改名，文件继续可用）；
  /// * `covers`、`image_discovery_cache`：新版本不再使用，直接删掉。
  static Future<void> migrateLegacySubDirectories() async {
    try {
      final base = await rootDirectory();
      final legacyArtwork = Directory(
        '${base.path}${Platform.pathSeparator}artwork_cache',
      );
      final localSongs = Directory(
        '${base.path}${Platform.pathSeparator}$localSongsImageCache',
      );
      if (await legacyArtwork.exists()) {
        // 目标已存在时先整目录改名；改不动（被占用 / 跨设备）就逐文件搬。
        await _moveDirectoryContents(legacyArtwork, localSongs);
      }
      for (final name in const ['covers', 'image_discovery_cache']) {
        final dir = Directory('${base.path}${Platform.pathSeparator}$name');
        if (!await dir.exists()) continue;
        try {
          await dir.delete(recursive: true);
        } catch (_) {
          // 删不掉（文件被占用）就留着，不影响功能。
        }
      }
    } catch (_) {}
  }

  /// 把 [source] 的内容移进 [target]，完成后删掉空的 [source]。
  static Future<void> _moveDirectoryContents(
    Directory source,
    Directory target,
  ) async {
    try {
      if (!await target.exists()) {
        try {
          // 同一磁盘内改名几乎不耗时，也不会丢数据。
          await source.rename(target.path);
          return;
        } catch (_) {
          // 跨设备 / 目标被占用：退化成逐个文件搬。
        }
      }
      await target.create(recursive: true);
      await for (final entity in source.list(followLinks: false)) {
        if (entity is! File) continue;
        final dest = File(p.join(target.path, p.basename(entity.path)));
        try {
          if (await dest.exists()) continue; // 目标已有同名文件：不覆盖
          await entity.rename(dest.path);
        } catch (_) {
          try {
            await entity.copy(dest.path);
            await entity.delete();
          } catch (_) {}
        }
      }
      try {
        if (await source.list().isEmpty) await source.delete(recursive: false);
      } catch (_) {}
    } catch (_) {}
  }

}
