import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mintmusic/features/discover/application/discover_providers.dart';
import 'package:mintmusic/features/discover/application/search_providers.dart';
import 'package:mintmusic/features/discover/data/discover_repository.dart';
import 'package:mintmusic/features/discover/domain/models/playlist.dart';
import 'package:mintmusic/features/discover/domain/models/search_collection.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';
import 'package:mintmusic/features/plugin/application/music_source_manager.dart';
import 'package:mintmusic/shared/pagination/page_result.dart';
import 'package:mintmusic/shared/pagination/page_slicer.dart';

class _Manager implements MusicSourceManager {
  Future<PageResult<Song>> Function(String, int)? songPage;
  Future<PageResult<Playlist>> Function(int)? playlistPage;
  Future<PageResult<Playlist>> Function(int)? categoryPage;
  Future<CollectionSearchPage> Function(int)? collectionPage;

  @override
  Future<PageResult<Song>> searchPage(
    String query, {
    String sourceId = 'wy',
    int page = 1,
    int limit = 30,
  }) => songPage!(query, page);

  @override
  Future<PageResult<Playlist>> searchPlaylistsSinglePage(
    String query, {
    required String sourceId,
    int page = 1,
    int limit = 30,
  }) => playlistPage!(page);

  @override
  Future<PageResult<Playlist>> getCategoryPlaylists({
    required String sortId,
    required String tagId,
    required int page,
    required int limit,
    String sourceId = 'wy',
  }) => categoryPage!(page);

  @override
  bool sourceSupportsCollectionSearch(String sourceId, CollectionType type) =>
      true;

