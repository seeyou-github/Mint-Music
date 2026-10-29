import '../../../shared/pagination/page_result.dart';
import '../domain/models/playlist.dart';
import '../domain/models/playlist_page.dart';
import '../domain/models/leaderboard.dart';
import '../../custom_sheet/application/custom_sheet_providers.dart';
import '../../player/domain/models/song.dart';
import '../../plugin/application/music_source_manager.dart';

class DiscoverRepository {
  final MusicSourceManager _manager;

  /// 读取 App 侧维护的自定义歌单（由 provider 注入，仓库自己不依赖 Riverpod）。
  final List<CustomSheet> Function() _customSheets;

  DiscoverRepository(
    this._manager, {
    List<CustomSheet> Function()? customSheets,
  }) : _customSheets = customSheets ?? (() => const <CustomSheet>[]);

  Future<List<Playlist>> getHotPlaylists({String sourceId = 'wy'}) async {
    return _manager.getHotPlaylists(sourceId: sourceId);
  }

  Future<List<PlaylistTagGroup>> getPlaylistTags({
    String sourceId = 'wy',
  }) async {
    return _manager.getPlaylistTags(sourceId: sourceId);
  }

  Future<List<PlaylistTag>> getHotPlaylistTags({String sourceId = 'wy'}) async {
    return _manager.getHotPlaylistTags(sourceId: sourceId);
  }

  Future<PageResult<Playlist>> getCategoryPlaylists({
    required String sortId,
    required String tagId,
    required int page,
    required int limit,
    String sourceId = 'wy',
  }) async {
    return _manager.getCategoryPlaylists(
      sortId: sortId,
      tagId: tagId,
      page: page,
      limit: limit,
      sourceId: sourceId,
    );
  }

  Future<List<Leaderboard>> getLeaderboards({String sourceId = 'wy'}) async {
    return _manager.getLeaderboards(sourceId: sourceId);
  }

  Future<Playlist?> getLeaderboardDetail(
    String boardId, {
    int page = 1,
    String sourceId = 'wy',
  }) async {
    return _manager.getLeaderboardDetail(
      boardId,
      page: page,
      sourceId: sourceId,
    );
  }

  Future<List<Song>> search(String query) async {
    if (query.isEmpty) return [];
    return _manager.search(query);
  }

  Future<List<String>> getHotSearchTags() async {
    return _manager.getHotSearchTags();
  }

  Future<List<String>> getSearchSuggestions(String query) async {
    return _manager.getSearchSuggestions(query);
  }

  Future<Playlist?> getPlaylistDetail(String playlistId) async {
    if (CustomSheet.isCustomPlaylistId(playlistId)) {
      final page = await _customSheetPage(playlistId, 1);
      return page.playlist;
    }
    return _manager.getPlaylistDetail(playlistId);
  }

  /// 歌单 / 榜单详情分页（插件源支持翻页）。
  Future<PlaylistPage> getPlaylistDetailPage(
    String playlistId, {
    int page = 1,
  }) async {
    if (CustomSheet.isCustomPlaylistId(playlistId)) {
      return _customSheetPage(playlistId, page);
    }
    return _manager.getPlaylistDetailPage(playlistId, page: page);
  }

  /// 自定义歌单的一页：用歌单绑定的音源按关键字搜索，搜索结果就是歌单内容。
  Future<PlaylistPage> _customSheetPage(String playlistId, int page) async {
    final sheetId = CustomSheet.idOf(playlistId);
    CustomSheet? sheet;
    for (final item in _customSheets()) {
      if (item.id == sheetId) {
        sheet = item;
        break;
      }
    }
    if (sheet == null) return const PlaylistPage();

    final currentPage = page < 1 ? 1 : page;
    const limit = 100;
    PageResult<Song> result;
    try {
      result = await _manager.searchPage(
        sheet.keyword,
        sourceId: sheet.sourceId,
        page: currentPage,
        limit: limit,
      );
    } catch (e) {
      // 搜索失败只影响当前页：第一页失败时让界面显示空歌单 + 错误，
      // 后面的页由详情页自己弹「加载失败」。
      if (currentPage > 1) rethrow;
      result = const PageResult();
      print('[DiscoverRepository] 自定义歌单搜索失败（${sheet.keyword}）: $e');
    }

    final playlist = Playlist(
      id: playlistId,
      title: sheet.name,
      description: '「${sheet.keyword}」的搜索结果',
      coverUrl: sheet.displayCover,
      songCount: result.total ?? result.items.length,
      songs: result.items,
      source: sheet.sourceId,
    );
    return PlaylistPage(
      playlist: playlist,
      isEnd: result.isEnd ?? false,
      total: result.total,
    );
  }
}
