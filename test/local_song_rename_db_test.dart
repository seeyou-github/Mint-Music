import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/storage/app_database.dart';
import 'package:mintmusic/features/local/data/local_music_repository.dart';
import 'package:mintmusic/features/local/domain/services/local_song_rename_service.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';

/// 本地歌曲改名后「按歌曲 id / 路径归属」的数据迁移。
///
/// 只碰测试环境自己的库（`AppDatabase` 在测试里落到 SDK 缓存目录下的临时库），
/// 用 `test_song_rename_` 前缀的 key，跑完就删。
void main() {
  const oldId = 'test_song_rename_old';
  const newId = 'test_song_rename_new';
  const playlistId = 'test_song_rename_playlist';
  const oldPath = r'D:\Music\old name.mp3';
  const newPath = r'D:\Music\new name.mp3';

  Song buildSong(String id, String path, String coverKey) => Song(
    id: id,
    title: '标题',
    artist: '歌手',
    album: '专辑',
    duration: 120,
    source: 'local',
    filePath: path,
    sourceUrl: path,
    coverKey: coverKey,
  );

  Future<void> cleanUp() async {
    final cache = await AppDatabase.cacheDatabase();
    await cache.delete(
      'recently_played',
      where: 'song_id IN (?, ?)',
      whereArgs: [oldId, newId],
    );
    await cache.delete(
      'download_entries',
      where: 'song_id IN (?, ?)',
      whereArgs: [oldId, newId],
    );
    final important = await AppDatabase.importantDatabase();
    await important.delete(
      'song_play_progress',
      where: 'song_id IN (?, ?)',
      whereArgs: [oldId, newId],
    );
    await important.delete(
      'playlist_songs',
      where: 'playlist_id = ?',
      whereArgs: [playlistId],
    );
  }

  setUp(cleanUp);
  tearDown(cleanUp);

  test('最近播放 / 下载记录 / 已听进度 / 歌单条目一起迁到新 id', () async {
    final before = buildSong(oldId, oldPath, 'cover_old');
    final after = buildSong(newId, newPath, 'cover_new');

    final cache = await AppDatabase.cacheDatabase();
    await cache.insert('recently_played', {
      'song_id': oldId,
      'played_at': 1700000000000,
      'play_count': 3,
      'data': jsonEncode({
        'song': before.toPersistJson(),
        'playedAt': '2026-01-01T00:00:00.000',
      }),
    });
    await cache.insert('download_entries', {
      'song_id': oldId,
      'file_path': oldPath,
      'quality': '320k',
      'file_size': 1024,
      'file_exists': 1,
      'song_json': jsonEncode(before.toPersistJson()),
      'created_at': 1,
      'updated_at': 1,
    });

    final important = await AppDatabase.importantDatabase();
    await important.insert('song_play_progress', {
      'song_id': oldId,
      'ratio': 0.6,
      'position_ms': 60000,
      'duration_ms': 120000,
      'updated_at': 1,
    });
    await important.insert('playlist_songs', {
      'playlist_id': playlistId,
      'song_id': oldId,
      'sort_order': 0,
      'added_at': 1,
      'data': jsonEncode(before.toJson()),
    });

    await LocalSongRenameService.migrateData(before: before, after: after);

    // 旧 id 一行都不该剩下。
    expect(
      await cache.query(
        'recently_played',
        where: 'song_id = ?',
        whereArgs: [oldId],
      ),
      isEmpty,
    );
    expect(
      await cache.query(
        'download_entries',
        where: 'song_id = ?',
        whereArgs: [oldId],
      ),
      isEmpty,
    );
    expect(
      await important.query(
        'song_play_progress',
        where: 'song_id = ?',
        whereArgs: [oldId],
      ),
      isEmpty,
    );
    expect(
      await important.query(
        'playlist_songs',
        where: 'song_id = ?',
        whereArgs: [oldId],
      ),
      isEmpty,
    );

    // 新 id 拿到了原来的数据，且 JSON 里的路径 / 封面 key 也跟着换。
    final recent = await cache.query(
      'recently_played',
      where: 'song_id = ?',
      whereArgs: [newId],
    );
    expect(recent, hasLength(1));
    expect(recent.first['played_at'], 1700000000000);
    final recentSong =
        AppDatabase.decodeMap(recent.first['data'])['song'] as Map;
    expect(recentSong['id'], newId);
    expect(recentSong['filePath'], newPath);
    expect(recentSong['sourceUrl'], newPath);

    final downloads = await cache.query(
      'download_entries',
      where: 'song_id = ?',
      whereArgs: [newId],
    );
    expect(downloads, hasLength(1));
    expect(downloads.first['file_path'], newPath);
    expect(downloads.first['quality'], '320k');
    final downloadSong = AppDatabase.decodeMap(downloads.first['song_json']);
    expect(downloadSong['filePath'], newPath);
    expect(downloadSong['coverKey'], 'cover_new');

    final progress = await important.query(
      'song_play_progress',
      where: 'song_id = ?',
      whereArgs: [newId],
    );
    expect(progress, hasLength(1));
    expect(progress.first['ratio'], 0.6);
    expect(progress.first['position_ms'], 60000);

    final playlistSongs = await important.query(
      'playlist_songs',
      where: 'playlist_id = ?',
      whereArgs: [playlistId],
    );
    expect(playlistSongs, hasLength(1));
    expect(playlistSongs.first['song_id'], newId);
    final playlistSong = AppDatabase.decodeMap(playlistSongs.first['data']);
    expect(playlistSong['id'], newId);
    expect(playlistSong['filePath'], newPath);
    expect(playlistSong['coverKey'], 'cover_new');
    expect(playlistSong['title'], '标题', reason: '其它标签字段不能被改动');
  });

  test('本地曲库索引：旧 id 行删掉，新 id 行写入', () async {
    final repo = LocalMusicRepository();
    await repo.init();
    final before = buildSong(oldId, oldPath, 'cover_old');
    await repo.upsertSong(before, forceOverwrite: true);
    expect(repo.getSongById(oldId)?.filePath, oldPath);

    final after = buildSong(newId, newPath, 'cover_new');
    final ok = await repo.renameSong(oldId, after);
    expect(ok, isTrue);
    expect(repo.getSongById(oldId), isNull, reason: '内存里旧 id 要消失');
    expect(repo.getSongById(newId)?.filePath, newPath);

    final db = await AppDatabase.cacheDatabase();
    expect(
      await db.query('local_songs', where: 'id = ?', whereArgs: [oldId]),
      isEmpty,
    );
    final newRows = await db.query(
      'local_songs',
      where: 'id = ?',
      whereArgs: [newId],
    );
    expect(newRows, hasLength(1));
    expect(newRows.first['file_path'], newPath);

    // 索引里的这一行不能留到别的测试里（文件本来就不存在，删不掉也无所谓）。
    await repo.deleteSongs([newId]);
  });

  test('同一个文件被多个歌单收藏：每条都迁', () async {
    final before = buildSong(oldId, oldPath, 'cover_old');
    final after = buildSong(newId, newPath, 'cover_new');
    final important = await AppDatabase.importantDatabase();
    for (final id in ['test_song_rename_pl_a', 'test_song_rename_pl_b']) {
      await important.insert('playlist_songs', {
        'playlist_id': id,
        'song_id': oldId,
        'sort_order': 0,
        'added_at': 1,
        'data': jsonEncode(before.toJson()),
      });
    }
    addTearDown(() async {
      await important.delete(
        'playlist_songs',
        where: 'playlist_id LIKE ?',
        whereArgs: ['test_song_rename_pl_%'],
      );
    });

    await LocalSongRenameService.migrateData(before: before, after: after);

    final rows = await important.query(
      'playlist_songs',
      where: 'playlist_id LIKE ?',
      whereArgs: ['test_song_rename_pl_%'],
    );
    expect(rows, hasLength(2));
    expect(rows.every((row) => row['song_id'] == newId), isTrue);
  });
}
