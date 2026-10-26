/// 电台分类。「全部」是内置分类，不参与持久化。
class RadioCategory {
  const RadioCategory({required this.id, required this.name});

  final String id;
  final String name;

  /// 「全部」分类的 id。
  static const String allId = 'all';

  /// 内置的「全部」分类。
  static const RadioCategory all = RadioCategory(id: allId, name: '全部');

  bool get isAll => id == all.id;

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory RadioCategory.fromJson(Map<String, dynamic> json) {
    return RadioCategory(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
    );
  }
}

/// 电台里选定的一个「音源 + 歌单分类」。
class RadioTagRef {
  const RadioTagRef({
    required this.sourceId,
    required this.tagId,
    required this.tagName,
  });

  final String sourceId;
  final String tagId;
  final String tagName;

  String get key => '$sourceId|$tagId';

  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'tagId': tagId,
    'tagName': tagName,
  };

  factory RadioTagRef.fromJson(Map<String, dynamic> json) {
    return RadioTagRef(
      sourceId: json['sourceId']?.toString() ?? '',
      tagId: json['tagId']?.toString() ?? '',
      tagName: json['tagName']?.toString() ?? '',
    );
  }
}

/// 一个电台。
///
/// 歌曲来源有两种，至少要配一种（也可以都配，播放时随机走其中一种）：
/// * [tags]：音源 + 歌单分类（可以多个音源、多个分类）；
/// * [keywords]：搜索歌单用的关键词（可以多个）。
class RadioStation {
  const RadioStation({
    required this.id,
    required this.name,
    required this.coverUrl,
    this.coverPath,
    this.categoryId = RadioCategory.allId,
    this.sourceIds = const [],
    this.tags = const [],
    this.keywords = const [],
    required this.createTime,
    required this.updateTime,
  });

  /// 「随机电台」的固定 id（内置，不存在存储里）。
  static const String randomId = '__random__';

  final String id;
  final String name;

  /// 用户填的封面：本地文件路径或网络地址。
  final String coverUrl;

  /// 缓存到硬盘后的本地路径（展示优先用它）。
  final String? coverPath;

  /// 所属电台分类 id。
  final String categoryId;

  /// 可以参与随机的音源（空表示用发现页当前音源）。
  final List<String> sourceIds;

  /// 指定的「音源 + 歌单分类」。
  final List<RadioTagRef> tags;

  /// 指定的搜索歌单关键词。
  final List<String> keywords;

  final DateTime createTime;
  final DateTime updateTime;

  bool get isRandom => id == randomId;

  /// 实际用于展示的封面（缓存过的本地文件优先）。
  String get displayCover {
    final cached = coverPath?.trim() ?? '';
    return cached.isNotEmpty ? cached : coverUrl;
  }

  bool get hasSongSource => tags.isNotEmpty || keywords.isNotEmpty;

  RadioStation copyWith({
    String? name,
    String? coverUrl,
    String? coverPath,
    bool clearCoverPath = false,
    String? categoryId,
    List<String>? sourceIds,
    List<RadioTagRef>? tags,
    List<String>? keywords,
    DateTime? updateTime,
  }) {
    return RadioStation(
      id: id,
      name: name ?? this.name,
      coverUrl: coverUrl ?? this.coverUrl,
      coverPath: clearCoverPath ? null : (coverPath ?? this.coverPath),
      categoryId: categoryId ?? this.categoryId,
      sourceIds: sourceIds ?? this.sourceIds,
      tags: tags ?? this.tags,
      keywords: keywords ?? this.keywords,
      createTime: createTime,
      updateTime: updateTime ?? this.updateTime,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'coverUrl': coverUrl,
    'coverPath': coverPath,
    'categoryId': categoryId,
    'sourceIds': sourceIds,
    'tags': tags.map((e) => e.toJson()).toList(),
    'keywords': keywords,
    'createTime': createTime.toIso8601String(),
    'updateTime': updateTime.toIso8601String(),
  };

  factory RadioStation.fromJson(Map<String, dynamic> json) {
    List<String> readStrings(Object? raw) {
      if (raw is! List) return const [];
      return raw
          .map((e) => '$e'.trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
    }

    final rawTags = json['tags'];
    return RadioStation(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      coverUrl: json['coverUrl']?.toString() ?? '',
      coverPath: json['coverPath']?.toString(),
      categoryId: json['categoryId']?.toString() ?? RadioCategory.allId,
      sourceIds: readStrings(json['sourceIds']),
      tags: rawTags is List
          ? rawTags
                .whereType<Map>()
                .map((e) => RadioTagRef.fromJson(Map<String, dynamic>.from(e)))
                .where((e) => e.tagId.isNotEmpty)
                .toList(growable: false)
          : const [],
      keywords: readStrings(json['keywords']),
      createTime:
          DateTime.tryParse(json['createTime']?.toString() ?? '') ??
          DateTime.now(),
      updateTime:
          DateTime.tryParse(json['updateTime']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}

/// 电台数据（分类 + 电台）。
class RadioData {
  const RadioData({this.categories = const [], this.stations = const []});

  /// 用户自建的分类（「全部」是内置的，不在这里）。
  final List<RadioCategory> categories;
  final List<RadioStation> stations;

  List<RadioStation> stationsIn(String categoryId) {
    if (categoryId == RadioCategory.allId) return stations;
    return stations
        .where((station) => station.categoryId == categoryId)
        .toList(growable: false);
  }

  Map<String, dynamic> toJson() => {
    'categories': categories.map((e) => e.toJson()).toList(),
    'stations': stations.map((e) => e.toJson()).toList(),
  };

  factory RadioData.fromJson(Map<String, dynamic> json) {
    final rawCategories = json['categories'];
    final rawStations = json['stations'];
    return RadioData(
      categories: rawCategories is List
          ? rawCategories
                .whereType<Map>()
                .map(
                  (e) => RadioCategory.fromJson(Map<String, dynamic>.from(e)),
                )
                .where((e) => e.id.isNotEmpty)
                .toList(growable: false)
          : const [],
      stations: rawStations is List
          ? rawStations
                .whereType<Map>()
                .map((e) => RadioStation.fromJson(Map<String, dynamic>.from(e)))
                .where((e) => e.id.isNotEmpty)
                .toList(growable: false)
          : const [],
    );
  }
}
