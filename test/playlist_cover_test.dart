import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/backup/playlist_merge.dart';
import 'package:mintmusic/features/library/domain/models/playlist.dart';
import 'package:mintmusic/features/library/utils/favorite_playlist.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';

Song _song(String id, String cover) => Song(
  id: id,
  title: 'song $id',
  artist: 'artist',
  album: 'album',
  duration: 1000,
  coverUrl: cover,
);

Playlist _playlist({
  required List<Song> songs,
  String cover = '',
  Map<String, dynamic> meta = const {},
  String description = '',
}) {
  final now = DateTime(2026, 1, 1);
  return Playlist(
    id: 'p1',
    name: 'p1',
    description: description,
    coverImgUrl: cover,
    createTime: now,
    updateTime: now,
    songs: songs,
    meta: meta,
  );
}

void main() {
  group('playlistCoverAfterSongChange', () {
    test('没有自己封面的歌单跟随第一首歌', () {
      final songs = [_song('a', 'coverA'), _song('b', 'coverB')];
      final playlist = _playlist(songs: songs);
      expect(playlist.coverFromFirstSong, isTrue);

      expect(playlistCoverAfterSongChange(playlist, [songs[1]]), 'coverB');
    });

    test('收藏 / 导入的远端歌单保留自己的封面', () {
      final songs = [_song('a', 'coverA'), _song('b', 'coverB')];
      // 封面正好等于第一首歌的封面（插件常见）时也不能被改掉。
      final playlist = _playlist(
        songs: songs,
        cover: 'coverA',
        meta: const {'discoverId': 'wy_1'},
      );
      expect(playlist.coverFromFirstSong, isFalse);

      expect(playlistCoverAfterSongChange(playlist, [songs[1]]), 'coverA');
    });

    test('有封面来源标记的歌单按标记处理', () {
      final songs = [_song('a', 'coverA'), _song('b', 'coverB')];
      final auto = _playlist(
        songs: songs,
        cover: 'coverA',
        meta: const {coverFromFirstSongKey: true},
      );
      expect(playlistCoverAfterSongChange(auto, [songs[1]]), 'coverB');

      final own = _playlist(
        songs: songs,
        cover: 'own',
        meta: const {coverFromFirstSongKey: false},
      );
      expect(playlistCoverAfterSongChange(own, [songs[1]]), 'own');
    });

    test('清空歌曲时自动封面置空', () {
      final songs = [_song('a', 'coverA')];
      final playlist = _playlist(songs: songs, cover: 'coverA');
      expect(playlistCoverAfterSongChange(playlist, const []), '');
    });

    test('withCoverSourceMeta 补上早期数据缺失的标记', () {
      final songs = [_song('a', 'coverA')];
      final legacy = _playlist(songs: songs, cover: 'coverA');
      final merged = withCoverSourceMeta(legacy);
      expect(merged.meta[coverFromFirstSongKey], isTrue);
    });
  });

  group('同步快照里的空歌单封面', () {
    Map<String, dynamic> json(
      String id,
      String cover,
      List<String> songIds, {
      Map<String, dynamic> meta = const {},
    }) => {
      'id': id,
      'name': id,
      'description': '',
      'coverImgUrl': cover,
      'source': 'local',
      'createTime': 0,
      'updateTime': 0,
      'meta': meta,
      'songs': [
        for (final s in songIds) {'id': s, 'updatedAt': 1},
      ],
    };

    test('我的收藏清空后不再带旧封面', () {
      final normalized = PlaylistMerge.normalizeEmptyCover(
        json('__favorites__', 'old', const []),
      );
      expect(normalized['coverImgUrl'], '');
    });

    test('我的收藏有歌时封面原样保留', () {
      final normalized = PlaylistMerge.normalizeEmptyCover(
        json('__favorites__', 'old', const ['s1']),
      );
      expect(normalized['coverImgUrl'], 'old');
    });

    test('自带封面的歌单（收藏的专辑）清空后保留封面', () {
      final normalized = PlaylistMerge.normalizeEmptyCover(
        json('p2', 'own', const [], meta: const {coverFromFirstSongKey: false}),
      );
      expect(normalized['coverImgUrl'], 'own');
    });

    test('合并时不会让空收藏的旧封面在设备间传播', () {
      // A 端已清空（封面空）；B 端空歌单还留着旧封面且元数据更新。
      final merged = PlaylistMerge.mergeAll(
        local: [json('__favorites__', '', const [])],
        remotePlaylists: [
          json('__favorites__', 'old', const [], meta: const {'metaUpdatedAt': 200}),
        ],
        playlistTombstones: const {},
        songTombstones: const {},
      );
      expect(merged.first['coverImgUrl'], '');
    });
  });
}
