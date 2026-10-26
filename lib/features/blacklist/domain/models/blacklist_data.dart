import '../../../player/domain/models/song.dart';
import 'blacklist_entry.dart';

/// 黑名单数据：歌曲黑名单 / 歌手黑名单 / 白名单。
class BlacklistData {
  const BlacklistData({
    this.songs = const [],
    this.artists = const [],
    this.whitelist = const [],
  });

  /// 歌曲黑名单：匹配「歌曲名 + 歌手」。
  final List<BlacklistEntry> songs;

  /// 歌手黑名单：只匹配歌手。
  final List<String> artists;

  /// 白名单：被歌手黑名单拦住时，这些歌可以照常播放。
  final List<BlacklistEntry> whitelist;

  bool get isEmpty => songs.isEmpty && artists.isEmpty && whitelist.isEmpty;

  /// 歌曲本身在黑名单里。
  bool isSongListed(Song song) => songs.any((entry) => entry.matchesSong(song));

  /// 歌手在黑名单里（多歌手时任意一位命中即算）。
  bool isArtistListed(String artist) =>
      artists.any((entry) => blacklistArtistMatches(entry, artist));

  /// 在白名单里（不受歌手黑名单影响）。
  bool isWhitelisted(Song song) =>
      whitelist.any((entry) => entry.matchesSong(song));

  /// 最终是否被拉黑：歌曲黑名单命中，或被歌手黑名单命中且不在白名单。
  bool isBlocked(Song song) =>
      isSongListed(song) ||
      (isArtistListed(song.artist) && !isWhitelisted(song));

  /// 只是因为歌手黑名单才被拉黑（歌曲本身没被单独拉黑）。
  bool isBlockedByArtistOnly(Song song) =>
      !isSongListed(song) &&
      isArtistListed(song.artist) &&
      !isWhitelisted(song);

  BlacklistData copyWith({
    List<BlacklistEntry>? songs,
    List<String>? artists,
    List<BlacklistEntry>? whitelist,
  }) {
    return BlacklistData(
      songs: songs ?? this.songs,
      artists: artists ?? this.artists,
      whitelist: whitelist ?? this.whitelist,
    );
  }

  Map<String, dynamic> toJson() => {
    'songs': songs.map((e) => e.toJson()).toList(),
    'artists': artists,
    'whitelist': whitelist.map((e) => e.toJson()).toList(),
  };

  factory BlacklistData.fromJson(Map<String, dynamic> json) {
    List<BlacklistEntry> readEntries(Object? raw) {
      if (raw is! List) return const [];
      return raw
          .whereType<Map>()
          .map((e) => BlacklistEntry.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => !e.isEmpty)
          .toList(growable: false);
    }

    final rawArtists = json['artists'];
    return BlacklistData(
      songs: readEntries(json['songs']),
      artists: rawArtists is List
          ? rawArtists
                .map((e) => '$e'.trim())
                .where((e) => e.isNotEmpty)
                .toList(growable: false)
          : const [],
      whitelist: readEntries(json['whitelist']),
    );
  }
}
