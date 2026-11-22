import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../player/domain/models/song.dart';
import '../../player/platform/audio_handler.dart';
import '../data/song_audio_cache.dart';
import 'playlist_providers.dart';

/// 这首歌是否属于「我的收藏 / 自建歌单」。
///
/// 直接查库（`PlaylistRepository.isSongInOfflineCachePlaylist`），不依赖
/// `playlistsProvider` 的加载状态：播完回调常常发生在后台 / 歌单页已关闭的
/// 时刻，读内存状态可能还没加载完，会静默漏掉缓存。
Future<bool> songIsInOfflineCachePlaylist(Ref ref, String songId) async {
  if (songId.isEmpty) return false;
  try {
    return await ref
        .read(playlistRepositoryProvider)
        .isSongInOfflineCachePlaylist(songId);
  } catch (e) {
    debugPrint('[SongAudioCache] 歌单判定失败: $e');
    return false;
  }
}

/// 播放前查缓存：只有「收藏 / 自建歌单」里的歌才走本地文件。
///
/// [quality] 是本次要播的档位：切换音质后不能用旧档位的缓存冒充。
Future<String?> findOfflineAudioForSong(
  Ref ref,
  Song song, {
  String quality = '',
}) async {
  if (song.isLocal || song.id.isEmpty) return null;
  if (!await songIsInOfflineCachePlaylist(ref, song.id)) return null;
  return SongAudioCache.findFile(song.id, quality: quality);
}

/// 一首歌听完后的静默缓存。
///
/// * 本地文件 / 已下载文件不处理（本来就在硬盘上）；
/// * 只有收藏 / 自建歌单里的在线歌曲才下载；
/// * 地址用播放时解析出来的那个（[Song.sourceUrl]），请求头与播放保持一致，
///   否则部分 CDN 会拒绝或只返回试听片段；
/// * 失败只打日志：缓存是锦上添花，不能影响播放。
Future<void> cachePlayedSongForOffline(Ref ref, Song song) async {
  if (song.isLocal) return;
  if (song.playedFromDownload) {
    debugPrint('[SongAudioCache] 跳过（已在下载目录）: ${song.title}');
    return;
  }
  final url = song.sourceUrl?.trim() ?? '';
  if (!url.startsWith('http')) {
    debugPrint('[SongAudioCache] 跳过（没有可下载地址）: ${song.title} url=$url');
    return;
  }
  if (!await songIsInOfflineCachePlaylist(ref, song.id)) {
    debugPrint(
      '[SongAudioCache] 跳过（不在收藏 / 自建歌单）: ${song.title} id=${song.id}',
    );
    return;
  }
  final headers = MusicAudioHandler.audioHeadersForUrl(
    url,
    songHeaders: song.sourceHeaders,
  );
  final ok = await SongAudioCache.store(
    song,
    url: url,
    headers: headers,
    quality: song.sourceQuality ?? '',
  );
  debugPrint('[SongAudioCache] 播完缓存${ok ? '成功' : '失败'}: ${song.title}');
}
