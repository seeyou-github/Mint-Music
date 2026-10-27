import 'playlist.dart';

/// 歌单 / 榜单详情的一「页」数据。
///
/// [isEnd] 表示当前音源是否已经没有更多数据：
/// - 插件结果是否到底由插件回传的 `isEnd` 决定；
/// - MusicFree 插件按 `getMusicSheetInfo(sheetItem, page)` /
///   `getTopListDetail(item, page)` 回传的 `isEnd` 字段决定。
class PlaylistPage {
  final Playlist? playlist;
  final bool isEnd;
  final int? total;

  const PlaylistPage({this.playlist, this.isEnd = true, this.total});
}
