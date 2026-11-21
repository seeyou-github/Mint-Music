import 'dart:convert';
import 'dart:isolate';

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
        _lastFingerprint = null;
        await db.delete(
          'playback_state',
          where: 'key = ?',
          whereArgs: [_rowKey],
        );
        return;
      }

      // 内容没变就直接跳过。
      //
      // [_sanitize] 会把 sourceUrl / 请求头 / 歌词全丢掉，所以「这首在线歌刚
      // 解析出新地址，队列里那一项被替换了」这类变化，写出去的内容和上一次
      // 一模一样；而整队重新 sanitize + 编码一遍仍要花时间（829 首实测
      // 788KB / 28ms，落在主 isolate）。日志里连续切歌时 15 秒写了 4 次，
      // 内容其实只有第一份不同。
      final fingerprint = _fingerprintOf(session);
      if (fingerprint == _lastFingerprint) {
        return;
      }

      // 整队 sanitize / toPersistJson / jsonEncode 是纯 CPU 工作：队列几百上千
      // 首时放在主 isolate 会在切歌后 3 秒左右（DeferredWriter 的落盘时机）
      // 卡一下帧。
      //
      // 但**先在这里把 Song 折成轻量 Map 再进 isolate**：`Isolate.run` 的入参
      // 是深拷贝，直接把整队 `Song` 搬过去会把每首歌词（lrc）、请求头、插件
      // 原始数据一起复制一遍，主 isolate 的拷贝开销比编码本身还大。折成 Map
      // 后带过去的只有基本类型，歌词 / 请求头已经被 [_sanitize] 丢掉。
      // 队列不大时干脆不走 isolate：冷启动一个 isolate 的成本比编码这几十条
      // 数据高得多。
      final queue = session.queue
          .map(_sanitize)
          .map((song) => song.toPersistJson())
          .toList(growable: false);
      final payload = <String, Object?>{
        'song': _sanitize(session.song).toPersistJson(),
        'queue': queue,
        'index': session.index,
        'quality': session.quality,
      };
      final data = queue.length >= _isolateEncodeThreshold
          ? await Isolate.run<String>(() => jsonEncode(payload))
          : jsonEncode(payload);
      await db.insert('playback_state', {
        'key': _rowKey,
        'data': data,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      _lastFingerprint = fingerprint;
    } catch (e) {
      debugPrint('[PlaybackSessionStore] 保存播放会话失败: $e');
    }
  }

  /// 上一次真正写进库的内容指纹（见 [_persist] 的「内容没变就跳过」）。
  int? _lastFingerprint;

  /// 会话内容的轻量指纹：只看落盘会保留的字段（队列顺序 / 歌曲 id 与标题 /
  /// 当前曲目 / 音质）。`sourceUrl`、请求头、歌词这些 [_sanitize] 会丢掉的字段
  /// 不参与，所以「解析出了新地址」不会造成一次多余的写盘。
  static int _fingerprintOf(PlaybackSession session) {
    var hash = session.index.hashCode;
    hash = hash * 31 + session.quality.hashCode;
    hash = hash * 31 + session.song.id.hashCode;
    hash = hash * 31 + session.queue.length;
    for (final song in session.queue) {
      hash = hash * 31 + song.id.hashCode;
      hash = hash * 31 + song.title.hashCode;
      // 本地 / 已下载歌曲的播放路径变了（例如「文件不存在」后重新下载），
      // 或者「本地歌曲」标记变了，都要算一次变化。
      hash = hash * 31 + (song.filePath ?? '').hashCode;
      hash = hash * 31 + (song.playedFromDownload ? 1 : 0);
    }
    return hash;
  }

  /// 队列达到多少首才值得开一个 isolate 来做 jsonEncode。
  ///
  /// 一个 isolate 的冷启动（起线程 + 拷贝入参）本身就有毫秒级开销；几十首的
  /// 队列直接编码反而更快，所以小的走主 isolate。
  static const int _isolateEncodeThreshold = 200;

  static Song _sanitize(Song song) {
    if (song.isLocal) return song;
    return song.copyWith(
      clearSourceUrl: true,
      clearSourceHeaders: true,
      clearSourceQuality: true,
      // 队列里可能带着已加载的整段歌词，落盘没有意义（恢复后重新取），
      // 一整队歌词能把 playback_state 撑到几百 KB。
      clearLrc: true,
    );
  }
}
