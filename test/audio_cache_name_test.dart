import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/player/platform/audio_cache_service.dart';

/// 回归：同一平台装了多个插件时，音频缓存文件名必须能区分插件。
///
/// 旧实现只按「平台名-内置/插件」命名，两个网易插件（星海、可下高音质）
/// 都会落到 `歌手 - 歌名 [128k-网易云音乐-插件].mp3` 这一个文件上，
/// 后播的那个直接命中前一个插件缓存下来的音频。
void main() {
  const xinghai = 'wy@1a16f66000f';
  const gaoYinZhi = 'wy@1a16f6600ab';

  group('AudioCacheService.sourceLabelFor', () {
    test('内置音源标为「平台-内置」', () {
      expect(AudioCacheService.sourceLabelFor('wy'), '网易云音乐-内置');
      expect(AudioCacheService.sourceLabelFor('kw'), '酷我音乐-内置');
    });

    test('插件音源带上插件 id', () {
      expect(AudioCacheService.sourceLabelFor(xinghai), '网易云音乐-插件-1a16f66000f');
    });

    test('同平台的两个插件标签不同（本次修复的核心）', () {
      expect(
        AudioCacheService.sourceLabelFor(xinghai),
        isNot(AudioCacheService.sourceLabelFor(gaoYinZhi)),
      );
    });

    test('同一个插件的不同平台标签也不同', () {
      expect(
        AudioCacheService.sourceLabelFor('wy@1a16f66000f'),
        isNot(AudioCacheService.sourceLabelFor('kw@1a16f66000f')),
      );
    });

    test('插件 id 缺失时退化为「平台-插件」', () {
      expect(AudioCacheService.sourceLabelFor('wy@'), '网易云音乐-插件');
    });

    test('本地与空值', () {
      expect(AudioCacheService.sourceLabelFor('local'), '本地');
      expect(AudioCacheService.sourceLabelFor(null), '未知音源');
      expect(AudioCacheService.sourceLabelFor('  '), '未知音源');
    });

    test('未知平台回退成平台 id', () {
      expect(AudioCacheService.sourceLabelFor('xyz'), 'xyz-内置');
      expect(AudioCacheService.sourceLabelFor('xyz@p1'), 'xyz-插件-p1');
    });
  });

  group('AudioCacheService.fileNameFor', () {
    String name(String source) => AudioCacheService.fileNameFor(
      songId: '123',
      quality: '128k',
      extension: 'mp3',
      source: source,
      artist: 'Whitney Houston',
      title: 'Call You Tonight',
    );

    test('两个插件不会落到同一个文件', () {
      expect(name(xinghai), isNot(name(gaoYinZhi)));
      expect(name(xinghai), 'Whitney Houston - Call You Tonight [128k-网易云音乐-插件-1a16f66000f].mp3');
    });

    test('内置与插件也不会互相命中', () {
      expect(name('wy'), isNot(name(xinghai)));
    });

    test('同名不同音质分开缓存', () {
      final a = AudioCacheService.fileNameFor(
        songId: '123',
        quality: '128k',
        extension: 'mp3',
        source: xinghai,
        artist: 'A',
        title: 'B',
      );
      final b = AudioCacheService.fileNameFor(
        songId: '123',
        quality: '320k',
        extension: 'mp3',
        source: xinghai,
        artist: 'A',
        title: 'B',
      );
      expect(a, isNot(b));
    });

    test('文件名里的非法字符被清掉', () {
      final fileName = AudioCacheService.fileNameFor(
        songId: '1',
        quality: '128k',
        extension: 'mp3',
        source: xinghai,
        artist: 'A/B',
        title: 'C:D?',
      );
      expect(fileName.contains('/'), isFalse);
      expect(fileName.contains(':'), isFalse);
      expect(fileName.contains('?'), isFalse);
    });
  });
}
