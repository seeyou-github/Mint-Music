import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../features/library/data/playlist_repository.dart';
import '../platform/app_paths.dart';
import '../storage/app_database.dart';
import '../storage/app_preferences.dart';

/// 备份 / 还原服务。
///
/// 备份内容（压缩包内）：
/// - `settings.json`：应用设置（主题、播放、下载等全部配置项）
/// - `plugins/`：插件脚本文件
/// - `playlists.json`：收藏的歌单与「我的收藏」
/// - `local_dirs.json`：本地音乐的扫描目录（**不含歌曲列表**）
///
/// 还原时**强制覆盖**现有配置。
class BackupService {
  const BackupService._();

  /// 备份包里的文件路径。
  static const String settingsEntry = 'settings.json';
  static const String playlistsEntry = 'playlists.json';
  static const String localDirsEntry = 'local_dirs.json';
  static const String pluginsDirEntry = 'plugins';

  /// 备份文件名前缀。
  static const String backupFilePrefix = 'mintmusic-backup';

  /// 备份文件名：`年-月-日-时:分:秒-mintmusic-backup.zip`。
  ///
  /// Windows 的文件名不能含冒号，这里用 `-` 代替（跨平台通用）。
  static String buildBackupFileName([DateTime? now]) {
    final t = now ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}-${two(t.hour)}-${two(t.minute)}-'
        '${two(t.second)}-$backupFilePrefix.zip';
  }

  // ---------------------------------------------------------------- 备份

  /// 生成一个备份压缩包。
  static Future<Uint8List> createBackup() async {
    final archive = Archive();

    // 1) 应用设置
    final prefs = await AppPreferences.getInstance();
    final settings = <String, Object?>{};
    for (final key in prefs.getKeys()) {
      final value = prefs.getString(key);
      if (value != null) {
        settings[key] = value;
        continue;
      }
      final list = prefs.getStringList(key);
      if (list != null) {
        settings[key] = list;
        continue;
      }
      final num = prefs.getInt(key);
      if (num != null) {
        settings[key] = num;
        continue;
      }
      final dbl = prefs.getDouble(key);
      if (dbl != null) {
        settings[key] = dbl;
      }
    }
    archive.addFile(
      ArchiveFile(settingsEntry, jsonEncode(settings).length,
          jsonEncode(settings)),
    );

    // 2) 插件脚本
    final pluginsDir = await AppPaths.pluginDirectory();
    if (await pluginsDir.exists()) {
      await for (final entity in pluginsDir.list(recursive: false)) {
        if (entity is! File) continue;
        final bytes = await entity.readAsBytes();
        final name = p.basename(entity.path);
        archive.addFile(
          ArchiveFile('$pluginsDirEntry/$name', bytes.length, bytes),
        );
      }
    }

    // 3) 收藏的歌单
    final playlists = await _exportPlaylists();
    final playlistsJson = jsonEncode(playlists);
    archive.addFile(
      ArchiveFile(playlistsEntry, playlistsJson.length, playlistsJson),
    );

    // 4) 本地音乐的扫描目录（不含歌曲列表）
    final dirs = await _exportLocalDirs();
    final dirsJson = jsonEncode(dirs);
    archive.addFile(ArchiveFile(localDirsEntry, dirsJson.length, dirsJson));

    final zipped = ZipEncoder().encode(archive);
    return Uint8List.fromList(zipped);
  }

  // ---------------------------------------------------------------- 还原

  /// 用备份包强制覆盖现有配置。
  static Future<void> restoreBackup(Uint8List bytes) async {
    final archive = ZipDecoder().decodeBytes(bytes);

    // 1) 应用设置
    final settingsFile = _findFile(archive, settingsEntry);
    if (settingsFile != null) {
      final raw = utf8.decode(settingsFile.content as List<int>);
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final prefs = await AppPreferences.getInstance();
        // 强制覆盖：先清空再写入
        await prefs.clear();
        for (final entry in decoded.entries) {
          final key = '${entry.key}';
          final value = entry.value;
          if (value is bool) {
            await prefs.setBool(key, value);
          } else if (value is int) {
            await prefs.setInt(key, value);
          } else if (value is double) {
            await prefs.setDouble(key, value);
          } else if (value is List) {
            await prefs.setStringList(
              key,
              value.map((e) => '$e').toList(),
            );
          } else if (value is String) {
            await prefs.setString(key, value);
          }
        }
      }
    }

    // 2) 插件脚本
    final pluginsDir = await AppPaths.pluginDirectory();
    for (final file in archive.files) {
      if (!file.isFile) continue;
      final name = p.basename(file.name);
      if (name.isEmpty) continue;
      final content = file.content;
      if (content is! List<int>) continue;
      final target = File(p.join(pluginsDir.path, name));
      await target.writeAsBytes(content, flush: true);
    }

    // 3) 收藏的歌单
    final playlistsFile = _findFile(archive, playlistsEntry);
    if (playlistsFile != null) {
      final raw = utf8.decode(playlistsFile.content as List<int>);
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        await _importPlaylists(decoded);
      }
    }

    // 4) 本地音乐的扫描目录
    final dirsFile = _findFile(archive, localDirsEntry);
    if (dirsFile != null) {
      final raw = utf8.decode(dirsFile.content as List<int>);
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        await _importLocalDirs(decoded.map((e) => '$e').toList());
      }
    }
  }

  static ArchiveFile? _findFile(Archive archive, String entry) {
    for (final file in archive.files) {
      if (file.isFile && file.name == entry) return file;
    }
    return null;
  }

  // ---------------------------------------------------------------- 歌单 / 目录 导入导出

  /// 导出收藏的歌单（不含本地扫描目录里的歌曲列表）。
  static Future<List<Map<String, dynamic>>> _exportPlaylists() async {
    try {
      final repo = PlaylistRepository();
      final playlists = await repo.loadPlaylists();
      return playlists.map((p) => p.toJson()).toList();
    } catch (e) {
      debugPrint('[BackupService] 导出歌单失败: $e');
      return const [];
    }
  }

  static Future<void> _importPlaylists(List<dynamic> raw) async {
    try {
      final db = await AppDatabase.importantDatabase();
      await db.transaction((txn) async {
        await txn.delete('playlist_songs');
        await txn.delete('playlists');
        for (final item in raw) {
          if (item is! Map) continue;
          final json = item.map((k, v) => MapEntry('$k', v));
          final id = '${json['id'] ?? ''}';
          if (id.isEmpty) continue;
          final name = '${json['name'] ?? ''}';
          final description = '${json['description'] ?? ''}';
          final coverImgUrl = '${json['coverImgUrl'] ?? ''}';
          final source = '${json['source'] ?? 'local'}';
          final createTime = DateTime.tryParse('${json['createTime'] ?? ''}');
          final updateTime = DateTime.tryParse('${json['updateTime'] ?? ''}');
          final songs = (json['songs'] as List?) ?? const [];
          await txn.insert('playlists', {
            'id': id,
            'name': name,
            'description': description,
            'cover_url': coverImgUrl,
            'source': source,
            'create_time':
                (createTime ?? DateTime.now()).millisecondsSinceEpoch,
            'update_time':
                (updateTime ?? DateTime.now()).millisecondsSinceEpoch,
            'meta': jsonEncode(json['meta'] ?? const <String, dynamic>{}),
            'data': jsonEncode(json),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          var order = 0;
          for (final song in songs) {
            if (song is! Map) continue;
            final songJson = song.map((k, v) => MapEntry('$k', v));
            final songId = '${songJson['id'] ?? ''}';
            if (songId.isEmpty) continue;
            await txn.insert('playlist_songs', {
              'playlist_id': id,
              'song_id': songId,
              'sort_order': order,
              'added_at': DateTime.now().millisecondsSinceEpoch,
              'data': jsonEncode(songJson),
            }, conflictAlgorithm: ConflictAlgorithm.replace);
            order++;
          }
        }
      });
    } catch (e) {
      debugPrint('[BackupService] 导入歌单失败: $e');
    }
  }

  /// 导出本地音乐的扫描目录（不含歌曲列表）。
  static Future<List<String>> _exportLocalDirs() async {
    try {
      final db = await AppDatabase.cacheDatabase();
      final rows = await db.query('local_dirs', orderBy: 'added_at ASC');
      return rows.map((r) => '${r['path']}').toList();
    } catch (e) {
      debugPrint('[BackupService] 导出扫描目录失败: $e');
      return const [];
    }
  }

  static Future<void> _importLocalDirs(List<String> dirs) async {
    try {
      final db = await AppDatabase.cacheDatabase();
      await db.transaction((txn) async {
        await txn.delete('local_dirs');
        var order = 0;
        for (final dir in dirs) {
          if (dir.trim().isEmpty) continue;
          await txn.insert('local_dirs', {
            'path': dir,
            'added_at': DateTime.now().millisecondsSinceEpoch,
          });
          order++;
        }
      });
    } catch (e) {
      debugPrint('[BackupService] 导入扫描目录失败: $e');
    }
  }
}
