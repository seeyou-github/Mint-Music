import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';
import 'package:mintmusic/shared/utils/song_match_score.dart';

Song _song({
  required String title,
  String artist = '封茗囧菌、千月兔',
  String album = '山海',
  int? year = 2020,
  int duration = 205,
}) {
  return Song(
    id: title,
    title: title,
    artist: artist,
    album: album,
    duration: duration,
    year: year,
    source: 'wy',
  );
}

const _local = LocalSongMatchFields(
  title: '女人是老虎',
  artist: '封茗囧菌、千月兔',
  album: '山海',
  year: 2020,
  durationSeconds: 205,
);

void main() {
  test('五字段全中 = 第 1 级', () {
    expect(songMatchLevel(_song(title: '女人是老虎'), _local), 1);
  });

  test('定级：按能够上的最高级别', () {
    // 年份不中，其余全中 → 第 2 级。
    expect(
      songMatchLevel(_song(title: '女人是老虎', year: 2019), _local),
      2,
    );
    // 专辑不中（时长命中）→ 第 3 级。
    expect(
      songMatchLevel(
        _song(title: '女人是老虎', album: '别的专辑'),
        _local,
      ),
      3,
    );
    // 时长不中 → 第 4 级（哪怕专辑 / 年份都命中，第 2 级要求时长）。
    expect(
      songMatchLevel(
        _song(title: '女人是老虎', duration: 300),
        _local,
      ),
      4,
    );
    // 歌手不中 → 第 5 级。
    expect(
      songMatchLevel(_song(title: '女人是老虎', artist: '别的歌手'), _local),
      5,
    );
    // 歌名不中 → 0，排最后。
    expect(songMatchLevel(_song(title: '别的歌'), _local), 0);
  });

  test('时长容差 ±2 秒，越界级别从 1 降到 4', () {
    expect(songMatchLevel(_song(title: '女人是老虎', duration: 206), _local), 1);
    expect(songMatchLevel(_song(title: '女人是老虎', duration: 207), _local), 1);
    expect(songMatchLevel(_song(title: '女人是老虎', duration: 208), _local), 4);
    // 双方缺时长（0）不算命中。
    expect(
      songMatchLevel(
        _song(title: '女人是老虎', duration: 0),
        LocalSongMatchFields(
          title: _local.title,
          artist: _local.artist,
          album: _local.album,
          year: _local.year,
          durationSeconds: 0,
        ),
      ),
      4,
    );
  });

  test('排序：级别越高越靠左，同级别保持原顺序（稳定）', () {
    final results = [
      _song(title: '女人是老虎（女版）'), // 歌名不完全一致 → 0
      _song(title: '女人是老虎', album: '山海（珍藏版）'), // 2 级（专辑包含不算相等）
      _song(title: '女人是老虎'), // 1 级
      _song(title: '别的歌'), // 0 级
    ];
    final sorted = sortSongsByMatchLevel(results, _local);
    expect(sorted[0].album, '山海'); // 1 级最左
    // 专辑「山海（珍藏版）」归一化后 != 「山海」：专辑不中 → 3 级（时长命中）。
    expect(sorted[1].album, '山海（珍藏版）');
    expect(songMatchLevel(sorted[1], _local), 3);
    // 0 级（歌名不中）按原顺序排在所有有级别的结果之后。
    expect(songMatchLevel(sorted[2], _local), 0); // 歌名（女版）也不中 → 0
    expect(songMatchLevel(sorted[3], _local), 0); // 别的歌 → 0
  });

  test('归一化：括号 / 空白 / 大小写差异不影响匹配', () {
    expect(
      songMatchLevel(
        _song(title: '女人是老虎', artist: '封茗囧菌', album: 'Shan Hai'),
        const LocalSongMatchFields(
          title: '女人是老虎 ',
          artist: '封茗囧菌',
          album: 'shan hai',
          year: 0,
          durationSeconds: 0,
        ),
      ),
      // 时长缺失（双方为 0 不算命中）→ 第 4 级；专辑归一化后相等。
      4,
    );
  });
}
