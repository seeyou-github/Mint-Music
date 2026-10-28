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

    test('序列化往返保留榜单与歌曲', () {
      final round = HotBoard.fromJson(board.toJson());
      expect(round.id, 'rank_1');
      expect(round.name, '飙升榜');
      expect(round.source, 'wy');
      expect(round.coverUrl, 'https://example.com/cover.jpg');
      expect(round.songs.length, 2);
      expect(round.songs.first.id, 's1');
      expect(round.songs.first.title, '晴天');
      expect(round.songs.first.coverUrl, 'https://example.com/1.jpg');
    });

    test('持久化时不带歌词与请求头', () {
      final json = board.toJson();
      final first = (json['songs'] as List).first as Map<String, dynamic>;
      expect(first.containsKey('lrc'), isFalse);
      expect(first.containsKey('sourceHeaders'), isFalse);
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

    test('多榜单列表编解码往返，坏条目跳过', () {
      final raw = HotBoardStore.encode([
        board,
        const HotBoard(id: 'rank_2', name: '新歌榜', source: 'tx'),
      ]);
      final decoded = HotBoardStore.decode(raw);
      expect(decoded.map((item) => item.id), ['rank_1', 'rank_2']);
      expect(decoded.first.songs.length, 2);

      final damaged = HotBoardStore.decode(
        '[{"id":"rank_3","name":"热歌榜","source":"wy"}, "bad"]',
      );
      expect(damaged.single.id, 'rank_3');
      expect(HotBoardStore.decode('not json'), isEmpty);
      expect(HotBoardStore.decode('{"id":"x"}'), isEmpty);
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

    test('不同音源的热榜互不影响，切换音源时展示对应数据', () async {
      final store = _FakeStore();
      final container = _container(store);
      await container.read(hotBoardsProvider.future);
      final notifier = container.read(hotBoardsProvider.notifier);
      await notifier.add(_board('wy-rank', 'wy'));
      await notifier.add(_board('tx-rank', 'tx'));

      expect(
        container
            .read(currentHotBoardsProvider)
            .valueOrNull!
            .map((item) => item.id),
        ['wy-rank'],
      );
      container.read(discoverSourceIdProvider.notifier).state = 'tx';
      expect(
        container
            .read(currentHotBoardsProvider)
            .valueOrNull!
            .map((item) => item.id),
        ['tx-rank'],
        reason: '热榜数据与音源绑定',
      );
      expect(container.read(hotBoardsProvider).valueOrNull!.length, 2);
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
  });
}
