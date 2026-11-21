/// 搜索结果与本地歌曲的字段匹配优先级 / 排序。
///
/// 「编辑标签-在线搜索」与「搜索歌词弹框」共用：按下面的级别给每条结果
/// 定级，**级别越高越靠前**（横向结果列表里越靠左）；同级别保持插件返回
/// 的原顺序。只影响排序，不过滤、不隐藏任何结果。
///
/// 级别按五遍过滤收窄（数字越大越优先，第 5 级最高）：
///
/// * 过滤第 1 遍：匹配歌名 → 命中的保存为 **1 级候选**；
/// * 过滤第 2 遍：1 级候选里继续匹配歌手 → **2 级候选**；
/// * 过滤第 3 遍：2 级候选里继续匹配时长 → **3 级候选**；
/// * 过滤第 4 遍：3 级候选里继续匹配专辑 → **4 级候选**；
/// * 过滤第 5 遍：4 级候选里继续匹配年份 → **5 级候选**。
///
/// 最终顺序（从左到右）：5 级 > 4 级 > 3 级 > 2 级 > 1 级（= 歌名包含歌名
/// 且歌手包含歌手）> 歌名包含歌名 > 其它结果。同级别保持插件返回的
/// 原顺序。
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

/// 时长匹配的容差（秒）：不同音源对时长的取整方向不一样，±1 秒内算匹配。
const int _durationToleranceSeconds = 1;

bool _eq(String a, String b) => normalizeForMatch(a) == normalizeForMatch(b);

bool _durationMatches(int candidate, int local) {
  return local > 0 &&
      candidate > 0 &&
      (candidate - local).abs() <= _durationToleranceSeconds;
}

/// 匹配定级：返回 (组, 级别)。
///
/// * 组 1 = 歌名**完全匹配**，按 歌手 → 时长 → 专辑 → 年份 逐遍收窄：
///   级别 4 = 五字段全中；3 = 歌名+歌手+时长+专辑（年份✗）；
///   2 = 歌名+歌手+时长（专辑✗）；1 = 歌名+歌手（时长✗）。
/// * 组 0 = 歌名不完全匹配，按包含关系分档：
///   档 2 = 歌名包含歌名且歌手包含歌手（新 1 级）；
///   档 1 = 仅歌名包含歌名（含「歌名精确但歌手不匹配」的歌）。
///
/// 排序：组 1 在前（级别 4→1），组 0 在后（档 2→1）。
(int, int) songMatchGroupAndLevel(Song candidate, LocalSongMatchFields local) {
  final localTitle = normalizeForMatch(local.title);
  final candidateTitle = normalizeForMatch(candidate.title);
  final titleExact = localTitle.isNotEmpty && candidateTitle == localTitle;
  final titleContains =
      localTitle.isNotEmpty && candidateTitle.contains(localTitle);
  final localArtist = normalizeForMatch(local.artist);
  final candidateArtist = normalizeForMatch(candidate.artist);
  final artistExact = localArtist.isNotEmpty && candidateArtist == localArtist;
  final artistContains =
      localArtist.isNotEmpty && candidateArtist.contains(localArtist);

  // 歌名完全匹配：歌手 / 时长 / 专辑 / 年份 逐遍收窄。
  if (titleExact) {
    if (!artistExact) return (0, 2); // 歌名精确但歌手不匹配：按「歌名包含」垫底
    if (!_durationMatches(candidate.duration, local.durationSeconds)) {
      return (1, 2); // 2 级：歌名 + 歌手
    }
    if (!_eq(candidate.album, local.album)) return (1, 3); // 3 级：+ 时长
    if (local.year > 0 && candidate.year == local.year) {
      return (1, 5); // 5 级：+ 专辑 + 年份
    }
    return (1, 4); // 4 级：+ 专辑（年份✗）
  }

  // 歌名不完全相等：双包含 → 新 1 级；仅歌名包含 → 组 0 档 2；其它 → 档 1。
  if (titleContains && artistContains) return (1, 1);
  if (titleContains) return (0, 2);
  return (0, 1);
}

/// 按定级降序**稳定**排序（Dart 的 List.sort 不保证稳定，这里带上
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
            rank: songMatchGroupAndLevel(results[i], local),
          ),
      ]..sort((a, b) {
        // 组 1（歌名完全匹配）在前、组 0 在后；组内级别 / 档位大的靠左。
        final byGroup = b.rank.$1.compareTo(a.rank.$1);
        if (byGroup != 0) return byGroup;
        final byLevel = b.rank.$2.compareTo(a.rank.$2);
        return byLevel != 0 ? byLevel : a.index.compareTo(b.index);
      });
  return [for (final entry in indexed) entry.song];
}
