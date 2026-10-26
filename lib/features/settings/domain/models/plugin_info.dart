class PluginSource {
  /// 插件声明的音源 id（宿主解析出的键，例如 'wy' / 'qs'）。
  ///
  /// 旧版本保存的插件没有这个字段，此时按名称推导。
  final String? id;
  final String name;
  final List<String> qualities;

  const PluginSource({
    this.id,
    required this.name,
    required this.qualities,
  });

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'name': name,
        'qualities': qualities,
      };

  factory PluginSource.fromJson(Map<String, dynamic> json) {
    return PluginSource(
      id: json['id'] as String?,
      name: json['name'] as String,
      qualities: List<String>.from(json['qualities'] as List),
    );
  }
}

class PluginInfo {
  final String id;
  final String name;
  final String version;
  final String author;
  final String description;
  final String type;
  final bool isEnabled;
  final DateTime installTime;
  final List<PluginSource> supportedSources;
  final String? filePath;
  final String? updateUrl;

  /// 是否是「数据源」插件（只提供元数据、不解析播放地址）。
  ///
  /// 由插件脚本自己声明（`pluginInfo.isDataSource = true`），导入时解析并
  /// 持久化：插件管理页据此把它归到「数据源」分类，播放时用用户为它指定的
  /// 播放源解析地址。
  final bool isDataSource;

  const PluginInfo({
    required this.id,
    required this.name,
    required this.version,
    required this.author,
    this.description = '',
    this.type = 'cr',
    this.isEnabled = true,
    required this.installTime,
    this.supportedSources = const [],
    this.filePath,
    this.updateUrl,
    this.isDataSource = false,
  });

  PluginInfo copyWith({
    String? id,
    String? name,
    String? version,
    String? author,
    String? description,
    String? type,
    bool? isEnabled,
    DateTime? installTime,
    List<PluginSource>? supportedSources,
    String? filePath,
    String? updateUrl,
    bool? isDataSource,
  }) {
    return PluginInfo(
      id: id ?? this.id,
      name: name ?? this.name,
      version: version ?? this.version,
      author: author ?? this.author,
      description: description ?? this.description,
      type: type ?? this.type,
      isEnabled: isEnabled ?? this.isEnabled,
      installTime: installTime ?? this.installTime,
      supportedSources: supportedSources ?? this.supportedSources,
      filePath: filePath ?? this.filePath,
      updateUrl: updateUrl ?? this.updateUrl,
      isDataSource: isDataSource ?? this.isDataSource,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'version': version,
      'author': author,
      'description': description,
      'type': type,
      'isEnabled': isEnabled,
      'installTime': installTime.toIso8601String(),
      'supportedSources': supportedSources.map((s) => s.toJson()).toList(),
      'filePath': filePath,
      if (updateUrl != null) 'updateUrl': updateUrl,
      'isDataSource': isDataSource,
    };
  }

  factory PluginInfo.fromJson(Map<String, dynamic> json) {
    return PluginInfo(
      id: json['id'] as String,
      name: json['name'] as String,
      version: json['version'] as String,
      author: json['author'] as String,
      description: json['description'] as String? ?? '',
      type: json['type'] as String? ?? 'cr',
      isEnabled: json['isEnabled'] as bool? ?? true,
      installTime: DateTime.parse(json['installTime'] as String),
      supportedSources: (json['supportedSources'] as List<dynamic>?)
              ?.map((e) => PluginSource.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      filePath: json['filePath'] as String?,
      updateUrl: json['updateUrl'] as String?,
      isDataSource: json['isDataSource'] as bool? ?? false,
    );
  }
}