  @override
  Future<CollectionSearchPage> searchCollections(
    String keyword, {
    required String sourceId,
    required CollectionType type,
    int page = 1,
    int limit = 30,
  }) => collectionPage!(page);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Song _song(int id) =>
    Song(id: '$id', title: 'Song $id', artist: '', album: '', duration: 0);
Playlist _playlist(int id) =>
    Playlist(id: '$id', title: 'List $id', description: '', songCount: 0);
SearchCollection _collection(int id) => SearchCollection(
  id: '$id',
  title: 'Album $id',
  type: CollectionType.album,
  source: 'wy',
);

void main() {
  test('歌曲首页即有总数，末页不再额外请求', () async {
    final manager = _Manager();
    var calls = 0;
    manager.songPage = (_, page) async {
      calls++;
      return PageResult(items: [_song(page)], total: 2, isEnd: page == 2);
    };
    final notifier = SearchResultsNotifier(manager);
    addTearDown(notifier.dispose);
    await notifier.start('song', 'wy');
    expect(notifier.state.total, 2);
    expect(notifier.state.hasMore, isTrue);
    await notifier.loadMore();
    await notifier.loadMore();
    expect(notifier.state.total, 2);
    expect(notifier.state.hasMore, isFalse);
    expect(calls, 2);
  });

  test('未知总数保留短页，遇到重复末页再确定总数', () async {
    final manager = _Manager();
    manager.songPage = (_, page) async =>
        PageResult(items: [_song(page > 2 ? 2 : page)]);
    final notifier = SearchResultsNotifier(manager);
    addTearDown(notifier.dispose);
    await notifier.start('song', 'wy');
    expect(notifier.state.total, isNull);
    await notifier.loadMore();
    expect(notifier.state.hasMore, isTrue);
    await notifier.loadMore();
    expect(notifier.state.hasMore, isFalse);
    expect(notifier.state.total, 2);
  });

  test('失败保留真实总数，重试仍请求同一页', () async {
    final manager = _Manager();
    final pages = <int>[];
    var fail = true;
    manager.songPage = (_, page) async {
      pages.add(page);
      if (page == 2 && fail) throw Exception('offline');
      return PageResult(items: [_song(page)], total: 2, isEnd: page == 2);
    };
    final notifier = SearchResultsNotifier(manager);
    addTearDown(notifier.dispose);
    await notifier.start('song', 'wy');
    await notifier.loadMore();
    expect(notifier.state.loadMoreError, 'offline');
    expect(notifier.state.total, 2);
    expect(notifier.state.hasMore, isTrue);
    fail = false;
    await notifier.retryLoadMore();
    expect(pages, [1, 2, 2]);
    expect(notifier.state.loadMoreError, isNull);
    expect(notifier.state.hasMore, isFalse);
  });

  test('新查询清除旧总数，迟到响应不覆盖新结果', () async {
    final manager = _Manager();
    final pending = Completer<PageResult<Song>>();
    manager.songPage = (query, _) async => query == 'old'
        ? pending.future
        : PageResult(items: [_song(2)], total: 1, isEnd: true);
    final notifier = SearchResultsNotifier(manager);
    addTearDown(notifier.dispose);
    final oldRequest = notifier.start('old', 'wy');
    expect(notifier.state.total, isNull);
    await notifier.start('new', 'wy');
    pending.complete(PageResult(items: [_song(1)], total: 999, isEnd: false));
    await oldRequest;
    expect(notifier.state.query, 'new');
    expect(notifier.state.total, 1);
    expect(notifier.state.songs.single.id, '2');
    notifier.reset();
    expect(notifier.state.total, isNull);
  });

  test('歌单搜索传递总数并在末页改为实际去重数量', () async {
    final manager = _Manager();
    manager.playlistPage = (page) async =>
        PageResult(items: [_playlist(page)], total: 99, isEnd: page == 2);
    final notifier = PlaylistSearchNotifier(manager);
    addTearDown(notifier.dispose);
    await notifier.search('list', 'wy');
    expect(notifier.state.total, 99);
    await notifier.loadMore();
    expect(notifier.state.total, 2);
    expect(notifier.state.hasMore, isFalse);
  });

  test('专辑作者搜索支持已知总数和真实零结果', () async {
    final manager = _Manager();
    manager.collectionPage = (page) async => CollectionSearchPage(
      items: [_collection(page)],
      total: 2,
      isEnd: page == 2,
    );
    final notifier = CollectionSearchController(manager);
    addTearDown(notifier.dispose);
    await notifier.search('album', 'wy', CollectionType.album);
    expect(notifier.state.total, 2);
    await notifier.loadMore();
    expect(notifier.state.hasMore, isFalse);
    manager.collectionPage = (_) async => const CollectionSearchPage(total: 0);
    await notifier.search('none', 'wy', CollectionType.artist);
    expect(notifier.state.total, 0);
    expect(notifier.state.results, isEmpty);
    expect(notifier.state.hasMore, isFalse);
  });

  test('跳页直达只请求目标页并替换缓冲，相邻页仍追加', () async {
    final manager = _Manager();
    final pages = <int>[];
    manager.songPage = (_, page) async {
      pages.add(page);
      return PageResult(items: [_song(page * 10)], total: 500, isEnd: false);
    };
    final notifier = SearchResultsNotifier(manager);
    addTearDown(notifier.dispose);
    await notifier.start('song', 'wy');
    final ok = await notifier.goToPage(5);
    expect(ok, isTrue);
    expect(pages, [1, 5], reason: '不补齐中间页');
    expect(notifier.state.page, 5);
    expect(notifier.state.songs.single.id, '50');
    expect(notifier.state.hasMore, isTrue);
    await notifier.loadMore();
    expect(pages, [1, 5, 6], reason: '相邻页继续追加');
    expect(notifier.state.songs.map((s) => s.id).toList(), ['50', '60']);
  });

  test('末页没有数据时回退到最近的有数据页', () async {
    final manager = _Manager();
    final pages = <int>[];
    manager.songPage = (_, page) async {
      pages.add(page);
      if (page >= 3) {
        return const PageResult(items: [], total: 500, isEnd: false);
      }
      return PageResult(
        items: [for (var i = 0; i < 30; i++) _song((page - 1) * 30 + i)],
        total: 500,
        isEnd: false,
      );
    };
    final notifier = SearchResultsNotifier(manager);
    addTearDown(notifier.dispose);
    await notifier.start('song', 'wy');
    final ok = await notifier.goToPage(5);
    expect(ok, isTrue);
    expect(pages, [1, 5, 4, 3, 2], reason: '往回找到有数据的页就停');
    expect(notifier.state.page, 2);
    expect(notifier.state.songs, hasLength(30));
    expect(notifier.state.hasMore, isFalse);
    expect(notifier.state.total, 60);
  });

  test('跳页失败保留原缓冲，重试仍直取目标页', () async {
    final manager = _Manager();
    final pages = <int>[];
    var fail = true;
    manager.songPage = (_, page) async {
      pages.add(page);
      if (page == 7 && fail) throw Exception('offline');
      return PageResult(items: [_song(page)], total: 100, isEnd: false);
    };
    final notifier = SearchResultsNotifier(manager);
    addTearDown(notifier.dispose);
    await notifier.start('song', 'wy');
    final ok = await notifier.goToPage(7);
    expect(ok, isFalse);
    expect(notifier.state.loadMoreError, 'offline');
    expect(notifier.state.songs.single.id, '1', reason: '原缓冲保留');
    fail = false;
    await notifier.retryLoadMore();
    expect(pages, [1, 7, 7]);
    expect(notifier.state.songs.single.id, '7');
    expect(notifier.state.loadMoreError, isNull);
  });

  test('歌单与专辑作者跳页同样单页直取', () async {
    final manager = _Manager();
    final playlistCalls = <int>[];
    final collectionCalls = <int>[];
    manager.playlistPage = (page) async {
      playlistCalls.add(page);
      return PageResult(items: [_playlist(page)], total: 90, isEnd: false);
    };
    manager.collectionPage = (page) async {
      collectionCalls.add(page);
      return CollectionSearchPage(
        items: [_collection(page)],
        total: 90,
        isEnd: false,
      );
    };
    final playlists = PlaylistSearchNotifier(manager);
    addTearDown(playlists.dispose);
    await playlists.search('list', 'wy');
    expect(await playlists.goToPage(3), isTrue);
    expect(playlistCalls, [1, 3]);
    expect(playlists.state.playlists.single.id, '3');

    final collections = CollectionSearchController(manager);
    addTearDown(collections.dispose);
    await collections.search('album', 'wy', CollectionType.album);
    expect(await collections.goToPage(4), isTrue);
    expect(collectionCalls, [1, 4]);
    expect(collections.state.results.single.id, '4');
  });

  test('发现分类短页不中断，总数在通知状态前更新', () async {
    final manager = _Manager();
    manager.categoryPage = (page) async =>
        PageResult(items: [_playlist(page)], total: 3, isEnd: page == 3);
    final notifier = CategoryPlaylistsNotifier(DiscoverRepository(manager));
    addTearDown(notifier.dispose);
    final observed = <(int?, bool)>[];
    notifier.addListener(
      (_) => observed.add((notifier.total, notifier.noMore)),
    );
    await notifier.fetchPlaylists(sortId: 'hot', tagId: '', reset: true);
    expect(notifier.total, 3);
    expect(notifier.noMore, isFalse);
    await notifier.fetchPlaylists(sortId: 'hot', tagId: '');
    await notifier.fetchPlaylists(sortId: 'hot', tagId: '');
    expect(notifier.noMore, isTrue);
    expect(observed.last, (3, true));
  });

  test('发现下一页失败不丢已有列表，不把错误当末页', () async {
    final manager = _Manager();
    var fail = true;
    manager.categoryPage = (page) async {
      if (page == 2 && fail) throw Exception('offline');
      return PageResult(items: [_playlist(page)], total: 2, isEnd: page == 2);
    };
    final notifier = CategoryPlaylistsNotifier(DiscoverRepository(manager));
    addTearDown(notifier.dispose);
    await notifier.fetchPlaylists(sortId: 'hot', tagId: '', reset: true);
    await notifier.fetchPlaylists(sortId: 'hot', tagId: '');
    expect(notifier.state.valueOrNull!.length, 1);
    expect(notifier.total, 2);
    expect(notifier.noMore, isFalse);
    expect(notifier.loadMoreError, 'offline');
    fail = false;
    await notifier.fetchPlaylists(sortId: 'hot', tagId: '');
    expect(notifier.state.valueOrNull!.length, 2);
    expect(notifier.noMore, isTrue);
    expect(notifier.loadMoreError, isNull);
  });

  test('已知总数跳到第40页可以继续补齐超过旧20页上限', () async {
    final manager = _Manager();
    manager.songPage = (_, page) async =>
        PageResult(items: [_song(page)], total: 40, isEnd: page == 40);
    final notifier = SearchResultsNotifier(manager);
    addTearDown(notifier.dispose);
    await notifier.start('song', 'wy');
    final pager = PageSlicer(pageSize: 1)..jumpTo(40);
    while (pager.missing(
          notifier.state.songs.length,
          hasMore: notifier.state.hasMore,
        ) >
        0) {
      await notifier.loadMore();
    }
    pager.clampTo(
      notifier.state.songs.length,
      hasMore: notifier.state.hasMore,
      total: notifier.state.total,
    );
    expect(pager.page, 40);
    expect(pager.slice(notifier.state.songs).single.id, '40');
  });
}
