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
  test('全部字段匹配得满分，排最前（靠左）', () {
    final results = [
      _song(title: '女人是老虎 (Live)'), // 歌名不完全一致：低分
      _song(title: '女人是老虎'), // 全中
    ];
    final sorted = sortSongsByMatchScore(results, _local);
    expect(sorted.first.title, '女人是老虎');
    expect(songMatchScore(results[1], _local), 5);
    expect(songMatchScore(results[0], _local), lessThan(5));
  });

  test('命中字段越多越靠前，同分保持原顺序（稳定排序）', () {
    final results = [
      _song(title: '别的歌', album: '别的专辑', year: 1999, duration: 300), // 0 分
      _song(title: '女人是老虎（女版）'), // 只有歌名+歌手：2 分
      _song(title: '女人是老虎'), // 5 分
      _song(title: '女人是老虎', album: '山海（珍藏版）'), // 5 分（专辑包含也算）
    ];
    final sorted = sortSongsByMatchScore(results, _local);
    // 满分的两条保持插件返回的原相对顺序。
    expect(sorted[0].title, '女人是老虎');
    expect(sorted[0].album, '山海');
    expect(sorted[1].album, '山海（珍藏版）');
    expect(sorted[2].title, '女人是老虎（女版）');
    expect(sorted[3].title, '别的歌');
  });

  test('年份与时长：双方都有值且在容差内才算命中', () {
    expect(songMatchScore(_song(title: '女人是老虎', year: 2020, duration: 206), _local), 5);
    expect(songMatchScore(_song(title: '女人是老虎', year: 2019, duration: 206), _local), 4);
    expect(songMatchScore(_song(title: '女人是老虎', year: 2020, duration: 215), _local), 4);
    // 本地 / 候选缺值（0 / null）不计分。
    expect(
      songMatchScore(_song(title: '女人是老虎', year: null, duration: 0), _local),
      3,
    );
  });

  test('归一化：括号 / 空白 / 大小写差异不影响匹配', () {
    expect(
      songMatchScore(
        _song(title: '女人是老虎', album: 'Shan Hai'),
        const LocalSongMatchFields(
          title: '女人是老虎 ',
          artist: '封茗囧菌',
          album: 'shan hai',
          year: 0,
          durationSeconds: 0,
        ),
      ),
      3,
    );
  });
}
