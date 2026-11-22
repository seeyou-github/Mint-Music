import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/library/domain/models/playlist.dart';
import 'package:mintmusic/features/library/utils/favorite_playlist.dart';

Playlist _playlist({
  required String id,
  String name = '',
  String description = '',
  Map<String, dynamic> meta = const {},
}) {
  return Playlist(
    id: id,
    name: name,
    description: description,
    createTime: DateTime(2024, 1, 1),
    updateTime: DateTime(2024, 1, 1),
    meta: meta,
  );
}

void main() {
  group('showsSourceTag：逐首音源标签只在「自己的歌单」里显示', () {
    test('我的收藏 / 自建歌单为 true', () {
      expect(_playlist(id: '__favorites__').showsSourceTag, isTrue);
      expect(
        _playlist(id: 'mine', name: '通勤', meta: const {}).showsSourceTag,
        isTrue,
      );
    });

    test('收藏的第三方歌单 / 专辑 / 作者为 false', () {
      final remote = _playlist(
        id: 'remote',
        name: '某歌单',
        meta: const {'discoverId': '123'},
      );
      final album = _playlist(
        id: 'album',
        name: '专辑：某专辑',
        description: 'mintmusic:album:wy:456',
      );
      final artist = _playlist(
        id: 'artist',
        name: '作者：某人',
        description: 'mintmusic:artist:wy:789',
      );

      expect(remote.showsSourceTag, isFalse);
      expect(album.showsSourceTag, isFalse);
      expect(artist.showsSourceTag, isFalse);
    });
  });
}
