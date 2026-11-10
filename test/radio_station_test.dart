import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/radio/application/radio_providers.dart';
import 'package:mintmusic/features/radio/data/radio_page_limits.dart';

class _FakeRadioStore extends RadioStore {
  RadioData data = const RadioData();
  int saveCount = 0;

  @override
  Future<RadioData> load() async => data;

  @override
  Future<void> save(RadioData value) async {
    data = value;
    saveCount++;
  }
}

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

  group('电台排序', () {
    late _FakeRadioStore store;
    late ProviderContainer container;

    RadioStation make(String id, {String category = RadioCategory.allId}) {
      return RadioStation(
        id: id,
        name: id,
        coverUrl: '',
        categoryId: category,
        createTime: DateTime(2026, 1, 1),
        updateTime: DateTime(2026, 1, 1),
      );
    }

    setUp(() async {
      store = _FakeRadioStore();
      store.data = RadioData(
        categories: const [RadioCategory(id: 'cat_1', name: '夜晚')],
        stations: [
          make('a'),
          make('b', category: 'cat_1'),
          make('c'),
        ],
      );
      container = ProviderContainer(
        overrides: [radioStoreProvider.overrideWithValue(store)],
      );
      container.read(radioProvider.notifier);
      await Future<void>.delayed(Duration.zero);
    });

    tearDown(() => container.dispose());

    test('拖动排序后电台页按新顺序展示，并写回存储', () async {
      await container.read(radioProvider.notifier).reorderStations(0, 3);
      expect(container.read(radioProvider).stations.map((s) => s.id), [
        'b',
        'c',
        'a',
      ]);
      expect(
        container
            .read(radioProvider)
            .stationsIn(RadioCategory.allId)
            .map((s) => s.id),
        ['b', 'c', 'a'],
      );
      expect(
        container.read(radioProvider).stationsIn('cat_1').map((s) => s.id),
        ['b'],
      );
      expect(store.data.stations.map((s) => s.id), ['b', 'c', 'a']);
      expect(store.saveCount, 1);
    });

    test('分类内电台跟随全局顺序，删除不影响其它电台', () async {
      await container.read(radioProvider.notifier).reorderStations(2, 0);
      expect(container.read(radioProvider).stations.map((s) => s.id), [
        'c',
        'a',
        'b',
      ]);
      expect(
        container.read(radioProvider).stationsIn('cat_1').map((s) => s.id),
        ['b'],
      );

      await container.read(radioProvider.notifier).removeStation('c');
      expect(container.read(radioProvider).stations.map((s) => s.id), [
        'a',
        'b',
      ]);
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
