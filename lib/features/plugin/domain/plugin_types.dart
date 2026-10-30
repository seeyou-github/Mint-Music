import 'source_id_mapping.dart';
import 'source_login_state.dart';

/// 插件声明的「一个音源」的完整能力描述（对应 LX 脚本 `sources[id]`）。
///
/// 这个类是插件协议的唯一权威定义：**新增插件请照下面的字段填写**，
/// 字段缺失时一律按「向后兼容」处理（见每个字段的缺省说明）。
///
/// ## 插件侧完整声明示例
///
/// ```js
/// const sources = {
///   wy: {
///     // ---- 必填 ----
///     name: '网易云音乐',
///     type: 'music',
///
///     // ---- 能力声明 ----
///     // 插件支持哪些 action。musicUrl 是播放/下载必需，其余按需。
///     actions: ['musicUrl', 'musicSearch', 'lyric', 'loginStatus'],
///
///     // ---- 音质声明（本协议的重点）----
///     // 播放音质：界面「音质切换」菜单只显示这里列出的档位，顺序即菜单顺序。
///     // 键名语义固定：'64k' | '128k' | '192k' | '320k' | 'flac' | 'flac24bit'
///     //             | 'hires' | 'atmos' | 'master' | '24bit' | 'sq' | 'dsd'
///     // 这里写的档位必须是「插件真的能给出」的档位，不要为了好看全列上：
///     // 宿主会按这个列表让用户选，插件返回的音质低于所选档位会被拒绝。
///     qualitys: ['128k', '320k', 'flac', 'flac24bit'],
///
///     // 下载音质：下载菜单与「下载音质」校验用这个列表。
///     // 缺省（不写）时等于 qualitys，老插件行为不变。
///     downloadQualitys: ['128k', '320k', 'flac'],
///
///     // 登录门槛：高音质依赖登录态时声明，宿主据此把不可用档位置灰。
///     login: {
///       required: true,                  // 高音质是否依赖登录
///       freeQualitys: ['128k', '320k'],  // 未登录时仍真实可用的档位
///       state: 'loggedOut',              // 静态初始态，会被运行时检测覆盖
///     },
///
///     // 需要用户填写的凭据（cookie / api key / 卡密…）。
///     // 宿主会在插件管理页渲染输入框，并通过 lx.getUserVariables() 注入。
///     credentials: [
///       { key: 'MUSIC_U', label: 'MUSIC_U', secret: true,
///         hint: '浏览器登录 music.163.com → F12 → Cookie 里复制 MUSIC_U' },
///     ],
///   },
/// };
/// ```
///
/// ## 插件侧读取凭据
///
/// ```js
/// const vars = (typeof lx.getUserVariables === 'function' && lx.getUserVariables()) || {};
/// const cookie = vars.MUSIC_U || '';
/// ```
class PluginSourceInfo {
  /// 插件声明的音源 id（宿主解析出的键，例如 'wy' / 'qs'）。
  final String? id;
  final String name;

  /// 播放音质（对应插件 `qualitys` / `qualities` / `types`）。
  ///
  /// 顺序即音质菜单顺序；为空表示「插件没声明」，此时界面回退到平台默认
  /// 档位并标注未声明，不会假装插件支持全部音质。
  final List<String> qualities;

  /// 下载音质（对应插件 `downloadQualitys`，缺省 = [qualities]）。
  ///
  /// 很多站点「能播 320k、但下载只给 128k」，声明后就只在下载菜单显示
  /// 真正能下的档位。
  final List<String> downloadQualities;

  /// 登录要求（对应插件 `login`）。null = 插件没声明，视为不做登录限制。
  final SourceLoginSpec? login;

  /// 需要用户填写的凭据（对应插件 `credentials`）。
  final List<SourceCredentialSpec> credentials;

  PluginSourceInfo({
    this.id,
    required this.name,
    required this.qualities,
    List<String>? downloadQualities,
    this.login,
    this.credentials = const [],
  }) : downloadQualities = _normalizeDownloadQualities(
         downloadQualities,
         qualities,
       );

  /// 下载音质缺省时跟随播放音质。
  static List<String> _normalizeDownloadQualities(
    List<String>? download,
    List<String> qualities,
  ) {
    if (download == null || download.isEmpty) return List<String>.from(qualities);
    return List<String>.from(download);
  }

  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    'name': name,
    'qualities': qualities,
    'downloadQualities': downloadQualities,
    if (login != null) 'login': login!.toJson(),
    if (credentials.isNotEmpty)
      'credentials': credentials.map((e) => e.toJson()).toList(),
  };

  factory PluginSourceInfo.fromJson(Map<String, dynamic> json) {
    final qualities = _stringList(json['qualities'] ?? json['qualitys']);
    return PluginSourceInfo(
      id: json['id'] as String?,
      name: '${json['name'] ?? ''}',
      qualities: qualities,
      downloadQualities: _stringListOrNull(
        json['downloadQualities'] ?? json['downloadQualitys'],
      ),
      login: SourceLoginSpec.fromJson(json['login']),
      credentials: SourceCredentialSpec.listFromJson(json['credentials']),
    );
  }

  static List<String> _stringList(dynamic value) =>
      _stringListOrNull(value) ?? const [];

  static List<String>? _stringListOrNull(dynamic value) {
    if (value is! List) return null;
    final result = value
        .map((e) => '$e'.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return result;
  }

  PluginSourceInfo copyWith({
    String? id,
    String? name,
    List<String>? qualities,
    List<String>? downloadQualities,
    SourceLoginSpec? login,
    List<SourceCredentialSpec>? credentials,
  }) {
    return PluginSourceInfo(
      id: id ?? this.id,
      name: name ?? this.name,
      qualities: qualities ?? this.qualities,
      downloadQualities: downloadQualities ?? this.downloadQualities,
      login: login ?? this.login,
      credentials: credentials ?? this.credentials,
    );
  }
}

