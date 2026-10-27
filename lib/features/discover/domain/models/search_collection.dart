import '../../../player/domain/models/song.dart';

/// 专辑 / 作者。
enum CollectionType { album, artist }

extension CollectionTypeX on CollectionType {
  String get id => this == CollectionType.album ? 'album' : 'artist';

  /// 收藏到「收藏」页面时的名称前缀。
  String get label => this == CollectionType.album ? '专辑' : '作者';

  static CollectionType fromId(String? raw) =>
      raw == 'artist' ? CollectionType.artist : CollectionType.album;
}

/// 搜索结果里的一个专辑 / 作者。
class SearchCollection {
  const SearchCollection({
    required this.id,
    required this.title,
    required this.type,
    required this.source,
    this.coverUrl,
    this.artist,
    this.worksNum = 0,
    this.date,
    this.description,
    this.raw = const {},
  });

  final String id;
  final String title;
  final CollectionType type;

  /// 提供这条数据的音源 id（`平台id@插件id`）。
  final String source;

  /// 专辑封面 / 作者头像。
  final String? coverUrl;

  /// 专辑歌手（作者为空）。
  final String? artist;

  /// 作品数量（专辑曲目数 / 作者作品数）。
  final int worksNum;

  /// 专辑发行日期（可能为空）。
  final String? date;

  final String? description;

  /// 插件返回的原始 item，打开详情时要原样传回去。
  final Map<String, dynamic> raw;

  /// 收藏时的名称：「专辑：xxx」/「作者：xxx」。
  String get favoriteName => '${type.label}：$title';

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'type': type.id,
    'source': source,
    'coverUrl': coverUrl,
    'artist': artist,
    'worksNum': worksNum,
    'date': date,
    'description': description,
    'raw': raw,
  };

  factory SearchCollection.fromJson(
    Map<String, dynamic> json, {
    String? source,
    CollectionType? type,
  }) {
    final raw = json['raw'] is Map
        ? (json['raw'] as Map).map((k, v) => MapEntry('$k', v))
        : <String, dynamic>{};
    // 各音源的封 / 头像字段不统一：
    //   平台直出：coverUrl / picUrl
    //   MusicFree 专辑：artwork
    //   MusicFree 作者：avatar（以前没读，导致作者头像一直加载不出来）
    final cover = _firstString([
      json['coverUrl'],
      json['artwork'],
      json['avatar'],
      json['picUrl'],
      json['cover'],
      json['face'],
    ]);
    return SearchCollection(
      id: '${json['id'] ?? ''}',
      title: '${json['title'] ?? json['name'] ?? ''}',
      type: type ?? CollectionTypeX.fromId(json['type'] as String?),
      source: source ?? '${json['source'] ?? ''}',
      coverUrl: cover,
      artist: json['artist'] as String?,
      worksNum: (json['worksNum'] as num?)?.toInt() ?? 0,
      date: json['date'] as String?,
      description: (json['description'] ?? json['desc']) as String?,
      raw: raw,
    );
  }

  static String? _firstString(List<dynamic> candidates) {
    for (final value in candidates) {
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }
}

/// 专辑 / 作者详情（含歌曲列表）。
class CollectionDetail {
  const CollectionDetail({
    required this.item,
    required this.songs,
    this.isEnd = true,
    this.total,
  });

  final SearchCollection item;
  final List<Song> songs;
  final bool isEnd;
  final int? total;
}

/// 一页专辑 / 作者搜索结果。
class CollectionSearchPage {
  const CollectionSearchPage({
    this.items = const [],
    this.isEnd = true,
    this.total,
  });

  final List<SearchCollection> items;

  /// 插件未返回结束标记时，默认已到最后一页。
  final bool isEnd;
  final int? total;
}

/// 专辑 / 作者详情加载失败。
///
/// 与「这个专辑 / 作者确实没有作品」区分开：界面遇到它要显示错误信息和
/// 「重试」按钮，而不是一句「没有获取到歌曲」。
class CollectionDetailException implements Exception {
  const CollectionDetailException(this.message);

  final String message;

  @override
  String toString() => message;
}
