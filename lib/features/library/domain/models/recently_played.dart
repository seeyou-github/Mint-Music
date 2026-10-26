import '../../../player/domain/models/song.dart';

/// 歌曲的播放来源：决定网格上的「歌单 / 专辑 / 榜单 / 搜索 / 作者 / 本地」标签。
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

  /// 网格上显示的标签文字（未知来源不显示）。
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

/// 一条最近播放记录（同一首歌只保留一条，重复播放累加次数）。
class RecentlyPlayedItem {
  const RecentlyPlayedItem({
    required this.song,
    required this.playedAt,
    this.playCount = 1,
    this.sourceType = PlaybackSourceType.unknown,
    this.sourceId,
    this.sourceName,
    this.sourceMeta,
    this.listenedMs = 0,
  });

  final Song song;

  /// 最近一次播放时间。
  final DateTime playedAt;

  /// 累计播放次数。
  final int playCount;

  /// 这首歌是从哪里点开播放的。
  final PlaybackSourceType sourceType;

  /// 来源 id（歌单 id / 专辑 id / 榜单 id）。
  final String? sourceId;

  /// 来源名称（歌单名 / 专辑名），用于展示与打开。
  final String? sourceName;

  /// 来源的完整信息（作者 / 专辑主页的 json），没有记录时为空。
  final Map<String, dynamic>? sourceMeta;

  /// 累计收听时长（毫秒）。
  final int listenedMs;

  /// 是否能在网格上显示来源标签（搜索 / 未知不显示可点击的来源）。
  bool get hasSourceLabel =>
      sourceType != PlaybackSourceType.unknown && sourceType.label.isNotEmpty;

  RecentlyPlayedItem copyWith({
    Song? song,
    DateTime? playedAt,
    int? playCount,
    PlaybackSourceType? sourceType,
    String? sourceId,
    String? sourceName,
    Map<String, dynamic>? sourceMeta,
    bool clearSourceMeta = false,
    int? listenedMs,
  }) {
    return RecentlyPlayedItem(
      song: song ?? this.song,
      playedAt: playedAt ?? this.playedAt,
      playCount: playCount ?? this.playCount,
      sourceType: sourceType ?? this.sourceType,
      sourceId: sourceId ?? this.sourceId,
      sourceName: sourceName ?? this.sourceName,
      sourceMeta: clearSourceMeta ? null : sourceMeta ?? this.sourceMeta,
      listenedMs: listenedMs ?? this.listenedMs,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'song': song.toJson(),
      'playedAt': playedAt.toIso8601String(),
      'playCount': playCount,
      'sourceType': sourceType.id,
      'sourceId': sourceId,
      'sourceName': sourceName,
      'sourceMeta': sourceMeta,
      'listenedMs': listenedMs,
    };
  }

  /// 落库用的瘦身版（歌曲不带整段歌词 / 请求头，见 [Song.toPersistJson]）。
  Map<String, dynamic> toPersistJson() {
    return {
      'song': song.toPersistJson(),
      'playedAt': playedAt.toIso8601String(),
      'playCount': playCount,
      'sourceType': sourceType.id,
      'sourceId': sourceId,
      'sourceName': sourceName,
      'sourceMeta': sourceMeta,
      'listenedMs': listenedMs,
    };
  }

