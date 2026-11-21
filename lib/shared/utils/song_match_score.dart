/// 搜索结果与本地歌曲的字段匹配优先级 / 排序。
///
/// 「编辑标签-在线搜索」与「搜索歌词弹框」共用：按下面的级别给每条结果
/// 定级，**级别越高越靠前**（横向结果列表里越靠左）；同级别保持插件返回
/// 的原顺序。只影响排序，不过滤、不隐藏任何结果。
///
/// 级别按五遍过滤收窄（数字越大越优先，第 5 级最高）：
///
/// * 过滤第 1 遍：匹配歌名 → 命中的保存为 **1 级列表**；
/// * 过滤第 2 遍：1 级列表里继续匹配歌手 → **2 级列表**（1 级去掉这些）；
/// * 过滤第 3 遍：2 级列表里继续匹配时长 → **3 级列表**；
/// * 过滤第 4 遍：3 级列表里继续匹配专辑 → **4 级列表**；
/// * 过滤第 5 遍：4 级列表里继续匹配年份 → **5 级列表**。
///
/// 最终顺序（从左到右）：5 级 > 4 级 > 3 级 > 2 级 > 1 级 > 其它结果
/// （歌名都不匹配的）。同级别保持插件返回的原顺序。
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

/// 单个候选的匹配级别（1~5，数字越大命中字段越多，见文件头注释的五遍
/// 过滤）；连歌名都不匹配返回 0（排在所有有级别的结果之后）。
int songMatchLevel(Song candidate, LocalSongMatchFields local) {
  // 过滤第 1 遍：歌名完全匹配。
  if (!_eq(candidate.title, local.title)) return 0;
  var level = 1;

  // 过滤第 2 遍：歌手。
  if (!_eq(candidate.artist, local.artist)) return level;
  level = 2;

  // 过滤第 3 遍：时长（±2 秒内）。
  if (!_durationMatches(candidate.duration, local.durationSeconds)) {
    return level;
  }
  level = 3;

  // 过滤第 4 遍：专辑。
  if (!_eq(candidate.album, local.album)) return level;
  level = 4;

  // 过滤第 5 遍：年份（双方都有值且一致）。
  if (local.year > 0 && candidate.year == local.year) level = 5;
  return level;
}

/// 按匹配级别降序**稳定**排序（Dart 的 List.sort 不保证稳定，这里带上
/// 原下标一起排，同级别保持插件返回的原顺序）。
List<Song> sortSongsByMatchLevel(
  List<Song> results,
  LocalSongMatchFields local,
) {
  final indexed =
      [
        for (var i = 0; i < results.length; i++)
          (
            index: i,
            song: results[i],
            level: songMatchLevel(results[i], local),
          ),
      ]..sort((a, b) {
        // 级别数字越大越优先（5 级最左）；歌名都不匹配（0）排最后。
        final byLevel = b.level.compareTo(a.level);
        return byLevel != 0 ? byLevel : a.index.compareTo(b.index);
      });
  return [for (final entry in indexed) entry.song];
}
