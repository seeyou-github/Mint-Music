import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 应用自身的数据目录。
///
/// **Windows**：`Music.exe` 所在目录下的 `AppData`；
/// **Android**：应用私有目录 `/data/data/<包名>/AppData`。两者结构一致：
///
/// ```
/// AppData\
///   config\            配置（跟着「备份 / 还原」整体打包）
///     setting\         设置（settings.json、字体、自定义封面等）
///       background_pic\ 高斯模糊背景图（用户体验上传的图片）
///     db\              重要数据库（我的收藏、收藏歌单、已听进度）
///     plugin\          插件文件
///   download_music\    默认下载目录（仅 Windows）
///   temp\              临时 / 缓存文件（含 temp\db 里的临时数据库）
/// ```
///
/// 除「设置 - 下载目录 / 缓存目录」用户自定义的路径外，应用生成的其它文件、
/// 文件夹都放在这些子目录里，方便整包搬运与清理。
///
/// **其它平台**（iOS / macOS / Linux）：沿用系统目录不变。
class AppPaths {
  const AppPaths._();

  /// 数据根目录的名字。
  static const String rootFolderName = 'AppData';

  /// 配置根目录名（下面再分 setting / db / plugin）。
  static const String configFolderName = 'config';

  /// 设置目录名（`config\setting`）。
  static const String settingFolderName = 'setting';

  /// 高斯模糊背景图目录名（`config\setting\background_pic`）。
  static const String backgroundPicFolderName = 'background_pic';

  /// 插件目录名（`config\plugin`）。
  static const String pluginFolderName = 'plugin';

  /// 默认下载目录名（`AppData\download_music`）。
  static const String musicFolderName = 'download_music';

  /// 旧版的默认下载目录名（`AppData\music`）：只用于识别与迁移。
  static const String legacyMusicFolderName = 'music';

  /// 默认临时目录名（`AppData\temp`）。
  static const String tempFolderName = 'temp';

  /// 数据库目录名（`config\db` 与 `temp\db`）。
  static const String databaseFolderName = 'db';

  /// 是否使用「AppData + config/setting、config/db、config/plugin」这套结构。
  ///
  /// 只有 Windows 与 Android 使用；其它平台仍然放在系统目录里。
  static bool get usesAppDataLayout => Platform.isWindows || Platform.isAndroid;

  /// `Music.exe` 所在目录（仅 Windows 返回）。
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

  /// 应用数据根目录。
  ///
  /// - Windows：`<exe 目录>\AppData`
  /// - Android：`/data/data/<包名>/AppData`（应用私有目录，系统支持目录的上一级）
  /// - 其它平台：应用支持目录（保持原样）
  ///
  /// 单元测试用 [debugRootOverride] 把它指到临时目录，避免测试往
  /// Flutter SDK 目录（`flutter_tester.exe` 所在处）里写 `AppData`。
  ///
  /// 根目录的**解析结果**做了缓存：Android 上 `getApplicationSupportDirectory()`
  /// 是一次平台通道往返，而目录路径在进程生命周期内不会变（key 里带
  /// [debugRootOverride]，测试切换覆盖目录时自动重解析）。存在性检查仍在
  /// 每次调用时执行，外部删掉目录后下一次访问会照常重建。
  static Future<Directory> rootDirectory() async {
    final override = debugRootOverride;
    final key = override ?? '';
    final cached = _rootCache;
    if (cached != null && _rootCacheKey == key) {
      return _ensureDirectory(cached);
    }
    final resolved = await _resolveRootDirectory(override);
    _rootCache = resolved;
    _rootCacheKey = key;
    return _ensureDirectory(resolved);
  }

  static Directory? _rootCache;
  static String? _rootCacheKey;

  static Future<Directory> _resolveRootDirectory(String? override) async {
    if (override != null && override.isNotEmpty) {
      return Directory(override);
    }
    if (Platform.isWindows) {
      final base = executableDirectory;
      if (base != null && base.isNotEmpty) {
        return Directory(p.join(base, rootFolderName));
      }
    }
    if (Platform.isAndroid) {
      // getApplicationSupportDirectory() 是 `<私有目录>/files`，上一级就是
      // `/data/data/<包名>`；`AppData` 直接建在这里（和 files / cache 同级）。
      final support = await getApplicationSupportDirectory();
      return Directory(p.join(p.dirname(support.path), rootFolderName));
    }
    return getApplicationSupportDirectory();
  }

