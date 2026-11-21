import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/platform/app_paths.dart';

/// 收藏相关的「小文件」存储：
///
/// * **删除墓碑**（歌单级 / 歌曲级）：跨设备同步时用来传播删除，避免
///   「本地删了、远端还有」的被合并回来。数据量小（一次删除几十字节，
///   保留 90 天），放 JSON 文件比建表省事，而且会随 `config/` 一起进备份包。
/// * **旧版收藏快照**（`playlists.json`）：仅用于把老数据迁移进数据库
///   （见 `PlaylistRepository.migrateLegacyFile`），迁移完成后删除。
///
/// 收藏本体（歌单 + 歌曲）已经移到重要库的 `playlists` / `playlist_songs`
/// 表，见 `AppDatabase` 与 `PlaylistRepository`。
class PlaylistStore {
  const PlaylistStore._();

  /// 旧版收藏文件（迁移来源）。
  static const String fileName = 'playlists.json';

  /// 歌单级删除墓碑：`{ "<playlistId>": <deletedAtMillis> }`。
  static const String tombstoneFileName = 'playlist_tombstones.json';

  /// 歌曲级删除墓碑：`{ "<playlistId>": { "<songId>": <deletedAtMillis> } }`。
  ///
  /// 逐首合并必须知道「这首歌是被删掉的，不是另一台设备没有」，否则每次
  /// 同步都会把删掉的歌从另一端合并回来。
  static const String songTombstoneFileName = 'playlist_song_tombstones.json';

  // ------------------------------------------------------------ 旧版收藏文件

  /// 旧版收藏文件位置。
  static Future<File> legacyFile() async {
    final dir = await AppPaths.settingsDirectory();
    return File(p.join(dir.path, fileName));
  }

