import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../platform/app_paths.dart';
import '../storage/app_database.dart';
import '../storage/app_preferences.dart';
import '../theme/app_font_manager.dart';
import '../theme/builtin_blur_backgrounds.dart';
import '../../features/discover/data/hot_board_store.dart';
import '../../features/player/data/play_progress_store.dart';
import '../../features/library/data/playlist_repository.dart';
import '../../features/library/data/playlist_store.dart';
import '../../features/radio/data/radio_cover_cache.dart';
import '../../features/radio/data/radio_store.dart';
import '../../features/settings/data/settings_service.dart';

/// 备份 / 还原服务。
///
/// 备份内容（压缩包内）：
/// - `config/setting/`：设置目录（`settings.json`、`settings.json.bak`、
///   删除墓碑、导入的字体、电台 / 自定义歌单封面等）
/// - `config/plugin/`：插件脚本目录
/// - `playlists.json`：收藏（我的收藏 + 歌单，存在重要库的两张表里）
/// - `playstats.json`：每首歌的已听进度（同样在重要库里；听歌统计 / 排行
///   已移除，老备份里的对应字段还原时忽略）
///
/// 两个顶层快照即使为空也照样写进包里，保证备份包的目录结构固定；
/// 老备份的 `config/*`、`plugin/*` 与 `hotboards.json` 仍然能还原。
///
/// 重要库（Windows：`AppData/config/db/mintmusic.db`）里的数据全部以 JSON 快照的形式单独
/// 打包，而不是直接拷数据库文件：正在使用的 SQLite 文件还有没合并的 WAL，
/// 直接拷会丢刚写的事务；而且换设备 / 换版本时 schema 可能不同，拷文件很
/// 容易把库读坏。
///
/// 还原时：
/// - 用备份里的 `config/setting` / `config/plugin` **覆盖**现有目录；
/// - 有 `playlists.json` / `playstats.json` 时把它们写回数据库；老备份的收藏
///   还在 `config/playlists.json` 里、热榜还在 `hotboards.json` 里，也照样能还原；
/// - 覆盖只写备份包里的文件、不删旧文件：还原后把**还原前在用、还原后不再
///   引用**的电台封面 / 模糊背景图 / 导入字体从 `config/setting` 删掉，避免
///   留下没人再引用的垃圾文件；
/// - **不改动 `temp` 目录**：播放记录、歌词 / 封面 / 歌曲缓存等临时数据
///   保持原样，还原后仍然可用。
class BackupService {
  const BackupService._();

  /// 压缩包内的配置目录名（下面固定分 `setting` / `plugin` 两个子目录）。
  static const String configDirEntry = 'config';

  /// 压缩包内的设置目录条目（对应 `AppData\config\setting`）。
  static const String settingDirEntry = '$configDirEntry/setting';

  /// 压缩包内的插件目录条目（对应 `AppData\config\plugin`）。
  static const String pluginDirEntry = '$configDirEntry/plugin';

  /// 老备份把插件目录放在包根下（`plugin/...`），还原时仍按这个条目读。
  static const String legacyPluginDirEntry = 'plugin';

  /// 压缩包内配置目录的旧形状：`config/*` 直接就是设置文件。
  ///
  /// 现在只用于还原老备份；新备份统一写在 [settingDirEntry] 下。
  static const String legacyConfigDirEntry = configDirEntry;

  /// 压缩包内的热榜条目名（**只用于读老备份**）。
  ///
  /// 新版本的热榜只是 settings.json 里的一段配置，已经随 `config/setting/`
  /// 一起打包，不再单独导出；这个常量只为还原「热榜还在临时库 / 老设置文件
  /// 的年代」做的备份，读到就把配置写回设置（里面的歌曲会被忽略，进页面会
  /// 重新拉）。
  static const String hotBoardsEntry = 'hotboards.json';

  /// 压缩包内的收藏快照条目名。
  ///
  /// 收藏（我的收藏 + 歌单）在重要库的两张表里，同样不在 config 目录内；
  /// 备份时导出成一份和旧版 `config/playlists.json` 结构一致的快照。
  /// 老备份包里的 `config/playlists.json` 也照样能还原（见 [_restorePlaylists]）。
  static const String playlistsEntry = 'playlists.json';

