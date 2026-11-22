import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/platform/app_paths.dart';
import 'package:mintmusic/features/library/application/audio_cache_providers.dart';
import 'package:mintmusic/features/library/application/playlist_providers.dart';
import 'package:mintmusic/features/library/data/playlist_repository.dart';
import 'package:mintmusic/features/library/data/song_audio_cache.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';

Song _song(String id) => Song(
  id: id,
  title: '歌曲 $id',
  artist: '歌手',
  album: '专辑',
  duration: 200,
  source: 'kw',
  sourceUrl: 'https://cdn.example.com/$id.mp3',
  sourceQuality: '320k',
);

final List<int> _mp3Bytes = List<int>.filled(16, 0)
  ..[0] = 0xFF
  ..[1] = 0xFB;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late ProviderContainer container;
  late PlaylistRepository repo;

  setUpAll(() async {
    tempRoot = await Directory.systemTemp.createTemp('audio_cache_trigger_');
    AppPaths.debugRootOverride = tempRoot.path;
  });

  tearDownAll(() async {
    AppPaths.debugRootOverride = null;
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {}
  });

  setUp(() async {
    SongAudioCache.debugDownloader = (url, savePath, headers) async {
      await File(savePath).writeAsBytes(_mp3Bytes);
      return true;
    };
    container = ProviderContainer();
    repo = container.read(playlistRepositoryProvider);
    // 每个用例从干净的歌单库开始（首次 load 会建「我的收藏」）。
    final playlists = await repo.loadPlaylists();
    for (final playlist in playlists) {
      if (playlist.id == '__favorites__') continue;
      await repo.deletePlaylist(playlist.id);
    }
    for (final song in playlists
        .expand((playlist) => playlist.songs)
        .map((song) => song.id)
        .toSet()) {
      await SongAudioCache.remove(song);
    }
  });

  tearDown(() {
    container.dispose();
    SongAudioCache.debugDownloader = null;
  });

  Future<void> runCache(Song song) {
    return container.read(
      Provider<Future<void>>((ref) => cachePlayedSongForOffline(ref, song)),
    );
  }

  test('自建歌单里的歌，播完写进缓存', () async {
    final song = _song('user-1');
    await repo.createPlaylist('我的歌单');
    final playlist = (await repo.loadPlaylists()).firstWhere(
      (playlist) => playlist.name == '我的歌单',
    );
    await repo.addSongToPlaylist(playlist.id, song);

    expect(
      await repo.isSongInOfflineCachePlaylist(song.id),
      isTrue,
      reason: '自建歌单要能被判定命中',
    );

    await runCache(song);

    final path = await SongAudioCache.findFile('user-1');
    expect(path, isNotNull);
    expect(File(path!).existsSync(), isTrue);
  });

  test('收藏里的歌同样写缓存', () async {
    final song = _song('fav-1');
    await repo.addSongToPlaylist('__favorites__', song);

    await runCache(song);

    expect(await SongAudioCache.findFile('fav-1'), isNotNull);
  });

  test('收藏的专辑不写缓存', () async {
    final song = _song('album-1');
    await repo.createPlaylist(
      '专辑：测试',
      description: 'mintmusic:album:kw:1',
    );
    final playlist = (await repo.loadPlaylists()).firstWhere(
      (playlist) => playlist.description.contains('mintmusic:album'),
    );
    await repo.addSongToPlaylist(playlist.id, song);

    expect(await repo.isSongInOfflineCachePlaylist(song.id), isFalse);

    await runCache(song);
    expect(await SongAudioCache.findFile('album-1'), isNull);
  });

  test('没有播放地址（sourceUrl 为空）不写缓存', () async {
    final song = _song('no-url').copyWith(clearSourceUrl: true);
    await repo.addSongToPlaylist('__favorites__', song);

    await runCache(song);

    expect(await SongAudioCache.findFile('no-url'), isNull);
  });

  test('从收藏移除后判定立即变成 false', () async {
    final song = _song('rm-1');
    await repo.addSongToPlaylist('__favorites__', song);
    expect(await repo.isSongInOfflineCachePlaylist('rm-1'), isTrue);

    await repo.removeSongFromPlaylist('__favorites__', 'rm-1');

    expect(await repo.isSongInOfflineCachePlaylist('rm-1'), isFalse);
  });
}