  /// 读取旧版收藏快照；文件不存在 / 损坏时返回 null。
  static Future<List<Map<String, dynamic>>?> readLegacySnapshot() async {
    try {
      final raw = await _readWithBackup(await legacyFile());
      if (raw == null || raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      return [
        for (final item in decoded)
          if (item is Map) item.map((key, value) => MapEntry('$key', value)),
      ];
    } catch (e) {
      debugPrint('[PlaylistStore] 读取旧版收藏失败: $e');
      return null;
    }
  }

  /// 迁移完成后删掉旧文件（连 `.bak` 一起；不删的话备份包里还会多一份
  /// 几百 KB 的过期数据）。
  static Future<void> deleteLegacyFiles() async {
    try {
      final file = await legacyFile();
      for (final target in [file, _backupOf(file)]) {
        if (await target.exists()) {
          await target.delete();
          debugPrint('[PlaylistStore] 已删除 ${p.basename(target.path)}');
        }
      }
    } catch (e) {
      debugPrint('[PlaylistStore] 删除旧版收藏文件失败: $e');
    }
  }

  // ------------------------------------------------------------ 歌单级墓碑

  static Future<File> tombstoneFile() async {
    final dir = await AppPaths.settingsDirectory();
    return File(p.join(dir.path, tombstoneFileName));
  }

  /// 读取歌单级墓碑（id → 删除时间毫秒）。
  static Future<Map<String, int>> readTombstones() =>
      _readMillisMap(tombstoneFile(), '歌单墓碑');

  /// 写入歌单级墓碑。
  static Future<void> writeTombstones(Map<String, int> tombstones) =>
      _writeMillisMap(tombstoneFile(), tombstones, '歌单墓碑');

  /// 记录一个被删除的歌单。
  static Future<void> recordTombstone(String id) async {
    if (id.isEmpty) return;
    final tombstones = await readTombstones();
    tombstones[id] = DateTime.now().millisecondsSinceEpoch;
    await writeTombstones(tombstones);
  }

  // ------------------------------------------------------------ 歌曲级墓碑

  static Future<File> songTombstoneFile() async {
    final dir = await AppPaths.settingsDirectory();
    return File(p.join(dir.path, songTombstoneFileName));
  }

  /// 读取歌曲级墓碑：歌单 id → (歌曲 id → 删除时间毫秒)。
  static Future<Map<String, Map<String, int>>> readSongTombstones() async {
    try {
      final file = await songTombstoneFile();
      final raw = await _readWithBackup(file);
      if (raw == null || raw.trim().isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final result = <String, Map<String, int>>{};
      decoded.forEach((playlistId, value) {
        if (value is! Map) return;
        final songs = <String, int>{};
        value.forEach((songId, deletedAt) {
          final millis = _toMillis(deletedAt);
          if (millis != null) songs['$songId'] = millis;
        });
        if (songs.isNotEmpty) result['$playlistId'] = songs;
      });
      return result;
    } catch (e) {
      debugPrint('[PlaylistStore] 读取歌曲墓碑失败: $e');
      return {};
    }
  }

  static Future<void> writeSongTombstones(
    Map<String, Map<String, int>> tombstones,
  ) async {
    try {
      final file = await songTombstoneFile();
      await file.parent.create(recursive: true);
      final payload = <String, Map<String, int>>{
        for (final entry in tombstones.entries)
          if (entry.value.isNotEmpty) entry.key: entry.value,
      };
      await _writeWithBackup(file, jsonEncode(payload));
    } catch (e) {
      debugPrint('[PlaylistStore] 写入歌曲墓碑失败: $e');
    }
  }

  /// 记录「某首歌被从某个歌单里删掉」。
  static Future<void> recordSongTombstone(
    String playlistId,
    String songId,
  ) async {
    if (playlistId.isEmpty || songId.isEmpty) return;
    final tombstones = await readSongTombstones();
    tombstones.putIfAbsent(playlistId, () => {})[songId] =
        DateTime.now().millisecondsSinceEpoch;
    await writeSongTombstones(tombstones);
  }

  /// 歌曲被重新加回来：把它的墓碑清掉，免得下次同步又被判成「已删除」。
  static Future<void> clearSongTombstone(
    String playlistId,
    String songId,
  ) async {
    final tombstones = await readSongTombstones();
    final songs = tombstones[playlistId];
    if (songs == null || !songs.containsKey(songId)) return;
    songs.remove(songId);
    if (songs.isEmpty) tombstones.remove(playlistId);
    await writeSongTombstones(tombstones);
  }

  // ------------------------------------------------------------ 通用读写

  static Future<Map<String, int>> _readMillisMap(
    Future<File> fileFuture,
    String label,
  ) async {
    try {
      final raw = await _readWithBackup(await fileFuture);
      if (raw == null || raw.trim().isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final result = <String, int>{};
      decoded.forEach((key, value) {
        final id = '$key';
        final millis = _toMillis(value);
        if (id.isNotEmpty && millis != null) result[id] = millis;
      });
      return result;
    } catch (e) {
      debugPrint('[PlaylistStore] 读取$label失败: $e');
      return {};
    }
  }

  static Future<void> _writeMillisMap(
    Future<File> fileFuture,
    Map<String, int> values,
    String label,
  ) async {
    try {
      final file = await fileFuture;
      await file.parent.create(recursive: true);
      await _writeWithBackup(file, jsonEncode(values));
    } catch (e) {
      debugPrint('[PlaylistStore] 写入$label失败: $e');
    }
  }

  static int? _toMillis(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value');
  }

  static File _backupOf(File file) => File('${file.path}.bak');

  /// 读取文件内容；主文件损坏 / 缺失时回退到 `.bak`（最后一次完整的写入）。
  static Future<String?> _readWithBackup(File file) async {
    var target = file;
    if (!await target.exists()) {
      final bak = _backupOf(file);
      if (!await bak.exists()) return null;
      target = bak;
      debugPrint('[PlaylistStore] ${p.basename(file.path)} 缺失，从 .bak 恢复');
    }
    try {
      return await target.readAsString();
    } catch (e) {
      debugPrint('[PlaylistStore] 读取 ${p.basename(file.path)} 失败: $e');
      return null;
    }
  }

  /// 写入：写 `.tmp` → 旧文件改名 `.bak` → `.tmp` 改名进来。
  ///
  /// 任何时刻磁盘上都有一份完整的文件，掉电 / 崩溃也不会只剩半截 JSON。
  static Future<void> _writeWithBackup(File file, String content) async {
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(content, flush: true);
    final bak = _backupOf(file);
    if (await file.exists()) {
      if (await bak.exists()) {
        await bak.delete();
      }
      await file.rename(bak.path);
    }
    await temp.rename(file.path);
  }
}
