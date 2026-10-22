import '../../../../player/domain/models/song.dart';

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
    return SearchCollection(
      id: '${json['id'] ?? ''}',
      title: '${json['title'] ?? json['name'] ?? ''}',
      type: type ?? CollectionTypeX.fromId(json['type'] as String?),
      source: source ?? '${json['source'] ?? ''}',
      coverUrl: (json['coverUrl'] ?? json['artwork']) as String?,
      artist: json['artist'] as String?,
      worksNum: (json['worksNum'] as num?)?.toInt() ?? 0,
      date: json['date'] as String?,
      description: json['description'] as String?,
      raw: raw,
    );
  }
}

/// 专辑 / 作者详情（含歌曲列表）。
class CollectionDetail {
  const CollectionDetail({
    required this.item,
    required this.songs,
    this.isEnd = true,
  });

  final SearchCollection item;
  final List<Song> songs;
  final bool isEnd;
}
