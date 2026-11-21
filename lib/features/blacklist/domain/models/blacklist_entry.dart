import '../../../player/domain/models/song.dart';

/// 文本归一化：黑名单匹配不区分大小写、多余空格。
String blacklistNormalize(String value) {
  return value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
}

/// 歌手名的几种常见分隔符：一首歌可能有多个歌手（`A/B`、`A、B`、`A feat. B`…）。
///
/// 歌手黑名单按「其中任意一位」匹配，否则 `周杰伦/费玉清` 这种合唱曲
/// 拉黑了周杰伦也不会被拦住。
final RegExp _artistSeparators = RegExp(
  r'\s*(?:/|、|,|，|;|；|&|＆|\+|\bfeat\.?\b|\bft\.?\b|\bvs\.?\b)\s*',
  caseSensitive: false,
);

/// 把 `A/B` 拆成 `[A, B]`（已归一化，去空）。
List<String> blacklistArtistParts(String artist) {
  final parts = artist
      .split(_artistSeparators)
      .map(blacklistNormalize)
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  if (parts.isEmpty) {
    final whole = blacklistNormalize(artist);
    return whole.isEmpty ? const [] : [whole];
  }
  return parts;
}

/// 歌手是否命中：整串相等，或任意一位歌手相等。
bool blacklistArtistMatches(String listArtist, String songArtist) {
  final target = blacklistNormalize(listArtist);
  if (target.isEmpty) return false;
  final whole = blacklistNormalize(songArtist);
  if (whole == target) return true;
  return blacklistArtistParts(songArtist).contains(target);
}

/// 黑名单里的一个歌曲条目（歌曲名 + 歌手）。
class BlacklistEntry {
  const BlacklistEntry({required this.title, required this.artist});

  final String title;
  final String artist;

  /// 去重 / 编辑用的唯一键。
  String get key =>
      '${blacklistNormalize(title)}|${blacklistNormalize(artist)}';

  bool get isEmpty => title.trim().isEmpty && artist.trim().isEmpty;

  /// 是否就是这首歌（歌曲名 + 歌手都匹配）。
  bool matchesSong(Song song) {
    if (blacklistNormalize(song.title) != blacklistNormalize(title)) {
      return false;
    }
    return blacklistArtistMatches(artist, song.artist);
  }

  BlacklistEntry copyWith({String? title, String? artist}) {
    return BlacklistEntry(
      title: title ?? this.title,
      artist: artist ?? this.artist,
    );
  }

  Map<String, dynamic> toJson() => {'title': title, 'artist': artist};

  factory BlacklistEntry.fromJson(Map<String, dynamic> json) {
    return BlacklistEntry(
      title: json['title']?.toString() ?? '',
      artist: json['artist']?.toString() ?? '',
    );
  }
}
