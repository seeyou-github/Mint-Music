import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/discover/domain/models/playlist.dart';
import 'package:mintmusic/features/discover/domain/models/playlist_page.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';
import 'package:mintmusic/features/plugin/application/music_source_manager.dart';
import 'package:mintmusic/features/plugin/data/plugin_service.dart';
import 'package:mintmusic/features/plugin/domain/plugin_types.dart';
import 'package:mintmusic/features/radio/application/radio_engine.dart';
import 'package:mintmusic/features/radio/domain/models/radio_station.dart';
import 'package:mintmusic/shared/pagination/page_result.dart';

class _NoopPluginService implements PluginService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeManager extends MusicSourceManager {
  _FakeManager(this.playlists) : super(_NoopPluginService());

  final List<Playlist> playlists;

  /// 每次取歌单页都会记录页码，便于断言「一轮只翻一页」。
  final List<int> pageRequests = [];

  /// 每个歌单被取详情的顺序。
  final List<String> detailRequests = [];

  @override
  List<SourceInfo> getDiscoverSupportedSources() =>
      const [SourceInfo(id: 'wy', name: '网易云音乐')];

  @override
  Future<PageResult<Playlist>> getCategoryPlaylists({
    required String sortId,
    required String tagId,
    required int page,
    required int limit,
    String sourceId = 'wy',
  }) async {
    pageRequests.add(page);
    return PageResult(items: playlists, isEnd: false);
  }

  @override
  Future<List<Playlist>> searchPlaylists(
    String query, {
    required String sourceId,
    int page = 1,
    int limit = 30,
  }) async {
    pageRequests.add(page);
    return playlists;
  }

  @override
  Future<PlaylistPage> getPlaylistDetailPage(
    String playlistId, {
    int page = 1,
    String sourceId = 'wy',
  }) async {
    detailRequests.add(playlistId);
    final playlist = playlists.firstWhere((item) => item.id == playlistId);
    return PlaylistPage(playlist: playlist, isEnd: true);
  }
}

Playlist _playlist(int index, {int songCount = 5}) {
  return Playlist(
    id: 'pl$index',
    title: '歌单 $index',
    description: '',
    songCount: songCount,
    source: 'wy',
    songs: [
      for (var i = 0; i < songCount; i++)
        Song(
          id: 'pl$index-song$i',
          title: '歌曲 $index-$i',
          artist: '歌手',
          album: '专辑',
          duration: 180,
          source: 'wy',
        ),
    ],
  );
}

const _tag = RadioTagRef(sourceId: 'wy', tagId: '1001', tagName: '华语');

void main() {
  group('电台起播', () {
    test('只取一个歌单的 3 首，只请求一个歌单详情', () async {
      final manager = _FakeManager([for (var i = 0; i < 20; i++) _playlist(i)]);
      final engine = RadioEngine(manager: manager, isBlocked: (_) => false);

      final batch = await engine.firstBatch(
        sourceIds: const ['wy'],
        tags: const [_tag],
        keywords: const [],
        count: 3,
      );

      expect(batch.songs.length, 3);
      // 3 首都来自同一个歌单，且只拉了一次详情。
      expect(manager.detailRequests.length, 1);
      expect(
        batch.songPlaylists.values.map((ref) => ref.id).toSet(),
        {manager.detailRequests.single},
      );
    });
  });

  group('电台补歌', () {
    test('只翻一页，按歌单顺序每个取 3 首，最多 30 首', () async {
      final manager = _FakeManager([for (var i = 0; i < 20; i++) _playlist(i)]);
      final engine = RadioEngine(manager: manager, isBlocked: (_) => false);

      final batch = await engine.nextBatch(
        sourceIds: const ['wy'],
        tags: const [_tag],
        keywords: const [],
        maxCount: 30,
        songsPerPlaylist: 3,
      );

      expect(batch.songs.length, 30);
      // 一轮只随机一页歌单。
      expect(manager.pageRequests.length, 1);
      // 按返回顺序取前 10 个歌单，每个歌单恰好 3 首，且按歌单顺序排列。
      expect(manager.detailRequests, [for (var i = 0; i < 10; i++) 'pl$i']);
      for (var i = 0; i < 10; i++) {
        final ids = batch.songs.skip(i * 3).take(3).map((song) => song.id);
        expect(ids.every((id) => id.startsWith('pl$i-')), isTrue);
      }
    });

    test('跳过本次电台用过的歌单', () async {
      final manager = _FakeManager([for (var i = 0; i < 20; i++) _playlist(i)]);
      final engine = RadioEngine(manager: manager, isBlocked: (_) => false);

      final batch = await engine.nextBatch(
        sourceIds: const ['wy'],
        tags: const [_tag],
        keywords: const [],
        maxCount: 30,
        songsPerPlaylist: 3,
        excludePlaylistIds: const {'pl0', 'pl1'},
      );

      expect(batch.songs.length, 30);
      expect(manager.detailRequests.contains('pl0'), isFalse);
      expect(manager.detailRequests.contains('pl1'), isFalse);
      expect(manager.detailRequests.first, 'pl2');
    });

    test('关键词来源同样按歌单顺序、每单 3 首、最多 30 首', () async {
      final manager = _FakeManager([for (var i = 0; i < 20; i++) _playlist(i)]);
      final engine = RadioEngine(manager: manager, isBlocked: (_) => false);

      final batch = await engine.nextBatch(
        sourceIds: const ['wy'],
        tags: const [],
        keywords: const ['情歌'],
        maxCount: 30,
        songsPerPlaylist: 3,
      );

      expect(batch.songs.length, 30);
      expect(manager.pageRequests.length, 1);
      expect(manager.detailRequests, [for (var i = 0; i < 10; i++) 'pl$i']);
    });
  });
}
