import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../player/domain/models/song.dart';
import '../../player/platform/audio_handler.dart';
import '../data/song_audio_cache.dart';
import '../domain/models/playlist.dart';
import '../utils/offline_cache_rules.dart';
import 'playlist_providers.dart';

/// 取当前歌单列表（未加载完时等一小会儿）。
///
/// 播放链路里不能因为歌单还没加载完就永远错过缓存：启动后立刻恢复队列时，
/// 首次播放可能正好赶上歌单初始化。等 3 秒仍拿不到就按「不是收藏歌曲」处理，
/// 走在线播放不会出错。
Future<List<Playlist>?> playlistsForSongCache(Ref ref) async {
  try {
    final current = ref.read(playlistsProvider);
    final value = current.valueOrNull;
    if (value != null) return value;
    return await ref
        .read(playlistsProvider.future)
        .timeout(const Duration(seconds: 3));
  } catch (e) {
    // provider 已销毁 / 歌单加载失败：本次按「没有缓存」处理，不影响播放。
    debugPrint('[SongAudioCache] 读取歌单失败，本次按无缓存处理: $e');
    return null;
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
  final playlists = await playlistsForSongCache(ref);
  if (playlists == null || !playlistsHoldSong(playlists, song.id)) return null;
  return SongAudioCache.findFile(song.id, quality: quality);
}

/// 一首歌自然播完后的静默缓存。
///
/// * 本地文件 / 已下载文件不处理（本来就在硬盘上）；
/// * 只有收藏 / 自建歌单里的在线歌曲才下载；
/// * 地址用播放时解析出来的那个（[Song.sourceUrl]），请求头与播放保持一致，
///   否则部分 CDN 会拒绝或只返回试听片段；
/// * 失败只打日志：缓存是锦上添花，不能影响播放。
Future<void> cachePlayedSongForOffline(Ref ref, Song song) async {
  if (song.isLocal || song.playedFromDownload) return;
  final url = song.sourceUrl?.trim() ?? '';
  if (!url.startsWith('http')) return;
  final playlists = await playlistsForSongCache(ref);
  if (playlists == null || !playlistsHoldSong(playlists, song.id)) return;
  final headers = MusicAudioHandler.audioHeadersForUrl(
    url,
    songHeaders: song.sourceHeaders,
  );
  await SongAudioCache.store(
    song,
    url: url,
    headers: headers,
    quality: song.sourceQuality ?? '',
  );
}
