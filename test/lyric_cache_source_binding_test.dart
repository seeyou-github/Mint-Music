import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';
import 'package:mintmusic/features/player/domain/services/lyric_cache.dart';

Song _song({String id = '1', String? source, String? preferredSource}) => Song(
  id: id,
  title: 't',
  artist: 'a',
  album: 'b',
  duration: 1,
  source: source,
  preferredSource: preferredSource,
);

/// 歌词缓存 / 删除关联 / 手动歌词都按「音源 + 歌曲」归属：
/// 同一首歌换音源播放时要用那个音源自己的歌词，不能共用一份缓存。
void main() {
  group('Song.lyricSourceId', () {
    test('优先用歌曲绑定的插件音源', () {
      expect(
        _song(source: 'wy', preferredSource: 'wy@plugin').lyricSourceId,
        'wy@plugin',
      );
    });

    test('没有绑定插件时用歌曲音源（含插件变体）', () {
      expect(_song(source: 'wy').lyricSourceId, 'wy');
      expect(_song(source: 'wy@plugin').lyricSourceId, 'wy@plugin');
    });

    test('本地歌曲是 local', () {
      expect(_song(source: 'local').lyricSourceId, 'local');
    });
  });

  group('LyricCache.keyFor', () {
    test('同一首歌不同平台音源使用不同缓存键', () {
      final wy = LyricCache.keyFor(_song(source: 'wy'));
      final kw = LyricCache.keyFor(_song(source: 'kw'));
      expect(wy, isNot(kw));
    });

    test('同一首歌不同插件音源使用不同缓存键', () {
      final a = LyricCache.keyFor(_song(source: 'wy', preferredSource: 'wy@a'));
      final b = LyricCache.keyFor(_song(source: 'wy', preferredSource: 'wy@b'));
      expect(a, isNot(b));
    });

    test('绑定插件与已解析成插件变体的音源是同一个键', () {
      final bound = _song(source: 'wy', preferredSource: 'wy@a');
      final resolved = _song(source: 'wy@a');
      expect(LyricCache.keyFor(bound), LyricCache.keyFor(resolved));
    });

    test('歌曲 id 相同但平台不同不共用缓存', () {
      final wy = LyricCache.keyFor(_song(id: '1', source: 'wy'));
      final tx = LyricCache.keyFor(_song(id: '1', source: 'tx'));
      expect(wy, isNot(tx));
    });
  });
}
