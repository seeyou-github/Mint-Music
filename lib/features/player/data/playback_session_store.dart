import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../../core/storage/app_database.dart';
import '../domain/models/song.dart';

/// 上次退出时的播放会话：当前歌曲 + 播放队列。
///
/// 只恢复「听什么」，不恢复播放进度，也不自动开始播放；用户点播放时
/// 再由控制器重新解析在线地址。
class PlaybackSession {
  const PlaybackSession({
    required this.song,
    required this.queue,
    required this.index,
    required this.quality,
  });

  final Song song;
  final List<Song> queue;
  final int index;
  final String quality;
}

/// 播放会话持久化（临时库 `playback_state` 表）。
///
/// 在线歌曲的播放地址、请求头与音质标记会过期，落盘前统一清掉，
/// 恢复后首次播放时重新解析；本地歌曲保留原始地址（文件路径）。
class PlaybackSessionStore {
  PlaybackSessionStore() {
    AppDatabase.registerWriter(_writer);
  }

  static const String _rowKey = 'session';

  late final DeferredWriter _writer = DeferredWriter(
    _persist,
    interval: const Duration(seconds: 3),
  );

  /// 待写入的会话；为 null 表示需要删除已保存的会话。
  PlaybackSession? _pending;

  /// 保存会话（合并写盘）。
  void save(PlaybackSession session) {
    _pending = session;
    _writer.schedule();
  }

  /// 清除已保存的会话（用户清空队列后，重启不再恢复）。
  void clear() {
    _pending = null;
    _writer.schedule();
  }

  /// 读取上次的播放会话；没有可恢复内容时返回 null。
  Future<PlaybackSession?> load() async {
    try {
      final db = await AppDatabase.cacheDatabase();
      final rows = await db.query(
        'playback_state',
        columns: ['data'],
        where: 'key = ?',
        whereArgs: [_rowKey],
        limit: 1,
      );
      if (rows.isEmpty) return null;

      final decoded = AppDatabase.decodeMap(rows.first['data']);
      final queueRaw = decoded['queue'];
      if (queueRaw is! List) return null;

      final queue = <Song>[];
      for (final item in queueRaw) {
        if (item is Map) {
          queue.add(
            Song.fromJson(item.map((key, value) => MapEntry('$key', value))),
          );
        }
      }
      if (queue.isEmpty) return null;

      var index = decoded['index'] is int ? decoded['index'] as int : 0;
      index = index.clamp(0, queue.length - 1);

      final songRaw = decoded['song'];
      final songId = songRaw is Map ? '${songRaw['id'] ?? ''}' : '';
      final matched = songId.isEmpty
          ? -1
          : queue.indexWhere((song) => song.id == songId);
      final resolvedIndex = matched >= 0 ? matched : index;

      return PlaybackSession(
        song: queue[resolvedIndex],
        queue: queue,
        index: resolvedIndex,
        quality: decoded['quality']?.toString() ?? '',
      );
    } catch (e) {
      debugPrint('[PlaybackSessionStore] 读取播放会话失败: $e');
      return null;
    }
  }

  Future<void> _persist() async {
    final session = _pending;
    try {
      final db = await AppDatabase.cacheDatabase();
      if (session == null) {
        await db.delete(
          'playback_state',
          where: 'key = ?',
          whereArgs: [_rowKey],
        );
        return;
      }

      final queue = session.queue.map(_sanitize).toList(growable: false);
      final data = jsonEncode({
        'song': _sanitize(session.song).toJson(),
        'queue': queue.map((song) => song.toJson()).toList(growable: false),
        'index': session.index,
        'quality': session.quality,
      });
      await db.insert('playback_state', {
        'key': _rowKey,
        'data': data,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (e) {
      debugPrint('[PlaybackSessionStore] 保存播放会话失败: $e');
    }
  }

  Song _sanitize(Song song) {
    if (song.isLocal) return song;
    return song.copyWith(
      clearSourceUrl: true,
      clearSourceHeaders: true,
      clearSourceQuality: true,
    );
  }
}
