import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/storage/app_database.dart';
import '../domain/models/playlist.dart';
import '../../player/domain/models/song.dart';
import 'playlist_store.dart';

/// 收藏（我的收藏 + 收藏的歌单）的读写。
///
/// 数据保存在一个 JSON 文件里（见 [PlaylistStore]），不在数据库中：
/// 收藏变动不频繁，文件形式更方便查看、拷贝与备份还原。
class PlaylistRepository {
  static const _favoritesId = '__favorites__';

  /// 读取全部歌单（含「我的收藏」）。
  Future<List<Playlist>> loadPlaylists() async {
    try {
      var raw = await PlaylistStore.read();
      // 早期版本把收藏放在数据库里，这里一次性搬到 JSON 文件。
      if (raw.isEmpty) {
        final migrated = await _migrateFromDatabase();
        if (migrated.isNotEmpty) {
          raw = migrated;
          await PlaylistStore.write(raw);
        }
      }
      var playlists = raw
          .map((e) => Playlist.fromJson(e))
          .where((p) => p.id.isNotEmpty)
          .toList();

      if (!playlists.any((p) => p.id == _favoritesId)) {
        final now = DateTime.now();
        final favorites = Playlist(
          id: _favoritesId,
          name: '我的收藏',
          description: '收藏的歌曲',
          createTime: now,
          updateTime: now,
        );
        playlists.insert(0, favorites);
        await savePlaylists(playlists);
      } else {
        // 「我的收藏」永远排在最前面。
        final index = playlists.indexWhere((p) => p.id == _favoritesId);
        if (index > 0) {
          final favorites = playlists.removeAt(index);
          playlists.insert(0, favorites);
        }
      }
      return playlists;
    } catch (e) {
      debugPrint('PlaylistRepository.loadPlaylists error: $e');
      rethrow;
    }
  }

  /// 把数据库里（旧版本）的收藏一次性搬到 JSON 文件。
  Future<List<Map<String, dynamic>>> _migrateFromDatabase() async {
    try {
      final db = await AppDatabase.importantDatabase();
      final rows = await db.query('playlists');
      if (rows.isEmpty) return const [];
      final result = <Map<String, dynamic>>[];
      for (final row in rows) {
        final data = AppDatabase.decodeMap(row['data']);
        if (data.isEmpty) continue;
        final id = '${row['id']}';
        if (id.isEmpty) continue;
        final songs = await db.query(
          'playlist_songs',
          where: 'playlist_id = ?',
          whereArgs: [id],
          orderBy: 'sort_order ASC',
        );
        data['songs'] = songs
            .map((s) => AppDatabase.decodeMap(s['data']))
            .where((s) => s.isNotEmpty)
            .toList();
        result.add(data);
      }
      if (result.isNotEmpty) {
        debugPrint('[PlaylistRepository] 已把数据库里的收藏迁移到 JSON 文件');
      }
      return result;
    } catch (e) {
      debugPrint('[PlaylistRepository] 迁移数据库收藏失败: $e');
      return const [];
    }
  }

  /// 覆盖写入全部歌单。
  Future<void> savePlaylists(List<Playlist> playlists) async {
    try {
      await PlaylistStore.write(
        playlists.map((p) => p.toJson()).toList(),
      );
    } catch (e) {
      debugPrint('PlaylistRepository.savePlaylists error: $e');
      rethrow;
    }
  }

  Future<void> savePlaylist(Playlist playlist) async {
    final playlists = await loadPlaylists();
    final existingIndex = playlists.indexWhere((p) => p.id == playlist.id);
    if (existingIndex != -1) {
      playlists[existingIndex] = playlist.copyWith(updateTime: DateTime.now());
    } else {
      playlists.add(playlist);
    }
    await savePlaylists(playlists);
  }

  Future<Playlist> createPlaylist(String name, {String description = ''}) async {
    final playlists = await loadPlaylists();
    final now = DateTime.now();
    final playlist = Playlist(
      id: now.millisecondsSinceEpoch.toString(),
      name: name,
      description: description,
      createTime: now,
      updateTime: now,
    );
    playlists.add(playlist);
    await savePlaylists(playlists);
    return playlist;
  }

