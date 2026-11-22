import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';
import 'package:mintmusic/shared/utils/song_match_score.dart';

Song _song({
  required String title,
  String artist = '周杰伦',
  String album = '叶惠美',
  int? year = 2003,
  int duration = 269,
}) {
  return Song(
    id: '$title|$artist|$album',
    title: title,
    artist: artist,
    album: album,
    duration: duration,
    year: year,
    source: 'kw',
  );
}

/// 本地歌曲：晴天 / 周杰伦 / 叶惠美 / 2003 / 4:29。
const _local = LocalSongMatchFields(
  title: '晴天',
  artist: '周杰伦',
  album: '叶惠美',
  year: 2003,
  durationSeconds: 269,
);

void main() {
  group('第 1~4 优先级：歌名 / 歌手 / 时长全中，按专辑与年份细分', () {
    test('五字段全中 → 1', () {
      expect(songMatchPriority(_song(title: '晴天'), _local), 1);
      // 归一化：空白 / 标点 / 大小写不影响「精确」。
      expect(songMatchPriority(_song(title: ' 晴 天 '), _local), 1);
    });

    test('专辑精确、年份不匹配 → 2', () {
      expect(songMatchPriority(_song(title: '晴天', year: 2020), _local), 2);
    });

    test('年份匹配、专辑不匹配 → 3', () {
      expect(
        songMatchPriority(_song(title: '晴天', album: '别的专辑'), _local),
        3,
      );
    });

    test('专辑、年份都不匹配 → 4', () {
      expect(
        songMatchPriority(
          _song(title: '晴天', album: '别的专辑', year: 2020),
          _local,
        ),
        4,
      );
    });
  });

  group('第 5~7 优先级：歌名 / 歌手存在包含关系，且时长匹配', () {
    test('歌名精确 & 歌手包含 → 5', () {
      expect(
        songMatchPriority(_song(title: '晴天', artist: '周杰伦 & 温岚'), _local),
        5,
      );
    });

    test('歌名包含 & 歌手精确 → 6', () {
      expect(songMatchPriority(_song(title: '晴天 (Live)'), _local), 6);
    });

    test('歌名包含 & 歌手包含 → 7', () {
      expect(
        songMatchPriority(
          _song(title: '晴天 (Live)', artist: '周杰伦 & 温岚'),
          _local,
        ),
        7,
      );
    });

    test('包含是双向的：本地是长字段、候选是短字段也算', () {
      const localLong = LocalSongMatchFields(
        title: '晴天Live',
        artist: '周杰伦',
        album: '叶惠美',
        year: 2003,
        durationSeconds: 269,
      );
      expect(songMatchPriority(_song(title: '晴天'), localLong), 6);
    });
  });

  group('第 8~9 优先级：时长不匹配', () {
    test('歌名精确 & 歌手精确 → 8', () {
      expect(songMatchPriority(_song(title: '晴天', duration: 300), _local), 8);
    });

    test('歌名 / 歌手的三种包含组合都归 9', () {
      expect(
        songMatchPriority(
          _song(title: '晴天', artist: '周杰伦 & 温岚', duration: 300),
          _local,
        ),
        9,
      );
      expect(
        songMatchPriority(_song(title: '晴天 (Live)', duration: 300), _local),
        9,
      );
      expect(
        songMatchPriority(
          _song(title: '晴天 (Live)', artist: '周杰伦 & 温岚', duration: 300),
          _local,
        ),
        9,
      );
    });
  });

  group('第 12 优先级：其它', () {
    test('歌名不匹配 → 12', () {
      expect(songMatchPriority(_song(title: '七里香'), _local), 12);
    });

    test('歌名精确但歌手既不精确也不包含 → 12（不再按「歌名包含」垫底）', () {
      expect(
        songMatchPriority(_song(title: '晴天', artist: '蔡依林'), _local),
        12,
      );
    });
  });

  test('本地歌手为空：歌手维度不参与，仍按歌名/时长/专辑年份分档', () {
    const localNoArtist = LocalSongMatchFields(
      title: '晴天',
      artist: '',
      album: '叶惠美',
      year: 2003,
      durationSeconds: 269,
    );
    // 五字段里除歌手外全中 → 第 1 档，而不是掉到「其它」。
    expect(songMatchPriority(_song(title: '晴天'), localNoArtist), 1);
    // 专辑不中、年份中 → 第 3 档。
    expect(
      songMatchPriority(_song(title: '晴天', album: '别的专辑'), localNoArtist),
      3,
    );
    // 歌名包含、时长不匹配 → 第 9 档（歌名包含 + 歌手视为精确的时长不符档）。
    expect(
      songMatchPriority(
        _song(title: '晴天 (Live)', duration: 300),
        localNoArtist,
      ),
      9,
    );
  });

  group('字段缺失不算「精确」', () {
    test('候选专辑为空：不能凭「空 vs 空」进第 1 档', () {
      // 专辑不匹配、年份匹配 → 3。
      expect(songMatchPriority(_song(title: '晴天', album: ''), _local), 3);
    });

    test('本地与候选专辑都为空：按专辑不匹配处理', () {
      const localNoAlbum = LocalSongMatchFields(
        title: '晴天',
        artist: '周杰伦',
        album: '',
        year: 2003,
        durationSeconds: 269,
      );
      expect(
        songMatchPriority(_song(title: '晴天', album: ''), localNoAlbum),
        3,
      );
    });

    test('候选没有年份：专辑精确也只是第 2 档', () {
      expect(songMatchPriority(_song(title: '晴天', year: null), _local), 2);
    });

    test('本地没有年份：不会与候选年份「猜中」', () {
      const localNoYear = LocalSongMatchFields(
        title: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
        year: 0,
        durationSeconds: 269,
      );
      expect(songMatchPriority(_song(title: '晴天', year: 2003), localNoYear), 2);
    });
  });

  test('时长容差 ±1 秒：4:28 / 4:30 算匹配，4:27 / 4:31 不算', () {
    expect(songMatchPriority(_song(title: '晴天', duration: 268), _local), 1);
    expect(songMatchPriority(_song(title: '晴天', duration: 270), _local), 1);
    expect(songMatchPriority(_song(title: '晴天', duration: 267), _local), 8);
    expect(songMatchPriority(_song(title: '晴天', duration: 271), _local), 8);
  });

  test('排序：第 1 → 9 → 12，同优先级保持原顺序', () {
    final results = [
      _song(title: '七里香'), // 12
      _song(title: '晴天 (Live)', artist: '周杰伦 & 温岚'), // 7
      _song(title: '晴天'), // 1
      _song(title: '晴天 (Live)'), // 6
      _song(title: '晴天', artist: '周杰伦 & 温岚'), // 5
      _song(title: '别的歌'), // 12
    ];
    final sorted = sortSongsByMatchLevel(results, _local);

    expect(
      sorted.map((song) => songMatchPriority(song, _local)).toList(),
      [1, 5, 6, 7, 12, 12],
    );
    // 两个「其它」保持插件返回的原顺序（七里香在别的歌前面）。
    expect(sorted[4].title, '七里香');
    expect(sorted[5].title, '别的歌');
  });
}
