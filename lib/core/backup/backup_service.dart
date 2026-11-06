import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../platform/app_paths.dart';
import '../storage/app_database.dart';
import '../storage/app_preferences.dart';
import '../../features/discover/data/hot_board_store.dart';
import '../../features/player/data/play_progress_store.dart';
import '../../features/library/data/playlist_repository.dart';
import '../../features/library/data/playlist_store.dart';

/// 备份 / 还原服务。
///
/// 备份内容（压缩包内）：
/// - `config/`：应用配置目录（`settings.json`、删除墓碑、导入的字体、
///   电台 / 自定义歌单封面等）
/// - `plugin/`：插件脚本目录
/// - `hotboards.json`：**只有还原老备份时才读**。热榜现在只是 settings.json
///   里的一小段配置（哪个音源加了哪个榜单），已经随 `config/` 一起打包
/// - `playlists.json`：收藏（我的收藏 + 歌单，存在重要库的两张表里）
/// - `playstats.json`：每首歌的已听进度（同样在重要库里；听歌统计 / 排行
///   已移除，老备份里的对应字段还原时忽略）
///
/// 重要库（`AppData/db/mintmusic.db`）里的数据全部以 JSON 快照的形式单独
/// 打包，而不是直接拷数据库文件：正在使用的 SQLite 文件还有没合并的 WAL，
/// 直接拷会丢刚写的事务；而且换设备 / 换版本时 schema 可能不同，拷文件很
/// 容易把库读坏。
///
/// 还原时：
/// - 用备份里的 `config` / `plugin` **覆盖**现有目录；
/// - 有 `playlists.json` / `playstats.json` 时把它们写回数据库；老备份的收藏
///   还在 `config/playlists.json` 里、热榜还在 `hotboards.json` 里，也照样能还原；
/// - **清空 `temp` 目录**（里面的本地歌曲索引等会失效，下次进入「本地」分类
///   会按配置里的扫描目录重新扫描一次）。
class BackupService {
  const BackupService._();

  /// 压缩包内的目录名。
  static const String configDirEntry = 'config';
  static const String pluginDirEntry = 'plugin';

  /// 压缩包内的热榜条目名（**只用于读老备份**）。
  ///
  /// 新版本的热榜只是 settings.json 里的一段配置，已经随 `config/` 一起打包，
  /// 不再单独导出；这个常量只为还原「热榜还在临时库 / 老设置文件的年代」做的
  /// 备份，读到就把配置写回设置（里面的歌曲会被忽略，进页面会重新拉）。
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

  /// 生成一个备份压缩包（config + plugin 两个目录 + 数据库里的快照）。
  static Future<Uint8List> createBackup() async {
    // 先把攒在内存里的增量落盘（已听进度是攒批写的）：
    // 不 flush 的话，最近 15 秒内的播放数据不会进备份包。
    await AppDatabase.flushAll();
    await AppDatabase.checkpointAll();

    final archive = Archive();
    // Android 上 config 目录（`/data/data/<包名>/files`）里嵌着重要库的
    // `db/mintmusic.db`。数据库文件不能直接拷（有未合并的 WAL，并且还原时
    // 覆盖一个正在打开的库会读坏），它的内容已经在 playlists.json /
    // playstats.json 里按逻辑数据导出了，所以这里跳过整个 db 目录。
    final databaseDir = await AppPaths.databaseDirectory();
    await _addDirectory(
      archive,
      await AppPaths.configDirectory(),
      configDirEntry,
      skipDirectory: databaseDir,
    );
    await _addDirectory(
      archive,
      await AppPaths.pluginDirectory(),
      pluginDirEntry,
    );
    // 收藏也单独导出（在重要库里，不在 config 目录内）。
    final playlists = await PlaylistRepository().exportAll();
    if (playlists.isNotEmpty) {
      final bytes = utf8.encode(jsonEncode(playlists));
      archive.addFile(ArchiveFile(playlistsEntry, bytes.length, bytes));
    }
    // 已听进度导出成一份逻辑快照（统计 / 排行已移除）。
    final progress = await PlayProgressStore.exportSnapshot();
    final hasProgress = (progress['progress'] as List?)?.isNotEmpty == true;
    if (hasProgress) {
      final bytes = utf8.encode(jsonEncode(progress));
      archive.addFile(ArchiveFile(playStatsEntry, bytes.length, bytes));
    }
    final zipped = ZipEncoder().encode(archive);
    return Uint8List.fromList(zipped);
  }

