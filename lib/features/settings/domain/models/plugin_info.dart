import '../../../plugin/domain/plugin_types.dart';

/// 持久化到 `plugins.json` 的音源能力描述。
///
/// 字段含义与插件侧声明一一对应，详见 [PluginSourceInfo] 的文档注释
/// （那里有完整的插件脚本示例）。这里只做持久化，不做业务判断。
class PluginSource {
  /// 插件声明的音源 id（宿主解析出的键，例如 'wy' / 'qs'）。
  ///
  /// 旧版本保存的插件没有这个字段，此时按名称推导。
  final String? id;
  final String name;

  /// 播放音质（对应插件 `qualitys`）。
  final List<String> qualities;

  /// 下载音质（对应插件 `downloadQualitys`）。缺省等于 [qualities]。
  final List<String> downloadQualities;

  /// 登录门槛（对应插件 `login`）。null = 插件没声明，视为不做限制。
  final SourceLoginSpec? login;

  /// 需要用户填写的凭据（对应插件 `credentials`）。
  final List<SourceCredentialSpec> credentials;

  PluginSource({
    this.id,
    required this.name,
    required this.qualities,
    List<String>? downloadQualities,
    this.login,
    this.credentials = const [],
  }) : downloadQualities =
           (downloadQualities == null || downloadQualities.isEmpty)
           ? List<String>.from(qualities)
           : List<String>.from(downloadQualities);

  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    'name': name,
    'qualities': qualities,
    'downloadQualities': downloadQualities,
    if (login != null) 'login': login!.toJson(),
    if (credentials.isNotEmpty)
      'credentials': credentials.map((e) => e.toJson()).toList(),
  };

  factory PluginSource.fromJson(Map<String, dynamic> json) {
    final qualities = _stringList(json['qualities'] ?? json['qualitys']);
    return PluginSource(
      id: json['id'] as String?,
      name: '${json['name'] ?? ''}',
      qualities: qualities,
      downloadQualities: _stringList(
        json['downloadQualities'] ?? json['downloadQualitys'],
      ),
      login: SourceLoginSpec.fromJson(json['login']),
      credentials: SourceCredentialSpec.listFromJson(json['credentials']),
    );
  }

  static List<String> _stringList(dynamic value) {
    if (value is! List) return const [];
    return value
        .map((e) => '$e'.trim())
        .where((e) => e.isNotEmpty)
        .toList();
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

  /// 插件声明的图标地址（`pluginInfo.iconUrl`，站点 favicon / logo）。
  final String? iconUrl;

  /// 图标缓存到插件目录后的本地路径（PNG）。
  ///
  /// 导入插件时下载并转换一次；音源切换按钮 / 音源列表优先显示它。
  final String? iconPath;

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
    this.iconUrl,
    this.iconPath,
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
    String? iconUrl,
    String? iconPath,
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
      iconUrl: iconUrl ?? this.iconUrl,
      iconPath: iconPath ?? this.iconPath,
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
      if (iconUrl != null) 'iconUrl': iconUrl,
      if (iconPath != null) 'iconPath': iconPath,
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
      supportedSources:
          (json['supportedSources'] as List<dynamic>?)
              ?.map((e) => PluginSource.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      filePath: json['filePath'] as String?,
      updateUrl: json['updateUrl'] as String?,
      iconUrl: json['iconUrl'] as String?,
      iconPath: json['iconPath'] as String?,
      isDataSource: json['isDataSource'] as bool? ?? false,
    );
  }
}
