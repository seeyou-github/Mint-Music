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

/// 备份 / 还原服务。
///
/// 备份内容（压缩包内）：
/// - `config/`：应用配置目录（`settings.json`、收藏歌单 `playlists.json`、
///   导入的字体等）
/// - `plugin/`：插件脚本目录
/// - `hotboards.json`：热榜（存在临时库 `hot_boards` 表里，不在 config 目录内）
///
/// 还原时：
/// - 用备份里的 `config` / `plugin` **覆盖**现有目录；
/// - 有 `hotboards.json` 时用它覆盖临时库里的热榜；
/// - **清空 `temp` 目录**（里面的本地歌曲索引等会失效，下次进入「本地」分类
///   会按配置里的扫描目录重新扫描一次）。
class BackupService {
  const BackupService._();

  /// 压缩包内的目录名。
  static const String configDirEntry = 'config';
  static const String pluginDirEntry = 'plugin';

  /// 压缩包内的热榜条目名。
  ///
  /// 热榜放在临时库的 `hot_boards` 表里（不在 config 目录内），所以单独打一个
  /// JSON 条目，否则换设备还原后用户挑的榜单会全部丢失。
  static const String hotBoardsEntry = 'hotboards.json';

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

  /// 生成一个备份压缩包（只含 config 与 plugin 两个目录 + 热榜）。
  static Future<Uint8List> createBackup() async {
    final archive = Archive();
    await _addDirectory(
      archive,
      await AppPaths.configDirectory(),
      configDirEntry,
    );
    await _addDirectory(
      archive,
      await AppPaths.pluginDirectory(),
      pluginDirEntry,
    );
    // 热榜在临时库里，单独序列化成一条 JSON 带进包。
    final hotBoards = await HotBoardStore().exportJson();
    if (hotBoards.isNotEmpty && hotBoards != '[]') {
      final bytes = utf8.encode(hotBoards);
      archive.addFile(ArchiveFile(hotBoardsEntry, bytes.length, bytes));
    }
    final zipped = ZipEncoder().encode(archive);
    return Uint8List.fromList(zipped);
  }

  /// 把目录里的文件加进压缩包。
  static Future<void> _addDirectory(
    Archive archive,
    Directory dir,
    String entryName,
  ) async {
    if (!await dir.exists()) return;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
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
    await _restoreDirectory(
      archive,
      configDirEntry,
      await AppPaths.configDirectory(),
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

    // 4) 热榜：新版本的备份包里是独立条目；老备份没有这一条，它的热榜在
    //    settings.json 的 `hot_boards_v2` 键里，会在 HotBoardStore 首次读取时
    //    自动迁移进临时库，这里不用额外处理。
    await _restoreHotBoards(archive);
  }

  /// 还原备份包里的热榜条目（没有就保持现有数据）。
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
  static Future<void> _restoreDirectory(
    Archive archive,
    String entryName,
    Directory target,
  ) async {
    await target.create(recursive: true);
    for (final file in archive.files) {
      if (!file.isFile) continue;
      if (!file.name.startsWith('$entryName/')) continue;
      final relative = file.name.substring(entryName.length + 1);
      if (relative.isEmpty || relative.contains('..')) continue;
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
