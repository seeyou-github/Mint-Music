import '../../player/domain/models/song.dart';
import '../domain/models/playlist.dart';
import '../domain/models/recently_played.dart';

/// 收藏专辑 / 作者时写进歌单描述的标记：
/// `mintmusic:album:<source>:<id>` / `mintmusic:artist:<source>:<id>`。
final _collectionMarker = RegExp(r'^mintmusic:(album|artist):([^:]+):');

/// 收藏页里的歌单：区分普通歌单与「收藏的专辑 / 作者」。
extension FavoritePlaylistX on Playlist {
  /// 收藏的专辑 / 作者类型；普通歌单为空。
  ///
  /// 新数据看描述里的标记，早期数据只能按名称前缀识别。
  PlaybackSourceType? get favoriteType {
    final match = _collectionMarker.firstMatch(description.trim());
    if (match != null) {
      return match.group(1) == 'artist'
          ? PlaybackSourceType.artist
          : PlaybackSourceType.album;
    }
    if (name.startsWith('专辑：')) return PlaybackSourceType.album;
    if (name.startsWith('作者：')) return PlaybackSourceType.artist;
    return null;
  }

  /// 去掉「专辑：」「作者：」前缀后的展示名称。
  String get displayName {
    for (final prefix in const ['专辑：', '作者：']) {
      if (name.startsWith(prefix)) {
        final rest = name.substring(prefix.length);
        if (rest.isNotEmpty) return rest;
      }
    }
    return name;
  }

  /// 收藏时所在的音源；普通本地歌单返回 null。
  String? get favoriteSource {
    final match = _collectionMarker.firstMatch(description.trim());
    if (match != null) return match.group(2);
    final value = source.trim();
    if (value.isEmpty || value == 'local') return null;
    return value;
  }

  /// 播放收藏内容时优先使用收藏时记录的音源。
  List<Song> get playbackSongs => applyFavoriteSource(songs, favoriteSource);
}

/// 把 [songs] 的音源统一成收藏时记录的音源。
///
/// 音源变化后原来的播放地址不再适用，所以一并清掉缓存地址，让播放器
/// 按新音源重新解析。
List<Song> applyFavoriteSource(List<Song> songs, String? source) {
  final target = source?.trim();
  if (target == null || target.isEmpty || target == 'local') return songs;
  final targetPlugin = target.contains('@');

  return [
    for (final song in songs)
      if (_keepSongSource(song, target, targetPlugin))
        song
      else
        song.copyWith(
          source: target,
          clearSourceUrl: true,
          clearSourceHeaders: true,
          clearSourceQuality: true,
        ),
  ];
}

/// 歌曲已经在用收藏音源（或同一平台的插件变体）时保持原样。
///
/// 收藏音源只精确到平台（`wy`）时，保留原有的 `wy@插件` —— 变体信息更具体；
/// 收藏音源本身就是插件变体时则强制使用它。
bool _keepSongSource(Song song, String target, bool targetPlugin) {
  if (song.isLocal) return true;
  final current = song.source?.trim();
  if (current == null || current.isEmpty) return false;
  if (current == target) return true;
  if (targetPlugin) return false;
  return _baseSource(current) == target;
}

String _baseSource(String source) {
  final separator = source.indexOf('@');
  return separator <= 0 ? source : source.substring(0, separator);
}