  Future<Playlist> createPlaylistWithSongs(
    String name,
    List<Map<String, dynamic>> songsData,
    {String description = ''}
  ) async {
    final playlists = await loadPlaylists();
    final now = DateTime.now();

    final songs = songsData.map((data) {
      return Song(
        id: data['id']?.toString() ?? '',
        title: data['title']?.toString() ?? '未知歌曲',
        artist: data['artist']?.toString() ?? '未知歌手',
        album: data['album']?.toString() ?? '未知专辑',
        duration: (data['duration'] is int) ? data['duration'] as int : 0,
        coverUrl: data['coverUrl']?.toString(),
        sourceUrl: data['sourceUrl']?.toString(),
        source: data['source']?.toString(),
        lrc: data['lrc']?.toString(),
      );
    }).toList();

    final playlist = Playlist(
      id: now.millisecondsSinceEpoch.toString(),
      name: name,
      description: description,
      createTime: now,
      updateTime: now,
      songs: songs,
      coverImgUrl: songs.isNotEmpty ? (songs.first.coverUrl ?? '') : '',
    );
    playlists.add(playlist);
    await savePlaylists(playlists);
    return playlist;
  }

  Future<void> updatePlaylist(Playlist playlist) async {
    final playlists = await loadPlaylists();
    final index = playlists.indexWhere((p) => p.id == playlist.id);
    if (index != -1) {
      playlists[index] = playlist.copyWith(updateTime: DateTime.now());
      await savePlaylists(playlists);
    }
  }

  Future<void> deletePlaylist(String id) async {
    if (id == _favoritesId) return;
    final playlists = await loadPlaylists();
    playlists.removeWhere((p) => p.id == id);
    await savePlaylists(playlists);
    // 记录墓碑，跨设备同步时把这次删除传播到其它端。
    await PlaylistStore.recordTombstone(id);
  }

  /// Returns true if the song was actually added (not a duplicate).
  Future<bool> addSongToPlaylist(String playlistId, Song song) async {
    try {
      final playlists = await loadPlaylists();
      final index = playlists.indexWhere((p) => p.id == playlistId);
      if (index != -1) {
        final playlist = playlists[index];
        if (!playlist.songs.any((s) => s.id == song.id)) {
          final updatedSongs = [song, ...playlist.songs];
          playlists[index] = playlist.copyWith(
            songs: updatedSongs,
            updateTime: DateTime.now(),
            // 歌单封面始终跟随当前第一首歌
            coverImgUrl: updatedSongs.first.coverUrl ?? '',
          );
          await savePlaylists(playlists);
          return true;
        }
      }
      return false;
    } catch (e) {
      debugPrint('PlaylistRepository.addSongToPlaylist error: $e');
      rethrow;
    }
  }

  Future<void> removeSongFromPlaylist(String playlistId, String songId) async {
    final playlists = await loadPlaylists();
    final index = playlists.indexWhere((p) => p.id == playlistId);
    if (index != -1) {
      final playlist = playlists[index];
      final updatedSongs = playlist.songs.where((s) => s.id != songId).toList();
      playlists[index] = playlist.copyWith(
        songs: updatedSongs,
        updateTime: DateTime.now(),
        // 删除歌曲后封面跟随新的第一首歌（没有歌曲时清空）
        coverImgUrl: updatedSongs.isEmpty
            ? ''
            : (updatedSongs.first.coverUrl ?? ''),
      );
      await savePlaylists(playlists);
    }
  }

  Future<String> exportPlaylist(Playlist playlist) async {
    return jsonEncode(playlist.toJson());
  }

  Future<Playlist> importPlaylist(String jsonString) async {
    final data = jsonDecode(jsonString) as Map<String, dynamic>;
    final playlist = Playlist.fromJson(data);
    final playlists = await loadPlaylists();
    final existingIndex = playlists.indexWhere((p) => p.id == playlist.id);
    if (existingIndex != -1) {
      playlists[existingIndex] = playlist.copyWith(updateTime: DateTime.now());
    } else {
      playlists.add(playlist.copyWith(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      ));
    }
    await savePlaylists(playlists);
    return playlist;
  }
}
