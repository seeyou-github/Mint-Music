import 'source_id_mapping.dart';

class PluginSourceInfo {
  /// 插件声明的音源 id（宿主解析出的键，例如 'wy' / 'qs'）。
  final String? id;
  final String name;
  final List<String> qualities;

  const PluginSourceInfo({
    this.id,
    required this.name,
    required this.qualities,
  });

  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    'name': name,
    'qualities': qualities,
  };

  factory PluginSourceInfo.fromJson(Map<String, dynamic> json) {
    return PluginSourceInfo(
      id: json['id'] as String?,
      name: json['name'] as String,
      qualities: List<String>.from(json['qualities'] as List),
    );
  }
}

/// 插件测试用：插件宿主声明的一个音源。
///
/// [id] 为规范化后的音源标识（已知平台映射为 wy/kg/kw/tx/mg，
/// 其余音源沿用插件声明名），供搜索与链接解析使用。
class PluginSourceSpec {
  final String id;
  final String name;
  final List<String> qualities;

  const PluginSourceSpec({
    required this.id,
    required this.name,
    required this.qualities,
  });
}

class PluginMetadata {
  final String name;
  final String version;
  final String author;
  final String? description;
  final String? homepage;

  /// 插件图标地址（站点 favicon / logo 的 http 地址，可空）。
  ///
  /// 导入插件时会下载并转成 PNG 缓存到插件目录，音源切换按钮与音源列表用它
  /// 代替默认的「平台首字圆标」。
  final String? iconUrl;

  /// 是否是「数据源」插件。
  ///
  /// 数据源只提供搜索 / 发现页 / 专辑 / 作者等元数据，**不提供播放地址**；
  /// 插件用 `pluginInfo.isDataSource = true`（或顶层 `isDataSource`）声明自己，
  /// 导入后归到「插件管理 → 数据源」分类，播放时用用户指定的播放源解析地址。
  final bool isDataSource;

  const PluginMetadata({
    required this.name,
    required this.version,
    required this.author,
    this.description,
    this.homepage,
    this.iconUrl,
    this.isDataSource = false,
  });

