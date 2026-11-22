import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/library/utils/offline_cache_rules.dart';
import 'package:mintmusic/features/library/domain/models/playlist.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';

Song _song(String id) => Song(
  id: id,
  title: '歌曲 $id',
  artist: '歌手',
  album: '专辑',
  duration: 200,
  source: 'kw',
);

Playlist _playlist({
  required String id,
  String name = '歌单',
  String description = '',
  Map<String, dynamic> meta = const {},
  List<Song> songs = const [],
}) {
  final now = DateTime(2026, 1, 1);
  return Playlist(
    id: id,
    name: name,
    description: description,
    source: 'local',
    createTime: now,
    updateTime: now,
    songs: songs,
    meta: meta,
  );
}

void main() {
  group('isOfflineCachePlaylist', () {
    test('我的收藏与自建歌单才缓存', () {
      expect(isOfflineCachePlaylist(_playlist(id: '__favorites__')), isTrue);
      expect(isOfflineCachePlaylist(_playlist(id: 'self-1')), isTrue);
    });

    test('收藏的专辑 / 作者、收藏或导入的远端歌单不缓存', () {
      expect(
        isOfflineCachePlaylist(
          _playlist(
            id: 'album-1',
            description: 'mintmusic:album:wy:123',
          ),
        ),
        isFalse,
      );
      expect(
        isOfflineCachePlaylist(
          _playlist(
            id: 'artist-1',
            description: 'mintmusic:artist:wy:9',
          ),
        ),
        isFalse,
      );
      expect(
        isOfflineCachePlaylist(
          _playlist(id: 'discover-1', meta: {'discoverId': 'x'}),
        ),
        isFalse,
      );
    });
  });

  group('playlistsHoldSong', () {
    test('只看收藏 / 自建歌单', () {
      final favorites = _playlist(
        id: '__favorites__',
        songs: [_song('s1')],
      );
      final userPlaylist = _playlist(
        id: 'self-1',
        songs: [_song('s2')],
      );
      final album = _playlist(
        id: 'album-1',
        description: 'mintmusic:album:wy:1',
        songs: [_song('s3')],
      );
      final all = [favorites, userPlaylist, album];

      expect(playlistsHoldSong(all, 's1'), isTrue);
      expect(playlistsHoldSong(all, 's2'), isTrue);
      expect(
        playlistsHoldSong(all, 's3'),
        isFalse,
        reason: '收藏的专辑不算「用户自己的歌单」',
      );
      expect(playlistsHoldSong(all, 's4'), isFalse);
      expect(playlistsHoldSong(all, ''), isFalse);
    });

    test('从某个歌单移除后，其它自建歌单还留着就不算孤立', () {
      final a = _playlist(id: 'self-a', songs: [_song('s1')]);
      final b = _playlist(id: 'self-b', songs: [_song('s1')]);
      expect(playlistsHoldSong([a, b], 's1'), isTrue);
      // 从 a 移除后只剩 b。
      expect(playlistsHoldSong([b], 's1'), isTrue);
      // 两个歌单都移除 → 可以删缓存。
      expect(playlistsHoldSong([], 's1'), isFalse);
    });
  });
}
