import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../../core/backup/playlist_merge.dart';
import '../../../core/storage/app_database.dart';
import '../../../core/storage/app_preferences.dart';
import '../domain/models/playlist.dart';
import '../utils/favorite_playlist.dart';
import '../../player/domain/models/song.dart';
import 'playlist_store.dart';

/// 收藏（我的收藏 + 收藏的歌单）的读写。
///
/// ## 为什么用数据库
///
/// 早先是 `config/playlists.json` 一个文件，写法是「读全部 → 改 → 全量写回」。
/// 上千首之后每收藏一首歌都要重写整份文件：实测 2000 首时一次约 80ms CPU +
/// 2MB 落盘，Android 上还要更慢。改成重要库的两张表后，单曲增删就是一条
/// `INSERT` / `DELETE`。
///
/// * `playlists`：歌单元数据，`data` 存整条歌单 JSON（不含歌曲）；
/// * `playlist_songs`：歌曲条目，`sort_order` 升序即展示顺序，`added_at`
///   是「这一条最后一次变更时间」，供跨设备**逐首合并**判断谁更新。
///
/// ## 跨设备同步
///
/// 远端仍然是「一份 `playlists.json` 快照」（现在 gzip 压缩），由
/// [exportAll] / [importAll] 与数据库互转，所以同步协议、备份包结构都跟以前
/// 兼容；老版本留下的 `config/playlists.json` 会在首次读取时自动迁移进库。
class PlaylistRepository {
  static const _favoritesId = '__favorites__';

  /// 迁移标记：老 `playlists.json` 已经搬进数据库。
  static const String _migratedKey = 'playlists_in_db_v1';

  /// 歌单元数据被修改的时间（塞在 `meta` 里，随快照一起走）。
  ///
  /// 逐首合并时歌曲用各自的 `added_at` 判断，元数据（名字 / 封面）用这个时间，
  /// 否则「这台改了名、那台加了首歌」会让改名被较新的加歌时间覆盖掉。
  static const String metaUpdatedAtKey = playlistMetaUpdatedAtKey;

  static bool _migrationDone = false;

  /// 写操作沿用「串行化」：多个修改排队执行，避免事务互相打断。
  static Future<void> _writeChain = Future.value();

  Future<T> _serialized<T>(Future<T> Function() action) {
    final task = _writeChain.then((_) => action());
    _writeChain = task.then((_) {}, onError: (Object _) {});
    return task;
  }

  // ---------------------------------------------------------------- 读取

  /// 读取全部歌单（含「我的收藏」，永远排在最前面）。
  Future<List<Playlist>> loadPlaylists() async {
    try {
      await _migrateLegacyFile();
      final db = await AppDatabase.importantDatabase();
      var playlists = await _readPlaylists(db);

      if (playlists.isEmpty) {
        final favorites = _favoritesPlaylist(DateTime.now());
        await _writePlaylist(db, favorites, withSongs: true);
        return [favorites];
      }
      if (!playlists.any((p) => p.id == _favoritesId)) {
        final favorites = _favoritesPlaylist(DateTime.now());
        await _writePlaylist(db, favorites, withSongs: true);
        playlists = [favorites, ...playlists];
      }
      // 「我的收藏」永远排在最前面。
      final index = playlists.indexWhere((p) => p.id == _favoritesId);
      if (index > 0) {
        final favorites = playlists.removeAt(index);
        playlists.insert(0, favorites);
      }
      return playlists;
    } catch (e) {
      debugPrint('PlaylistRepository.loadPlaylists error: $e');
      rethrow;
    }
  }

