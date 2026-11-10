import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/discover/application/discover_providers.dart';
import 'package:mintmusic/features/discover/application/hot_board_providers.dart';
import 'package:mintmusic/features/discover/data/hot_board_store.dart';
import 'package:mintmusic/features/discover/domain/models/hot_board.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';
import 'package:mintmusic/features/settings/application/settings_providers.dart';

class _FakeStore implements HotBoardStore {
  List<HotBoard> boards = const [];
  int saveCount = 0;

  @override
  Future<List<HotBoard>> load() async => boards;

  @override
  Future<void> save(List<HotBoard> value) async {
    boards = [...value];
    saveCount++;
  }

  @override
  List<HotBoard> loadSync() => boards;

  @override
  Set<String> loadSourceIdsSync() => {
    for (final board in boards)
      if (board.source.isNotEmpty) board.source,
  };

  @override
  Future<void> importJson(String raw) async {
    boards = HotBoardStore.decode(raw);
  }

  @override
  Future<void> clear() async {
    boards = const [];
  }
}

Song _song(String id) =>
    Song(id: id, title: 'Song $id', artist: 'Artist', album: '', duration: 0);

HotBoard _board(String id, String source) => HotBoard(
  id: id,
  name: '榜单 $id',
  source: source,
  songs: [_song('$source-$id')],
);

