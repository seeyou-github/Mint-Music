import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm, Database;

import '../../../../core/platform/media_scanner.dart';
import '../../../../core/storage/app_database.dart';
import '../../../../shared/services/cover_cache_service.dart';
import '../../../../shared/utils/local_song_id.dart';
import '../../../player/domain/models/song.dart';
import '../../data/local_music_repository.dart';

/// 本地歌曲改文件名的错误，[message] 是可以直接显示给用户的中文原因。
class LocalSongRenameException implements Exception {
  final String message;

  const LocalSongRenameException(this.message);

  @override
  String toString() => message;
}

/// 本地歌曲改文件名。
///
/// 本地歌曲的 id / 封面缓存 key 都是**文件路径的哈希**（见
/// [localSongIdForPath]），所以改名不只是 `File.rename`：凡是按歌曲 id 或
/// 路径归属的数据都要跟着换，否则「已听 60%」「续播位置」「收藏 / 自建歌单
/// 里的这一条」会全部失效（或者更糟：歌单里留下一条指向旧路径的死条目）。
///
/// 迁移范围：
/// * 本地曲库索引（`local_songs`，走 [LocalMusicRepository] 保持内存一致）；
/// * 封面缓存（`<歌曲id>.jpg`，内存 + 磁盘）；
/// * 临时库：`recently_played`、`download_entries`；
/// * 重要库：`song_play_progress`（已听进度 / 续播）、`playlist_songs`
///   （收藏 / 自建歌单）。
///
/// 播放队列里的这首歌由调用方用 `PlaybackController.replaceSong` 换掉
/// （播放器的状态在 application 层，这里只处理文件与存储）。
class LocalSongRenameService {
  LocalSongRenameService._();

  /// 文件名里不允许出现的字符（按 Windows 最严的口径，各平台统一）。
  static const Set<String> _invalidChars = {
    '\\',
    '/',
    ':',
    '*',
    '?',
    '"',
    '<',
    '>',
    '|',
  };

  /// 文件名主体的长度上限（留出扩展名与长路径的余量）。
  static const int _maxBaseNameLength = 180;

  /// 取文件名主体（不含目录、不含扩展名）。
  static String baseNameOf(String filePath) {
    final name = p.basename(filePath);
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }

  /// 取扩展名（含点、小写；没有扩展名返回空串）。
  static String extensionOf(String filePath) {
    final name = p.basename(filePath);
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return name.substring(dot).toLowerCase();
  }

  /// 校验文件名主体，返回错误文案；null 表示可以用。
  ///
  /// 只改主体、扩展名保持原样（扩展名决定播放器怎么解码，不让用户误改）。
  static String? validate(String baseName) {
    final name = baseName.trim();
    if (name.isEmpty) return '文件名不能为空';
    if (name.length > _maxBaseNameLength) {
      return '文件名太长（最多 $_maxBaseNameLength 个字符）';
    }
    for (final char in _invalidChars) {
      if (name.contains(char)) return '文件名不能包含 \\ / : * ? " < > | 这些字符';
    }
    if (name.endsWith('.')) return '文件名不能以「.」结尾';
    // 首尾空格会被系统静默裁掉，导致「改完名字对不上」。
    if (baseName != baseName.trimRight()) return '文件名不能以空格结尾';
    // Windows 设备名（CON、NUL、COM1…）不能做文件名。
    final upper = name.toUpperCase();
    const reserved = {
      'CON',
      'PRN',
      'AUX',
      'NUL',
      'COM1',
      'COM2',
      'COM3',
      'COM4',
      'COM5',
      'COM6',
      'COM7',
      'COM8',
      'COM9',
      'LPT1',
      'LPT2',
      'LPT3',
      'LPT4',
      'LPT5',
      'LPT6',
      'LPT7',
      'LPT8',
      'LPT9',
    };
    if (reserved.contains(upper)) return '「$name」是系统保留名，请换一个';
    return null;
  }

