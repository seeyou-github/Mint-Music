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
  test('定级：五遍过滤（用户示例）', () {
    // 傅又宣：五字段全中 → 组 1 级 5。
    expect(songMatchGroupAndLevel(_song(title: '爱. 这件事 情'), _local), (1, 5));
    expect(songMatchGroupAndLevel(_song(title: '爱这件事情'), _local), (1, 5));
    // 吉那罐子：仅歌名命中（归一化后相等），歌手不中 → 组 0 档 2。
    expect(
      songMatchGroupAndLevel(
        _song(
          title: '爱，这件事情',
          artist: '吉那罐子',
          album: '小吉的路',
          year: 2021,
          duration: 232,
        ),
        _local,
      ),
      (0, 2),
    );
    // 歌名+歌手、时长不中 → 组 1 级 2。
    expect(songMatchGroupAndLevel(_song(title: '爱这件事情', duration: 300), _local), (1, 2));
    // 歌名+歌手+时长、专辑不中 → 组 1 级 3。
    expect(
      songMatchGroupAndLevel(_song(title: '爱这件事情', album: '别的专辑'), _local),
      (1, 3),
    );
    // 歌名+歌手+时长+专辑、年份不中 → 组 1 级 4。
    expect(songMatchGroupAndLevel(_song(title: '爱这件事情', year: 2021), _local), (1, 4));
    // 歌名不中 → 组 0 档 1。
    expect(songMatchGroupAndLevel(_song(title: '别的歌'), _local), (0, 1));
    // 歌名精确但歌手不匹配 → 组 0 档 2（歌名包含档）。
    expect(songMatchGroupAndLevel(_song(title: '爱这件事情', artist: '张三'), _local), (0, 2));
  });

  test('时长容差 ±1 秒：3:55 vs 3:54 算匹配，3:53 / 3:58 不算', () {
    expect(songMatchGroupAndLevel(_song(title: '爱这件事情', duration: 234), _local), (1, 5));
    expect(songMatchGroupAndLevel(_song(title: '爱这件事情', duration: 233), _local), (1, 2));
    expect(songMatchGroupAndLevel(_song(title: '爱这件事情', duration: 236), _local), (1, 5));
    expect(songMatchGroupAndLevel(_song(title: '爱这件事情', duration: 238), _local), (1, 2));
  });

  test('排序：5 级 → 1 级（双包含）→ 歌名包含 → 其它，同级别稳定', () {
    final results = [
      _song(
        title: '爱，这件事情',
        artist: '吉那罐子',
        album: '小吉的路',
        year: 2021,
        duration: 232,
      ), // 组 0 档 2（歌名精确、歌手不匹配）
      _song(title: '爱这件事情', artist: '白沐'), // 组 0 档 2
      _song(title: '爱这件事情（Live）', artist: '傅又宣 feat. 李四'), // 组 1 级 1（双包含）
      _song(title: '爱. 这件事 情'), // 组 1 级 5（傅又宣）
    ];
    final sorted = sortSongsByMatchLevel(results, _local);

    expect(sorted[0].artist, '傅又宣'); // 组 1 级 5 最左
    expect(sorted[1].artist, '傅又宣 feat. 李四'); // 组 1 级 1（双包含）
    expect(sorted[2].artist, '吉那罐子'); // 组 0 档 2，保持原顺序
    expect(sorted[3].artist, '白沐');
  });
}
