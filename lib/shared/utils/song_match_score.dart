/// 搜索结果与本地歌曲的字段匹配优先级 / 排序。
///
/// 「编辑标签-在线搜索」与「搜索歌词弹框」共用：给每条结果定一个
/// 1~12 的优先级（1 最靠前），排序后最匹配的排在最左边；同级保持插件
/// 返回的原顺序。只影响排序，不过滤、不隐藏任何结果。
///
/// 优先级（数字越小越靠前）：
///
/// 1. 歌名精确 & 歌手精确 & 时长匹配 & 专辑精确 & 年份匹配；
/// 2. 歌名精确 & 歌手精确 & 时长匹配 & 专辑精确（年份不匹配）；
/// 3. 歌名精确 & 歌手精确 & 时长匹配 & 年份匹配（专辑不匹配）；
/// 4. 歌名精确 & 歌手精确 & 时长匹配（专辑、年份都不匹配）；
/// 5. 歌名精确 & 歌手包含 & 时长匹配；
/// 6. 歌名包含 & 歌手精确 & 时长匹配；
/// 7. 歌名包含 & 歌手包含 & 时长匹配；
/// 8. 歌名精确 & 歌手精确（时长不匹配）；
/// 9. 歌名 / 歌手为「包含」关系的其余组合（时长不匹配）；
/// 12. 其它。
///
/// 「精确」= 归一化后完全相等（忽略空白 / 标点 / 大小写，见
/// [normalizeForMatch]）；「包含」= 双向包含，长字段含短字段即可，
/// 「晴天」与「晴天Live」互相算包含。
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

/// 「其它」结果统一档位（排在最后）。
const int _otherPriority = 12;

/// 两个字段都**非空**且归一化后完全相等。
///
/// 专辑这类字段搜索结果经常为空：空 vs 空虽然「相等」，但没有任何信息量，
/// 不能据此把一条无关结果提到第 1 / 2 档。
bool _exactNonEmpty(String a, String b) {
  final na = normalizeForMatch(a);
  final nb = normalizeForMatch(b);
  return na.isNotEmpty && nb.isNotEmpty && na == nb;
}

/// 双向包含：长字段包含短字段即算命中（任一侧为空都不算）。
bool _containsEither(String a, String b) {
  if (a.isEmpty || b.isEmpty) return false;
  return a.contains(b) || b.contains(a);
}

bool _durationMatches(int candidate, int local) {
  return local > 0 &&
      candidate > 0 &&
      (candidate - local).abs() <= _durationToleranceSeconds;
}

bool _yearMatches(int? candidateYear, int localYear) {
  return localYear > 0 && candidateYear != null && candidateYear == localYear;
}

/// 匹配优先级：返回 1~12，数字越小越靠前（列表里越靠左）。
///
/// 规则见文件头注释；「包含」是双向的，所以「晴天」与「晴天Live」互相命中。
int songMatchPriority(Song candidate, LocalSongMatchFields local) {
  final localTitle = normalizeForMatch(local.title);
  final candidateTitle = normalizeForMatch(candidate.title);
  final localArtist = normalizeForMatch(local.artist);
  final candidateArtist = normalizeForMatch(candidate.artist);

  final titleExact = localTitle.isNotEmpty && candidateTitle == localTitle;
  final artistExact = localArtist.isNotEmpty && candidateArtist == localArtist;
  final titleContains = _containsEither(candidateTitle, localTitle);
  final artistContains = _containsEither(candidateArtist, localArtist);

  // 歌名既不相等也不互相包含：无论歌手多准都只能算「其它」。
  if (!titleContains) return _otherPriority;

  final durationOk = _durationMatches(
    candidate.duration,
    local.durationSeconds,
  );

  if (titleExact && artistExact) {
    if (!durationOk) return 8;
    final albumOk = _exactNonEmpty(candidate.album, local.album);
    final yearOk = _yearMatches(candidate.year, local.year);
    if (albumOk) return yearOk ? 1 : 2;
    return yearOk ? 3 : 4;
  }
  if (titleExact && artistContains) {
    return durationOk ? 5 : 9;
  }
  if (titleContains && artistExact) {
    return durationOk ? 6 : 9;
  }
  if (titleContains && artistContains) {
    return durationOk ? 7 : 9;
  }
  // 歌名命中但歌手既不精确也不包含。
  return _otherPriority;
}

/// 按优先级升序**稳定**排序（Dart 的 List.sort 不保证稳定，这里带上
/// 原下标一起排，同优先级保持插件返回的原顺序）。
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
            priority: songMatchPriority(results[i], local),
          ),
      ]..sort((a, b) {
        // 数字越小越靠左（第 1 优先级在最前）。
        final byPriority = a.priority.compareTo(b.priority);
        return byPriority != 0 ? byPriority : a.index.compareTo(b.index);
      });
  return [for (final entry in indexed) entry.song];
}
