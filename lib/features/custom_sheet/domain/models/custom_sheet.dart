import 'package:flutter/foundation.dart';

/// 自定义歌单的分类（App 侧维护，按音源共享一份列表）。
@immutable
class CustomSheetCategory {
  const CustomSheetCategory({required this.id, required this.name});

  final String id;
  final String name;

  CustomSheetCategory copyWith({String? name}) =>
      CustomSheetCategory(id: id, name: name ?? this.name);

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory CustomSheetCategory.fromJson(Map<String, dynamic> json) =>
      CustomSheetCategory(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
      );
}

/// 一条「自定义歌单」：App 里手工建的歌单，内容由绑定音源按 [keyword] 搜索得到。
///
/// 插件侧只需要声明 `customSheets: true`，不需要实现任何歌单接口。
@immutable
class CustomSheet {
  const CustomSheet({
    required this.id,
    required this.sourceId,
    required this.name,
    required this.keyword,
    this.categoryId = '',
    this.coverUrl = '',
    this.coverPath,
    this.updateTime = 0,
  });

  /// 歌单详情页 / 路由里使用的 id 前缀。
  static const String idPrefix = 'custom:';

  /// 内部 id（不含前缀）。
  final String id;

  /// 绑定的音源（完整 id，例如 `bilibili@3f2a1b`）。
  final String sourceId;

  /// 分类 id；空字符串表示未分类（显示在「全部」里）。
  final String categoryId;

  final String name;

  /// 搜索关键字：歌单内容 = 该音源按这个关键字搜索的结果。
  final String keyword;

  /// 用户填的封面（本地路径或网络地址）。
  final String coverUrl;

  /// 缓存到本地的封面路径。
  final String? coverPath;

  final int updateTime;

  /// 详情页路由用的 id。
  String get playlistId => '$idPrefix$id';

  /// 界面上显示的封面（缓存优先）。
  String get displayCover {
    final cached = coverPath?.trim() ?? '';
    return cached.isNotEmpty ? cached : coverUrl;
  }

  static String idOf(String playlistId) {
    if (!playlistId.startsWith(idPrefix)) return playlistId;
    return playlistId.substring(idPrefix.length);
  }

  static bool isCustomPlaylistId(String playlistId) =>
      playlistId.startsWith(idPrefix);

  CustomSheet copyWith({
    String? sourceId,
    String? categoryId,
    String? name,
    String? keyword,
    String? coverUrl,
    String? coverPath,
    int? updateTime,
  }) {
    return CustomSheet(
      id: id,
      sourceId: sourceId ?? this.sourceId,
      categoryId: categoryId ?? this.categoryId,
      name: name ?? this.name,
      keyword: keyword ?? this.keyword,
      coverUrl: coverUrl ?? this.coverUrl,
      coverPath: coverPath ?? this.coverPath,
      updateTime: updateTime ?? this.updateTime,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'sourceId': sourceId,
    'categoryId': categoryId,
    'name': name,
    'keyword': keyword,
    'coverUrl': coverUrl,
    'coverPath': coverPath,
    'updateTime': updateTime,
  };

  factory CustomSheet.fromJson(Map<String, dynamic> json) => CustomSheet(
    id: json['id']?.toString() ?? '',
    sourceId: json['sourceId']?.toString() ?? '',
    categoryId: json['categoryId']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    keyword: json['keyword']?.toString() ?? '',
    coverUrl: json['coverUrl']?.toString() ?? '',
    coverPath: json['coverPath']?.toString(),
    updateTime: (json['updateTime'] as num?)?.toInt() ?? 0,
  );
}

/// 全部自定义歌单数据（分类 + 歌单）。
@immutable
class CustomSheetData {
  const CustomSheetData({this.categories = const [], this.sheets = const []});

  final List<CustomSheetCategory> categories;
  final List<CustomSheet> sheets;

  bool get isEmpty => categories.isEmpty && sheets.isEmpty;

  CustomSheetCategory? categoryById(String id) {
    for (final category in categories) {
      if (category.id == id) return category;
    }
    return null;
  }

  CustomSheet? sheetById(String id) {
    for (final sheet in sheets) {
      if (sheet.id == id) return sheet;
    }
    return null;
  }

  /// 某个音源下的歌单（发现页只显示当前音源的）。
  List<CustomSheet> sheetsOfSource(String sourceId) => [
    for (final sheet in sheets)
      if (sheet.sourceId == sourceId) sheet,
  ];

  /// 某个音源 + 某个分类下的歌单（[categoryId] 为空表示未分类）。
  List<CustomSheet> sheetsOfCategory(String sourceId, String categoryId) => [
    for (final sheet in sheets)
      if (sheet.sourceId == sourceId && sheet.categoryId == categoryId) sheet,
  ];

  Map<String, dynamic> toJson() => {
    'categories': [for (final category in categories) category.toJson()],
    'sheets': [for (final sheet in sheets) sheet.toJson()],
  };

  factory CustomSheetData.fromJson(Map<String, dynamic> json) {
    final categoriesRaw = json['categories'];
    final sheetsRaw = json['sheets'];
    return CustomSheetData(
      categories: [
        if (categoriesRaw is List)
          for (final item in categoriesRaw)
            if (item is Map)
              CustomSheetCategory.fromJson(Map<String, dynamic>.from(item)),
      ],
      sheets: [
        if (sheetsRaw is List)
          for (final item in sheetsRaw)
            if (item is Map)
              CustomSheet.fromJson(Map<String, dynamic>.from(item)),
      ],
    );
  }
}
