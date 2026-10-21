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

  /// `薄荷音乐.exe` 所在目录（仅 Windows 返回）。
  static String? get executableDirectory {
    if (!Platform.isWindows) return null;
    final exe = Platform.resolvedExecutable;
    if (exe.isEmpty) return null;
    return File(exe).parent.path;
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
