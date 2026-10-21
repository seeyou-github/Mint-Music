import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/backup/playlist_sync_service.dart';
import '../../../core/backup/webdav_service.dart';
import '../../settings/application/settings_providers.dart';
import '../data/playlist_repository.dart';
import '../domain/models/playlist.dart';
import '../../player/domain/models/song.dart';

final playlistRepositoryProvider = Provider<PlaylistRepository>((ref) {
  return PlaylistRepository();
});

final playlistsProvider = AsyncNotifierProvider<PlaylistsNotifier, List<Playlist>>(
  PlaylistsNotifier.new,
);

class PlaylistsNotifier extends AsyncNotifier<List<Playlist>> {
  @override
  Future<List<Playlist>> build() async {
    final repo = ref.read(playlistRepositoryProvider);
    return repo.loadPlaylists();
  }

  Future<void> createPlaylist(String name, {String description = ''}) async {
    final repo = ref.read(playlistRepositoryProvider);
    await repo.createPlaylist(name, description: description);
    ref.invalidateSelf();
    _syncToRemote();
  }

  Future<void> createPlaylistWithSongs(
    String name,
    List<Map<String, dynamic>> songsData,
    {String description = ''}
  ) async {
    final repo = ref.read(playlistRepositoryProvider);
    await repo.createPlaylistWithSongs(name, songsData, description: description);
    ref.invalidateSelf();
    _syncToRemote();
  }

  Future<void> createPlaylistFromModel(Playlist playlist) async {
    final repo = ref.read(playlistRepositoryProvider);
    await repo.savePlaylist(playlist);
    ref.invalidateSelf();
    _syncToRemote();
  }

  Future<void> updatePlaylist(Playlist playlist) async {
    final repo = ref.read(playlistRepositoryProvider);
    await repo.updatePlaylist(playlist);
    ref.invalidateSelf();
    _syncToRemote();
  }

  Future<void> deletePlaylist(String id) async {
    final repo = ref.read(playlistRepositoryProvider);
    await repo.deletePlaylist(id);
    ref.invalidateSelf();
    _syncToRemote();
  }

  /// 把本地歌单推送到 WebDAV 远端（开启了「歌单实时同步」时）。
  void _syncToRemote() {
    final config = ref.read(webDavConfigProvider);
    if (!config.playlistSyncEnabled || !config.isConfigured) return;
    unawaited(() async {
      try {
        await PlaylistSyncService.push(WebDavService(config));
      } catch (e) {
        debugPrint('[PlaylistsNotifier] 歌单同步到远端失败: $e');
      }
    }());
  }

  /// Returns true if the song was actually added (not a duplicate).
  Future<bool> addSongToPlaylist(String playlistId, Song song) async {
    final repo = ref.read(playlistRepositoryProvider);
    try {
      final added = await repo.addSongToPlaylist(playlistId, song);
      ref.invalidateSelf();
      if (added) _syncToRemote();
      return added;
    } catch (e) {
      // ignore: avoid_print
      print('addSongToPlaylist error: $e');
      ref.invalidateSelf();
      rethrow;
    }
  }

  Future<void> removeSongFromPlaylist(String playlistId, String songId) async {
    // 先同步更新内存状态：Dismissible 的 onDismissed 要求被滑出的条目
    // 在当帧就从列表中移除，否则触发 "A dismissed Dismissible widget is
    // still part of the tree" 断言 → debug 模式闪红屏。
    // 磁盘持久化随后异步完成，成功后 invalidateSelf 从磁盘重读保持一致；
    // 失败时 finally 中 invalidateSelf 回滚为磁盘真实状态。
    final current = state.valueOrNull;
    if (current != null) {
      state = AsyncData(
        current
            .map(
              (p) => p.id == playlistId
                  ? p.copyWith(
                      songs: p.songs.where((s) => s.id != songId).toList(),
                    )
                  : p,
            )
            .toList(),
      );
    }
    final repo = ref.read(playlistRepositoryProvider);
    try {
      await repo.removeSongFromPlaylist(playlistId, songId);
    } catch (e) {
      // ignore: avoid_print
      print('removeSongFromPlaylist error: $e');
    } finally {
      ref.invalidateSelf();
      _syncToRemote();
    }
  }

  Future<void> addSongsToPlaylist(String playlistId, List<Song> songs) async {
    final repo = ref.read(playlistRepositoryProvider);
    for (final song in songs) {
      await repo.addSongToPlaylist(playlistId, song);
    }
    ref.invalidateSelf();
    _syncToRemote();
  }

  Future<String> exportPlaylist(Playlist playlist) async {
    final repo = ref.read(playlistRepositoryProvider);
    return repo.exportPlaylist(playlist);
  }

  Future<Playlist> importPlaylist(String jsonString) async {
    final repo = ref.read(playlistRepositoryProvider);
    final playlist = await repo.importPlaylist(jsonString);
    ref.invalidateSelf();
    return playlist;
  }
}