import 'playlist.dart';

/// 歌单 / 榜单详情的一「页」数据。
///
/// [isEnd] 表示当前音源是否已经没有更多数据：
/// - 内置音源一次性返回全量歌曲，恒为 `true`（不参与翻页）；
/// - MusicFree 插件按 `getMusicSheetInfo(sheetItem, page)` /
///   `getTopListDetail(item, page)` 回传的 `isEnd` 字段决定。
class PlaylistPage {
  final Playlist? playlist;
  final bool isEnd;

  const PlaylistPage({this.playlist, this.isEnd = true});
}
