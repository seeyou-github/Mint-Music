import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/platform/app_paths.dart';

/// 全局缓存目录配置。
///
/// 之前「设置 - 存储管理 - 缓存目录」只用于展示目录大小，实际的封面/图片缓存
/// 仍然写在系统临时目录。这里统一成唯一来源：所有缓存写入都通过本类取目录，
/// 设置变化后重新调用 [configure] 即可。
class CachePaths {
  CachePaths._();

  static String? _root;

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

  /// 「我的收藏 / 自建歌单」歌曲的离线音频缓存目录（`audio_cache`）。
  ///
  /// 只存用户常听的收藏 / 自建歌单歌曲：听完一首后静默写入，播放前优先
  /// 命中，最多 200 首（按最久没听过淘汰）。索引在 `AppData\temp\db` 的
  /// `audio_cache_entries` 表里，见 `SongAudioCache`。
  static const String audioCache = 'audio_cache';

  /// 应用自己管理的缓存子目录（会创建 / 统计 / 清理）。
  static const List<String> managedSubDirectories = [
    localSongsImageCache,
    imageCache,
    audioCache,
  ];

  /// 由设置初始化 / 修改缓存目录时调用；传空表示使用系统应用缓存目录。
  static void configure(String? root) {
    final trimmed = root?.trim();
    _root = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  static String? get root => _root;

  /// 当前生效的缓存根目录（绝对路径，已展开默认目录）。
  static Future<String> currentRootPath() async => (await rootDirectory()).path;

  /// 缓存根目录：优先使用用户指定的目录，否则使用应用缓存目录。
  static Future<Directory> rootDirectory() async {
    final root = _root;
    if (root != null && root.trim().isNotEmpty) {
      final dir = Directory(root);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    }
    return AppPaths.cacheRootDirectory();
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

  /// 缓存目录切换后调用：删掉旧目录里的本地歌曲封面缓存。
  ///
  /// 封面跟着「缓存目录」设置走，新目录会重新从音频文件 / MediaStore 提取，
  /// 旧目录留着只会占空间。[keepRoot] 与 [rootPath] 是同一个目录时不做任何事
  /// （用户可能只是重新选了同一个目录，别把还能用的封面删了）。
  static Future<void> deleteLocalSongsImageCacheAt(
    String? rootPath, {
    String? keepRoot,
  }) async {
    final root = rootPath?.trim();
    if (root == null || root.isEmpty) return;
    final keep = keepRoot?.trim();
    if (keep != null &&
        keep.isNotEmpty &&
        p.equals(p.normalize(root), p.normalize(keep))) {
      return;
    }
    try {
      final dir = Directory(p.join(root, localSongsImageCache));
      if (!await dir.exists()) return;
      await dir.delete(recursive: true);
    } catch (_) {
      // 删不掉（文件被占用）就留着，不影响功能。
    }
  }

  /// 把旧版缓存子目录迁到当前结构。
  ///
  /// * `artwork_cache` → [localSongsImageCache]（只是改名，文件继续可用）；
  /// * `covers`、`image_discovery_cache`：新版本不再使用，直接删掉。
  ///
  /// 必须在 [configure] 之后调用（才知道真实的缓存根目录，含用户自定义）。
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