ProviderContainer _container(_FakeStore store) {
  final container = ProviderContainer(
    overrides: [
      hotBoardStoreProvider.overrideWithValue(store),
      defaultSourceIdProvider.overrideWithValue('wy'),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('热榜数据', () {
    final songs = [
      const Song(
        id: 's1',
        title: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
        duration: 269000,
        coverUrl: 'https://example.com/1.jpg',
        source: 'wy',
        lrc: '[00:00.00]歌词',
        sourceHeaders: {'Referer': 'https://example.com'},
      ),
      const Song(
        id: 's2',
        title: '七里香',
        artist: '周杰伦',
        album: '七里香',
        duration: 299000,
        coverUrl: 'https://example.com/2.jpg',
        source: 'wy',
      ),
    ];
    final board = HotBoard(
      id: 'rank_1',
      name: '飙升榜',
      source: 'wy',
      coverUrl: 'https://example.com/cover.jpg',
      songs: songs,
    );

    test('落盘只存配置：音源 / 名称 / 封面，不带歌曲', () {
      final json = board.toConfigJson();
      expect(json['id'], 'rank_1');
      expect(json['name'], '飙升榜');
      expect(json['source'], 'wy');
      expect(json['coverUrl'], 'https://example.com/cover.jpg');
      expect(json.containsKey('songs'), isFalse, reason: '歌曲每次进页面实时拉');

      final round = HotBoard.fromConfigJson(json);
      expect(round.id, 'rank_1');
      expect(round.name, '飙升榜');
      expect(round.source, 'wy');
      expect(round.coverUrl, 'https://example.com/cover.jpg');
      expect(round.songs, isEmpty);
    });

    test('老数据里的歌曲不参与落盘', () {
      // 老备份 / 老设置键里的榜单带 songs：解析出来只保留配置部分。
      final legacy = HotBoard.fromJson({
        'id': 'rank_9',
        'name': '热歌榜',
        'source': 'tx',
        'coverUrl': 'https://example.com/9.jpg',
        'songs': [
          {'id': 's9', 'title': '稻香', 'artist': '周杰伦', 'album': '魔杰座'},
        ],
      });
      expect(legacy.songs.length, 1);
      expect(legacy.toConfigJson().containsKey('songs'), isFalse);
    });

    test('歌曲字段异常时跳过而不是整份失败', () {
      final round = HotBoard.fromJson({
        'id': 'rank_2',
        'name': '新歌榜',
        'source': 'tx',
        'songs': [
          'not a map',
          {'id': 's3', 'title': '稻香', 'artist': '周杰伦', 'album': '魔杰座'},
        ],
      });
      expect(round.songs.length, 1);
      expect(round.songs.single.id, 's3');
      expect(round.coverUrl, isNull);
    });

    test('多榜单配置编解码往返，坏条目跳过', () {
      final raw = HotBoardStore.encodeConfigs([
        board,
        const HotBoard(id: 'rank_2', name: '新歌榜', source: 'tx'),
      ]);
      final decoded = HotBoardStore.decodeConfigs(raw);
      expect(decoded.map((item) => item.id), ['rank_1', 'rank_2']);
      expect(decoded.every((item) => item.songs.isEmpty), isTrue);

      final damaged = HotBoardStore.decodeConfigs(
        '[{"id":"rank_3","name":"热歌榜","source":"wy"}, "bad"]',
      );
      expect(damaged.single.id, 'rank_3');
      expect(HotBoardStore.decodeConfigs('not json'), isEmpty);
      expect(HotBoardStore.decodeConfigs('{"id":"x"}'), isEmpty);
      expect(HotBoardStore.decodeConfigs(null), isEmpty);

      // 老数据（带 songs）仍然能解析，且只取配置。
      final legacy = HotBoardStore.decode(
        '[{"id":"rank_4","name":"老榜","source":"wy","songs":[{"id":"s4","title":"t","artist":"a","album":"b"}]}]',
      );
      expect(legacy.single.id, 'rank_4');
      expect(legacy.single.songs.length, 1);
    });
  });

  group('热榜列表', () {
    test('连续添加多个榜单，重复添加只刷新对应榜单', () async {
      final store = _FakeStore();
      final container = _container(store);
      await container.read(hotBoardsProvider.future);
      final notifier = container.read(hotBoardsProvider.notifier);

      await notifier.add(_board('a', 'wy'));
      await notifier.add(_board('b', 'wy'));
      expect(
        container.read(hotBoardsProvider).valueOrNull!.map((item) => item.id),
        ['a', 'b'],
        reason: '新增榜单不能替换之前的榜单',
      );

      await notifier.add(
        HotBoard(
          id: 'a',
          name: '榜单 a',
          source: 'wy',
          songs: [_song('refreshed')],
        ),
      );
      final boards = container.read(hotBoardsProvider).valueOrNull!;
      expect(boards.map((item) => item.id), ['a', 'b']);
      expect(boards.first.songs.single.id, 'refreshed');
      expect(store.saveCount, 3);
      expect(store.boards.length, 2);
    });

    test('跨音源聚合：不同音源的榜单同时展示，切换音源不影响列表', () async {
      final store = _FakeStore();
      final container = _container(store);
      await container.read(hotBoardsProvider.future);
      final notifier = container.read(hotBoardsProvider.notifier);
      await notifier.add(_board('wy-rank', 'wy'));
      await notifier.add(_board('tx-rank', 'tx'));

      List<String> ids() => container
          .read(hotBoardsProvider)
          .valueOrNull!
          .map((item) => item.id)
          .toList();

      expect(ids(), ['wy-rank', 'tx-rank']);

      container.read(discoverSourceIdProvider.notifier).state = 'tx';
      expect(ids(), ['wy-rank', 'tx-rank'], reason: '热榜数据不跟随主页音源');
    });

    test('拖动排序只调整当前音源内的顺序', () async {
      final store = _FakeStore();
      final container = _container(store);
      await container.read(hotBoardsProvider.future);
      final notifier = container.read(hotBoardsProvider.notifier);
      await notifier.add(_board('wy-a', 'wy'));
      await notifier.add(_board('tx-a', 'tx'));
      await notifier.add(_board('wy-b', 'wy'));
      await notifier.add(_board('wy-c', 'wy'));

      // 把第 1 个（wy-a）拖到末尾：ReorderableListView 传入的 newIndex 是插入位。
      await notifier.reorderForSource('wy', 0, 3);
      expect(
        container
            .read(hotBoardsProvider)
            .valueOrNull!
            .where((item) => item.source == 'wy')
            .map((item) => item.id),
        ['wy-b', 'wy-c', 'wy-a'],
      );
      expect(
        container.read(hotBoardsProvider).valueOrNull!.map((item) => item.id),
        ['wy-b', 'tx-a', 'wy-c', 'wy-a'],
        reason: '其它音源的榜单位置不变',
      );
      expect(store.boards.map((item) => item.id), [
        'wy-b',
        'tx-a',
        'wy-c',
        'wy-a',
      ]);
    });

    test('移除榜单只删除自己', () async {
      final store = _FakeStore();
      final container = _container(store);
      await container.read(hotBoardsProvider.future);
      final notifier = container.read(hotBoardsProvider.notifier);
      await notifier.add(_board('a', 'wy'));
      await notifier.add(_board('b', 'wy'));

      await notifier.remove(_board('a', 'wy'));
      expect(
        container.read(hotBoardsProvider).valueOrNull!.map((item) => item.id),
        ['b'],
      );
      expect(store.boards.map((item) => item.id), ['b']);
    });

    test('卸载插件时删掉该插件音源的榜单，同前缀的其他插件保留', () async {
      final store = _FakeStore();
      final container = _container(store);
      await container.read(hotBoardsProvider.future);
      final notifier = container.read(hotBoardsProvider.notifier);
      await notifier.add(_board('wy-app', 'wy'));
      await notifier.add(_board('wy-abc', 'wy@abc'));
      await notifier.add(_board('wy-abc2', 'wy@abc2'));
      await notifier.add(_board('wy-abcd', 'wy@abcd'));

      await notifier.removeForPlugin('abc');
      expect(
        container.read(hotBoardsProvider).valueOrNull!.map((item) => item.id),
        ['wy-app', 'wy-abcd'],
        reason: '同前缀的 @abcd 不能误删',
      );
      expect(store.boards.map((item) => item.id), ['wy-app', 'wy-abcd']);

      final savesAfterRemove = store.saveCount;
      await notifier.removeForPlugin('abc');
      expect(store.saveCount, savesAfterRemove, reason: '没有可删的榜单时不重复写入');
    });
  });
}