  /// 压缩包内的听歌数据条目名。
  ///
  /// 现在只剩「每首歌听到哪」（已听进度）：它是用户长期积累的数据，换设备时
  /// 要跟着走，因此单独导出一份快照（见 [PlayProgressStore.exportSnapshot]）。
  static const String playStatsEntry = 'playstats.json';

  /// 备份文件名前缀。
  static const String backupFilePrefix = 'mintmusic-backup';

  /// 备份文件名：`年-月-日-时-分-秒-mintmusic-backup.zip`。
  ///
  /// Windows 的文件名不能含冒号，这里统一用 `-`（跨平台通用）。
  static String buildBackupFileName([DateTime? now]) {
    final t = now ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}-${two(t.hour)}-${two(t.minute)}-'
        '${two(t.second)}-$backupFilePrefix.zip';
  }

  // ---------------------------------------------------------------- 备份

  /// 生成一个备份压缩包（`config/setting` + `config/plugin` + 数据库快照）。
  static Future<Uint8List> createBackup() async {
    // 先把攒在内存里的增量落盘（已听进度是攒批写的）：
    // 不 flush 的话，最近 15 秒内的播放数据不会进备份包。
    await AppDatabase.flushAll();
    await AppDatabase.checkpointAll();
    // 设置现在是防抖写盘，备份前必须结算，否则刚改的设置不会进包。
    await AppPreferences.maybeInstance?.flushNow();

    final archive = Archive();
    // 设置目录（`AppData\config\setting`）打成包里的 `config/setting`，
    // 插件目录打成 `config/plugin`，和 AppData 下的实际结构一一对应。
    // 重要库（`AppData\config\db`）不能直接拷：有未合并的 WAL，覆盖一个
    // 正在打开的库还会读坏，它的内容已经在 playlists.json / playstats.json
    // 里按逻辑数据导出了，所以这里跳过 db。
    final databaseDir = await AppPaths.databaseDirectory();
    await _addDirectory(
      archive,
      await AppPaths.settingsDirectory(),
      settingDirEntry,
      skipDirectory: databaseDir,
    );
    await _addDirectory(
      archive,
      await AppPaths.pluginDirectory(),
      pluginDirEntry,
    );
    // 收藏也单独导出（在重要库里，不在 config 目录内）。即使为空也写一份，
    // 让备份包的条目固定，方便查看 / 比对。
    final playlists = await PlaylistRepository().exportAll();
    final playlistBytes = utf8.encode(jsonEncode(playlists));
    archive.addFile(
      ArchiveFile(playlistsEntry, playlistBytes.length, playlistBytes),
    );
    // 已听进度导出成一份逻辑快照（统计 / 排行已移除）。
    final progress = await PlayProgressStore.exportSnapshot();
    final progressBytes = utf8.encode(jsonEncode(progress));
    archive.addFile(
      ArchiveFile(playStatsEntry, progressBytes.length, progressBytes),
    );
    final zipped = ZipEncoder().encode(archive);
    return Uint8List.fromList(zipped);
  }

  /// 把目录里的文件加进压缩包（连同子目录条目一起写，空目录也保留）。
  ///
  /// [skipDirectory] 用于跳过嵌在目录里的子目录（Android 的 config 目录里就
  /// 包含重要库所在的 `db` 目录）。
  static Future<void> _addDirectory(
    Archive archive,
    Directory dir,
    String entryName, {
    Directory? skipDirectory,
  }) async {
    if (!await dir.exists()) return;
    // 目录本身也写一条：即使里面没有文件，备份包里也能看到这个文件夹。
    archive.addFile(ArchiveFile.directory('$entryName/'));
    final skipPath = skipDirectory?.path;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (skipPath != null &&
          (p.equals(skipPath, entity.path) ||
              p.isWithin(skipPath, entity.path))) {
        continue;
      }
      final relative = p
          .relative(entity.path, from: dir.path)
          .replaceAll('\\', '/');
      if (entity is Directory) {
        archive.addFile(ArchiveFile.directory('$entryName/$relative/'));
        continue;
      }
      if (entity is! File) continue;
      // 设置写盘时先落 `settings.json.tmp` 再改名：半成品没有备份价值
      // （`.bak` 才是上一份完整设置），也别让它跟着还原回去。
      if (entity.path.endsWith('.tmp')) continue;
      final bytes = await entity.readAsBytes();
      archive.addFile(ArchiveFile('$entryName/$relative', bytes.length, bytes));
    }
  }

  // ---------------------------------------------------------------- 还原

  /// 用备份包强制覆盖现有配置。
  static Future<void> restoreBackup(Uint8List bytes) async {
    // 先把延迟写的数据落盘（已听进度是攒批写的）：不落盘的话，导入备份
    // 快照之后，内存里攒着的旧进度还会被写回库里。
    await AppDatabase.flushAll();

    final archive = ZipDecoder().decodeBytes(bytes);

    // 1) 设置 / 插件目录：覆盖还原
    //
    // 老备份的 `config/` 里可能带着重要库的 `db` 目录，**不能**把这些数据库
    // 文件盖到正在用的库上（SQLite 会直接读坏）；新备份已经不打包它了，
    // 这里再挡一次老备份包。
    final configDir = await AppPaths.settingsDirectory();
    final pluginDir = await AppPaths.pluginDirectory();
    final dbDir = await AppPaths.databaseDirectory();
    // 老备份（尤其 Android）把重要库的 `db/` 一起打进了配置目录：还原时
    // 一律跳过这个前缀，库内容由 playlists.json / playstats.json 还原。
    final dbRelative = p.relative(dbDir.path, from: configDir.path);
    final skipDbPrefix = dbRelative.startsWith('..') || p.isAbsolute(dbRelative)
        ? 'db'
        : dbRelative.replaceAll('\\', '/');

    // 还原只覆盖备份包里的文件，不会删旧文件。先记下还原前还在引用的封面 /
    // 背景图 / 字体，还原完再对比：只有「还原前在用、还原后不再引用」的文件
    // 才删，备份包自己带的文件不受影响。
    final prefs = await AppPreferences.getInstance();
    final refsBefore = await _readConfigFileRefs(prefs);

    // 新备份：`config/setting/*` + `config/plugin/*`。
    await _restoreDirectory(
      archive,
      settingDirEntry,
      configDir,
      skipPrefixes: [skipDbPrefix],
    );
    await _restoreDirectory(archive, pluginDirEntry, pluginDir);

    // 老备份：`config/*` 直接就是设置文件，插件目录在包根 `plugin/*`。
    // 新格式的两个子目录已经还原过了，这里跳过，别把插件放进设置目录。
    await _restoreDirectory(
      archive,
      legacyConfigDirEntry,
      configDir,
      skipPrefixes: [skipDbPrefix, 'setting', 'plugin'],
    );
    await _restoreDirectory(archive, legacyPluginDirEntry, pluginDir);

    // 2) 还原出的 settings.json 要重新读进内存：不重载的话，此后任何一次
    //    设置写入都会用还原前的内存值把整个文件覆盖回去（还原白做）。
    var settingsReloaded = false;
    try {
      await prefs.reload();
      settingsReloaded = true;
    } catch (e) {
      debugPrint('[BackupService] 重载设置失败: $e');
    }

    // 2.1) 被还原覆盖掉的旧封面 / 背景图 / 字体：从配置目录删掉。
    //      设置没重载成功时不删——读到的还是还原前的引用，判断不可靠。
    if (settingsReloaded) {
      try {
        final refsAfter = await _readConfigFileRefs(prefs);
        await _removeOverwrittenConfigFiles(
          refsBefore,
          refsAfter,
          settingsDir: configDir,
        );
      } catch (e) {
        debugPrint('[BackupService] 清理旧配置图片 / 字体失败: $e');
      }
    }

    // 3) 收藏 / 已听进度在重要库里，单独从条目还原（老备份的收藏还在
    //    `config/playlists.json`，见 [_restorePlaylists]）；热榜配置现在就在
    //    刚还原的 settings.json 里，只有老备份的 `hotboards.json` 才需要这一步。
    await _restoreHotBoards(archive);
    await _restorePlaylists(archive);
    await _restorePlayStats(archive);
  }

  /// 还原备份包里的已听进度（老备份里的统计 / 排行字段忽略）。
  static Future<void> _restorePlayStats(Archive archive) async {
    ArchiveFile? entry;
    for (final file in archive.files) {
      if (file.isFile && file.name == playStatsEntry) {
        entry = file;
        break;
      }
    }
    // 新版备份固定带这一条；老备份没有，或者快照里一条进度都没有时，
    // 保持现有已听进度不动（和热榜的处理一致），免得「还原一个没有进度的
    // 备份」把已有进度抹掉。
    if (entry == null) return;
    try {
      final raw = utf8.decode(entry.content as List<int>);
      if (raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final progress = decoded['progress'];
      if (progress is! List || progress.isEmpty) return;
      await PlayProgressStore.importSnapshot(
        decoded.map((key, value) => MapEntry('$key', value)),
      );
    } catch (e) {
      debugPrint('[BackupService] 还原听歌数据失败: $e');
    }
  }

  /// 还原收藏（我的收藏 + 歌单）。
  ///
  /// 优先用新备份里的顶层 `playlists.json` 条目；老备份没有这一条，收藏在
  /// `config/playlists.json`（已经随 config 目录还原到磁盘上了），直接读它。
  static Future<void> _restorePlaylists(Archive archive) async {
    if (!AppDatabase.isPersistent) {
      // 数据库没能落盘（降级成内存库）：导入只写进内存，退出就没了。
      // 保留原文件，下次正常启动时会自动迁移。
      return;
    }
    try {
      List<Map<String, dynamic>>? snapshot;
      for (final file in archive.files) {
        if (!file.isFile || file.name != playlistsEntry) continue;
        final decoded = jsonDecode(utf8.decode(file.content as List<int>));
        if (decoded is List) {
          snapshot = [
            for (final item in decoded)
              if (item is Map)
                item.map((key, value) => MapEntry('$key', value)),
          ];
        }
        break;
      }
      snapshot ??= await PlaylistStore.readLegacySnapshot();
      if (snapshot == null || snapshot.isEmpty) return;
      await PlaylistRepository().importAll(snapshot);
      // 老备份还原出来的文件已经进库了，删掉，避免下次启动再迁移一遍，
      // 也免得备份包里一直带着一份几百 KB 的过期数据。
      await PlaylistStore.deleteLegacyFiles();
      debugPrint('[BackupService] 已还原 ${snapshot.length} 个歌单');
    } catch (e) {
      debugPrint('[BackupService] 还原收藏失败: $e');
    }
  }

  /// 还原**老备份**里的热榜条目（新备份不再有这个条目）。
  ///
  /// 老包里的榜单带着歌曲，这里只把配置写进 settings.json，歌曲进页面再拉；
  /// 没有这个条目就保持现有配置不动。
  static Future<void> _restoreHotBoards(Archive archive) async {
    ArchiveFile? entry;
    for (final file in archive.files) {
      if (file.isFile && file.name == hotBoardsEntry) {
        entry = file;
        break;
      }
    }
    if (entry == null) return;
    try {
      final raw = utf8.decode(entry.content as List<int>);
      if (raw.trim().isEmpty) return;
      await HotBoardStore().importJson(raw);
      debugPrint('[BackupService] 已还原热榜');
    } catch (e) {
      debugPrint('[BackupService] 还原热榜失败: $e');
    }
  }

  /// 把压缩包里的某个目录还原到目标目录（覆盖同名文件）。
  ///
  /// [skipPrefixes] 是目录内的相对路径前缀：命中的文件直接跳过。用途：
  /// - Android 老备份里的 `db`（数据库文件由逻辑快照还原，不能覆盖正在
  ///   打开的库）；
  /// - 老格式还原时跳过 `setting` / `plugin`（新格式的两个子目录）。
  static Future<void> _restoreDirectory(
    Archive archive,
    String entryName,
    Directory target, {
    Iterable<String> skipPrefixes = const [],
  }) async {
    final skip = [
      for (final prefix in skipPrefixes)
        if (prefix.isNotEmpty) prefix.replaceAll('\\', '/'),
    ];
    await target.create(recursive: true);
    for (final file in archive.files) {
      if (!file.isFile) continue;
      if (!file.name.startsWith('$entryName/')) continue;
      final relative = file.name.substring(entryName.length + 1);
      if (relative.isEmpty || relative.contains('..')) continue;
      if (skip.any(
        (prefix) => relative == prefix || relative.startsWith('$prefix/'),
      )) {
        continue;
      }
      final content = file.content;
      final dest = File(p.join(target.path, relative));
      await dest.parent.create(recursive: true);
      await dest.writeAsBytes(content, flush: true);
    }
  }

  /// 读出当前设置里引用的、保存在配置目录内的文件。
  ///
  /// 三个来源都是「还原会整体覆盖」的数据：
  /// - 自定义电台的封面缓存（`radio_covers`，存的是绝对路径）；
  /// - 高斯模糊的背景图（`background_pic`，只存文件名）；
  /// - 用户导入的外部字体（`fonts`，只存文件名）。
  static Future<_ConfigFileRefs> _readConfigFileRefs(
    AppPreferences prefs,
  ) async {
    final radioCovers = <String>{};
    try {
      final data = await RadioStore().load();
      for (final station in data.stations) {
        final path = station.coverPath?.trim() ?? '';
        if (path.isNotEmpty) radioCovers.add(path);
      }
    } catch (_) {}

    final settings = SettingsService(prefs);
    final blurImages = <String>{
      ...settings.getBlurBackgroundImages(),
      // 单独存过选中项（列表之外的兜底）：一并算作在用。
      if (settings.getBlurBackgroundImage().trim().isNotEmpty)
        settings.getBlurBackgroundImage().trim(),
    };

    final fontFiles = <String>{
      for (final font in AppFontManager.savedFonts(prefs)) font.fileName.trim(),
    }..removeWhere((name) => name.isEmpty);

    return _ConfigFileRefs(
      radioCovers: radioCovers,
      blurImages: blurImages,
      fontFiles: fontFiles,
    );
  }

  /// 删掉还原前引用、还原后不再引用的配置图片 / 字体文件。
  ///
  /// 电台封面按**文件名**对比：备份里的 `coverPath` 是制作备份那台机器的
  /// 绝对路径，换安装目录还原后路径必然对不上，但缓存文件名（源的 md5）
  /// 不变，同名文件要保留。背景图和字体本来就只存文件名。
  static Future<void> _removeOverwrittenConfigFiles(
    _ConfigFileRefs before,
    _ConfigFileRefs after, {
    required Directory settingsDir,
  }) async {
    // 电台封面：只处理确实位于 radio_covers 下的旧引用，避免误删用户
    // 手填到别处的原始图片。
    final radioDir = Directory(
      p.join(settingsDir.path, RadioCoverCache.directoryName),
    );
    final beforeCoverNames = <String>{
      for (final path in before.radioCovers)
        if (p.isWithin(radioDir.path, path)) p.basename(path),
    };
    final afterCoverNames = <String>{
      for (final path in after.radioCovers) p.basename(path),
    };
    for (final name in beforeCoverNames.difference(afterCoverNames)) {
      if (!_isPlainFileName(name)) continue;
      await _deleteFileQuietly(File(p.join(radioDir.path, name)));
    }

    // 模糊背景图：新位置在 background_pic，旧版直接放在设置目录根下。
    final blurDirs = [
      p.join(settingsDir.path, AppPaths.backgroundPicFolderName),
      settingsDir.path,
    ];
    for (final name in before.blurImages.difference(after.blurImages)) {
      if (!_isPlainFileName(name)) continue;
      // 内置图不允许删除，下次启动也会补回来。
      if (builtinBlurBackgroundNames.contains(name)) continue;
      for (final dir in blurDirs) {
        await _deleteFileQuietly(File(p.join(dir, name)));
      }
    }

    // 导入字体：字体目录里的文件。
    final fontDir = await AppPaths.fontDirectory();
    for (final name in before.fontFiles.difference(after.fontFiles)) {
      if (!_isPlainFileName(name)) continue;
      await _deleteFileQuietly(File(p.join(fontDir.path, name)));
    }
  }
}

/// 是否是单纯的文件名（不含目录、不是 `.` / `..`）。
bool _isPlainFileName(String name) =>
    name.isNotEmpty &&
    name != '.' &&
    name != '..' &&
    p.basename(name) == name;

Future<void> _deleteFileQuietly(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {
    // 文件被占用 / 权限不足时保留，不影响还原结果。
  }
}

/// 还原前 / 后从设置里读到的、配置目录内的文件引用。
class _ConfigFileRefs {
  const _ConfigFileRefs({
    required this.radioCovers,
    required this.blurImages,
    required this.fontFiles,
  });

  /// 自定义电台封面缓存的绝对路径。
  final Set<String> radioCovers;

  /// 高斯模糊背景图文件名。
  final Set<String> blurImages;

  /// 导入字体的文件名。
  final Set<String> fontFiles;
}
