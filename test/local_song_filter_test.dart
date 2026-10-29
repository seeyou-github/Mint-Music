import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/local/domain/local_song_filter.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';

Song _song({
  String id = '1',
  String title = '晴天',
  String artist = '周杰伦',
  String album = '叶惠美',
  String? filePath = r'D:\Music\a.mp3',
  String? coverUrl,
  bool hasCover = false,
  int? year,
  String? genre,
  String? comment,
  bool hasLyric = false,
  bool hasWordLyric = false,
}) {
  return Song(
    id: id,
    title: title,
    artist: artist,
    album: album,
    duration: 200,
    source: 'local',
    filePath: filePath,
    coverUrl: coverUrl,
    hasCover: hasCover,
    year: year,
    genre: genre,
    comment: comment,
    hasLyric: hasLyric,
    hasWordLyric: hasWordLyric,
  );
}

void main() {
  group('字段「有没有」判断', () {
    test('封面：远程地址或本地封面都算有', () {
      expect(songHasField(_song(), LocalSongField.cover), isFalse);
      expect(
        songHasField(_song(coverUrl: 'http://a/b.jpg'), LocalSongField.cover),
        isTrue,
      );
      expect(songHasField(_song(hasCover: true), LocalSongField.cover), isTrue);
    });

    test('歌名 / 歌手 / 专辑：占位文案算「没有」', () {
      expect(songHasField(_song(title: '未知曲目'), LocalSongField.title), false);
      expect(songHasField(_song(title: '晴天'), LocalSongField.title), isTrue);
      expect(
        songHasField(_song(artist: '未知艺术家'), LocalSongField.artist),
        false,
      );
      expect(songHasField(_song(artist: '未知歌手'), LocalSongField.artist), false);
      expect(songHasField(_song(album: '未知专辑'), LocalSongField.album), false);
    });

    test('年份 / 流派 / 注释', () {
      expect(songHasField(_song(), LocalSongField.year), isFalse);
      expect(songHasField(_song(year: 2003), LocalSongField.year), isTrue);
      expect(songHasField(_song(genre: '流行'), LocalSongField.genre), isTrue);
      expect(songHasField(_song(genre: '  '), LocalSongField.genre), isFalse);
      expect(
        songHasField(_song(comment: '备注'), LocalSongField.comment),
        isTrue,
      );
    });

    test('歌词状态优先用传入的实时状态', () {
      final song = _song(hasLyric: false);
      expect(songHasField(song, LocalSongField.lyric), isFalse);
      expect(
        songHasField(
          song,
          LocalSongField.lyric,
          lyric: const LyricPresence(hasLyric: true, hasWordLyric: true),
        ),
        isTrue,
      );
      expect(
        songHasField(
          song,
          LocalSongField.wordLyric,
          lyric: const LyricPresence(hasLyric: true, hasWordLyric: true),
        ),
        isTrue,
      );
    });
  });

  group('筛选', () {
    final songs = [
      _song(id: '1', title: 'A', filePath: r'D:\Music\a.mp3'),
      _song(
        id: '2',
        title: 'B',
        filePath: r'D:\Music\sub\b.mp3',
        coverUrl: 'http://x/y.jpg',
        year: 2020,
      ),
      _song(id: '3', title: 'C', filePath: r'D:\Music2\c.mp3', genre: '摇滚'),
    ];

    test('默认不过滤', () {
      expect(filterLocalSongs(songs).length, 3);
    });

    test('按目录筛选（不会把同名前缀的目录算进去）', () {
      final result = filterLocalSongs(songs, directory: r'D:\Music');
      expect(result.map((s) => s.id), ['1', '2']);
    });

    test('只看没有封面', () {
      final result = filterLocalSongs(
        songs,
        filters: {LocalSongField.cover: FieldFilter.lacks},
      );
      expect(result.map((s) => s.id), ['1', '3']);
    });

    test('多个条件同时生效', () {
      final result = filterLocalSongs(
        songs,
        filters: {
          LocalSongField.cover: FieldFilter.lacks,
          LocalSongField.year: FieldFilter.has,
        },
      );
      expect(result, isEmpty);
    });

    test('目录 + 字段组合', () {
      final result = filterLocalSongs(
        songs,
        directory: r'D:\Music',
        filters: {LocalSongField.cover: FieldFilter.has},
      );
      expect(result.map((s) => s.id), ['2']);
    });
  });

  test('筛选按钮状态循环：无 → 有 → 无值 → 无', () {
    expect(nextFieldFilter(FieldFilter.any), FieldFilter.has);
    expect(nextFieldFilter(FieldFilter.has), FieldFilter.lacks);
    expect(nextFieldFilter(FieldFilter.lacks), FieldFilter.any);
  });

  test('从文件名提取搜索词', () {
    expect(filenameKeyword(r'D:\Music\周杰伦 - 晴天.mp3'), '周杰伦 - 晴天');
    expect(filenameKeyword('晴天_周杰伦.flac'), '晴天 周杰伦');
    expect(filenameKeyword('/music/a.b.c.mp3'), 'a b c');
    expect(filenameKeyword(''), '');
  });

  test('逐字歌词判断', () {
    expect(isWordLyricText(null), isFalse);
    expect(isWordLyricText('[00:01.00]普通歌词'), isFalse);
    expect(isWordLyricText('[1000,500](1000,200,0)逐(1200,150,0)字'), isTrue);
  });
}
