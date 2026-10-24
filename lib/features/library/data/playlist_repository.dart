import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/storage/app_database.dart';
import '../domain/models/playlist.dart';
import '../utils/favorite_playlist.dart';
import '../../player/domain/models/song.dart';
import 'playlist_store.dart';

/// 收藏（我的收藏 + 收藏的歌单）的读写。
///
/// 数据保存在一个 JSON 文件里（见 [PlaylistStore]），不在数据库中：
/// 收藏变动不频繁，文件形式更方便查看、拷贝与备份还原。
class PlaylistRepository {
  static const _favoritesId = '__favorites__';

  /// 写操作串行化链。
  ///
  /// 收藏文件的写法是「读全部 → 改 → 全量写回」，两个修改操作在 await 点
  /// 交错时会互相覆盖（后写的把先写的改动丢掉）。这里把所有修改排成一条
  /// 链，一次只跑一个；链尾吞掉错误，前一次失败不会卡死后续操作。
  static Future<void> _writeChain = Future.value();

  Future<T> _serialized<T>(Future<T> Function() action) {
    final task = _writeChain.then((_) => action());
    _writeChain = task.then((_) {}, onError: (Object _) {});
    return task;
  }

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
          // 「我的收藏」没有自己的封面，始终显示第一首歌的封面。
          meta: const {coverFromFirstSongKey: true},
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

  /// 覆盖写入全部歌单（内部原语，不经串行化链；外部修改走 [_serialized]）。
  Future<void> savePlaylists(List<Playlist> playlists) async {
    try {
      // 落盘用瘦身版：不带整段歌词 / 请求头，避免收藏文件成倍膨胀。
      await PlaylistStore.write(
        playlists.map((p) => p.toPersistJson()).toList(),
      );
    } catch (e) {
      debugPrint('PlaylistRepository.savePlaylists error: $e');
      rethrow;
    }
  }

  Future<void> savePlaylist(Playlist playlist) {
    return _serialized(() async {
      final playlists = await loadPlaylists();
      final existingIndex = playlists.indexWhere((p) => p.id == playlist.id);
      if (existingIndex != -1) {
        // 早期歌单没有封面来源标记，按更新前的状态补上，避免删歌时改封面。
        final merged = withCoverSourceMeta(
          playlist,
          stored: playlists[existingIndex],
        );
        playlists[existingIndex] = merged.copyWith(updateTime: DateTime.now());
      } else {
        playlists.add(withCoverSourceMeta(playlist));
      }
      await savePlaylists(playlists);
    });
  }

  Future<Playlist> createPlaylist(
    String name, {
    String description = '',
  }) {
    return _serialized(() async {
      final playlists = await loadPlaylists();
      final now = DateTime.now();
      final playlist = Playlist(
        id: now.millisecondsSinceEpoch.toString(),
        name: name,
        description: description,
        createTime: now,
        updateTime: now,
        // 新建的空歌单没有封面，显示第一首歌的封面，所以标记为自动封面。
        meta: const {coverFromFirstSongKey: true},
      );
      playlists.add(playlist);
      await savePlaylists(playlists);
      return playlist;
    });
  }