  /// 把目录里的文件加进压缩包。
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
    final skipPath = skipDirectory?.path;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (skipPath != null && p.isWithin(skipPath, entity.path)) continue;
      final bytes = await entity.readAsBytes();
      final relative = p
          .relative(entity.path, from: dir.path)
          .replaceAll('\\', '/');
      archive.addFile(ArchiveFile('$entryName/$relative', bytes.length, bytes));
    }
  }

  // ---------------------------------------------------------------- 还原

  /// 用备份包强制覆盖现有配置。
  static Future<void> restoreBackup(Uint8List bytes) async {
    // 先把延迟写的数据落盘：还原会清空临时数据，不落盘的话这些数据
    // 之后仍可能被内存态写回去。
    await AppDatabase.flushAll();

    final archive = ZipDecoder().decodeBytes(bytes);

    // 1) config / plugin 目录：覆盖还原
    //
    // Android 上配置目录里嵌着重要库所在的 `db` 目录，**不能**把备份里的
    // 数据库文件盖到正在使用的库上（SQLite 会直接读坏）。新备份已经不打包
    // 它了，这里再挡一次老备份包（老版本会把 `files/db` 一起打进去）。
    final configDir = await AppPaths.configDirectory();
    final dbDir = await AppPaths.databaseDirectory();
    final dbRelative = p.relative(dbDir.path, from: configDir.path);
    final skipDbPrefix = dbRelative.startsWith('..') || p.isAbsolute(dbRelative)
        ? null
        : dbRelative.replaceAll('\\', '/');
    await _restoreDirectory(
      archive,
      configDirEntry,
      configDir,
      skipPrefix: skipDbPrefix,
    );
    await _restoreDirectory(
      archive,
      pluginDirEntry,
      await AppPaths.pluginDirectory(),
    );

    // 2) 清空 temp 目录：本地歌曲索引等在这里，下次进入「本地」分类会
    //    按配置里的扫描目录重新扫描。数据库文件被占用删不掉时，把表也清了。
    await AppDatabase.clearAllCacheData();
    await _clearTempDirectory();

    // 3) 还原出的 settings.json 要重新读进内存：不重载的话，此后任何一次
    //    设置写入都会用还原前的内存值把整个文件覆盖回去（还原白做）。
    try {
      await (await AppPreferences.getInstance()).reload();
    } catch (e) {
      debugPrint('[BackupService] 重载设置失败: $e');
    }

    // 4) 收藏 / 已听进度在重要库里，单独从条目还原（老备份的收藏还在
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
    // 老备份没有这一条：保持现有已听进度不动（和热榜的处理一致），
    // 免得「还原一个没有进度的旧备份」把已有进度抹掉。
    if (entry == null) return;
    try {
      final raw = utf8.decode(entry.content as List<int>);
      if (raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
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
  /// [skipPrefix] 是目录内的相对路径前缀（Android 上的 `db`），命中的文件
  /// 直接跳过（数据库文件由逻辑快照还原，不能覆盖正在打开的库）。
  static Future<void> _restoreDirectory(
    Archive archive,
    String entryName,
    Directory target, {
    String? skipPrefix,
  }) async {
    await target.create(recursive: true);
    for (final file in archive.files) {
      if (!file.isFile) continue;
      if (!file.name.startsWith('$entryName/')) continue;
      final relative = file.name.substring(entryName.length + 1);
      if (relative.isEmpty || relative.contains('..')) continue;
      if (skipPrefix != null &&
          skipPrefix.isNotEmpty &&
          (relative == skipPrefix || relative.startsWith('$skipPrefix/'))) {
        continue;
      }
      final content = file.content;
      final dest = File(p.join(target.path, relative));
      await dest.parent.create(recursive: true);
      await dest.writeAsBytes(content, flush: true);
    }
  }

  /// 清空临时目录的内容（保留目录本身）。
  static Future<void> _clearTempDirectory() async {
    try {
      final dir = await AppPaths.tempDirectory();
      if (!await dir.exists()) return;
      await for (final entity in dir.list(followLinks: false)) {
        try {
          if (entity is Directory) {
            await entity.delete(recursive: true);
          } else if (entity is File) {
            await entity.delete();
          }
        } catch (e) {
          debugPrint('[BackupService] 删除临时文件失败: $e');
        }
      }
    } catch (e) {
      debugPrint('[BackupService] 清空临时目录失败: $e');
    }
  }
}
