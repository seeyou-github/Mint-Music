import 'dart:io';

import 'package:path_provider/path_provider.dart';

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
    final dir = root != null
        ? Directory(root)
        : await getApplicationCacheDirectory();
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

  /// 应用自己管理的缓存子目录。
  static const List<String> managedSubDirectories = [
    'artwork_cache',
    'covers',
    'image_cache',
  ];

  /// 按最大缓存大小清理应用自己的缓存子目录（三个目录合计，只删最旧的文件）。
  static Future<void> enforceLimit() async {
    final limit = maxBytes;
    if (limit <= 0) return;
    try {
      final entries = <({File file, int size, DateTime modified})>[];
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