  factory RecentlyPlayedItem.fromJson(Map<String, dynamic> json) {
    return RecentlyPlayedItem(
      song: Song.fromJson(json['song'] as Map<String, dynamic>),
      playedAt: DateTime.tryParse('${json['playedAt'] ?? ''}') ??
          DateTime.now(),
      playCount: (json['playCount'] as num?)?.toInt() ?? 1,
      sourceType: PlaybackSourceTypeX.fromId(json['sourceType'] as String?),
      sourceId: json['sourceId'] as String?,
      sourceName: json['sourceName'] as String?,
      sourceMeta: json['sourceMeta'] is Map
          ? (json['sourceMeta'] as Map).map(
              (key, value) => MapEntry('$key', value),
            )
          : null,
      listenedMs: (json['listenedMs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 打开过的歌单（最近播放页「歌单」分类）。
class RecentlyPlayedPlaylist {
  const RecentlyPlayedPlaylist({
    required this.id,
    required this.name,
    required this.openedAt,
    this.coverUrl = '',
    this.songCount = 0,
    this.source = '',
    this.collectionType,
  });

  final String id;
  final String name;
  final DateTime openedAt;
  final String coverUrl;
  final int songCount;

  /// 所属平台 / 音源 id（用于重新拉取歌单详情）。
  final String source;

  /// 收藏的专辑 / 作者歌单的类型；普通歌单为空。
  final PlaybackSourceType? collectionType;

  /// 去掉「专辑：」「作者：」前缀后的展示名称。
  String get displayName {
    for (final prefix in const ['专辑：', '作者：']) {
      if (name.startsWith(prefix)) {
        final rest = name.substring(prefix.length);
        if (rest.isNotEmpty) return rest;
      }
    }
    return name;
  }

  /// 专辑 / 作者标签类型（新记录直接读字段，旧记录按名称前缀识别）。
  PlaybackSourceType? get favoriteType {
    final type = collectionType;
    if (type == PlaybackSourceType.album || type == PlaybackSourceType.artist) {
      return type;
    }
    if (name.startsWith('专辑：')) return PlaybackSourceType.album;
    if (name.startsWith('作者：')) return PlaybackSourceType.artist;
    return null;
  }

  RecentlyPlayedPlaylist copyWith({
    String? name,
    DateTime? openedAt,
    String? coverUrl,
    int? songCount,
    String? source,
    PlaybackSourceType? collectionType,
  }) {
    return RecentlyPlayedPlaylist(
      id: id,
      name: name ?? this.name,
      openedAt: openedAt ?? this.openedAt,
      coverUrl: coverUrl ?? this.coverUrl,
      songCount: songCount ?? this.songCount,
      source: source ?? this.source,
      collectionType: collectionType ?? this.collectionType,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'coverUrl': coverUrl,
    'songCount': songCount,
    'source': source,
    'collectionType': collectionType?.id,
  };

  factory RecentlyPlayedPlaylist.fromJson(Map<String, dynamic> json) {
    final type = PlaybackSourceTypeX.fromId(
      json['collectionType'] as String?,
    );
    return RecentlyPlayedPlaylist(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      openedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['openedAt'] as num?)?.toInt() ?? 0,
      ),
      coverUrl: '${json['coverUrl'] ?? ''}',
      songCount: (json['songCount'] as num?)?.toInt() ?? 0,
      source: '${json['source'] ?? ''}',
      collectionType:
          type == PlaybackSourceType.unknown ? null : type,
    );
  }
}

/// 听歌统计（「统计」分类用）。
class PlaybackStats {
  const PlaybackStats({
    this.totalListenedMs = 0,
    this.totalPlays = 0,
    this.songCount = 0,
    this.buckets = const [],
  });

  /// 累计听歌时长。
  final int totalListenedMs;

  /// 累计播放次数。
  final int totalPlays;

  /// 听过的不同歌曲数。
  final int songCount;

  /// 按当前粒度聚合的柱状数据（按时间正序）。
  final List<PlaybackStatBucket> buckets;
}

/// 统计图上的一个柱。
class PlaybackStatBucket {
  const PlaybackStatBucket({
    required this.label,
    required this.listenedMs,
    required this.plays,
  });

  /// 横轴标签（如 `10-23` / `第43周` / `10月` / `2026`）。
  final String label;
  final int listenedMs;
  final int plays;
}

/// 统计粒度。
enum PlaybackStatsGranularity { day, week, month, year }

extension PlaybackStatsGranularityX on PlaybackStatsGranularity {
  String get label => switch (this) {
    PlaybackStatsGranularity.day => '天',
    PlaybackStatsGranularity.week => '周',
    PlaybackStatsGranularity.month => '月',
    PlaybackStatsGranularity.year => '年',
  };
}
