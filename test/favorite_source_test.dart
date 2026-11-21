import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/library/utils/favorite_playlist.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';

Song _song(String id, {String? source, String? preferredSource}) => Song(
  id: id,
  title: 'song $id',
  artist: 'artist',
  album: 'album',
  duration: 1000,
  source: source,
  sourceUrl: 'https://example.com/$id.mp3',
  preferredSource: preferredSource,
);

Song _localSong(String id) => Song(
  id: id,
  title: 'local',
  artist: 'artist',
  album: 'album',
  duration: 1000,
  source: 'local',
  filePath: '/tmp/a.flac',
);

void main() {
  group('applyFavoriteSource', () {
    test('收藏的插件音源 → 记到 preferredSource，平台音源不变', () {
      final songs = [_song('1', source: 'wy')];
      final result = applyFavoriteSource(songs, 'wy@luoxue');

      expect(result.first.preferredSource, 'wy@luoxue');
      expect(result.first.source, 'wy');
      // 收藏起来的地址会过期，清掉重新解析。
      expect(result.first.sourceUrl, isNull);
    });

    test('已经绑过同一个插件时原样返回', () {
      final bound = _song('2', source: 'wy', preferredSource: 'wy@luoxue');
      final result = applyFavoriteSource([bound], 'wy@luoxue');
      expect(identical(result.first, bound), isTrue);

      final hardBound = _song('2b', source: 'wy@luoxue');
      final result2 = applyFavoriteSource([hardBound], 'wy@luoxue');
      expect(identical(result2.first, hardBound), isTrue);
    });

    test('硬绑在别的插件上时退回平台 id，让优先插件能生效', () {
      final other = _song('3', source: 'wy@other');
      final result = applyFavoriteSource([other], 'wy@luoxue').first;
      expect(result.source, 'wy');
      expect(result.preferredSource, 'wy@luoxue');
    });

    test('本地歌曲不受影响', () {
      final local = _localSong('3');
      final result = applyFavoriteSource([local], 'wy@luoxue');
      expect(identical(result.first, local), isTrue);
    });

    test('收藏源只有平台 id：同平台保留原插件，跨平台才改写', () {
      final samePlatform = _song('4', source: 'wy@other');
      expect(
        identical(
          applyFavoriteSource([samePlatform], 'wy').first,
          samePlatform,
        ),
        isTrue,
      );

      final crossPlatform = applyFavoriteSource([
        _song('5', source: 'kg'),
      ], 'wy').first;
      expect(crossPlatform.source, 'wy');
      expect(crossPlatform.preferredSource, isNull);
    });

    test('没有记录音源时不做改动', () {
      final songs = [_song('6', source: 'wy')];
      expect(identical(applyFavoriteSource(songs, null), songs), isTrue);
      expect(identical(applyFavoriteSource(songs, 'local'), songs), isTrue);
    });
  });

  group('upgradeFavoriteMarkerSource', () {
    test('把描述标记里的平台 id 换成具体插件', () {
      expect(
        upgradeFavoriteMarkerSource('mintmusic:album:wy:123', 'wy@luoxue'),
        'mintmusic:album:wy@luoxue:123',
      );
      expect(
        upgradeFavoriteMarkerSource('mintmusic:artist:wy:abc', 'wy@luoxue'),
        'mintmusic:artist:wy@luoxue:abc',
      );
    });

    test('已经是同一个音源 / 不是收藏标记时原样返回', () {
      expect(
        upgradeFavoriteMarkerSource('mintmusic:album:wy@x:1', 'wy@x'),
        'mintmusic:album:wy@x:1',
      );
      expect(upgradeFavoriteMarkerSource('普通描述', 'wy@luoxue'), '普通描述');
    });
  });
}