/// 音源的登录门槛声明（对应插件 `login` 字段）。
///
/// 语义：**未登录时只有 [freeQualitys] 里的档位是真实可用的**，其余档位在
/// 界面上显示但置灰（点击提示去填凭据），宿主也不会把请求发出去。
///
/// 缺省行为：
/// * 插件不写 `login` → 宿主视为「不做登录限制」，所有声明档位都显示可用；
/// * 写了 `login.required` 但没写 `freeQualitys` / 为空 → 视为「所有档位
///   都需要登录」。
class SourceLoginSpec {
  /// 高音质是否依赖登录（false 表示声明了凭据但只是可选增强）。
  final bool required;

  /// 未登录（含登录失效）时仍然可用的档位。
  final List<String> freeQualitys;

  /// 插件在初始化时声明的静态登录态；运行时检测结果会覆盖它。
  final SourceLoginState state;

  const SourceLoginSpec({
    this.required = false,
    this.freeQualitys = const [],
    this.state = SourceLoginState.unknown,
  });

  /// 未登录时可用的档位是否包含 [quality]。
  bool freeAllows(String quality) => freeQualitys.contains(quality);

  Map<String, dynamic> toJson() => {
    'required': required,
    'freeQualitys': freeQualitys,
    'state': state.storageKey,
  };

  static SourceLoginSpec? fromJson(dynamic value) {
    if (value == null) return null;
    // 允许简写：login: true → 有登录门槛但没说哪些档位免费（视为全部需要）。
    if (value is bool) return SourceLoginSpec(required: value);
    if (value is! Map) return null;
    return SourceLoginSpec(
      required: value['required'] == true,
      freeQualitys:
          PluginSourceInfo._stringListOrNull(
            value['freeQualitys'] ?? value['freeQualities'],
          ) ??
          const [],
      state: SourceLoginState.fromRaw(value['state']),
    );
  }

  SourceLoginSpec copyWith({
    bool? required,
    List<String>? freeQualitys,
    SourceLoginState? state,
  }) {
    return SourceLoginSpec(
      required: required ?? this.required,
      freeQualitys: freeQualitys ?? this.freeQualitys,
      state: state ?? this.state,
    );
  }
}

/// 一个需要用户填写的凭据（对应插件 `credentials[i]`）。
///
/// 宿主把用户填的值通过 `lx.getUserVariables()` 注入给插件，插件用
/// `vars[key]` 读取。凭据存放在设置里（key `plugin_credentials`），
/// **会随备份文件一起导出**，因此 `secret` 为 true 的输入框要做遮挡。
class SourceCredentialSpec {
  /// 注入给插件的变量名（插件里 `vars[key]`），例如 `'MUSIC_U'`。
  final String key;

  /// 界面上显示的标题，缺省用 [key]。
  final String label;

  /// 是否敏感（cookie / token）：输入框遮挡显示，日志里不打印值。
  final bool secret;

  /// 填写说明（去哪里复制、格式是什么）。
  final String? hint;

  const SourceCredentialSpec({
    required this.key,
    String? label,
    this.secret = true,
    this.hint,
  }) : label = label ?? key;

  Map<String, dynamic> toJson() => {
    'key': key,
    'label': label,
    'secret': secret,
    if (hint != null) 'hint': hint,
  };

  static SourceCredentialSpec? fromJson(dynamic value) {
    if (value is! Map) return null;
    final key = '${value['key'] ?? ''}'.trim();
    if (key.isEmpty) return null;
    return SourceCredentialSpec(
      key: key,
      label: '${value['label'] ?? key}',
      secret: value['secret'] != false,
      hint: value['hint'] == null ? null : '${value['hint']}',
    );
  }

  /// 解析 `credentials` 数组，非法项直接丢弃（不抛异常）。
  static List<SourceCredentialSpec> listFromJson(dynamic value) {
    if (value is! List) return const [];
    final result = <SourceCredentialSpec>[];
    for (final item in value) {
      final spec = fromJson(item);
      if (spec != null) result.add(spec);
    }
    return result;
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

  /// 插件是否支持「自定义歌单」：歌单由 App 侧新建（封面 / 名称 / 搜索关键字），
  /// 内容用插件自己的搜索接口按关键字分页取，插件不需要提供歌单接口。
  final bool customSheets;

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
    this.customSheets = false,
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
      customSheets: json['customSheets'] == true,
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
    if (customSheets) 'customSheets': true,
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

/// 音质的用途：插件可以为「播放」和「下载」声明两套不同的档位。
///
/// 常见场景：某站点允许在线听 320k，但下载只给 128k；或者下载需要额外权限。
/// 用户选择「下载音质」时按 [download] 列表显示，避免下到与所选不符的文件。
enum QualityUsage {
  /// 播放（音质切换菜单）。
  play,

  /// 下载（下载音质菜单 / 下载任务校验）。
  download,
}

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
