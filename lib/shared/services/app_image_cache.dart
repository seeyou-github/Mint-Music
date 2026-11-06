import 'dart:async';
import 'dart:io' as io;

import 'package:file/file.dart' hide FileSystem;
import 'package:file/local.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;

import '../../core/platform/app_paths.dart';
import 'cache_paths.dart';
import 'sqlite_cache_info_repository.dart';

/// 网络图片磁盘缓存（**所有**图片类型共用这一个目录）。
///
/// `cached_network_image` 默认把文件写到系统临时目录（Windows 上是
/// `%TEMP%`），导致「设置 - 存储管理 - 缓存目录」看起来不生效。
/// 这里用自定义 [FileSystem] 把缓存写到缓存目录下的 `image_cache`。
///
/// 歌曲封面、歌单 / 榜单封面、搜索结果、听歌识曲的图片都写在这里，用图片
/// 地址（或自定义 key）作缓存键。淘汰规则由 `flutter_cache_manager` 负责：
/// 最多保留 [maxCachedImages] 张、[stalePeriod] 内没用过的自动删除。
class AppImageCache {
  AppImageCache._();

  static const String _key = 'mintmusic_image_cache';

  /// 最多保留的图片数量，超出后按「最久没用」淘汰。
  static const int maxCachedImages = 2000;

  /// 多久没用过就删掉（`touched` 由每次读取刷新，不是下载时间）。
  static const Duration stalePeriod = Duration(days: 30);

  /// 小于这个字节数的一律当成错误页，不写缓存。
  static const int _minBytes = 100;

  static CacheManager? _manager;
  static String? _currentKey;

  /// 当前缓存目录（用于目录变化时清理旧目录）。
  static io.Directory? _currentDir;

  /// 在设置初始化完成 / 修改缓存目录后调用。
  static Future<void> configure() async {
    try {
      final dir = await CachePaths.subDirectory(CachePaths.imageCache);
      final previousDir = _currentDir;
      _currentDir = dir;
      final key = '${_key}_${dir.path.hashCode.toRadixString(16)}';
      if (key == _currentKey && _manager != null) return;
      _currentKey = key;
      _manager = CacheManager(
        Config(
          key,
          // 30 天是「最后使用时间」的窗口，不是下载时间：
          // flutter_cache_manager 清理时按索引里的 `touched` 判断
          // （见 SqliteCacheInfoRepository.getOldObjects），而每次读到缓存都会
          // 把 `touched` 刷成当前时间，所以常用的图片不会被删。
          // `validTill` 只用来决定「要不要在后台重新下载一份」，两者互不影响。
          stalePeriod: stalePeriod,
          maxNrOfCacheObjects: maxCachedImages,
          // 缓存索引（索引 + 元数据）放进临时库：以前是一个 JSON 文件，
          // 每新增 / 淘汰一张图片都要整个重写一遍。
          repo: SqliteCacheInfoRepository(
            legacyJsonPath: p.join(dir.path, '$key.json'),
          ),
          fileSystem: _CacheDirFileSystem(dir.path),
        ),
      );
      // 缓存目录变了：旧目录里的图片已经没人引用（新管理器会重新下载），
      // 直接删掉，否则会一直占着旧目录的空间。
      if (previousDir != null && previousDir.path != dir.path) {
        unawaited(_deleteDirectoryQuietly(previousDir));
      }
      unawaited(_cleanupLegacyIndex());
    } catch (e) {
      // 初始化失败时退回默认缓存管理器，不影响页面功能。
      debugPrint('[AppImageCache] 配置缓存目录失败: $e');
    }
  }

  /// 删除目录（失败静默：文件被占用时留给「清除缓存」处理）。
  static Future<void> _deleteDirectoryQuietly(io.Directory dir) async {
    try {
      if (!await dir.exists()) return;
      await dir.delete(recursive: true);
      debugPrint('[AppImageCache] 已清理旧缓存目录: ${dir.path}');
    } catch (_) {}
  }

