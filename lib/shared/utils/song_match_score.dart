/// 搜索结果与本地歌曲的字段匹配打分 / 排序。
///
/// 「编辑标签-在线搜索」与「搜索歌词弹框」共用：按歌曲、歌手、专辑、年份、
/// 时长五个字段逐一比对，**命中的字段越多越靠前**（横向结果列表里越靠左），
/// 全部匹配的排最前；同分保持插件返回的原顺序。只影响排序，不过滤、
/// 不隐藏任何结果。
library;

import '../../features/player/domain/models/song.dart';

/// 匹配时忽略的字符：空白与常见标点 / 括号（全角半角都算），
/// 「你的样子（女版）」与「你的样子 (女版)」这种排版差异不影响匹配。
const String _matchNoiseChars =
    ' \u3000（）()[]【】{}<>《》「」『』"“”\'‘’·、,，.。!！?？:：;；_-—–/\\|&+~';

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

/// 单个候选与本地歌曲的匹配得分：命中的字段数（0~5）。
/// 歌曲 / 歌手 / 专辑 / 年份 / 时长 各算一项；本地侧缺失的字段不计。
int songMatchScore(Song candidate, LocalSongMatchFields local) {
  var score = 0;

  // 歌曲：要求归一化后完全一致（Live / 翻唱版不该算命中同一首歌）。
  final candidateTitle = normalizeForMatch(candidate.title);
  if (local.title.isNotEmpty &&
      candidateTitle == normalizeForMatch(local.title)) {
    score++;
  }

  // 歌手：允许「包含」——很多结果把合作歌手拼在一起（「三妹、苗小青」），
  // 要求完全相等会把它们全判成不匹配。
  final candidateArtist = normalizeForMatch(candidate.artist);
  final artist = normalizeForMatch(local.artist);
  if (artist.isNotEmpty && candidateArtist.isNotEmpty) {
    if (candidateArtist == artist ||
        candidateArtist.contains(artist) ||
        artist.contains(candidateArtist)) {
      score++;
    }
  }

  // 专辑：允许「包含」——结果常带 (Deluxe) / (单曲) 这类后缀。
  final candidateAlbum = normalizeForMatch(candidate.album);
  final album = normalizeForMatch(local.album);
  if (album.isNotEmpty && candidateAlbum.isNotEmpty) {
    if (candidateAlbum == album ||
        candidateAlbum.contains(album) ||
        album.contains(candidateAlbum)) {
      score++;
    }
  }

  // 年份：双方都有值且一致。
  final candidateYear = candidate.year;
  if (local.year > 0 && candidateYear != null && candidateYear == local.year) {
    score++;
  }

  // 时长：双方都有值且相差在容差内。
  if (local.durationSeconds > 0 &&
      candidate.duration > 0 &&
      (candidate.duration - local.durationSeconds).abs() <=
          _durationToleranceSeconds) {
    score++;
  }

  return score;
}

/// 按匹配得分降序**稳定**排序（Dart 的 List.sort 不保证稳定，
/// 这里带上原下标一起排，同分保持插件返回的原顺序）。
List<Song> sortSongsByMatchScore(
  List<Song> results,
  LocalSongMatchFields local,
) {
  final indexed =
      [
        for (var i = 0; i < results.length; i++)
          (
            index: i,
            song: results[i],
            score: songMatchScore(results[i], local),
          ),
      ]..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        return byScore != 0 ? byScore : a.index.compareTo(b.index);
      });
  return [for (final entry in indexed) entry.song];
}
