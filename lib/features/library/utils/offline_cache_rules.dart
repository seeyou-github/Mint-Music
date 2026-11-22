/// 「我的收藏 / 自建歌单」歌曲的离线缓存判定规则。
///
/// 单独放一个纯函数文件：歌单侧（增删歌曲后清缓存）与播放侧（播完写缓存、
/// 播放前查缓存）都要用同一套口径，避免两边以后判断不一致。
library;

import '../domain/models/playlist.dart';
import 'favorite_playlist.dart';

/// 只有「我的收藏」和用户自建歌单里的在线歌曲才会写离线音频缓存。
///
/// 收藏的专辑 / 作者 / 远端歌单是别人整理的内容，用户不一定常听；把它们也
/// 缓存会让 200 首的名额被一次跳转整张专辑占满，所以明确排除。
bool isOfflineCachePlaylist(Playlist playlist) =>
    playlist.id == '__favorites__' || playlist.isUserCreated;

/// 这首歌是否还在某个收藏 / 自建歌单里。
///
/// 歌单移除后用它判断「还有没有别的歌单在用」，决定要不要连带删缓存。
bool playlistsHoldSong(Iterable<Playlist> playlists, String songId) {
  if (songId.isEmpty) return false;
  for (final playlist in playlists) {
    if (!isOfflineCachePlaylist(playlist)) continue;
    if (playlist.songs.any((song) => song.id == songId)) return true;
  }
  return false;
}
