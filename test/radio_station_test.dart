import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/radio/data/radio_page_limits.dart';
import 'package:mintmusic/features/radio/domain/models/radio_station.dart';

void main() {
  test('电台分类：内置「全部」', () {
    expect(RadioCategory.all.id, 'all');
    expect(RadioCategory.all.isAll, isTrue);
    expect(RadioCategory.allId, 'all');
  });

  group('电台配置', () {
    final station = RadioStation(
      id: 'radio_1',
      name: '深夜电台',
      coverUrl: 'https://example.com/a.jpg',
      coverPath: '/tmp/a.jpg',
      categoryId: 'cat_1',
      sourceIds: const ['wy', 'tx'],
      tags: const [RadioTagRef(sourceId: 'wy', tagId: '1001', tagName: '华语')],
      keywords: const ['情歌', '晚安'],
      createTime: DateTime(2026, 1, 1),
      updateTime: DateTime(2026, 1, 2),
    );

    test('序列化往返', () {
      final round = RadioStation.fromJson(station.toJson());
      expect(round.id, 'radio_1');
      expect(round.name, '深夜电台');
      expect(round.coverPath, '/tmp/a.jpg');
      expect(round.categoryId, 'cat_1');
      expect(round.sourceIds, ['wy', 'tx']);
      expect(round.tags.single.tagId, '1001');
      expect(round.keywords, ['情歌', '晚安']);
      expect(round.createTime, DateTime(2026, 1, 1));
    });

    test('封面优先用缓存到本地的文件', () {
      expect(station.displayCover, '/tmp/a.jpg');
      final noCache = station.copyWith(clearCoverPath: true);
      expect(noCache.displayCover, 'https://example.com/a.jpg');
    });

    test('至少要有一种取歌来源', () {
      expect(station.hasSongSource, isTrue);
      expect(
        station.copyWith(tags: const [], keywords: const []).hasSongSource,
        isFalse,
      );
    });

    test('分类筛选', () {
      final data = RadioData(
        categories: const [RadioCategory(id: 'cat_1', name: '夜晚')],
        stations: [
          station,
          station.copyWith(categoryId: RadioCategory.allId),
        ],
      );
      expect(data.stationsIn(RadioCategory.allId).length, 2);
      expect(data.stationsIn('cat_1').length, 1);
    });
  });

  group('随机页回缩规则', () {
    test('空页后先缩 5 页，5 页以内每次缩 1 页', () {
      expect(nextPageAfterEmpty(50), 45);
      expect(nextPageAfterEmpty(12), 7);
      expect(nextPageAfterEmpty(6), 1);
      expect(nextPageAfterEmpty(5), 4);
      expect(nextPageAfterEmpty(1), 0);
    });

    test('一直缩到 0 就停（页面用 >= 1 判断）', () {
      var page = 8;
      final visited = <int>[];
      while (page >= 1) {
        visited.add(page);
        page = nextPageAfterEmpty(page);
      }
      expect(visited, [8, 3, 2, 1]);
    });
  });
}
