import '../../../player/domain/models/song.dart';

/// 歌曲的播放来源：决定播放页 / 列表上的「歌单 / 专辑 / 榜单 / 搜索 / 作者 / 本地」
/// 标签，以及「回到原处」的目标。
///
/// 注意：**最近播放不再记录来源**，这个枚举只描述「当前正在播放的上下文」
/// （见 `PlaybackContext`），不参与最近播放的落库。
enum PlaybackSourceType {
  /// 未知来源（例如直接从播放队列开始播放）。
  unknown,

  /// 从歌单里播放（含本地歌单、「我的收藏」）。
  playlist,

  /// 从专辑里播放。
  album,

  /// 从排行榜里播放。
  rank,

  /// 从搜索结果里播放。
  search,

  /// 从作者作品里播放。
  artist,

  /// 本地音乐。
  local,

  /// 电台（随机电台 / 自定义电台）。
  radio,
}

extension PlaybackSourceTypeX on PlaybackSourceType {
  /// 数据库 / JSON 里存的值。
  String get id => switch (this) {
    PlaybackSourceType.playlist => 'playlist',
    PlaybackSourceType.album => 'album',
    PlaybackSourceType.rank => 'rank',
    PlaybackSourceType.search => 'search',
    PlaybackSourceType.artist => 'artist',
    PlaybackSourceType.local => 'local',
    PlaybackSourceType.radio => 'radio',
    PlaybackSourceType.unknown => 'unknown',
  };

  /// 列表上显示的标签文字（未知来源不显示）。
  String get label => switch (this) {
    PlaybackSourceType.playlist => '歌单',
    PlaybackSourceType.album => '专辑',
    PlaybackSourceType.rank => '榜单',
    PlaybackSourceType.search => '搜索',
    PlaybackSourceType.artist => '作者',
    PlaybackSourceType.local => '本地',
    PlaybackSourceType.radio => '电台',
    PlaybackSourceType.unknown => '',
  };

  static PlaybackSourceType fromId(String? raw) => switch (raw) {
    'playlist' => PlaybackSourceType.playlist,
    'album' => PlaybackSourceType.album,
    'rank' => PlaybackSourceType.rank,
    'search' => PlaybackSourceType.search,
    'artist' => PlaybackSourceType.artist,
    'local' => PlaybackSourceType.local,
    'radio' => PlaybackSourceType.radio,
    _ => PlaybackSourceType.unknown,
  };
}

/// 一条最近播放记录。
///
/// 同一首歌只保留一条：再播一次就刷新播放时间并挪到最前面。
/// 只存歌曲本身与时间——来源（歌单 / 专辑 / 榜单 …）不再保存，旧记录里
/// 多出来的字段在 [fromJson] 里会被忽略。
class RecentlyPlayedItem {
  const RecentlyPlayedItem({required this.song, required this.playedAt});

  final Song song;

  /// 最近一次播放时间。
  final DateTime playedAt;

  /// 落库用的瘦身版（歌曲不带整段歌词 / 请求头，见 [Song.toPersistJson]）。
  Map<String, dynamic> toPersistJson() {
    return {
      'song': song.toPersistJson(),
      'playedAt': playedAt.toIso8601String(),
    };
  }

  factory RecentlyPlayedItem.fromJson(Map<String, dynamic> json) {
    return RecentlyPlayedItem(
      song: Song.fromJson(json['song'] as Map<String, dynamic>),
      playedAt:
          DateTime.tryParse('${json['playedAt'] ?? ''}') ?? DateTime.now(),
    );
  }
}
