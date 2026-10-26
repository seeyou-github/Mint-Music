import '../../player/domain/models/song.dart';
import '../domain/models/playlist.dart';
import '../domain/models/recently_played.dart';

/// 收藏专辑 / 作者时写进歌单描述的标记：
/// `mintmusic:album:<source>:<id>` / `mintmusic:artist:<source>:<id>`。
final _collectionMarker = RegExp(r'^mintmusic:(album|artist):([^:]+):([^:]+)');

/// 歌单 meta 里的封面来源标记：`true` 表示封面跟随第一首歌（自动封面），
/// `false` 表示歌单有自己的封面（远端歌单封面 / 专辑封面 / 作者头像）。
const String coverFromFirstSongKey = 'coverFromFirstSong';

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

  /// 收藏时记录的专辑 / 作者 id，重新拉取详情时使用。
  String? get favoriteCollectionId {
    return _collectionMarker.firstMatch(description.trim())?.group(3);
  }

  /// 播放收藏内容时优先使用收藏时记录的音源。
  List<Song> get playbackSongs => applyFavoriteSource(songs, favoriteSource);

  /// 封面是否「跟随第一首歌」（也就是歌单自己没有封面）。
  ///
  /// 新建歌单、没有自带封面的远端歌单用第一首歌的封面；收藏的专辑 / 作者
  /// 与收藏、导入的远端歌单都有自己的封面，不随歌曲变化。
  ///
  /// 新数据看 [coverFromFirstSongKey] 标记；早期数据没有标记，按封面对比推断：
  /// 收藏的专辑 / 作者、收藏 / 导入的远端歌单视为自带封面，其余在上述封面
  /// 为空、或正好等于当前第一首歌封面时视为自动封面。
  bool get coverFromFirstSong {
    final flag = meta[coverFromFirstSongKey];
    if (flag is bool) return flag;
    if (favoriteType != null) return false;
    if (meta['discoverId'] != null) return false;
    final cover = coverImgUrl.trim();
    if (cover.isEmpty) return true;
    final firstCover = songs.isNotEmpty
        ? (songs.first.coverUrl ?? '').trim()
        : '';
    return firstCover.isNotEmpty && cover == firstCover;
  }

  /// 歌单是否有自己的封面（有的话增删歌曲都不能改它）。
  bool get hasOwnCover => !coverFromFirstSong;
}

/// 歌曲列表变化后歌单应使用的封面。
///
/// 歌单有自己的封面（收藏的专辑 / 作者、收藏或导入的远端歌单、用户设置的
/// 封面）时保持原样；只有封面本来就跟随第一首歌时才换成新的第一首歌封面。
String playlistCoverAfterSongChange(
  Playlist playlist,
  List<Song> updatedSongs,
) {
  if (!playlist.coverFromFirstSong) return playlist.coverImgUrl;
  if (updatedSongs.isEmpty) return '';
  return updatedSongs.first.coverUrl ?? '';
}

/// 给歌单补上封面来源标记。
///
/// 新建歌单时由创建方决定；[stored] 用于早期数据（没有标记）——按它当时
/// 的封面推断，避免删歌时把用户自己挑的封面改成第一首歌的封面。
Playlist withCoverSourceMeta(Playlist playlist, {Playlist? stored}) {
  if (playlist.meta.containsKey(coverFromFirstSongKey)) return playlist;
  final follows = (stored ?? playlist).coverFromFirstSong;
  return playlist.copyWith(
    meta: {...playlist.meta, coverFromFirstSongKey: follows},
  );
}

/// 把收藏专辑 / 作者时写进描述的标记音源换成具体插件。
///
/// 描述里的 `mintmusic:album:<source>:<id>` 是「从收藏播放时优先用哪个音源」的
/// 依据；收藏时如果只拿到平台 id（内置源），这里补成具体插件。
/// 不是收藏标记的描述原样返回。
String upgradeFavoriteMarkerSource(String description, String? source) {
  final target = source?.trim() ?? '';
  if (target.isEmpty) return description;
  final match = _collectionMarker.firstMatch(description.trim());
  if (match == null) return description;
  final current = match.group(2) ?? '';
  if (current == target) return description;
  return description.replaceRange(
    match.start,
    match.end,
    'mintmusic:${match.group(1)}:$target:${match.group(3)}',
  );
}

/// 把收藏时记录的插件音源写成「这首歌优先使用的插件」。
///
/// 收藏的专辑 / 作者 / 歌单 / 榜单记的是具体插件（`平台id@插件id`）。播放时
/// 先用这个插件解析地址——比设置里的「优先音源」更具体；插件不
/// 可用时仍按原规则回退，所以这里不改写歌曲的平台音源（[Song.source]）。
///
/// 原来是「直接把 song.source 改成插件变体」，但那样会让内置平台失去兜底
/// 解析时这首歌就算失败，所以改成歌曲级优先插件。
List<Song> applyFavoriteSource(List<Song> songs, String? source) {
  final target = source?.trim();
  if (target == null || target.isEmpty || target == 'local') return songs;
  final targetIsPlugin = target.contains('@');

  return [
    for (final song in songs)
      if (_keepSongSource(song, target, targetIsPlugin))
        song
      else if (targetIsPlugin)
        // 记下优先插件；歌曲原本硬绑在别的插件上时退回平台 id，
        // 否则优先插件根本轮不到（选插件前会按音源过滤 host）。
        song.copyWith(
          source: _shouldDropPluginSource(song, target)
              ? _baseSource(song.source!.trim())
              : null,
          preferredSource: target,
          clearSourceUrl: true,
          clearSourceHeaders: true,
          clearSourceQuality: true,
        )
      else
        song.copyWith(
          source: target,
          clearPreferredSource: true,
          clearSourceUrl: true,
          clearSourceHeaders: true,
          clearSourceQuality: true,
        ),
  ];
}

/// 歌曲当前硬绑的插件和 [target] 不是同一个时，需要退回平台 id。
bool _shouldDropPluginSource(Song song, String target) {
  final current = song.source?.trim() ?? '';
  return current.contains('@') && current != target;
}

/// 歌曲已经在用收藏音源（或同一平台的插件变体）时保持原样。
///
/// 收藏音源只精确到平台（`wy`）时，保留原有的 `wy@插件` —— 变体信息更具体；
/// 收藏音源本身就是插件变体时，已经绑定同一个插件就不必再改。
bool _keepSongSource(Song song, String target, bool targetPlugin) {
  if (song.isLocal) return true;
  final current = song.source?.trim();
  if (targetPlugin) {
    // 已经硬绑到同一个插件，或者已经记着这个优先插件，都不用再改。
    return song.preferredSource == target || current == target;
  }
  if (current == null || current.isEmpty) return false;
  if (current == target) return true;
  return _baseSource(current) == target;
}

String _baseSource(String source) {
  final separator = source.indexOf('@');
  return separator <= 0 ? source : source.substring(0, separator);
}
