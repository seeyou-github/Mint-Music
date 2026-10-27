import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/player/application/desktop_lyric_controller.dart';
import 'package:mintmusic/features/player/application/lyric_controller.dart';
import 'package:mintmusic/features/player/domain/models/lyric_line.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';

Song _song(String id, {String source = 'wy'}) => Song(
  id: id,
  title: 'song-$id',
  artist: 'artist',
  album: 'album',
  duration: 100,
  source: source,
);

List<LyricLine> _lines(String text) => [
  LyricLine(
    startTimeMs: 0,
    endTimeMs: 1000,
    words: [LyricWord(word: text, startTimeMs: 0, endTimeMs: 1000)],
  ),
];

void main() {
  group('areLyricsReadyForSong', () {
    test('没有正在播放的歌曲时不可用', () {
      expect(areLyricsReadyForSong(null, const LyricState()), isFalse);
    });

    test('加载中不可用：lines 仍是上一首的旧歌词', () {
      // 这正是 LyricController.loadLyrics 开头的状态：
      // 保留旧 lines 防止 AMLL 闪屏，但 currentSongId 已经是新歌。
      final lyric = LyricState(
        lines: _lines('上一首的歌词'),
        isLoading: true,
        currentSongId: 'b',
        currentSongSource: 'wy',
      );
      expect(areLyricsReadyForSong(_song('b'), lyric), isFalse);
    });

    test('歌词属于另一首歌时不可用', () {
      final lyric = LyricState(
        lines: _lines('上一首的歌词'),
        currentSongId: 'a',
        currentSongSource: 'wy',
      );
      expect(areLyricsReadyForSong(_song('b'), lyric), isFalse);
    });

    test('来源不一致时不可用', () {
      final lyric = LyricState(
        lines: _lines('歌词'),
        currentSongId: 'a',
        currentSongSource: 'wy',
      );
      expect(
        areLyricsReadyForSong(_song('a', source: 'local'), lyric),
        isFalse,
      );
    });

    test('已加载完成且属于当前歌曲时可用', () {
      final lyric = LyricState(
        lines: _lines('当前歌词'),
        currentSongId: 'a',
        currentSongSource: 'wy',
      );
      expect(areLyricsReadyForSong(_song('a'), lyric), isTrue);
    });

    test('无歌词（加载失败/空结果）也算就绪，由调用方显示占位', () {
      // loadLyrics 失败时的最终状态：lines 为空、isLoading 为 false
      final lyric = LyricState(error: '加载歌词失败', currentSongId: 'a');
      expect(areLyricsReadyForSong(_song('a'), lyric), isTrue);
    });

    test('来源为空时不比较来源', () {
      const lyric = LyricState(currentSongId: 'a');
      expect(areLyricsReadyForSong(_song('a'), lyric), isTrue);
    });
  });
}
