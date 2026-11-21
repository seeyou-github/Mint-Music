import 'dart:io';

import '../../../player/domain/models/song.dart';
import '../../../player/domain/services/lyric_parser.dart';
import '../../data/local_metadata_reader.dart';
import '../local_song_filter.dart';

/// 内嵌歌词状态（有没有歌词 / 是不是逐字）的实时读取器。
///
/// 为什么不再把这两个标记写进曲库索引：文件标签可能被外部工具改过（往 MP3
/// 里内嵌 QRC 逐字歌词），索引不会自己跟着更新，于是播放页读文件显示
/// 「QRC」、快速匹配页读索引却没有「逐字」标签。这里统一成「用的时候读文件」，
/// 且只在内存里按「路径 + 文件修改时间」缓存：进程退出即失效，绝不落盘，
/// 文件被改写（mtime 变化）后自动重新读。
class EmbeddedLyricPresence {
  EmbeddedLyricPresence._();

  /// 会话级缓存：key = `路径|修改时间`。歌曲几百首也就几百个条目，很小。
  static final Map<String, LyricPresence> _cache = {};

  /// 读一首歌当前文件里的内嵌歌词状态。文件不存在 / 读失败按「无歌词」。
  static Future<LyricPresence> read(Song song) async {
    final path = song.filePath ?? '';
    if (path.isEmpty) return LyricPresence.none;
    String key;
    try {
      final modified = (await File(path).stat()).modified.millisecondsSinceEpoch;
      key = '$path|$modified';
    } catch (_) {
      return LyricPresence.none;
    }
    final cached = _cache[key];
    if (cached != null) return cached;
    final text = await LocalMetadataReader.readLyrics(path);
    final presence = text == null
        ? LyricPresence.none
        : LyricPresence(
            hasLyric: true,
            hasWordLyric: detectWordLyricFormat(text) != null,
          );
    _cache[key] = presence;
    return presence;
  }

  /// 批量读取：每读完 [concurrency] 首回调一次进度，界面可以边读边更新。
  static Future<Map<String, LyricPresence>> readMany(
    List<Song> songs, {
    int concurrency = 12,
    void Function(Map<String, LyricPresence> batch)? onBatch,
  }) async {
    final result = <String, LyricPresence>{};
    var index = 0;
    while (index < songs.length) {
      final end = (index + concurrency).clamp(0, songs.length);
      final chunk = songs.sublist(index, end);
      index = end;
      final batch = await Future.wait(chunk.map(read));
      final map = <String, LyricPresence>{};
      for (var i = 0; i < chunk.length; i++) {
        map[chunk[i].id] = batch[i];
      }
      result.addAll(map);
      onBatch?.call(map);
    }
    return result;
  }
}