  /// 主题 / 列表 / 歌词页共用的缓存管理器。
  static BaseCacheManager get manager => _manager ?? DefaultCacheManager();

  /// 读取缓存的图片字节；没有缓存、文件损坏时返回 null。
  ///
  /// 命中会刷新该图片的「最后使用时间」，30 天窗口从这次读起重新算。
  static Future<Uint8List?> read(String url) async {
    try {
      final info = await manager.getFileFromCache(url);
      if (info == null) return null;
      final bytes = await info.file.readAsBytes();
      if (bytes.length < _minBytes || !looksLikeImage(bytes)) {
        unawaited(remove(url));
        return null;
      }
      return bytes;
    } catch (e) {
      debugPrint('[AppImageCache] 读取图片缓存失败: $e');
      return null;
    }
  }

  /// 写入图片缓存（已下载好直接存，不触发网络请求）。
  static Future<void> write(String url, Uint8List bytes) async {
    if (bytes.length < _minBytes || !looksLikeImage(bytes)) return;
    try {
      // 已经缓存过就不再写：同一张图被两处同时下载时，重复 putFile 会生成
      // 两个文件、只有一个进索引，另一个变成永远没人清理的孤儿文件。
      if (await manager.getFileFromCache(url) != null) return;
      await manager.putFile(url, bytes, fileExtension: _extensionFor(bytes));
    } catch (e) {
      debugPrint('[AppImageCache] 写入图片缓存失败: $e');
    }
  }

  /// 删掉某张图的缓存（图片坏了 / 换地址时用）。
  static Future<void> remove(String url) async {
    try {
      await manager.removeFile(url);
    } catch (_) {}
  }

  /// 按图片头判断扩展名，缓存文件名不带上正确的后缀也能靠内容解码，
  /// 这里只是让目录里一眼能看出是什么图。
  static String _extensionFor(Uint8List data) {
    if (data.length >= 3 &&
        data[0] == 0xFF &&
        data[1] == 0xD8 &&
        data[2] == 0xFF) {
      return 'jpg';
    }
    if (data.length >= 4 &&
        data[0] == 0x89 &&
        data[1] == 0x50 &&
        data[2] == 0x4E &&
        data[3] == 0x47) {
      return 'png';
    }
    if (data.length >= 12 &&
        data[0] == 0x52 &&
        data[1] == 0x49 &&
        data[2] == 0x46 &&
        data[3] == 0x46 &&
        data[8] == 0x57 &&
        data[9] == 0x45 &&
        data[10] == 0x42 &&
        data[11] == 0x50) {
      return 'webp';
    }
    if (data.length >= 4 &&
        data[0] == 0x47 &&
        data[1] == 0x49 &&
        data[2] == 0x46 &&
        data[3] == 0x38) {
      return 'gif';
    }
    return 'img';
  }

  /// 校验图片头，避免把错误页 / HTML 当成封面缓存下来。
  static bool looksLikeImage(Uint8List data) {
    if (data.length < 12) return false;
    // JPEG
    if (data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) return true;
    // PNG
    if (data[0] == 0x89 &&
        data[1] == 0x50 &&
        data[2] == 0x4E &&
        data[3] == 0x47) {
      return true;
    }
    // WEBP (RIFF....WEBP)
    if (data[0] == 0x52 &&
        data[1] == 0x49 &&
        data[2] == 0x46 &&
        data[3] == 0x46 &&
        data[8] == 0x57 &&
        data[9] == 0x45 &&
        data[10] == 0x42 &&
        data[11] == 0x50) {
      return true;
    }
    // GIF
    if (data[0] == 0x47 &&
        data[1] == 0x49 &&
        data[2] == 0x46 &&
        data[3] == 0x38) {
      return true;
    }
    // BMP
    if (data[0] == 0x42 && data[1] == 0x4D) return true;
    return false;
  }

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
