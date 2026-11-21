/// 搜索结果与本地歌曲的字段匹配优先级 / 排序。
///
/// 「编辑标签-在线搜索」与「搜索歌词弹框」共用：按下面的级别给每条结果
/// 定级，**级别越高越靠前**（横向结果列表里越靠左）；同级别保持插件返回
/// 的原顺序。只影响排序，不过滤、不隐藏任何结果。
///
/// 级别（第 1 级最高）：
/// 1. 歌名、歌手、专辑、年份、时长 全部匹配；
/// 2. 歌名、歌手、专辑、时长 匹配；
/// 3. 歌名、歌手、时长 匹配；
/// 4. 歌名、歌手 匹配；
/// 5. 歌名 匹配。
library;

import '../../features/player/domain/models/song.dart';

/// 匹配时忽略的字符：空白与常见标点 / 括号（全角半角都算），
/// 「你的样子（女版）」与「你的样子 (女版)」这种排版差异不影响匹配。
const String _matchNoiseChars =
    ' 　（）()[]【】{}<>《》「」『』"“”\'‘’·、,，.。!！?？:：;；_-—–/\\|&+~';

/// 匹配用的归一化：转小写并去掉噪音字符。
String normalizeForMatch(String value) {
  final buffer = StringBuffer();
  for (final rune in value.toLowerCase().runes) {
    final ch = String.fromCharCode(rune);
    if (_matchNoiseChars.contains(ch)) continue;
    buffer.write(ch);
  }
  return buffer.toString();
}

/// 本地歌曲的基准字段（编辑表单的当前内容 / 本地歌曲对象）。
class LocalSongMatchFields {
  const LocalSongMatchFields({
    required this.title,
    required this.artist,
    required this.album,
    required this.year,
    required this.durationSeconds,
  });

  /// 从本地歌曲对象构造。
  factory LocalSongMatchFields.fromSong(Song song) {
    return LocalSongMatchFields(
      title: song.title,
      artist: song.artist,
      album: song.album,
      year: song.year ?? 0,
      durationSeconds: song.duration,
    );
  }

  final String title;
  final String artist;
  final String album;
  final int year;
  final int durationSeconds;
}

/// 时长匹配的容差（秒）：不同音源对时长的取整方向不一样，±2 秒内算匹配。
const int _durationToleranceSeconds = 2;

bool _eq(String a, String b) => normalizeForMatch(a) == normalizeForMatch(b);

bool _durationMatches(int candidate, int local) {
  return local > 0 &&
      candidate > 0 &&
      (candidate - local).abs() <= _durationToleranceSeconds;
}

/// 单个候选的匹配级别（1~5，见文件头注释）；歌名都不匹配返回 0
/// （排在所有有级别的结果之后）。
///
/// 定级按「能够上的最高级别」：例如专辑、年份都匹配但时长不匹配 →
/// 只算第 4 级（第 2/3 级都要求时长）。
int songMatchLevel(Song candidate, LocalSongMatchFields local) {
  // 第 5 级的门槛：歌名匹配。歌名不匹配直接 0。
  if (!_eq(candidate.title, local.title)) return 0;
  if (!_eq(candidate.artist, local.artist)) return 5;

  final duration = _durationMatches(candidate.duration, local.durationSeconds);
  if (!duration) return 4;

  // 第 2 级要求专辑匹配；年份只在第 1 级才要求（双方都有值且一致）。
  if (_eq(candidate.album, local.album)) {
    if (local.year > 0 && candidate.year == local.year) return 1;
    return 2;
  }
  return 3;
}

/// 按匹配级别降序**稳定**排序（Dart 的 List.sort 不保证稳定，这里带上
/// 原下标一起排，同级别保持插件返回的原顺序）。
List<Song> sortSongsByMatchLevel(
  List<Song> results,
  LocalSongMatchFields local,
) {
  final indexed = [
    for (var i = 0; i < results.length; i++)
      (index: i, song: results[i], level: songMatchLevel(results[i], local)),
  ]..sort((a, b) {
      // 歌名都不匹配（level 0）排到所有有级别的结果之后。
      final ka = a.level == 0 ? 99 : a.level;
      final kb = b.level == 0 ? 99 : b.level;
      final byLevel = ka.compareTo(kb);
      return byLevel != 0 ? byLevel : a.index.compareTo(b.index);
    });
  return [for (final entry in indexed) entry.song];
}
