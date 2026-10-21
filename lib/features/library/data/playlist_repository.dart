import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../../core/storage/app_database.dart';
import '../../../core/storage/app_preferences.dart';
import '../domain/models/playlist.dart';
import '../../player/domain/models/song.dart';

/// 收藏（我的收藏 + 收藏的歌单）的持久化。
///
/// 收藏是用户最重要的数据，单独放在「重要库」里
/// （Windows：`AppData\db\mintmusic.db`）：
///
/// * 增删改都是行级操作 —— 给歌单加一首歌只写那一行，不重写整个歌单；
/// * 变更后立即落盘（SQLite 事务 + WAL + `synchronous=FULL`），不会丢。
class PlaylistRepository {
  static const _favoritesId = '__favorites__';

  /// 旧版把整个收藏列表塞在设置文件里的键（首次启动时迁移）。
  static const _legacyKey = 'playlists';

  /// 内存里的歌单缓存，写入时用来做增量对比。
  Map<String, Playlist>? _cache;

  Future<List<Playlist>> loadPlaylists() async {
    try {
      // 已经在内存里了就直接用，避免每次操作都重新查一遍数据库。
      final cached = _cache;
      if (cached != null) return cached.values.toList();

      final db = await AppDatabase.importantDatabase();
      var playlists = await _readAll(db);

      if (playlists.isEmpty &&
          !await AppDatabase.isMigrated('playlists')) {
        playlists = await _importLegacy(db);
        if (AppDatabase.isPersistent) {
          await AppDatabase.markMigrated('playlists');
        }
      }

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
          // 同步内存缓存的顺序
          _cache = {for (final p in playlists) p.id: p};
        }
      }
      return playlists;
    } catch (e) {
      // ignore: avoid_print
      print('PlaylistRepository.loadPlaylists error: $e');
      rethrow;
    }
  }

  Future<void> savePlaylists(List<Playlist> playlists) async {
    try {
      final db = await AppDatabase.importantDatabase();
      if (_cache == null) {
        await _readAll(db);
      }
      await _writeAll(db, playlists);
    } catch (e) {
      // log and rethrow so the notifier can surface the error
      // ignore: avoid_print
      print('PlaylistRepository.savePlaylists error: $e');
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
      // ignore: avoid_print
      print('PlaylistRepository.addSongToPlaylist error: $e');
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

  // ---------------------------------------------------------------- 数据库

  /// 读取全部歌单（含歌曲）。
  Future<List<Playlist>> _readAll(Database db) async {
    final playlistRows = await db.query(
      'playlists',
      orderBy: 'create_time ASC, rowid ASC',
    );
    final songRows = await db.query(
      'playlist_songs',
      orderBy: 'playlist_id ASC, sort_order ASC',
    );

    final songsByPlaylist = <String, List<Map<String, dynamic>>>{};
    for (final row in songRows) {
      final pid = '${row['playlist_id']}';
      songsByPlaylist.putIfAbsent(pid, () => []).add(row);
    }

    final result = <Playlist>[];
    for (final row in playlistRows) {
      final pid = '${row['id']}';
      final meta = AppDatabase.decodeMap(row['data']);
      final songsJson = <Map<String, dynamic>>[];
      for (final songRow in songsByPlaylist[pid] ?? const <Map<String, dynamic>>[]) {
        final songMap = AppDatabase.decodeMap(songRow['data']);
        if (songMap.isEmpty) continue;
        songsJson.add(songMap);
      }
      result.add(
        Playlist.fromJson({...meta, 'id': pid, 'songs': songsJson}),
      );
    }

    _cache = {for (final p in result) p.id: p};
    return result;
  }

  /// 写入全部歌单（行级增量：只写变化过的歌单 / 歌曲）。
  Future<void> _writeAll(Database db, List<Playlist> playlists) async {
    final previous = _cache ?? const <String, Playlist>{};

    await db.transaction((txn) async {
      final currentIds = playlists.map((p) => p.id).toSet();

      // 删掉已经不存在的歌单
      final existingRows = await txn.query('playlists', columns: ['id']);
      for (final row in existingRows) {
        final id = '${row['id']}';
        if (!currentIds.contains(id)) {
          await txn.delete('playlists', where: 'id = ?', whereArgs: [id]);
          await txn.delete(
            'playlist_songs',
            where: 'playlist_id = ?',
            whereArgs: [id],
          );
        }
      }

      for (final playlist in playlists) {
        final meta = playlist.toJson()..remove('songs');
        await txn.insert(
          'playlists',
          {
            'id': playlist.id,
            'name': playlist.name,
            'description': playlist.description,
            'cover_url': playlist.coverImgUrl,
            'source': playlist.source,
            'create_time': playlist.createTime.millisecondsSinceEpoch,
            'update_time': playlist.updateTime.millisecondsSinceEpoch,
            'meta': jsonEncode(playlist.meta),
            'data': jsonEncode(meta),
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );

        final old = previous[playlist.id];
        final oldSongs = old?.songs ?? const <Song>[];
        final oldIndex = <String, int>{};
        final oldJson = <String, String>{};
        for (var i = 0; i < oldSongs.length; i++) {
          oldIndex[oldSongs[i].id] = i;
          oldJson[oldSongs[i].id] = jsonEncode(oldSongs[i].toJson());
        }

        final newIds = <String>{};
        for (var i = 0; i < playlist.songs.length; i++) {
          final song = playlist.songs[i];
          newIds.add(song.id);
          final songJson = jsonEncode(song.toJson());
          final prevPos = oldIndex[song.id];
          if (prevPos != null) {
            // 内容与顺序都没变就不用写。
            if (prevPos == i && oldJson[song.id] == songJson) continue;
            await txn.update(
              'playlist_songs',
              {'sort_order': i, 'data': songJson},
              where: 'playlist_id = ? AND song_id = ?',
              whereArgs: [playlist.id, song.id],
            );
          } else {
            await txn.insert('playlist_songs', {
              'playlist_id': playlist.id,
              'song_id': song.id,
              'sort_order': i,
              'added_at': DateTime.now().millisecondsSinceEpoch,
              'data': songJson,
            });
          }
        }

        for (final removedId in oldIndex.keys) {
          if (!newIds.contains(removedId)) {
            await txn.delete(
              'playlist_songs',
              where: 'playlist_id = ? AND song_id = ?',
              whereArgs: [playlist.id, removedId],
            );
          }
        }
      }
    });

    _cache = {for (final p in playlists) p.id: p};
  }

  /// 首次启动：把旧设置文件里的收藏导入数据库。
  Future<List<Playlist>> _importLegacy(Database db) async {
    final playlists = <Playlist>[];
    try {
      final prefs = await AppPreferences.getInstance();
      final raw = prefs.getString(_legacyKey);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List<dynamic>;
        playlists.addAll(
          list.map((e) => Playlist.fromJson(e as Map<String, dynamic>)),
        );
      }
      if (playlists.isNotEmpty) {
        await _writeAll(db, playlists);
        // 只有真正落盘了才删旧数据，避免降级模式下把收藏弄丢。
        await AppDatabase.removeLegacyKey(_legacyKey);
        // ignore: avoid_print
        print('[PlaylistRepository] 已从旧设置迁移 ${playlists.length} 个歌单');
      }
    } catch (e) {
      // ignore: avoid_print
      print('[PlaylistRepository] 迁移旧收藏失败: $e');
    }
    return playlists;
  }
}
