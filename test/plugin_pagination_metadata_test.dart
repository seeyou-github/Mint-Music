import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/discover/data/discover_repository.dart';
import 'package:mintmusic/features/discover/domain/models/playlist_page.dart';
import 'package:mintmusic/features/discover/domain/models/search_collection.dart';
import 'package:mintmusic/features/plugin/application/music_source_manager.dart';
import 'package:mintmusic/features/plugin/data/plugin_host.dart';
import 'package:mintmusic/features/plugin/data/plugin_service.dart';
import 'package:mintmusic/features/plugin/domain/plugin_types.dart';
import 'package:mintmusic/shared/pagination/page_result.dart';

class _PluginService implements PluginService {
  _PluginService(this.hosts);

  final List<_Host> hosts;

  @override
  List<PluginHost> get enabledPlugins => hosts;

  @override
  String? getPluginIdForHost(PluginHost host) => (host as _Host).id;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Host implements PluginHost {
  _Host([this.id = 'test']);

  final String id;
  final replies = <String, Object? Function(int)>{};
  final calls = <(String, int)>[];

  Future<String?> _reply(String method, int page) async {
    calls.add((method, page));
    final result = replies[method]?.call(page);
    if (result == null || result is String) return result as String?;
    return jsonEncode(result);
  }

  @override
  List<PluginSourceInfo> get sources => const [];

  @override
  Map<String, List<String>> get sourceActions => const {
    'wy': ['musicSearch'],
  };

  @override
  bool supportsSearch(String sourceId) => true;

  @override
  bool get supportsPlaylistSearch => true;

  @override
  bool get supportsAlbumSearch => true;

  @override
  bool get supportsArtistSearch => true;

  @override
  bool get supportsDiscover => true;

  @override
  bool get supportsRecommendSheets => true;

  @override
  bool get supportsSheetDetail => true;

  @override
  bool get supportsTopLists => true;

  @override
  Future<String?> search(
    String source,
    String keyword, {
    int page = 1,
    int limit = 30,
  }) => _reply('search', page);

  @override
  Future<String?> searchWithHandler(
    String source,
    String keyword, {
    int page = 1,
    int limit = 30,
  }) => _reply('handler', page);

  @override
  Future<String?> searchPlaylists(String query, {int page = 1}) =>
      _reply('playlists', page);

  @override
  Future<String?> getRecommendSheetsByTag(String tagId, {int page = 1}) =>
      _reply('category', page);

  @override
  Future<String?> getMusicSheetInfo(String sheetId, {int page = 1}) =>
      _reply('sheet', page);

  @override
  Future<String?> getTopListDetail(String id, {int page = 1}) =>
      _reply('board', page);

  @override
  Future<String?> searchTyped(
    String source,
    String keyword, {
    required String type,
    int page = 1,
    int limit = 30,
  }) => _reply('typed', page);

  @override
  Future<String?> getAlbumInfo(
    String source,
    Map<String, dynamic> albumItem, {
    int page = 1,
  }) => _reply('album', page);

  @override
  Future<String?> getArtistWorks(
    String source,
    Map<String, dynamic> artistItem, {
    int page = 1,
    String type = 'music',
  }) => _reply('artist', page);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<Map<String, Object>> _items(int start, int count) => List.generate(
  count,
  (i) => {'id': '${start + i}', 'title': 'item ${start + i}'},
);

void main() {
  late _Host host;
  late MusicSourceManager manager;

  setUp(() {
    host = _Host();
    manager = MusicSourceManager(_PluginService([host]));
  });

  test('page models distinguish unknown totals from zero', () {
    expect(const PageResult<int>().total, isNull);
    expect(const PageResult<int>().isEnd, isNull);
    expect(const PageResult<int>(total: 0).total, 0);
    expect(const PlaylistPage().total, isNull);
    expect(const CollectionSearchPage().total, isNull);
  });

  test(
    'song search caches metadata and List wrapper makes no extra request',
    () async {
      host.replies['search'] = (_) => {
        'list': _items(0, 2),
        'total': 100,
        'isEnd': false,
      };
      final first = await manager.searchPage('song');
      final cached = await manager.searchPage('song');
      final songs = await manager.search('song');
      expect(first.total, 100);
      expect(first.isEnd, isFalse);
      expect(identical(first, cached), isTrue);
      expect(identical(first.items, songs), isTrue);
      expect(host.calls, [('search', 1)]);
    },
  );

  for (final metadata in [
    {'total': 0},
    {'total': null, 'isEnd': true},
  ]) {
    test(
      'explicit empty song page is cached without fallback: $metadata',
      () async {
        host.replies['search'] = (_) => {'list': [], ...metadata};
        final first = await manager.searchPage('empty', page: 2);
        final cached = await manager.searchPage('empty', page: 2);
        expect(first.items, isEmpty);
        expect(first.total, metadata['total']);
        expect(identical(first, cached), isTrue);
        expect(host.calls, [('search', 2)]);
      },
    );
  }

  for (final total in [null, -1, 1.5, '2']) {
    test('invalid or unknown song total stays null: $total', () async {
      host.replies['search'] = (_) => {'list': _items(0, 1), 'total': total};
      final page = await manager.searchPage('legacy');
      expect(page.total, isNull);
      expect(page.isEnd, isNull);
    });
  }

  test(
    'song error body cannot masquerade as a successful empty page',
    () async {
      host.replies['search'] = (_) => {
        'list': [],
        'total': 0,
        'isEnd': true,
        'error': 'offline',
      };
      host.replies['handler'] = (_) => {
        'list': [],
        'total': 0,
        'isEnd': true,
        'error': 'offline handler',
      };
      await expectLater(manager.searchPage('retry'), throwsException);
      host.replies['search'] = (_) => {
        'list': _items(0, 1),
        'total': 1,
        'isEnd': true,
      };
      expect((await manager.searchPage('retry')).total, 1);
      expect(host.calls, [('search', 1), ('handler', 1), ('search', 1)]);
    },
  );

  test('song handler fallback preserves its total', () async {
    host.replies['search'] = (_) => {
      'error': 'failed',
      'total': 0,
      'isEnd': true,
    };
    host.replies['handler'] = (_) => {
      'list': _items(0, 1),
      'total': 7,
      'isEnd': false,
    };
    final page = await manager.searchPage('fallback');
    expect(page.total, 7);
    expect(page.isEnd, isFalse);
  });

  test(
    'buffered playlists expose total without ending before cached slices',
    () async {
      host.replies['playlists'] = (_) => {
        'playlists': _items(0, 65),
        'total': 65,
        'isEnd': true,
      };
      final first = await manager.searchPlaylistsPage(
        'sheet',
        sourceId: 'wy@test',
      );
      final second = await manager.searchPlaylistsPage(
        'sheet',
        sourceId: 'wy@test',
        page: 2,
      );
      final third = await manager.searchPlaylistsPage(
        'sheet',
        sourceId: 'wy@test',
        page: 3,
      );
      expect(
        [first.items.length, second.items.length, third.items.length],
        [30, 30, 5],
      );
      expect([first.total, second.total, third.total], [65, 65, 65]);
      expect([first.isEnd, second.isEnd, third.isEnd], [false, false, true]);
      expect(
        (await manager.searchPlaylists('sheet', sourceId: 'wy@test')).length,
        30,
      );
      expect(host.calls, [('playlists', 1)]);
    },
  );

  test('small plugin pages fill UI slices and retain known total', () async {
    host.replies['playlists'] = (page) => {
      'playlists': _items((page - 1) * 20, page == 3 ? 5 : 20),
      if (page == 1) 'total': 45,
      'isEnd': page == 3,
    };
    final first = await manager.searchPlaylistsPage(
      'sheet',
      sourceId: 'wy@test',
    );
    final second = await manager.searchPlaylistsPage(
      'sheet',
      sourceId: 'wy@test',
      page: 2,
    );
    expect(first.items.length, 30);
    expect(first.isEnd, isFalse);
    expect(second.items.length, 15);
    expect(second.total, 45);
    expect(second.isEnd, isTrue);
    expect(host.calls, [('playlists', 1), ('playlists', 2), ('playlists', 3)]);
  });

  test(
    'playlist failure does not advance plugin page or mark cache ended',
    () async {
      var failing = true;
      host.replies['playlists'] = (page) {
        if (page == 2 && failing)
          return {'error': 'offline', 'playlists': [], 'isEnd': true};
        return {
          'playlists': _items((page - 1) * 20, 20),
          'total': 40,
          'isEnd': page == 2,
        };
      };
      await expectLater(
        manager.searchPlaylistsPage('retry', sourceId: 'wy@test'),
        throwsException,
      );
      failing = false;
      final result = await manager.searchPlaylistsPage(
        'retry',
        sourceId: 'wy@test',
      );
      expect(result.items.length, 30);
      expect(result.total, 40);
      expect(result.isEnd, isFalse);
      expect(host.calls, [
        ('playlists', 1),
        ('playlists', 2),
        ('playlists', 2),
      ]);
    },
  );

  test('multiple playlist hosts do not publish one hosts total', () async {
    final other = _Host('other');
    for (final h in [host, other]) {
      h.replies['playlists'] = (_) => {
        'playlists': _items(0, 1),
        'total': 1,
        'isEnd': true,
      };
    }
    manager = MusicSourceManager(_PluginService([host, other]));
    final result = await manager.searchPlaylistsPage('merged', sourceId: 'wy');
    expect(result.items.length, 2);
    expect(result.total, isNull);
  });

  test('playlist cache is reset together with search caches', () async {
    host.replies['playlists'] = (_) => {
      'playlists': [],
      'total': 0,
      'isEnd': true,
    };
    expect(
      (await manager.searchPlaylistsPage('reset', sourceId: 'wy@test')).total,
      0,
    );
    manager.clearSearchCache();
    host.replies['playlists'] = (_) => {
      'playlists': _items(0, 1),
      'isEnd': true,
    };
    expect(
      (await manager.searchPlaylistsPage('reset', sourceId: 'wy@test')).total,
      isNull,
    );
    expect(host.calls.length, 2);
  });

  test(
    'category repository preserves oversized pages, zero and errors',
    () async {
      final repository = DiscoverRepository(manager);
      Future<PageResult<dynamic>> load() => repository.getCategoryPlaylists(
        sortId: '',
        tagId: '',
        page: 1,
        limit: 30,
        sourceId: 'wy@test',
      );
      host.replies['category'] = (_) => {
        'playlists': _items(0, 50),
        'total': 80,
        'isEnd': false,
      };
      final result = await load();
      expect(result.items.length, 50);
      expect(result.total, 80);
      expect(result.isEnd, isFalse);
      host.replies['category'] = (_) => {
        'playlists': [],
        'total': 0,
        'isEnd': true,
      };
      expect((await load()).total, 0);
      host.replies['category'] = (_) => {
        'error': 'offline',
        'playlists': [],
        'isEnd': true,
      };
      await expectLater(load(), throwsException);
      host.replies['category'] = (_) => null;
      await expectLater(load(), throwsFormatException);
    },
  );

  test(
    'sheet and board metadata prefer songCount, then total, never page length',
    () async {
      for (final isBoard in [false, true]) {
        final method = isBoard ? 'board' : 'sheet';
        final id = isBoard
            ? MusicSourceManager.pluginBoardId('wy@test', '1')
            : MusicSourceManager.pluginSheetId('wy@test', '1');
        host.replies[method] = (_) => {
          'songs': _items(0, 2),
          'total': 100,
          'isEnd': false,
          'sheet': {'title': 'sheet', 'songCount': 120},
        };
        final first = await manager.getPlaylistDetailPage(id);
        expect(first.total, 100);
        expect(first.playlist!.songCount, 120);
        expect(first.isEnd, isFalse);
        host.replies[method] = (_) => {
          'songs': _items(0, 2),
          'total': 100,
          'isEnd': true,
        };
        expect(
          (await manager.getPlaylistDetailPage(id)).playlist!.songCount,
          100,
        );
        host.replies[method] = (_) => {'songs': _items(0, 2), 'isEnd': true};
        final unknown = await manager.getPlaylistDetailPage(id);
        expect(unknown.total, isNull);
        expect(unknown.playlist!.songCount, 0);
      }
    },
  );

  test(
    'collection search and detail use explicit total, not worksNum',
    () async {
      host.replies['typed'] = (_) => {
        'list': _items(0, 1),
        'total': 21,
        'isEnd': false,
      };
      final search = await manager.searchCollections(
        'artist',
        sourceId: 'wy@test',
        type: CollectionType.artist,
      );
      expect(search.total, 21);
      expect(search.isEnd, isFalse);
      for (final type in CollectionType.values) {
        final item = SearchCollection(
          id: '1',
          title: 'collection',
          type: type,
          source: 'wy@test',
          worksNum: 999,
        );
        host.replies[type.id] = (_) => {
          'list': _items(0, 2),
          'total': 80,
          'isEnd': false,
        };
        final detail = await manager.getCollectionDetail(item, page: 2);
        expect(detail.total, 80);
        expect(detail.isEnd, isFalse);
        host.replies[type.id] = (_) => {'list': _items(0, 2), 'isEnd': true};
        expect((await manager.getCollectionDetail(item)).total, isNull);
        host.replies[type.id] = (_) => {'list': [], 'total': 0, 'isEnd': true};
        expect((await manager.getCollectionDetail(item)).total, 0);
      }
      host.replies['typed'] = (_) => {'list': [], 'total': 0, 'isEnd': true};
      expect(
        (await manager.searchCollections(
          'none',
          sourceId: 'wy@test',
          type: CollectionType.album,
        )).total,
        0,
      );
    },
  );
}