  Future<Playlist> createPlaylistWithSongs(
    String name,
    List<Map<String, dynamic>> songsData, {
    String description = '',
    String? source,
    String? coverImgUrl,
  }) {
    return _serialized(() async {
      final playlists = await loadPlaylists();
      final now = DateTime.now();

      // 这里必须走 Song.fromJson 全量还原，不能按字段手工 new Song：
      // 手工重建会丢掉 lx（MusicFree 插件的 extra.musicItem）、hash、
      // preferredSource 等字段。丢了 lx 之后，收藏里的 b 站歌曲播放时
      // 插件只能拿到一个最小 musicItem，解析地址就会报
      // 「bilibili 视频信息 -400」（拿不到 bvid/aid/cid）。
      final songs = songsData.map((data) {
        final song = Song.fromJson(data);
        if (song.title.isNotEmpty && song.artist.isNotEmpty && song.album.isNotEmpty) {
          return song;
        }
        return song.copyWith(
          title: song.title.isEmpty ? '未知歌曲' : null,
          artist: song.artist.isEmpty ? '未知歌手' : null,
          album: song.album.isEmpty ? '未知专辑' : null,
        );
      }).toList();

      // 收藏专辑 / 作者时用详情页拿到的封面或头像;普通歌单仍跟随第一首歌。
      final explicitCover = coverImgUrl?.trim() ?? '';
      final fallbackCover = songs.isNotEmpty ? (songs.first.coverUrl ?? '') : '';

      final playlist = Playlist(
        id: now.millisecondsSinceEpoch.toString(),
        name: name,
        description: description,
        source: source ?? 'local',
        createTime: now,
        updateTime: now,
        songs: songs,
        coverImgUrl: explicitCover.isNotEmpty ? explicitCover : fallbackCover,
        // 显式给了封面（专辑 / 作者 / 远端歌单）就固定下来；
        // 只有兜底用第一首歌封面时才随歌曲变化。
        meta: {coverFromFirstSongKey: explicitCover.isEmpty},
      );
      playlists.add(playlist);
      await savePlaylists(playlists);
      return playlist;
    });
  }

  Future<void> updatePlaylist(Playlist playlist) {
    return _serialized(() async {
      final playlists = await loadPlaylists();
      final index = playlists.indexWhere((p) => p.id == playlist.id);
      if (index != -1) {
        // 早期歌单没有封面来源标记，按更新前的状态补上。
        final merged = withCoverSourceMeta(playlist, stored: playlists[index]);
        playlists[index] = merged.copyWith(updateTime: DateTime.now());
        await savePlaylists(playlists);
      }
    });
  }

  Future<void> deletePlaylist(String id) {
    if (id == _favoritesId) return Future.value();
    return _serialized(() async {
      final playlists = await loadPlaylists();
      playlists.removeWhere((p) => p.id == id);
      await savePlaylists(playlists);
      // 记录墓碑，跨设备同步时把这次删除传播到其它端。
      await PlaylistStore.recordTombstone(id);
    });
  }

  /// Returns true if the song was actually added (not a duplicate).
  Future<bool> addSongToPlaylist(String playlistId, Song song) {
    return _serialized<bool>(() async {
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
              // 收藏的专辑 / 作者保留封面；普通歌单只有封面跟随第一首歌时才更新。
              coverImgUrl: playlistCoverAfterSongChange(playlist, updatedSongs),
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
    });
  }

  Future<void> removeSongFromPlaylist(String playlistId, String songId) {
    return _serialized(() async {
      final playlists = await loadPlaylists();
      final index = playlists.indexWhere((p) => p.id == playlistId);
      if (index != -1) {
        final playlist = playlists[index];
        final updatedSongs = playlist.songs.where((s) => s.id != songId).toList();
        playlists[index] = playlist.copyWith(
          songs: updatedSongs,
          updateTime: DateTime.now(),
          // 收藏的专辑 / 作者保留封面；普通歌单只有封面跟随第一首歌时才更新。
          coverImgUrl: playlistCoverAfterSongChange(playlist, updatedSongs),
        );
        await savePlaylists(playlists);
      }
    });
  }

  Future<String> exportPlaylist(Playlist playlist) async {
    return jsonEncode(playlist.toJson());
  }

  Future<Playlist> importPlaylist(String jsonString) {
    return _serialized(() async {
      final data = jsonDecode(jsonString) as Map<String, dynamic>;
      final playlist = Playlist.fromJson(data);
      final playlists = await loadPlaylists();
      final existingIndex = playlists.indexWhere((p) => p.id == playlist.id);
      if (existingIndex != -1) {
        playlists[existingIndex] = withCoverSourceMeta(
          playlist,
          stored: playlists[existingIndex],
        ).copyWith(updateTime: DateTime.now());
      } else {
        playlists.add(
          withCoverSourceMeta(playlist).copyWith(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            createTime: DateTime.now(),
            updateTime: DateTime.now(),
          ),
        );
      }
      await savePlaylists(playlists);
      return playlist;
    });
  }
}