  /// 全部歌单的快照（同步 / 备份用）。
  ///
  /// 每首歌多带一个 `updatedAt`：这是「这条记录最后变更时间」，逐首合并时
  /// 用来判断同 id 的两份哪份更新；老版本客户端不认识这个键，会原样忽略。
  Future<List<Map<String, dynamic>>> exportAll() async {
    await _migrateLegacyFile();
    final db = await AppDatabase.importantDatabase();
    final rows = await db.query(
      'playlists',
      orderBy: 'sort_order ASC, create_time ASC, id ASC',
    );
    if (rows.isEmpty) return const [];
    final songRows = await db.query(
      'playlist_songs',
      orderBy: 'playlist_id ASC, sort_order ASC',
    );
    final songsByPlaylist = <String, List<Map<String, dynamic>>>{};
    for (final row in songRows) {
      final data = AppDatabase.decodeMap(row['data']);
      if (data.isEmpty) continue;
      final updatedAt = (row['added_at'] as num?)?.toInt() ?? 0;
      songsByPlaylist.putIfAbsent('${row['playlist_id']}', () => []).add({
        ...data,
        'updatedAt': updatedAt,
      });
    }
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      final data = AppDatabase.decodeMap(row['data']);
      final id = '${row['id']}';
      final base = data.isNotEmpty
          ? (data..remove('songs'))
          : (_playlistFromRow(row, const []).toPersistJson()..remove('songs'));
      // `songs` 统一放在最后，快照在两端之间往返时键顺序保持一致
      // （同步里判断「有没有变化」直接用字符串比较）。
      result.add({
        ...base,
        'songs': songsByPlaylist[id] ?? const <Map<String, dynamic>>[],
      });
    }
    // 「我的收藏」排在最前面，和老文件顺序一致。
    final index = result.indexWhere((p) => '${p['id']}' == _favoritesId);
    if (index > 0) {
      final favorites = result.removeAt(index);
      result.insert(0, favorites);
    }
    return result;
  }

  /// 用一份快照覆盖数据库里的全部收藏（同步合并结果 / 还原备份用）。
  ///
  /// 时间戳原样写回，不做「现在」的更新，否则每次同步都会让本地看起来更新，
  /// 另一端就再也合不进来。
  Future<void> importAll(List<Map<String, dynamic>> snapshot) {
    return _serialized(() async {
      final db = await AppDatabase.importantDatabase();
      await db.transaction((txn) async {
        await txn.delete('playlist_songs');
        await txn.delete('playlists');
        var order = 0;
        for (final item in snapshot) {
          final json = item.map((key, value) => MapEntry(key, value));
          final rawSongs = json['songs'];
          final playlistJson = {...json}..remove('songs');
          final playlist = Playlist.fromJson(playlistJson);
          if (playlist.id.isEmpty) continue;
          await _insertRow(txn, playlist, sortOrder: order++);
          if (rawSongs is List) {
            var songOrder = 0;
            final batch = txn.batch();
            for (final songItem in rawSongs) {
              if (songItem is! Map) continue;
              final songJson = songItem.map(
                (key, value) => MapEntry('$key', value),
              );
              final updatedAt = (songJson.remove('updatedAt') as num?)?.toInt();
              batch.insert('playlist_songs', {
                'playlist_id': playlist.id,
                'song_id': '${songJson['id'] ?? ''}',
                'sort_order': songOrder++,
                'added_at':
                    updatedAt ?? playlist.updateTime.millisecondsSinceEpoch,
                'data': jsonEncode(songJson),
              }, conflictAlgorithm: ConflictAlgorithm.replace);
            }
            await batch.commit(noResult: true);
          }
        }
      });
    });
  }

  // ---------------------------------------------------------------- 写入

  /// 覆盖写入一条歌单（含歌曲）。歌单不存在时创建。
  Future<void> savePlaylist(Playlist playlist) {
    return _serialized(() async {
      final db = await AppDatabase.importantDatabase();
      await db.transaction((txn) async {
        final stored = await _playlistById(txn, playlist.id);
        final merged = stored == null
            ? withCoverSourceMeta(playlist)
            : withCoverSourceMeta(playlist, stored: stored);
        final now = DateTime.now();
        await _writePlaylist(
          txn,
          _touchMeta(merged, now),
          withSongs: true,
          songs: merged.songs,
        );
      });
    });
  }

  Future<Playlist> createPlaylist(String name, {String description = ''}) {
    return _serialized(() async {
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
      final db = await AppDatabase.importantDatabase();
      await _writePlaylist(db, _touchMeta(playlist, now), withSongs: false);
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
      final now = DateTime.now();

      // 这里必须走 Song.fromJson 全量还原，不能按字段手工 new Song：
      // 手工重建会丢掉 lx（MusicFree 插件的 extra.musicItem）、hash、
      // preferredSource 等字段。丢了 lx 之后，收藏里的 b 站歌曲播放时
      // 插件只能拿到一个最小 musicItem，解析地址就会报
      // 「bilibili 视频信息 -400」（拿不到 bvid/aid/cid）。
      final songs = songsData.map((data) {
        final song = Song.fromJson(data);
        if (song.title.isNotEmpty &&
            song.artist.isNotEmpty &&
            song.album.isNotEmpty) {
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
      final fallbackCover = songs.isNotEmpty
          ? (songs.first.coverUrl ?? '')
          : '';
      final hasOwnCover = explicitCover.isNotEmpty;

      final playlist = Playlist(
        id: now.millisecondsSinceEpoch.toString(),
        name: name,
        description: description,
        source: source ?? 'local',
        createTime: now,
        updateTime: now,
        songs: songs,
        coverImgUrl: hasOwnCover ? explicitCover : fallbackCover,
        // 显式给了封面（专辑 / 作者 / 远端歌单）就固定下来；
        // 只有兜底用第一首歌封面时才随歌曲变化。
        meta: {coverFromFirstSongKey: !hasOwnCover},
      );
      final db = await AppDatabase.importantDatabase();
      await _writePlaylist(
        db,
        _touchMeta(playlist, now),
        withSongs: true,
        songs: songs,
      );
      return playlist;
    });
  }

  Future<void> updatePlaylist(Playlist playlist) {
    return _serialized(() async {
      final db = await AppDatabase.importantDatabase();
      await db.transaction((txn) async {
        final stored = await _playlistRowById(txn, playlist.id);
        if (stored == null) return;
        // 早期歌单没有封面来源标记，按更新前的状态推断（那只老数据才需要
        // 把歌读出来，正常数据用不到）。
        final base = stored.meta.containsKey(coverFromFirstSongKey)
            ? stored
            : (await _playlistById(txn, playlist.id) ?? stored);
        final merged = withCoverSourceMeta(playlist, stored: base);
        final now = DateTime.now();
        // 界面上只是改名 / 换封面时不动歌曲表（避免把几百行重写一遍）。
        // 传进来的歌单没有歌曲（只带了元数据）时也按「只改元数据」处理，
        // 否则一次改名就会把整张歌单清空。
        final replaceSongs =
            merged.songs.isNotEmpty &&
            !_sameSongIdList(await _songIdsOf(txn, playlist.id), merged.songs);
        await _writePlaylist(
          txn,
          _touchMeta(merged, now),
          withSongs: replaceSongs,
          songs: replaceSongs ? merged.songs : const [],
        );
      });
    });
  }

  Future<void> deletePlaylist(String id) {
    if (id == _favoritesId) return Future.value();
    return _serialized(() async {
      final db = await AppDatabase.importantDatabase();
      await db.transaction((txn) async {
        await txn.delete(
          'playlist_songs',
          where: 'playlist_id = ?',
          whereArgs: [id],
        );
        await txn.delete('playlists', where: 'id = ?', whereArgs: [id]);
      });
      // 记录墓碑，跨设备同步时把这次删除传播到其它端。
      await PlaylistStore.recordTombstone(id);
      final songTombstones = await PlaylistStore.readSongTombstones();
      if (songTombstones.remove(id) != null) {
        await PlaylistStore.writeSongTombstones(songTombstones);
      }
    });
  }

  /// 保存用户自定义的歌单顺序（「我的收藏」固定在最前，不参与排序）。
  Future<void> reorderPlaylists(List<String> orderedIds) {
    return _serialized(() async {
      final db = await AppDatabase.importantDatabase();
      await db.transaction((txn) async {
        var order = 0;
        final batch = txn.batch();
        for (final id in orderedIds) {
          if (id == _favoritesId) continue;
          batch.update(
            'playlists',
            {'sort_order': order++},
            where: 'id = ?',
            whereArgs: [id],
          );
        }
        await batch.commit(noResult: true);
      });
    });
  }

  /// Returns true if the song was actually added (not a duplicate).
  Future<bool> addSongToPlaylist(String playlistId, Song song) {
    return _serialized<bool>(() async {
      try {
        final db = await AppDatabase.importantDatabase();
        final added = await db.transaction<bool>((txn) async {
          // 只取歌单行，不把整张歌单的歌都读出来解析一遍：一次加一首歌要读
          // 800 首的话，「收藏整个歌单」会退化成 O(n²)。
          final stored = await _playlistRowById(txn, playlistId);
          if (stored == null) return false;
          if (await _hasSong(txn, playlistId, song.id)) return false;

          final minOrder = await _minSortOrder(txn, playlistId);
          final now = DateTime.now();
          await txn.insert('playlist_songs', {
            'playlist_id': playlistId,
            'song_id': song.id,
            // 新收藏的歌插在最前面：用比当前最小序更小的值，不用整表后移。
            'sort_order': minOrder == null ? 0 : minOrder - 1,
            'added_at': now.millisecondsSinceEpoch,
            'data': jsonEncode(song.toPersistJson()),
          }, conflictAlgorithm: ConflictAlgorithm.replace);

          await _touchAfterSongChange(txn, stored, now);
          return true;
        });
        if (added) {
          // 之前删过同一首：墓碑要清掉，否则下次同步又被判成删除。
          await PlaylistStore.clearSongTombstone(playlistId, song.id);
        }
        return added;
      } catch (e) {
        debugPrint('PlaylistRepository.addSongToPlaylist error: $e');
        rethrow;
      }
    });
  }

  /// 批量加歌（收藏整个专辑 / 歌单 / 榜单时用），一个事务写完。
  ///
  /// 顺序和逐首添加一致：最后加的那首排最前。返回真正新增的条数。
  Future<int> addSongsToPlaylist(String playlistId, List<Song> songs) {
    if (songs.isEmpty) return Future.value(0);
    return _serialized<int>(() async {
      final db = await AppDatabase.importantDatabase();
      final addedIds = <String>[];
      await db.transaction((txn) async {
        final stored = await _playlistRowById(txn, playlistId);
        if (stored == null) return;
        final existing = {
          for (final row in await txn.query(
            'playlist_songs',
            columns: ['song_id'],
            where: 'playlist_id = ?',
            whereArgs: [playlistId],
          ))
            '${row['song_id']}',
        };
        var order = await _minSortOrder(txn, playlistId) ?? 0;
        final now = DateTime.now();
        final batch = txn.batch();
        for (final song in songs) {
          if (!existing.add(song.id)) continue;
          order -= 1;
          addedIds.add(song.id);
          batch.insert('playlist_songs', {
            'playlist_id': playlistId,
            'song_id': song.id,
            'sort_order': order,
            'added_at': now.millisecondsSinceEpoch,
            'data': jsonEncode(song.toPersistJson()),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        if (addedIds.isEmpty) return;
        await batch.commit(noResult: true);
        await _touchAfterSongChange(txn, stored, now);
      });
      if (addedIds.isNotEmpty) {
        final tombstones = await PlaylistStore.readSongTombstones();
        final playlistTombstones = tombstones[playlistId];
        if (playlistTombstones != null) {
          final before = playlistTombstones.length;
          for (final id in addedIds) {
            playlistTombstones.remove(id);
          }
          if (playlistTombstones.length != before) {
            if (playlistTombstones.isEmpty) tombstones.remove(playlistId);
            await PlaylistStore.writeSongTombstones(tombstones);
          }
        }
      }
      return addedIds.length;
    });
  }

  Future<void> removeSongFromPlaylist(String playlistId, String songId) {
    return _serialized(() async {
      final db = await AppDatabase.importantDatabase();
      final removed = await db.transaction<bool>((txn) async {
        final stored = await _playlistRowById(txn, playlistId);
        if (stored == null) return false;
        final count = await txn.delete(
          'playlist_songs',
          where: 'playlist_id = ? AND song_id = ?',
          whereArgs: [playlistId, songId],
        );
        if (count == 0) return false;
        await _touchAfterSongChange(txn, stored, DateTime.now());
        return true;
      });
      if (removed) {
        // 逐首合并靠这个墓碑区分「这端删了」和「那端没有」。
        await PlaylistStore.recordSongTombstone(playlistId, songId);
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
      final db = await AppDatabase.importantDatabase();
      final now = DateTime.now();
      final stored = await _playlistById(db, playlist.id);
      if (stored != null) {
        final merged = withCoverSourceMeta(playlist, stored: stored);
        await _writePlaylist(
          db,
          _touchMeta(merged, now),
          withSongs: true,
          songs: merged.songs,
        );
        return merged;
      }
      final created = withCoverSourceMeta(playlist);
      final target = created.copyWith(
        id: now.millisecondsSinceEpoch.toString(),
        createTime: now,
        updateTime: now,
        meta: {...created.meta, metaUpdatedAtKey: now.millisecondsSinceEpoch},
      );
      await _writePlaylist(db, target, withSongs: true, songs: target.songs);
      return target;
    });
  }

  // ---------------------------------------------------------------- 迁移

  /// 把老版本的 `config/playlists.json` 搬进数据库（只做一次）。
  ///
  /// * 内存降级库（数据库没能落盘）时什么都不做，原文件留着，下次启动再试；
  /// * 迁移成功后删掉旧文件与 `.bak`，否则备份包里还会多一份过期数据。
  Future<void> _migrateLegacyFile() async {
    if (_migrationDone) return;
    _migrationDone = true;
    try {
      final prefs = await AppPreferences.getInstance();
      if (prefs.getBool(_migratedKey) == true) return;
      if (!AppDatabase.isPersistent) return;
      final snapshot = await PlaylistStore.readLegacySnapshot();
      if (snapshot != null && snapshot.isNotEmpty) {
        await importAll(snapshot);
        debugPrint(
          '[PlaylistRepository] 已把 ${snapshot.length} 个歌单从 '
          'playlists.json 迁移进数据库',
        );
      }
      await prefs.setBool(_migratedKey, true);
      if (snapshot != null) await PlaylistStore.deleteLegacyFiles();
    } catch (e) {
      debugPrint('[PlaylistRepository] 迁移旧版收藏失败: $e');
    }
  }

  // ---------------------------------------------------------------- 内部实现

  Playlist _favoritesPlaylist(DateTime now) => Playlist(
    id: _favoritesId,
    name: '我的收藏',
    description: '收藏的歌曲',
    createTime: now,
    updateTime: now,
    // 「我的收藏」没有自己的封面，始终显示第一首歌的封面。
    meta: {
      coverFromFirstSongKey: true,
      metaUpdatedAtKey: now.millisecondsSinceEpoch,
    },
  );

  Future<List<Playlist>> _readPlaylists(DatabaseExecutor db) async {
    final rows = await db.query(
      'playlists',
      orderBy: 'sort_order ASC, create_time ASC, id ASC',
    );
    if (rows.isEmpty) return const [];
    final songRows = await db.query(
      'playlist_songs',
      orderBy: 'playlist_id ASC, sort_order ASC',
    );
    final songsByPlaylist = <String, List<Song>>{};
    for (final row in songRows) {
      final data = AppDatabase.decodeMap(row['data']);
      if (data.isEmpty) continue;
      songsByPlaylist
          .putIfAbsent('${row['playlist_id']}', () => [])
          .add(Song.fromJson(data));
    }
    return [
      for (final row in rows)
        _playlistFromRow(row, songsByPlaylist['${row['id']}'] ?? const []),
    ];
  }

  Playlist _playlistFromRow(Map<String, Object?> row, List<Song> songs) {
    final data = AppDatabase.decodeMap(row['data']);
    if (data.isNotEmpty) {
      final json = {...data, 'songs': const <dynamic>[]};
      return Playlist.fromJson(json).copyWith(songs: songs);
    }
    return Playlist(
      id: '${row['id']}',
      name: '${row['name']}',
      description: '${row['description']}',
      coverImgUrl: '${row['cover_url']}',
      source: '${row['source']}',
      createTime: DateTime.fromMillisecondsSinceEpoch(
        (row['create_time'] as num?)?.toInt() ?? 0,
      ),
      updateTime: DateTime.fromMillisecondsSinceEpoch(
        (row['update_time'] as num?)?.toInt() ?? 0,
      ),
      songs: songs,
      meta: AppDatabase.decodeMap(row['meta']),
    );
  }

  Future<Playlist?> _playlistById(DatabaseExecutor db, String id) async {
    final rows = await db.query(
      'playlists',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final songRows = await db.query(
      'playlist_songs',
      where: 'playlist_id = ?',
      whereArgs: [id],
      orderBy: 'sort_order ASC',
    );
    final songs = <Song>[];
    for (final row in songRows) {
      final data = AppDatabase.decodeMap(row['data']);
      if (data.isEmpty) continue;
      songs.add(Song.fromJson(data));
    }
    return _playlistFromRow(rows.first, songs);
  }

  Future<Song?> _firstSong(DatabaseExecutor db, String playlistId) async {
    final rows = await db.query(
      'playlist_songs',
      where: 'playlist_id = ?',
      whereArgs: [playlistId],
      orderBy: 'sort_order ASC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final data = AppDatabase.decodeMap(rows.first['data']);
    if (data.isEmpty) return null;
    return Song.fromJson(data);
  }

  bool _sameSongIdList(List<String> a, List<Song> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i].id) return false;
    }
    return true;
  }

  /// 歌单行（不带歌曲），用于「只改元数据 / 封面」的路径。
  Future<Playlist?> _playlistRowById(DatabaseExecutor db, String id) async {
    final rows = await db.query(
      'playlists',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _playlistFromRow(rows.first, const []);
  }

  Future<bool> _hasSong(
    DatabaseExecutor db,
    String playlistId,
    String songId,
  ) async {
    final rows = await db.query(
      'playlist_songs',
      columns: ['song_id'],
      where: 'playlist_id = ? AND song_id = ?',
      whereArgs: [playlistId, songId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<int?> _minSortOrder(DatabaseExecutor db, String playlistId) async {
    final rows = await db.rawQuery(
      'SELECT MIN(sort_order) AS value FROM playlist_songs '
      'WHERE playlist_id = ?',
      [playlistId],
    );
    return (rows.first['value'] as num?)?.toInt();
  }

  Future<List<String>> _songIdsOf(
    DatabaseExecutor db,
    String playlistId,
  ) async {
    final rows = await db.query(
      'playlist_songs',
      columns: ['song_id'],
      where: 'playlist_id = ?',
      whereArgs: [playlistId],
      orderBy: 'sort_order ASC',
    );
    return [for (final row in rows) '${row['song_id']}'];
  }

  /// 歌曲增删之后：更新「歌单最后变化时间」和跟随第一首歌的封面。
  Future<void> _touchAfterSongChange(
    DatabaseExecutor db,
    Playlist stored,
    DateTime now,
  ) async {
    final firstSong = await _firstSong(db, stored.id);
    final coverSource = stored.copyWith(songs: [?firstSong]);
    await _writeRow(
      db,
      coverSource.copyWith(
        updateTime: now,
        // 收藏的专辑 / 作者保留封面；普通歌单只有封面跟随第一首歌时才更新。
        coverImgUrl: playlistCoverAfterSongChange(
          coverSource,
          coverSource.songs,
        ),
      ),
    );
  }

  /// 元数据变更：`updateTime` 和 `metaUpdatedAt` 一起往前推。
  Playlist _touchMeta(Playlist playlist, DateTime now) {
    return playlist.copyWith(
      updateTime: now,
      meta: {...playlist.meta, metaUpdatedAtKey: now.millisecondsSinceEpoch},
    );
  }

  Future<void> _writePlaylist(
    DatabaseExecutor db,
    Playlist playlist, {
    required bool withSongs,
    List<Song> songs = const [],
  }) async {
    await _writeRow(db, playlist);
    if (!withSongs) return;
    await db.delete(
      'playlist_songs',
      where: 'playlist_id = ?',
      whereArgs: [playlist.id],
    );
    await _insertSongs(db, playlist.id, songs, DateTime.now());
  }

  Future<void> _writeRow(DatabaseExecutor db, Playlist playlist) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final json = playlist.copyWith(songs: const []).toJson();
    // 改名 / 换封面 / 加歌都要保留用户拖出来的顺序：已有行沿用原值，
    // 新歌单追加到末尾（老数据全是 0 时继续按 create_time 排）。
    final existing = await db.query(
      'playlists',
      columns: ['sort_order'],
      where: 'id = ?',
      whereArgs: [playlist.id],
      limit: 1,
    );
    int sortOrder;
    if (existing.isNotEmpty) {
      sortOrder = (existing.first['sort_order'] as num?)?.toInt() ?? 0;
    } else {
      final rows = await db.rawQuery(
        'SELECT MAX(sort_order) AS value FROM playlists',
      );
      sortOrder = ((rows.first['value'] as num?)?.toInt() ?? -1) + 1;
    }
    await db.insert('playlists', {
      'id': playlist.id,
      'name': playlist.name,
      'description': playlist.description,
      'cover_url': playlist.coverImgUrl,
      'source': playlist.source,
      'create_time': playlist.createTime.millisecondsSinceEpoch == 0
          ? now
          : playlist.createTime.millisecondsSinceEpoch,
      'update_time': playlist.updateTime.millisecondsSinceEpoch,
      'sort_order': sortOrder,
      'meta': jsonEncode(playlist.meta),
      'data': jsonEncode(json),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 只插入歌单行（不碰歌曲），用于快照导入。
  Future<void> _insertRow(
    DatabaseExecutor db,
    Playlist playlist, {
    required int sortOrder,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final createTime = playlist.createTime.millisecondsSinceEpoch;
    await db.insert('playlists', {
      'id': playlist.id,
      'name': playlist.name,
      'description': playlist.description,
      'cover_url': playlist.coverImgUrl,
      'source': playlist.source,
      'create_time': createTime == 0 ? now : createTime,
      'update_time': playlist.updateTime.millisecondsSinceEpoch,
      'sort_order': sortOrder,
      'meta': jsonEncode(playlist.meta),
      'data': jsonEncode(playlist.copyWith(songs: const []).toJson()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _insertSongs(
    DatabaseExecutor db,
    String playlistId,
    List<Song> songs,
    DateTime now,
  ) async {
    if (songs.isEmpty) return;
    final batch = db.batch();
    for (var i = 0; i < songs.length; i++) {
      batch.insert('playlist_songs', {
        'playlist_id': playlistId,
        'song_id': songs[i].id,
        'sort_order': i,
        'added_at': now.millisecondsSinceEpoch,
        'data': jsonEncode(songs[i].toPersistJson()),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }
}
