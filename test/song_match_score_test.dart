import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';
import 'package:mintmusic/shared/utils/song_match_score.dart';

Song _song({
  required String title,
  String artist = '傅又宣',
  String album = '爱.这件事情',
  int? year = 2014,
  int duration = 235,
}) {
  return Song(
    id: title,
    title: title,
    artist: artist,
    album: album,
    duration: duration,
    year: year,
    source: 'kg',
  );
}

/// 用户示例的本地歌曲：爱.这件事情 / 傅又宣 / 2014 / 3:55。
const _local = LocalSongMatchFields(
  title: '爱.这件事情',
  artist: '傅又宣',
  album: '爱.这件事情',
  year: 2014,
  durationSeconds: 235,
);

void main() {
  test('五遍过滤全部通过 = 第 5 级（含归一化：逗号/点/空格差异）', () {
    expect(
      songMatchLevel(
        _song(title: '爱. 这件事 情', duration: 234),
        _local,
      ),
      5,
    );
    expect(songMatchLevel(_song(title: '爱这件事情'), _local), 5);
  });

  test('定级：每少过一遍降一级', () {
    // 歌手不中（吉那罐子）→ 停在第 1 级。
    expect(
      songMatchLevel(
        _song(
          title: '爱，这件事情',
          artist: '吉那罐子',
          album: '小吉的路',
          year: 2021,
          duration: 232,
        ),
        _local,
      ),
      1,
    );
    // 歌手中、时长不中 → 第 2 级。
    expect(
      songMatchLevel(_song(title: '爱这件事情', duration: 300), _local),
      2,
    );
    // 时长中、专辑不中 → 第 3 级。
    expect(
      songMatchLevel(
        _song(title: '爱这件事情', album: '别的专辑'),
        _local,
      ),
      3,
    );
    // 专辑中、年份不中 → 第 4 级。
    expect(
      songMatchLevel(_song(title: '爱这件事情', year: 2021), _local),
      4,
    );
    // 歌名不中 → 0，排最后。
    expect(songMatchLevel(_song(title: '别的歌'), _local), 0);
  });

  test('时长容差 ±2 秒：3:55 vs 3:54 算匹配，3:58 不算', () {
    expect(songMatchLevel(_song(title: '爱这件事情', duration: 234), _local), 5);
    expect(songMatchLevel(_song(title: '爱这件事情', duration: 233), _local), 5);
    expect(songMatchLevel(_song(title: '爱这件事情', duration: 238), _local), 2);
  });

  test('排序：5 级最左，1 级在其后保持原顺序，0 级垫底', () {
    // 用户截图的真实顺序（酷狗原始返回）。
    final results = [
      _song(
        title: '爱，这件事情',
        artist: '吉那罐子',
        album: '小吉的路',
        year: 2021,
        duration: 232,
      ), // 1 级
      _song(title: '爱这件事情', artist: '白沐'), // 1 级
      _song(title: '爱这件事情', artist: '初伊'), // 1 级
      _song(title: '爱·这件事情', artist: '还很九'), // 1 级
      _song(title: '爱. 这件事 情'), // 5 级（傅又宣）
    ];
    final sorted = sortSongsByMatchLevel(results, _local);

    expect(sorted.first.artist, '傅又宣'); // 5 级最左
    expect(sorted[1].artist, '吉那罐子'); // 1 级保持原顺序
    expect(sorted[2].artist, '白沐');
    expect(sorted[3].artist, '初伊');
    expect(sorted[4].artist, '还很九');
  });
}