  /// 仅测试使用：覆盖数据根目录。正式运行时始终为 null。
  static String? debugRootOverride;

  /// 设置目录：`settings.json`、字体、自定义封面等。
  ///
  /// - Windows / Android：`AppData\config\setting`
  /// - 其它平台：应用支持目录（保持原样）
  static Future<Directory> settingsDirectory() async {
    if (usesAppDataLayout) {
      return _subDirectory(p.join(configFolderName, settingFolderName));
    }
    return _ensureDirectory(await getApplicationSupportDirectory());
  }

  /// 导入的字体文件目录（`config\setting\fonts`）。
  static Future<Directory> fontDirectory() async {
    final base = await settingsDirectory();
    return _ensureDirectory(Directory(p.join(base.path, 'fonts')));
  }

  /// 高斯模糊背景图目录（`config\setting\background_pic`）。
  ///
  /// 单独放一层子目录：设置页可以上传多张图，和 settings.json / 字体混在
  /// 一起不好管理；备份是把整个 `config\setting` 递归打包的，图片照样跟着走。
  static Future<Directory> blurBackgroundDirectory() async {
    final base = await settingsDirectory();
    return _ensureDirectory(
      Directory(p.join(base.path, backgroundPicFolderName)),
    );
  }

  /// 插件文件目录。
  ///
  /// - Windows / Android：`AppData\config\plugin`
  /// - 其它平台：文档目录下的 `plugin`
  static Future<Directory> pluginDirectory() async {
    if (usesAppDataLayout) {
      return _subDirectory(p.join(configFolderName, pluginFolderName));
    }
    final docs = await getApplicationDocumentsDirectory();
    return _ensureDirectory(Directory(p.join(docs.path, pluginFolderName)));
  }

  /// 默认下载目录。
  ///
  /// - Windows：`AppData\download_music`
  /// - Android：公共音乐目录（见 `download_paths.dart`，这里只作兜底）
  /// - 其它平台：文档目录下的 `MintMusic`
  static Future<Directory> musicDirectory() async {
    if (Platform.isWindows) {
      return _subDirectory(musicFolderName);
    }
    final docs = await getApplicationDocumentsDirectory();
    return _ensureDirectory(Directory(p.join(docs.path, 'MintMusic')));
  }

  /// 默认临时目录。
  ///
  /// - Windows / Android：`AppData\temp`
  /// - 其它平台：系统临时目录
  static Future<Directory> tempDirectory() async {
    if (usesAppDataLayout) return _subDirectory(tempFolderName);
    return _ensureDirectory(await getTemporaryDirectory());
  }

  /// 默认缓存根目录（Windows / Android 与临时目录同一个：`AppData\temp`）。
  ///
  /// 用户在「设置 - 缓存目录」里自定义之后，由设置值优先。
  static Future<Directory> cacheRootDirectory() async {
    if (usesAppDataLayout) return _subDirectory(tempFolderName);
    return _ensureDirectory(await getApplicationCacheDirectory());
  }

  /// 重要数据库目录（`AppData\config\db`）。
  ///
  /// 存放「不能丢」的数据：我的收藏、收藏歌单、每首歌的已听进度。
  /// 变更后立即落盘。
  static Future<Directory> databaseDirectory() async {
    if (usesAppDataLayout) {
      return _subDirectory(p.join(configFolderName, databaseFolderName));
    }
    final base = await getApplicationSupportDirectory();
    return _ensureDirectory(Directory(p.join(base.path, databaseFolderName)));
  }

  /// 临时数据库目录（`AppData\temp\db`）。
  ///
  /// 存放「丢了可以重新生成」的高频数据：本地歌曲列表、最近播放、缓存索引。
  /// 写入会合并延迟落盘，减少 SSD 写入次数。
  static Future<Directory> cacheDatabaseDirectory() async {
    if (usesAppDataLayout) {
      return _subDirectory(p.join(tempFolderName, databaseFolderName));
    }
    final base = await getApplicationCacheDirectory();
    return _ensureDirectory(Directory(p.join(base.path, databaseFolderName)));
  }

