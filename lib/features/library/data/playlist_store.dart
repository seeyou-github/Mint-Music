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
      if (!await f.exists()) return const [];
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return const [];
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

  /// 写入全部歌单（先写临时文件再替换，避免中途损坏）。
  static Future<void> write(List<Map<String, dynamic>> playlists) async {
    try {
      final f = await file();
      await f.parent.create(recursive: true);
      final temp = File('${f.path}.tmp');
      await temp.writeAsString(jsonEncode(playlists), flush: true);
      if (await f.exists()) {
        await f.delete();
      }
      await temp.rename(f.path);
    } catch (e) {
      debugPrint('[PlaylistStore] 写入收藏失败: $e');
    }
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
      if (!await f.exists()) return {};
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return {};
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

  /// 写入删除墓碑。
  static Future<void> writeTombstones(Map<String, int> tombstones) async {
    try {
      final f = await tombstoneFile();
      await f.parent.create(recursive: true);
      final temp = File('${f.path}.tmp');
      await temp.writeAsString(jsonEncode(tombstones), flush: true);
      if (await f.exists()) {
        await f.delete();
      }
      await temp.rename(f.path);
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
