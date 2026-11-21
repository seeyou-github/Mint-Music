import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../../core/storage/app_database.dart';
import '../../player/domain/models/song.dart';
import '../domain/models/download_task.dart';

/// 一条「已下载歌曲」的永久记录（存在 `AppData\temp\db` 的临时库里）。
///
/// 为什么需要它：下载任务本身只活在内存里，重启就没了；而播放时又要「先看看
/// 这首歌是不是已经下载过」。所以下载完成后把「歌曲信息 + 文件路径 + 文件大小
/// + 文件是否还在」单独落库，播放前查一次就能直接播本地文件。
class DownloadRecord {
  const DownloadRecord({
    required this.songId,
    required this.filePath,
    required this.song,
    this.quality = '',
    this.fileSize = 0,
    this.fileExists = true,
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  final String songId;

  /// 音频文件的绝对路径（下载目录里）。
  final String filePath;

  /// 下载时的音质（`320k` / `flac` …）。
  final String quality;

  /// 文件大小（字节）：写入时取一次，之后每次扫描文件存在性时同步。
  final int fileSize;

  /// 上次检查时文件是否还在。
  final bool fileExists;

  /// 基本歌曲信息（封面、时长、音源等），重启后靠它复原下载列表。
  final Song song;

  final int createdAt;
  final int updatedAt;

  DownloadRecord copyWith({
    String? songId,
    String? filePath,
    String? quality,
    int? fileSize,
    bool? fileExists,
    Song? song,
    int? createdAt,
    int? updatedAt,
  }) {
    return DownloadRecord(
      songId: songId ?? this.songId,
      filePath: filePath ?? this.filePath,
      quality: quality ?? this.quality,
      fileSize: fileSize ?? this.fileSize,
      fileExists: fileExists ?? this.fileExists,
      song: song ?? this.song,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// 转成下载列表用的任务（状态为「已完成」或「文件不存在」）。
  DownloadTask toTask() {
    return DownloadTask(
      // 记录里没有 uuid：用文件路径派生一个稳定的 id，重启后同一条记录
      // 的 id 不变，列表复用 / 删除都按它来。
      id: 'disk:${songId.hashCode.toRadixString(16)}:${filePath.hashCode.toRadixString(16)}',
      song: song,
      url: '',
      quality: quality,
      filePath: filePath,
      status: fileExists
          ? DownloadStatus.completed
          : DownloadStatus.fileMissing,
      progress: fileExists ? 1 : 0,
      totalSize: fileSize,
      downloadedSize: fileSize,
      error: fileExists ? null : '文件已删除或移动',
      createdAt: createdAt == 0
          ? DateTime.now().millisecondsSinceEpoch
          : createdAt,
    );
  }

  Map<String, dynamic> toRow() => {
    'song_id': songId,
    'file_path': filePath,
    'quality': quality,
    'file_size': fileSize,
    'file_exists': fileExists ? 1 : 0,
    'song_json': jsonEncode(song.toPersistJson()),
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  static DownloadRecord? fromRow(Map<String, dynamic> row) {
    final songId = (row['song_id'] as String?) ?? '';
    final filePath = (row['file_path'] as String?) ?? '';
    if (songId.isEmpty || filePath.isEmpty) return null;
    Song song;
    try {
      final raw = row['song_json'];
      final map = raw is String && raw.isNotEmpty
          ? jsonDecode(raw) as Map<String, dynamic>
          : <String, dynamic>{};
      song = map.isEmpty
          ? _placeholderSong(songId, filePath)
          : Song.fromJson(map);
    } catch (_) {
      song = _placeholderSong(songId, filePath);
    }
    return DownloadRecord(
      songId: songId,
      filePath: filePath,
      quality: (row['quality'] as String?) ?? '',
      fileSize: (row['file_size'] as int?) ?? 0,
      fileExists: (row['file_exists'] as int?) != 0,
      song: song,
      createdAt: (row['created_at'] as int?) ?? 0,
      updatedAt: (row['updated_at'] as int?) ?? 0,
    );
  }

  /// 歌曲信息损坏时的兜底：列表里至少还能显示个文件名。
  static Song _placeholderSong(String songId, String filePath) {
    final name = filePath.split(RegExp(r'[/\\]')).last;
    final dot = name.lastIndexOf('.');
    return Song(
      id: songId,
      title: dot > 0 ? name.substring(0, dot) : name,
      artist: '',
      album: '',
      duration: 0,
      filePath: filePath,
    );
  }
}

/// [DownloadRecord] 的读写。
///
/// 表在临时库（`AppData\temp\db\mintmusic_cache.db`）的 `download_entries`，
/// 与播放记录等临时数据同一份库，所以不用另外开连接。
class DownloadRecordStore {
  DownloadRecordStore._();

  /// 下载完成后写入 / 覆盖一条记录。
  ///
  /// 文件大小在这里取一次真实值（写标签会改动文件，`task.downloadedSize` 是
  /// 下载过程中的字节数，未必等于最终大小）。
  static Future<void> save(DownloadTask task) async {
    if (kIsWeb) return;
    if (task.filePath.isEmpty) return;
    var size = task.totalSize;
    try {
      final file = File(task.filePath);
      if (await file.exists()) size = await file.length();
    } catch (_) {}
    final now = DateTime.now().millisecondsSinceEpoch;
    final record = DownloadRecord(
      songId: task.song.id,
      filePath: task.filePath,
      quality: task.quality,
      fileSize: size,
      fileExists: true,
      song: task.song,
      createdAt: task.createdAt == 0 ? now : task.createdAt,
      updatedAt: now,
    );
    try {
      final db = await AppDatabase.cacheDatabase();
      await db.insert(
        'download_entries',
        record.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}
  }

  /// 读取全部记录（按下载时间倒序）。
  static Future<List<DownloadRecord>> all() async {
    if (kIsWeb) return const [];
    try {
      final db = await AppDatabase.cacheDatabase();
      final rows = await db.query(
        'download_entries',
        orderBy: 'created_at DESC',
      );
      return rows
          .map(DownloadRecord.fromRow)
          .whereType<DownloadRecord>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 查某首歌的记录（最近的排前面）。
  ///
  /// 同一首歌可能因音质不同存在多条；调用方从前往后挑第一条「文件还在」的。
  static Future<List<DownloadRecord>> findBySong(String songId) async {
    if (kIsWeb || songId.isEmpty) return const [];
    try {
      final db = await AppDatabase.cacheDatabase();
      final rows = await db.query(
        'download_entries',
        where: 'song_id = ?',
        whereArgs: [songId],
        orderBy: 'updated_at DESC',
      );
      return rows
          .map(DownloadRecord.fromRow)
          .whereType<DownloadRecord>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 标记文件已不存在（播放 / 扫描时发现文件没了）。
  static Future<void> markMissing(String songId, String filePath) async {
    await _setExists(songId, filePath, exists: false);
  }

  /// 文件还在：顺手把大小刷新成当前值（用户可能替换过文件）。
  static Future<void> markExists(
    String songId,
    String filePath, {
    int? size,
  }) async {
    await _setExists(songId, filePath, exists: true, size: size);
  }

  static Future<void> _setExists(
    String songId,
    String filePath, {
    required bool exists,
    int? size,
  }) async {
    if (kIsWeb) return;
    try {
      final db = await AppDatabase.cacheDatabase();
      final values = <String, Object?>{
        'file_exists': exists ? 1 : 0,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      };
      if (size != null) values['file_size'] = size;
      await db.update(
        'download_entries',
        values,
        where: 'song_id = ? AND file_path = ?',
        whereArgs: [songId, filePath],
      );
    } catch (_) {}
  }

  /// 删除一条记录（删文件时调用）。
  static Future<void> deleteByPath(String filePath) async {
    if (kIsWeb || filePath.isEmpty) return;
    try {
      final db = await AppDatabase.cacheDatabase();
      await db.delete(
        'download_entries',
        where: 'file_path = ?',
        whereArgs: [filePath],
      );
    } catch (_) {}
  }

  /// 删除某首歌的全部记录（列表里整首删除时用）。
  static Future<void> deleteBySong(String songId) async {
    if (kIsWeb || songId.isEmpty) return;
    try {
      final db = await AppDatabase.cacheDatabase();
      await db.delete(
        'download_entries',
        where: 'song_id = ?',
        whereArgs: [songId],
      );
    } catch (_) {}
  }

  /// 「清除下载记录」：整张表清空。
  static Future<void> clear() async {
    if (kIsWeb) return;
    try {
      final db = await AppDatabase.cacheDatabase();
      await db.delete('download_entries');
    } catch (_) {}
  }

  /// 播放前查：这首歌有没有「下载成功且文件真的还在」的本地文件。
  ///
  /// 返回可播的绝对路径，没有就返回 null。只有记录里 `file_exists = 1` 的才去
  /// 试文件；试的时候文件已经没了（用户在应用外删掉 / 挪走），顺手把记录标成
  /// 不存在，下次播放就不用再白试一次。
  ///
  /// 同一首歌可能有多条记录（不同音质），按 `updated_at` 从新到旧取第一条命中。
  static Future<String?> findPlayableFile(String songId) async {
    if (kIsWeb || songId.isEmpty) return null;
    try {
      final records = await findBySong(songId);
      for (final record in records) {
        if (!record.fileExists || record.filePath.isEmpty) continue;
        if (await File(record.filePath).exists()) return record.filePath;
        await markMissing(record.songId, record.filePath);
      }
    } catch (_) {}
    return null;
  }
}