  // ---------------------------------------------------------------- 旧结构迁移

  /// 把旧版的目录结构搬到 [结构](#AppPaths) 说明的新结构里。
  ///
  /// 迁移映射（一次性、幂等，目标已存在时**不覆盖**）：
  ///
  /// | 旧位置 | 新位置 |
  /// |---|---|
  /// | Windows `AppData\config\*`（settings.json / 字体 / 封面等） | `AppData\config\setting\*` |
  /// | Windows `AppData\db` | `AppData\config\db` |
  /// | Windows `AppData\plugin` | `AppData\config\plugin` |
  /// | Windows `AppData\music` | `AppData\download_music` |
  /// | Android `files\*` | `AppData\config\setting\*` |
  /// | Android `files\db` | `AppData\config\db` |
  /// | Android `<文档>\plugin` | `AppData\config\plugin` |
  /// | Android `<缓存>\db` | `AppData\temp\db` |
  /// | 设置目录里的 `background_blur*` | `AppData\config\setting\background_pic\` |
  ///
  /// 任何一步失败都只打日志、不影响启动（下次启动会再试）。缓存目录里的图片
  /// 等可再生数据不搬（系统会自己回收旧缓存目录）。
  static Future<void> migrateLegacyLayout() async {
    try {
      if (usesAppDataLayout) {
        if (Platform.isWindows) {
          await _migrateWindowsLayout();
        } else {
          await _migrateAndroidLayout();
        }
      }
      await _migrateBlurBackgroundImages();
    } catch (e) {
      print('[AppPaths] 迁移旧目录结构失败: $e');
    }
  }

