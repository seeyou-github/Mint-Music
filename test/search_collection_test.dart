import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/discover/domain/models/search_collection.dart';

void main() {
  group('SearchCollection.fromJson', () {
    test('MusicFree 作者：头像取 avatar 字段', () {
      // 哔哩哔哩等 MusicFree 插件的 searchArtist 返回这个结构，
      // 以前只读 coverUrl / artwork，作者头像一直是空的。
      final item = SearchCollection.fromJson(
        {
          'id': '12345',
          'name': '某UP主',
          'avatar': 'https://i0.hdslb.com/bfs/face/abc.jpg',
          'fans': 10000,
          'description': '简介',
          'worksNum': 88,
        },
        source: 'bilibili',
        type: CollectionType.artist,
      );

      expect(item.id, '12345');
      expect(item.title, '某UP主');
      expect(item.coverUrl, 'https://i0.hdslb.com/bfs/face/abc.jpg');
      expect(item.worksNum, 88);
      expect(item.description, '简介');
      expect(item.favoriteName, '作者：某UP主');
    });

    test('MusicFree 专辑：封面取 artwork 字段', () {
      final item = SearchCollection.fromJson(
        {
          'id': 'bvid1',
          'title': '某视频',
          'artwork': 'https://i0.hdslb.com/bfs/archive/xyz.jpg',
          'date': '2026-01-01',
          'worksNum': 3,
        },
        source: 'bilibili',
        type: CollectionType.album,
      );

      expect(item.coverUrl, 'https://i0.hdslb.com/bfs/archive/xyz.jpg');
      expect(item.favoriteName, '专辑：某视频');
    });

    test('内置源：封面取 coverUrl，avatar 为空时回退 artwork', () {
      final withCover = SearchCollection.fromJson(
        {'id': '1', 'title': 'A', 'coverUrl': 'https://p1.music.126.net/a.jpg'},
        source: 'wy',
        type: CollectionType.album,
      );
      expect(withCover.coverUrl, 'https://p1.music.126.net/a.jpg');

      final fallback = SearchCollection.fromJson(
        {
          'id': '2',
          'title': 'B',
          'avatar': '   ',
          'artwork': 'https://x.com/b.jpg',
        },
        source: 'wy',
        type: CollectionType.artist,
      );
      expect(fallback.coverUrl, 'https://x.com/b.jpg');
    });

    test('没有可用封面时返回 null，交给界面显示占位图', () {
      final item = SearchCollection.fromJson(
        {'id': '3', 'title': 'C'},
        source: 'wy',
        type: CollectionType.album,
      );
      expect(item.coverUrl, isNull);
    });
  });

  test('CollectionDetailException 的文案直接可读', () {
    const error = CollectionDetailException('音源返回异常：超时');
    expect(error.toString(), '音源返回异常：超时');
  });

  test('CollectionSearchPage 默认认为已经到底', () {
    const page = CollectionSearchPage();
    expect(page.items, isEmpty);
    expect(page.isEnd, isTrue);
  });
}