  /// 改名后的完整路径：同目录 + 新主体 + 原扩展名。
  static String renamedPath(String filePath, String baseName) {
    final name = '${baseName.trim()}${extensionOf(filePath)}';
    final parent = p.dirname(filePath);
    return parent.isEmpty || parent == '.' ? name : p.join(parent, name);
  }

  /// 只改磁盘上的文件名，返回更新了 id / 路径 / 封面 key 的歌曲对象。
  ///
  /// 不碰任何数据库：迁移数据见 [migrateData]（由 [rename] 串起来）。
  static Future<Song> renameFile(Song song, String baseName) async {
    final error = validate(baseName);
    if (error != null) throw LocalSongRenameException(error);

    final oldPath = song.filePath ?? '';
    if (oldPath.isEmpty) {
      throw const LocalSongRenameException('这首歌没有文件路径，无法改文件名');
    }
    final newPath = renamedPath(oldPath, baseName);
    if (newPath == oldPath) return song;

    final source = File(oldPath);
    if (!await source.exists()) {
      throw LocalSongRenameException('找不到歌曲文件：$oldPath');
    }
    // 大小写不敏感的文件系统（Windows）上「只改大小写」也算同一个文件，
    // 先判断出来，别误报「同名文件已存在」。
    final caseOnly = p.equals(newPath, oldPath);
    if (!caseOnly && await File(newPath).exists()) {
      throw const LocalSongRenameException('同目录下已有同名文件，请换一个名字');
    }
    try {
      if (caseOnly) {
        // 直接 rename 会被当成「目标已存在」，走两步：先临时名，再目标名。
        final temp = '$oldPath.mintrename';
        await source.rename(temp);
        await File(temp).rename(newPath);
      } else {
        await source.rename(newPath);
      }
    } catch (e) {
      throw LocalSongRenameException('重命名失败（文件可能正被占用）：$e');
    }
    // Android 的 MediaStore 里还记着旧路径：让系统把新路径重新登记一次
    // （旧条目由系统在下次媒体扫描时清掉）。桌面端没有这条通道，静默失败。
    unawaited(scanFileInMediaStore(newPath));

    return song.copyWith(
      id: localSongIdForPath(newPath),
      filePath: newPath,
      coverKey: localCoverKeyForPath(newPath),
      // 本地歌曲的 sourceUrl 就是文件路径（收藏 / 播放都靠它兜底），一起换掉。
      sourceUrl: _samePath(song.sourceUrl, oldPath) ? newPath : null,
    );
  }