  factory PluginMetadata.fromJson(Map<String, dynamic> json) {
    return PluginMetadata(
      name: json['name'] as String,
      version: json['version'] as String,
      author: json['author'] as String,
      description: json['description'] as String?,
      homepage: json['homepage'] as String?,
      iconUrl: (json['iconUrl'] ?? json['icon']) as String?,
      isDataSource: json['isDataSource'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'version': version,
    'author': author,
    'description': description,
    if (homepage != null) 'homepage': homepage,
    if (iconUrl != null) 'iconUrl': iconUrl,
    if (isDataSource) 'isDataSource': true,
  };
}

class MusicInfoForPlugin {
  final String? songmid;
  final dynamic songId;
  final String? hash;
  final String singer;
  final String name;
  final String albumName;
  final dynamic albumId;
  final dynamic albumMid;
  final dynamic strMediaMid;
  final dynamic copyrightId;
  final String source;
  final String interval;
  final String? img;
  final String? lrc;
  final String? lrcUrl;
  final String? mrcUrl;
  final String? trcUrl;
  final List<dynamic>? types;
  final Map<String, dynamic>? typeMap;
  final Map<String, dynamic>? typeUrl;

  /// 插件自定义的附加数据（原样透传，不做平台字段映射）。
  ///
  /// MusicFree 插件依赖原始 `musicItem`（`extra.musicItem`）解析播放地址与
  /// 歌词，因此搜索结果会把它塞进这里并经由 [Song.lx] 往返。
  final Map<String, dynamic>? extra;

  const MusicInfoForPlugin({
    this.songmid,
    this.songId,
    this.hash,
    required this.singer,
    required this.name,
    required this.albumName,
    this.albumId,
    this.albumMid,
    this.strMediaMid,
    this.copyrightId,
    required this.source,
    this.interval = '',
    this.img,
    this.lrc,
    this.lrcUrl,
    this.mrcUrl,
    this.trcUrl,
    this.types,
    this.typeMap,
    this.typeUrl,
    this.extra,
  });

  String get id => songmid ?? songId?.toString() ?? hash ?? '';

  Map<String, dynamic> toJson() => {
    'songmid': songmid,
    'songId': songId,
    'songid': songId,
    'hash': hash,
    'singer': singer,
    'name': name,
    'albumName': albumName,
    'albumId': albumId,
    'albumMid': albumMid,
    'strMediaMid': strMediaMid,
    'copyrightId': copyrightId,
    'source': source,
    'interval': interval,
    'img': img,
    'lrc': lrc,
    'lrcUrl': lrcUrl,
    'mrcUrl': mrcUrl,
    'trcUrl': trcUrl,
    'types': types,
    '_types': typeMap,
    'typeUrl': typeUrl ?? <String, dynamic>{},
    'extra': extra,
    'id': id,
  };

  factory MusicInfoForPlugin.fromJson(Map<String, dynamic> json) {
    return MusicInfoForPlugin(
      songmid: json['songmid']?.toString(),
      songId: json['songId'] ?? json['songid'],
      hash: json['hash']?.toString(),
      singer: json['singer'] as String? ?? '',
      name: json['name'] as String? ?? '',
      albumName: json['albumName'] as String? ?? '',
      albumId: json['albumId'],
      albumMid: json['albumMid'],
      strMediaMid: json['strMediaMid'],
      copyrightId: json['copyrightId'],
      source: json['source'] as String? ?? '',
      interval: json['interval'] as String? ?? '',
      img: json['img'] as String?,
      lrc: json['lrc'] as String?,
      lrcUrl: json['lrcUrl'] as String?,
      mrcUrl: json['mrcUrl'] as String?,
      trcUrl: json['trcUrl'] as String?,
      types: json['types'] is List ? List<dynamic>.from(json['types']) : null,
      typeMap: json['_types'] is Map
          ? Map<String, dynamic>.from(json['_types'])
          : null,
      typeUrl: json['typeUrl'] is Map
          ? Map<String, dynamic>.from(json['typeUrl'])
          : null,
      extra: json['extra'] is Map
          ? Map<String, dynamic>.from(json['extra'])
          : null,
    );
  }
}

class SearchResultFromPlugin {
  final List<MusicInfoForPlugin> list;
  final int allPage;
  final int limit;
  final int total;
  final String source;

  const SearchResultFromPlugin({
    required this.list,
    this.allPage = 0,
    this.limit = 30,
    this.total = 0,
    required this.source,
  });

  factory SearchResultFromPlugin.fromJson(Map<String, dynamic> json) {
    return SearchResultFromPlugin(
      list:
          (json['list'] as List?)
              ?.map(
                (e) => MusicInfoForPlugin.fromJson(e as Map<String, dynamic>),
              )
              .toList() ??
          [],
      allPage: json['allPage'] as int? ?? 0,
      limit: json['limit'] as int? ?? 30,
      total: json['total'] as int? ?? 0,
      source: json['source'] as String? ?? '',
    );
  }
}

class RequestResultFromPlugin {
  final dynamic body;
  final int statusCode;
  final Map<String, String> headers;

  const RequestResultFromPlugin({
    required this.body,
    required this.statusCode,
    required this.headers,
  });
}

/// Only these aliases are interchangeable; all other quality labels stay exact.
const musicQualityAliases = <String, String>{
  'low': '64k',
  'standard': '128k',
  'high': '320k',
  'hq': '320k',
  'super': 'flac',
  'lossless': 'flac',
};

/// Known non-bitrate LX quality types (not codecs such as mp3/aac/ogg).
const musicQualityTypes = <String>[
  'flac',
  'flac24bit',
  'hires',
  'atmos',
  'master',
  '24bit',
  'sq',
  'dsd',
];

String musicQualityKey(String quality) {
  final value = quality.trim().toLowerCase();
  return musicQualityAliases[value] ?? value;
}

bool isMusicQualityType(String type) {
  final key = musicQualityKey(type);
  return RegExp(r'^\d{2,4}k$').hasMatch(key) || musicQualityTypes.contains(key);
}

/// Normalized playback information returned by an LX source.
///
/// LX scripts may return a URL directly or wrap it in several layers of
/// response data. Keeping the optional request headers here is important for
/// sources whose final media URL is protected by a referer or token header.
class PluginMusicUrlResult {
  final String url;

  /// Reported or requested label; not verification of the actual media bitrate.
  final String quality;
  final Map<String, String> headers;

  /// 实际提供这个地址的音源 id（`平台id@插件id`）。
  ///
  /// 平台歌曲最终也是由插件解析地址，带上这个字段就能在界面上显示真正
  /// 正在使用的音源。
  final String? source;

  const PluginMusicUrlResult({
    required this.url,
    this.quality = '',
    this.headers = const <String, String>{},
    this.source,
  });
}

enum PluginType { ceruMusic, lx }

/// 数据源（只提供元数据的插件）的歌曲解析播放地址失败。
///
/// 这类失败要原样展示给用户（例如「此网易云音乐数据源指定的 xxx音源失效…」），
/// 调用方不要再加「当前音源播放失败」之类的前缀。
class DataSourcePlaybackException implements Exception {
  const DataSourcePlaybackException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SourceInfo {
  final String id;
  final String name;

  const SourceInfo({required this.id, required this.name});

  /// 取出音源 id 中的平台部分。
  ///
  /// 同名同平台的不同插件（不同作者）会得到 `平台id@插件id` 这样的唯一
  /// id，展示图标时仍然使用平台部分。
  static String baseIdOf(String id) {
    final index = id.indexOf('@');
    if (index <= 0 || index >= id.length - 1) return id;
    return id.substring(0, index);
  }

  static String getNameById(String id) {
    return SourceIdMapping.idToName[baseIdOf(id)] ?? '未知音源';
  }
}
