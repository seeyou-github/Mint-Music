import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 应用自身的数据目录。
///
/// **Windows**：全部落在 `薄荷音乐.exe` 所在目录的 `AppData` 下：
///
/// ```
/// <exe 所在目录>\AppData\
///   config\   配置文件（设置、字体、均衡器配置等）
///   plugin\   插件文件
///   music\    默认下载目录
///   temp\     默认临时目录（默认缓存也放在这里）
/// ```
///
/// 除「设置 - 下载目录 / 缓存目录」用户自定义的路径外，应用在 Windows 上
/// 生成的其它文件、文件夹都放在这些子目录里，方便整包搬运与清理。
///
/// **其它平台**：保持原有的系统目录（文档 / 缓存 / 临时目录等）不变。
class AppPaths {
  const AppPaths._();

  /// Windows 上数据根目录的名字。
  static const String rootFolderName = 'AppData';

  /// 配置文件目录名。
  static const String configFolderName = 'config';

  /// 插件目录名。
  static const String pluginFolderName = 'plugin';

  /// 默认下载目录名。
  static const String musicFolderName = 'music';

  /// 默认临时目录名。
  static const String tempFolderName = 'temp';

  /// 重要数据库目录名（我的收藏、收藏歌单）。
  static const String databaseFolderName = 'db';

  /// `薄荷音乐.exe` 所在目录（仅 Windows 返回）。
  static String? get executableDirectory {
    if (!Platform.isWindows) return null;
    final exe = Platform.resolvedExecutable;
    if (exe.isEmpty) return null;
    return File(exe).parent.path;
  }

  /// 旧版设置目录（Windows 漫游 AppData 下的应用目录）。
  ///
  /// 只用于迁移旧数据。这里直接拼路径，**不调用 path_provider**：
  /// `getApplicationSupportDirectory()` 会顺手把目录创建出来，那样即使只是
  /// 读旧文件，也会在系统目录里留下一个空文件夹。
  static String? get legacySupportDirectoryPath {
    if (!Platform.isWindows) return null;
    final appData = Platform.environment['APPDATA'];
    if (appData == null || appData.isEmpty) return null;
    // 与 windows/runner/Runner.rc 里的 CompanyName / ProductName 保持一致。
    return p.join(appData, 'com.kingmc.mintmusic', '薄荷音乐');
  }

  /// 应用数据根目录（Windows 为 `<exe 目录>\AppData`）。
  static Future<Directory> rootDirectory() async {
    if (Platform.isWindows) {
      final base = executableDirectory;
      if (base != null && base.isNotEmpty) {
        return _ensureDirectory(Directory(p.join(base, rootFolderName)));
      }
    }
    return _ensureDirectory(await getApplicationSupportDirectory());
  }

  /// 配置文件目录：设置、字体、均衡器配置等。
  static Future<Directory> configDirectory() async {
    if (Platform.isWindows) {
      return _subDirectory(configFolderName);
    }
    return _ensureDirectory(await getApplicationSupportDirectory());
  }

  /// 导入的字体文件目录。
  static Future<Directory> fontDirectory() async {
    final base = await configDirectory();
    return _ensureDirectory(Directory(p.join(base.path, 'fonts')));
  }

  /// 插件文件目录。
  static Future<Directory> pluginDirectory() async {
    if (Platform.isWindows) {
      return _subDirectory(pluginFolderName);
    }
    final docs = await getApplicationDocumentsDirectory();
    return _ensureDirectory(Directory(p.join(docs.path, pluginFolderName)));
  }

  /// 默认下载目录（Windows 为 `AppData\music`）。
  ///
  /// 用户在「设置 - 下载目录」里自定义之后，由设置值优先。
  static Future<Directory> musicDirectory() async {
    if (Platform.isWindows) {
      return _subDirectory(musicFolderName);
    }
    final docs = await getApplicationDocumentsDirectory();
    return _ensureDirectory(Directory(p.join(docs.path, 'MintMusic')));
  }
  /// 默认临时目录（Windows 为 `AppData\temp`）。
  static Future<Directory> tempDirectory() async {
    if (Platform.isWindows) {
      return _subDirectory(tempFolderName);
    }
    return _ensureDirectory(await getTemporaryDirectory());
  }

  /// 默认缓存根目录（Windows 为 `AppData\temp`）。
  ///
  /// 用户在「设置 - 缓存目录」里自定义之后，由设置值优先。
  static Future<Directory> cacheRootDirectory() async {
    if (Platform.isWindows) {
      return _subDirectory(tempFolderName);
    }
    return _ensureDirectory(await getApplicationCacheDirectory());
  }

  /// 重要数据库目录（Windows 为 `AppData\db`）。
  ///
  /// 存放「不能丢」的数据：我的收藏、收藏歌单。变更后立即落盘。
  static Future<Directory> databaseDirectory() async {
    if (Platform.isWindows) {
      return _subDirectory(databaseFolderName);
    }
    final base = await getApplicationSupportDirectory();
    return _ensureDirectory(Directory(p.join(base.path, databaseFolderName)));
  }

  /// 临时数据库目录（Windows 为 `AppData\temp\db`）。
  ///
  /// 存放「丢了可以重新生成」的高频数据：本地歌曲列表、最近播放、下载列表、
  /// 搜索历史、缓存索引。写入会合并延迟落盘，减少 SSD 写入次数。
  static Future<Directory> cacheDatabaseDirectory() async {
    if (Platform.isWindows) {
      final base = await _subDirectory(tempFolderName);
      return _ensureDirectory(Directory(p.join(base.path, databaseFolderName)));
    }
    final base = await getApplicationCacheDirectory();
    return _ensureDirectory(Directory(p.join(base.path, databaseFolderName)));
  }

  /// 数据根目录下的子目录（自动创建）。
  static Future<Directory> _subDirectory(String name) async {
    final base = await rootDirectory();
    return _ensureDirectory(Directory(p.join(base.path, name)));
  }

  static Future<Directory> _ensureDirectory(Directory dir) async {
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
}