  /// 把「按歌曲 id / 路径归属」的数据从 [before] 迁到 [after]。
  ///
  /// 每一步单独兜错：文件已经改好名字了，某张表迁移失败只影响那一项数据，
  /// 不该让整个改名操作回滚（也回滚不了）。
  static Future<void> migrateData({
    required Song before,
    required Song after,
    LocalMusicRepository? repository,
  }) async {
    if (before.id == after.id && before.filePath == after.filePath) return;

    // 1) 本地曲库索引（内存 + local_songs 表）。
    if (repository != null) {
      try {
        await repository.renameSong(before.id, after);
      } catch (e) {
        debugPrint('[SongRename] 本地索引迁移失败: $e');
      }
    }

    // 2) 封面缓存（按歌曲 id 存成 <id>.jpg）。
    try {
      await CoverCacheService().moveArtwork(before.id, after.id);
    } catch (e) {
      debugPrint('[SongRename] 封面缓存迁移失败: $e');
    }

    // 3) 临时库：最近播放、下载记录。
    try {
      final db = await AppDatabase.cacheDatabase();
      await _migrateRecentlyPlayed(db, before, after);
      await _migrateDownloadEntries(db, before, after);
    } catch (e) {
      debugPrint('[SongRename] 临时库迁移失败: $e');
    }

    // 4) 重要库：已听进度 / 续播、收藏与自建歌单。
    try {
      final db = await AppDatabase.importantDatabase();
      await db.update(
        'song_play_progress',
        {'song_id': after.id},
        where: 'song_id = ?',
        whereArgs: [before.id],
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await _migratePlaylistSongs(db, before, after);
    } catch (e) {
      debugPrint('[SongRename] 重要库迁移失败: $e');
    }
  }

  /// 改文件名 + 迁移数据，返回改名后的歌曲。
  static Future<Song> rename(
    Song song,
    String baseName, {
    LocalMusicRepository? repository,
  }) async {
    final renamed = await renameFile(song, baseName);
    if (identical(renamed, song)) return song;
    await migrateData(before: song, after: renamed, repository: repository);
    return renamed;
  }

  // ------------------------------------------------------------ 表迁移

  static Future<void> _migrateRecentlyPlayed(
    Database db,
    Song before,
    Song after,
  ) async {
    final rows = await db.query(
      'recently_played',
      where: 'song_id = ?',
      whereArgs: [before.id],
    );
    for (final row in rows) {
      final data = AppDatabase.decodeMap(row['data']);
      final songJson = data['song'];
      if (songJson is Map) {
        data['song'] = _patchSongJson(
          Map<String, dynamic>.from(songJson),
          before,
          after,
        );
      }
      await db.update(
        'recently_played',
        {'song_id': after.id, 'data': jsonEncode(data)},
        where: 'song_id = ?',
        whereArgs: [before.id],
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  static Future<void> _migrateDownloadEntries(
    Database db,
    Song before,
    Song after,
  ) async {
    final rows = await db.query(
      'download_entries',
      where: 'song_id = ?',
      whereArgs: [before.id],
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final row in rows) {
      final stored = AppDatabase.decodeMap(row['song_json']);
      final songJson = _patchSongJson(stored, before, after);
      await db.update(
        'download_entries',
        {
          'song_id': after.id,
          'file_path': after.filePath,
          'song_json': jsonEncode(songJson),
          'updated_at': now,
        },
        where: 'song_id = ? AND file_path = ?',
        whereArgs: [before.id, row['file_path']],
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  static Future<void> _migratePlaylistSongs(
    Database db,
    Song before,
    Song after,
  ) async {
    // 同一首歌可能同时躺在收藏和好几个自建歌单里，逐条改（主键含歌单 id）。
    final rows = await db.query(
      'playlist_songs',
      where: 'song_id = ?',
      whereArgs: [before.id],
    );
    for (final row in rows) {
      final data = AppDatabase.decodeMap(row['data']);
      final songJson = _patchSongJson(data, before, after);
      await db.update(
        'playlist_songs',
        {'song_id': after.id, 'data': jsonEncode(songJson)},
        where: 'playlist_id = ? AND song_id = ?',
        whereArgs: [row['playlist_id'], before.id],
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  /// 只改歌曲 JSON 里与文件相关的几个键，其它字段（歌词 / 音源信息 / 附加
  /// 字段）原样保留 —— 不整条重编码，避免顺手丢掉不认识的字段。
  static Map<String, dynamic> _patchSongJson(
    Map<String, dynamic> json,
    Song before,
    Song after,
  ) {
    if (json.isEmpty) return json;
    json['id'] = after.id;
    if (_samePath(json['filePath'] as String?, before.filePath)) {
      json['filePath'] = after.filePath;
    }
    if (json['coverKey'] != null) {
      json['coverKey'] = after.coverKey;
    }
    if (json.containsKey('sourceUrl') &&
        _samePath(json['sourceUrl'] as String?, before.filePath)) {
      json['sourceUrl'] = after.filePath;
    }
    return json;
  }

  static bool _samePath(String? a, String? b) {
    if (a == null || b == null || a.isEmpty || b.isEmpty) return false;
    return p.equals(a.replaceAll('\\', '/'), b.replaceAll('\\', '/'));
  }
}
