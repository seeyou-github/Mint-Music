import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/storage/app_database.dart';
import '../../core/platform/app_paths.dart';

/// 全局缓存目录配置。
///
/// 之前「设置 - 存储管理 - 缓存目录」只用于展示目录大小，实际的封面/图片缓存
/// 仍然写在系统临时目录。这里统一成唯一来源：所有缓存写入都通过本类取目录，
/// 设置变化后重新调用 [configure] 即可。
class CachePaths {
  CachePaths._();

  static String? _root;

  /// 最大缓存占用（字节），<= 0 表示不限制。
  static int maxBytes = 0;

  /// 由设置初始化 / 修改缓存目录时调用；传空表示使用系统应用缓存目录。
  static void configure(String? root) {
    final trimmed = root?.trim();
    _root = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  static String? get root => _root;

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

  /// 应用自己管理的缓存子目录。
  static const List<String> managedSubDirectories = [
    'artwork_cache',
    'covers',
    'image_cache',
    'image_discovery_cache',
    'audio_cache',
  ];

  /// 按最大缓存大小清理应用自己的缓存子目录（合计，只删最旧的文件）。
  ///
  /// 全目录遍历 + 逐文件 stat 在缓存接近上限（万级文件）时开销不小，
  /// 因此例行调用有 [_enforceThrottle] 节流；用户改「最大缓存大小」等
  /// 需要立即生效的场合传 `force: true`。
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
      final entries = <({File file, int size, DateTime modified})>[];
      final deletedImageCacheFiles = <String>[];
      var total = 0;
      for (final name in managedSubDirectories) {
        final dir = await subDirectory(name);
        await for (final entity in dir.list(recursive: true)) {
          if (entity is! File) continue;
          try {
            final stat = await entity.stat();
            total += stat.size;
            entries.add((
              file: entity,
              size: stat.size,
              modified: stat.modified,
            ));
          } catch (_) {}
        }
      }
      if (total > limit) {
        entries.sort((a, b) => a.modified.compareTo(b.modified));
        for (final entry in entries) {
          if (total <= limit) break;
          try {
            // 图片缓存索引（临时库 cache_index 表）跟着文件一起清，
            // 否则会留下指向已删文件的孤儿行。
            if (p.basename(entry.file.parent.path) == 'image_cache') {
              deletedImageCacheFiles.add(p.basename(entry.file.path));
            }
            await entry.file.delete();
            total -= entry.size;
          } catch (_) {}
        }
      }
      if (deletedImageCacheFiles.isNotEmpty) {
        await _deleteImageIndexRows(deletedImageCacheFiles);
      }
    } catch (_) {}
  }

  static DateTime? _lastEnforceAt;
  static bool _enforcing = false;
  static const Duration _enforceThrottle = Duration(minutes: 1);

  /// 删除图片缓存索引里指向已删文件的行。
  static Future<void> _deleteImageIndexRows(List<String> fileNames) async {
    try {
      final db = await AppDatabase.cacheDatabase();
      final placeholders = List.filled(fileNames.length, '?').join(', ');
      await db.delete(
        'cache_index',
        where: 'relative_path IN ($placeholders)',
        whereArgs: fileNames,
      );
    } catch (_) {
      // 索引清不掉只会多留几行，flutter_cache_manager 取不到文件会自愈
    }
  }

  /// 删除 [dir] 中最旧的文件，直到总大小不超过 [limit]。
  static Future<void> pruneDirectory(Directory dir, int limit) =>
      _pruneDirectory(dir, limit);

  static Future<void> _pruneDirectory(Directory dir, int limit) async {
    try {
      if (!await dir.exists()) return;
      final entries = <({File file, int size, DateTime modified})>[];
      var total = 0;
      await for (final entity in dir.list(recursive: true)) {
        if (entity is! File) continue;
        try {
          final stat = await entity.stat();
          total += stat.size;
          entries.add((file: entity, size: stat.size, modified: stat.modified));
        } catch (_) {}
      }
      if (total <= limit) return;
      entries.sort((a, b) => a.modified.compareTo(b.modified));
      for (final entry in entries) {
        if (total <= limit) break;
        try {
          await entry.file.delete();
          total -= entry.size;
        } catch (_) {}
      }
    } catch (_) {}
  }
}
