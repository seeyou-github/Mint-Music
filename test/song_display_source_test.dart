import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';

/// 回归：列表里的音源徽标要显示「真正用的插件」。
///
/// 插件搜索出来的歌，`source` 只记平台 id（播放 / 歌词按平台处理），
/// 实际插件记在 `preferredSource`。旧实现只读 `source`，于是「用元力KW
/// 搜出来的歌」全部被标成「酷我音乐-内置」，看起来像没走插件。
void main() {
  Song songWith({String? source, String? preferredSource}) => Song(
    id: '1',
    title: 't',
    artist: 'a',
    album: 'b',
    duration: 1,
    source: source,
    preferredSource: preferredSource,
  );

  group('Song.displaySource', () {
    test('插件搜索结果优先显示插件（平台 id + preferredSource）', () {
      final song = songWith(source: 'kw', preferredSource: 'kw@1a16f66000f');
      expect(song.displaySource, 'kw@1a16f66000f');
    });

    test('没有绑定插件时回退到平台 id', () {
      expect(songWith(source: 'kw').displaySource, 'kw');
    });

    test('preferredSource 为空字符串时不算绑定', () {
      expect(songWith(source: 'kw', preferredSource: '  ').displaySource, 'kw');
    });

    test('两个都为空时返回 null', () {
      expect(songWith().displaySource, isNull);
    });

    test('本地歌曲不受影响', () {
      expect(songWith(source: 'local').displaySource, 'local');
    });
  });
}