  /// 把旧版直接放在设置目录里的高斯模糊背景图挪进 `background_pic\`。
  ///
  /// 设置里只存文件名，移动文件不改配置；目标同名文件已存在时跳过，
  /// 下次启动会再试，不会覆盖。
  static Future<void> _migrateBlurBackgroundImages() async {
    try {
      final setting = await settingsDirectory();
      final target = await blurBackgroundDirectory();
      if (!await setting.exists() || p.equals(setting.path, target.path)) {
        return;
      }
      await for (final entity in setting.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        // 与设置页里生成的文件名前缀一致（`background_blur_<时间戳>.jpg`）。
        if (!name.startsWith('background_blur')) continue;
        final dest = File(p.join(target.path, name));
        if (await dest.exists()) continue;
        try {
          await entity.rename(dest.path);
        } catch (_) {
          // 跨盘 / 权限不允许 rename 时退回复制 + 删除。
          try {
            await entity.copy(dest.path);
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (e) {
      print('[AppPaths] 迁移高斯模糊背景图失败: $e');
    }
  }

  static Future<void> _migrateWindowsLayout() async {
    final root = await rootDirectory();
    // AppData\config 下除 setting / db / plugin 之外的条目，都是旧版直接放在
    // config 里的配置（settings.json、字体、封面缓存、删除墓碑……）。
    final setting = await settingsDirectory();
    await _moveStrayEntries(
      Directory(p.join(root.path, configFolderName)),
      setting,
      keepNames: const {
        settingFolderName,
        databaseFolderName,
        pluginFolderName,
      },
    );

    // 旧版：db / plugin / music 都在 AppData 根下。
    await _mergeDirectory(
      Directory(p.join(root.path, databaseFolderName)),
      await databaseDirectory(),
    );
    await _mergeDirectory(
      Directory(p.join(root.path, pluginFolderName)),
      await pluginDirectory(),
    );
    await _mergeDirectory(
      Directory(p.join(root.path, legacyMusicFolderName)),
      await musicDirectory(),
    );
  }

  static Future<void> _migrateAndroidLayout() async {
    // 旧版：配置目录就是应用支持目录（/data/data/<包名>/files），
    // 里面还嵌着重要库所在的 db 子目录。
    final support = await getApplicationSupportDirectory();
    final setting = await settingsDirectory();
    final database = await databaseDirectory();
    if (await support.exists()) {
      await for (final entity in support.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (name == databaseFolderName) {
          await _mergeDirectory(Directory(entity.path), database);
        } else {
          await _moveEntity(entity, setting);
        }
      }
    }

    final docs = await getApplicationDocumentsDirectory();
    await _mergeDirectory(
      Directory(p.join(docs.path, pluginFolderName)),
      await pluginDirectory(),
    );

    // 旧版的临时库在 `<缓存目录>/db`。
    final cache = await getApplicationCacheDirectory();
    await _mergeDirectory(
      Directory(p.join(cache.path, databaseFolderName)),
      await cacheDatabaseDirectory(),
    );

    // 封面 / 音频缓存在旧缓存目录的根下：一起搬进 `AppData\temp`，否则这批
    // 文件会变成没人统计、没人清理的垃圾（缓存索引里存的是相对路径，整棵
    // 目录搬过去索引依然对得上）。
    final temp = await tempDirectory();
    for (final name in const ['artwork_cache', 'image_cache', 'audio_cache']) {
      await _mergeDirectory(
        Directory(p.join(cache.path, name)),
        Directory(p.join(temp.path, name)),
      );
    }
    // 新版不再使用这两个目录：`covers` 是封面副本，`image_discovery_cache`
    // 已经并入 `image_cache`（文件名体系不同，搬过去也没有索引能对上）。
    for (final name in const ['covers', 'image_discovery_cache']) {
      try {
        final dir = Directory(p.join(cache.path, name));
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// 把 [source] 里除 [keepNames] 之外的条目移进 [target]。
  static Future<void> _moveStrayEntries(
    Directory source,
    Directory target, {
    Set<String> keepNames = const {},
  }) async {
    if (!await source.exists()) return;
    await for (final entity in source.list(followLinks: false)) {
      if (keepNames.contains(p.basename(entity.path))) continue;
      await _moveEntity(entity, target);
    }
  }

  /// 把 [source] 目录里的内容并进 [target]（目标已有同名条目时跳过）。
  ///
  /// 搬空之后删掉 [source] 空目录，避免留下 `AppData\db` 这种空壳。
  static Future<void> _mergeDirectory(
    Directory source,
    Directory target,
  ) async {
    if (!await source.exists()) return;
    await _moveStrayEntries(source, target);
    try {
      if (await source.exists() && await source.list().isEmpty) {
        await source.delete(recursive: false);
      }
    } catch (_) {
      // 删不掉（被占用）就留着，不影响使用。
    }
  }

  /// 把单个文件 / 目录移到 [target] 下；目标已有同名条目时保持原样。
  static Future<void> _moveEntity(
    FileSystemEntity entity,
    Directory target,
  ) async {
    final name = p.basename(entity.path);
    final dest = p.join(target.path, name);
    try {
      // 目标已有同名条目：不动它（绝不覆盖用户数据）。
      if (FileSystemEntity.typeSync(dest) != FileSystemEntityType.notFound) {
        return;
      }
      await _ensureDirectory(target);
      // 同一个应用目录内，rename 等于改目录项，几乎不耗时也不会丢数据。
      await entity.rename(dest);
    } catch (e) {
      // 跨设备 / 被占用：退化成复制 + 删除。
      try {
        if (entity is Directory) {
          await for (final child in entity.list(
            recursive: true,
            followLinks: false,
          )) {
            if (child is! File) continue;
            final relative = p.relative(child.path, from: entity.path);
            final copy = File(p.join(dest, relative));
            await copy.parent.create(recursive: true);
            await child.copy(copy.path);
          }
          await entity.delete(recursive: true);
        } else if (entity is File) {
          await entity.copy(dest);
          await entity.delete();
        }
      } catch (error) {
        print('[AppPaths] 迁移 $name 失败: $error');
      }
    }
  }

  /// 把「旧版默认目录」的存量设置值改成新路径（用户自己挑的路径不动）。
  ///
  /// 典型场景：`download_dir` 里存着旧默认的 `AppData\music`，目录结构改成
  /// `download_music` 后，不改的话下载会继续往旧目录（已被搬空）里写。
  static String normalizeLegacyPath(String path) {
    if (path.isEmpty) return path;
    final base = executableDirectory;
    if (base != null && base.isNotEmpty) {
      final oldMusic = p.join(base, rootFolderName, legacyMusicFolderName);
      if (p.equals(path, oldMusic)) {
        return p.join(base, rootFolderName, musicFolderName);
      }
    }
    return path;
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
