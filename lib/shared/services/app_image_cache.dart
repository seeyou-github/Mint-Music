import 'dart:async';
import 'dart:io' as io;

import 'package:file/file.dart' hide FileSystem;
import 'package:file/local.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;

import '../../core/platform/app_paths.dart';
import 'cache_paths.dart';

/// 网络图片磁盘缓存。
///
/// `cached_network_image` 默认把文件写到系统临时目录（Windows 上是
/// `%TEMP%`），导致「设置 - 存储管理 - 缓存目录」看起来不生效。
/// 这里用自定义 [FileSystem] 把缓存写到缓存目录下的 `image_cache`。
class AppImageCache {
  AppImageCache._();

  static const String _key = 'mintmusic_image_cache';

  static CacheManager? _manager;
  static String? _currentKey;

  /// 在设置初始化完成 / 修改缓存目录后调用。
  static Future<void> configure() async {
    try {
      final dir = await CachePaths.subDirectory('image_cache');
      final key = '${_key}_${dir.path.hashCode.toRadixString(16)}';
      if (key == _currentKey && _manager != null) return;
      _currentKey = key;
      _manager = CacheManager(
        Config(
          key,
          stalePeriod: const Duration(days: 30),
          maxNrOfCacheObjects: 800,
          // 缓存信息（索引）文件也要放在缓存目录里：只指定 databaseName 时
          // flutter_cache_manager 会把 <databaseName>.json 写到系统默认目录
          // （Windows 上是漫游 AppData），会跑到 AppData 外面去。
          repo: JsonCacheInfoRepository(
            path: p.join(dir.path, '$key.json'),
          ),
          fileSystem: _CacheDirFileSystem(dir.path),
        ),
      );
      unawaited(_cleanupLegacyIndex());
    } catch (e) {
      // 初始化失败时退回默认缓存管理器，不影响页面功能。
      debugPrint('[AppImageCache] 配置缓存目录失败: $e');
    }
  }

  /// 主题 / 列表 / 歌词页共用的缓存管理器。
  static BaseCacheManager get manager => _manager ?? DefaultCacheManager();

  /// 清理旧版遗留在系统目录里的缓存索引文件。
  ///
  /// 旧版本只指定了 databaseName，索引文件会被写到系统默认目录
  /// （Windows 上是 `%APPDATA%\com.kingmc.mintmusic\薄荷音乐\`）。
  static Future<void> _cleanupLegacyIndex() async {
    try {
      // 直接拼旧目录的路径，不调用 path_provider：否则只是清理旧文件就会在
      // 系统漫游目录里创建出一个空文件夹。
      final legacyRoot = AppPaths.legacySupportDirectoryPath;
      if (legacyRoot == null) return;
      // 注意：本文件同时引入了 package:file（缓存管理器用的是它的 File 类型），
      // 这里的目录要用 dart:io 的实现。
      final dir = io.Directory(legacyRoot);
      if (!await dir.exists()) return;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! io.File) continue;
        final name = p.basename(entity.path);
        if (!name.startsWith(_key) || !name.endsWith('.json')) continue;
        await entity.delete();
      }
    } catch (_) {}
  }
}

/// 把文件固定写到指定目录的 [FileSystem] 实现。
///
/// 注意：`flutter_cache_manager` 的 `FileSystem` 接口使用的是
/// `package:file` 的 `File`，不是 `dart:io` 的 `File`。
class _CacheDirFileSystem implements FileSystem {
  _CacheDirFileSystem(this.path);

  final String path;

  static const LocalFileSystem _fs = LocalFileSystem();

  @override
  Future<File> createFile(String name) async {
    final dir = _fs.directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.childFile(name);
  }
}
