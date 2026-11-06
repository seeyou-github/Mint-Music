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

  /// 音频缓存目录（唯一受「最大缓存大小」限制的目录）。
  static const String audioCache = 'audio_cache';

  /// 应用自己管理的缓存子目录。
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

  /// 超限后清理到「上限的 [cleanTargetRatio]」。
  ///
  /// 不清到刚好等于上限：那样只要再缓存一首歌 / 再存几张图就又超了，于是每次
  /// 写入都要来一次「全目录遍历 + 批量删除」。清到 50% 之后要再攒满一半容量
  /// 才会再次清理，清理次数能少一个数量级，用户也不会感觉到「一直在删缓存」。
  static const double cleanTargetRatio = 0.5;

  /// 按最大缓存大小清理 [audioCache]，只删最旧的文件。
  ///
  /// 「最大缓存大小」只约束音频缓存：图片缓存有自己的一套规则（最多 2000 张、
  /// 30 天未使用淘汰，见 `AppImageCache`），不参与这里的计算，也不会被这里删掉。
  ///
  /// 全目录遍历 + 逐文件 stat 在缓存文件多时开销不小（几万个文件要几百毫秒），
  /// 所以例行调用按 [_enforceThrottle] 节流，且**只有超限时才会真的删**；
  /// 用户改「最大缓存大小」等需要立即生效的场合传 `force: true`。
  static Future<void> enforceLimit({bool force = false}) async {
    final limit = maxBytes;
    if (limit <= 0) return;
    if (_enforcing) return;
    final last = _lastEnforceAt;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < _enforceThrottle) {
      return;
    }
    _enforcing = true;
    _lastEnforceAt = DateTime.now();
    try {
      await _pruneDirectory(await subDirectory(audioCache), limit);
    } catch (_) {
    } finally {
      _enforcing = false;
    }
  }

  static DateTime? _lastEnforceAt;
  static bool _enforcing = false;

  /// 例行检查的最小间隔。
  ///
  /// 每次检查都要把音频缓存目录整体遍历一遍，频繁做纯属浪费 CPU 和磁盘。
  /// 配合「清到 50%」，5 分钟一次足够：正常听歌一小时也未必再触发一次删除。
  static const Duration _enforceThrottle = Duration(minutes: 5);

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

  static Future<void> _pruneDirectory(Directory dir, int limit) async {
    try {
      if (!await dir.exists()) return;
      final entries = <({File file, int size, DateTime modified})>[];
      var total = 0;
      await for (final entity in dir.list(recursive: true)) {
        if (entity is! File) continue;
        // 半成品（正在下载的音频 / 临时文件）既不计入总量，也不参与删除：
        // 删了只会把正在进行的缓存写入打断，留着下一轮自然会消失。
        if (entity.path.endsWith('.part') || entity.path.endsWith('.temp')) {
          continue;
        }
        try {
          final stat = await entity.stat();
          total += stat.size;
          entries.add((file: entity, size: stat.size, modified: stat.modified));
        } catch (_) {}
      }
      if (total <= limit) return;
      // 一次清到上限的一半，而不是刚好压到线上（见 [cleanTargetRatio]）。
      final target = (limit * cleanTargetRatio).round();
      entries.sort((a, b) => a.modified.compareTo(b.modified));
      for (final entry in entries) {
        if (total <= target) break;
        try {
          await entry.file.delete();
          total -= entry.size;
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 最大缓存占用（字节），<= 0 表示不限制。只作用于 [audioCache]。
  static int maxBytes = 0;
}
