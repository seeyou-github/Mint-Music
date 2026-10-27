import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/platform/app_paths.dart';

/// 收藏（我的收藏 + 收藏的歌单）的 JSON 文件存储。
///
/// 收藏变动不频繁，没有必要放进数据库，用一个 JSON 文件更方便：
/// 直接查看、直接拷贝、还原时也随配置文件一起恢复。
///
/// * Windows：`薄荷音乐.exe` 同级 `AppData\config\playlists.json`
/// * 其它平台：应用私有目录 `playlists.json`
class PlaylistStore {
  const PlaylistStore._();

  /// 文件名。
  static const String fileName = 'playlists.json';

  /// 收藏文件所在位置。
  static Future<File> file() async {
    final dir = await AppPaths.configDirectory();
    return File(p.join(dir.path, fileName));
  }

  /// 读取全部歌单（文件不存在时返回空列表）。
  static Future<List<Map<String, dynamic>>> read() async {
    try {
      final f = await file();
      final raw = await _readWithBackup(f);
      if (raw == null || raw.trim().isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry('$k', v)))
          .toList();
    } catch (e) {
      debugPrint('[PlaylistStore] 读取收藏失败: $e');
      return const [];
    }
  }

  /// 写入全部歌单（见 [_writeWithBackup]）。
  static Future<void> write(List<Map<String, dynamic>> playlists) async {
    try {
      final f = await file();
      await f.parent.create(recursive: true);
      await _writeWithBackup(f, jsonEncode(playlists));
    } catch (e) {
      debugPrint('[PlaylistStore] 写入收藏失败: $e');
    }
  }

  // ------------------------------------------------------------ 原子读写

  /// 读取文件内容；主文件损坏 / 缺失时回退到 `.bak`（最后一次完整的写入）。
  static Future<String?> _readWithBackup(File file) async {
    File? target;
    if (await file.exists()) {
      target = file;
    } else {
      final bak = File('${file.path}.bak');
      if (await bak.exists()) {
        target = bak;
        debugPrint('[PlaylistStore] ${p.basename(file.path)} 缺失，从 .bak 恢复');
      }
    }
    if (target == null) return null;
    try {
      return await target.readAsString();
    } catch (e) {
      debugPrint('[PlaylistStore] 读取 ${p.basename(file.path)} 失败: $e');
      return null;
    }
  }

  /// 写入：写 `.tmp` → 旧文件改名 `.bak` → `.tmp` 改名进来。
  ///
  /// 旧版是「delete 旧文件再 rename」，两步之间崩溃会连一份完整收藏都不剩；
  /// 现在任何时刻磁盘上都有一份完整的文件，`.bak` 还能用来回退。
  static Future<void> _writeWithBackup(File file, String content) async {
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(content, flush: true);
    final bak = File('${file.path}.bak');
    if (await file.exists()) {
      if (await bak.exists()) {
        await bak.delete();
      }
      await file.rename(bak.path);
    }
    await temp.rename(file.path);
  }

  // ------------------------------------------------------------ 删除墓碑

  /// 删除墓碑文件：记录被删除歌单的 id 与删除时间，供跨设备同步时
  /// 判断「远端还有、本地已删」的情况，避免删除被另一端合并回来。
  static const String tombstoneFileName = 'playlist_tombstones.json';

  static Future<File> tombstoneFile() async {
    final dir = await AppPaths.configDirectory();
    return File(p.join(dir.path, tombstoneFileName));
  }

  /// 读取删除墓碑（id → 删除时间毫秒）。
  static Future<Map<String, int>> readTombstones() async {
    try {
      final f = await tombstoneFile();
      final raw = await _readWithBackup(f);
      if (raw == null || raw.trim().isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final result = <String, int>{};
      decoded.forEach((key, value) {
        final id = '$key';
        final millis = value is int
            ? value
            : value is num
            ? value.toInt()
            : int.tryParse('$value');
        if (id.isNotEmpty && millis != null) result[id] = millis;
      });
      return result;
    } catch (e) {
      debugPrint('[PlaylistStore] 读取删除墓碑失败: $e');
      return {};
    }
  }

  /// 写入删除墓碑（见 [_writeWithBackup]）。
  static Future<void> writeTombstones(Map<String, int> tombstones) async {
    try {
      final f = await tombstoneFile();
      await f.parent.create(recursive: true);
      await _writeWithBackup(f, jsonEncode(tombstones));
    } catch (e) {
      debugPrint('[PlaylistStore] 写入删除墓碑失败: $e');
    }
  }

  /// 记录一个被删除的歌单。
  static Future<void> recordTombstone(String id) async {
    if (id.isEmpty) return;
    final tombstones = await readTombstones();
    tombstones[id] = DateTime.now().millisecondsSinceEpoch;
    await writeTombstones(tombstones);
  }
}
