/// 平台侧的「能不能免费听」状态。
///
/// 与 [Song.isVipExclusive] 的区别：
/// * [isVipExclusive] 是 B 站专属的「充电专属 / 大会员专享」布尔标记，还挂着
///   「隐藏B站会员专属歌曲」开关；
/// * [SongAccess] 是 QQ / 网易 / 酷我 / 酷狗 数据源返回的付费与版权状态，
///   只用来在歌曲列表里显示标签，**不参与任何过滤**。
///
/// 插件在歌曲对象里用 `access: 'vip' | 'album' | 'paid' | 'offline' | 'nocopyright'`
/// 声明；不写（或写空）表示免费。
enum SongAccess {
  /// 免费（或平台没给状态）。
  free,

  /// 会员歌曲：需要会员才能完整播放，非会员只能试听片段。
  vip,

  /// 数字专辑：需要购买专辑才能听。
  album,

  /// 单曲付费：需要单独购买这首。
  paid,

  /// 已下架。
  offline,

  /// 无版权 / 未上架。
  noCopyright;

  /// 插件传来的原始值 → 枚举。认不出的值一律当免费，避免误标。
  static SongAccess fromRaw(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'vip':
      case 'viponly':
      case 'member':
        return SongAccess.vip;
      case 'album':
      case 'digital':
      case 'digital_album':
        return SongAccess.album;
      case 'paid':
      case 'pay':
      case 'charge':
        return SongAccess.paid;
      case 'offline':
      case 'removed':
        return SongAccess.offline;
      case 'nocopyright':
      case 'no_copyright':
      case 'uncopyrightable':
        return SongAccess.noCopyright;
      default:
        return SongAccess.free;
    }
  }

  /// 写回 JSON / 传给插件时用的原始值。
  String get raw {
    switch (this) {
      case SongAccess.free:
        return '';
      case SongAccess.vip:
        return 'vip';
      case SongAccess.album:
        return 'album';
      case SongAccess.paid:
        return 'paid';
      case SongAccess.offline:
        return 'offline';
      case SongAccess.noCopyright:
        return 'nocopyright';
    }
  }

  /// 歌曲列表里的标签文案；[free] 不显示标签。
  String? get label {
    switch (this) {
      case SongAccess.free:
        return null;
      case SongAccess.vip:
        return 'VIP';
      case SongAccess.album:
        return '数字专辑';
      case SongAccess.paid:
        return '付费';
      case SongAccess.offline:
        return '下架';
      case SongAccess.noCopyright:
        return '无版权';
    }
  }
}

class Song {
  final String id;
  final String title;
  final String artist;
  final String album;
  final int duration;
  final String? coverUrl;
  final String? sourceUrl;
  final String? lyricUrl;
  final String? source;
  final String? filePath;
  final bool hasCover;
  final String? coverKey;
  final String? lrc;
  final int? bitrate;
  final int? sampleRate;
  final int? channels;
  final int? year;
  final int? mediaStoreId;
  final String? hash;
  final Map<String, dynamic>? lx;
  final Map<String, String>? sourceHeaders;
  final String? sourceQuality;

  /// 流派（本地歌曲扫描时从标签里读出来的 TCON / GENRE）。
  final String? genre;

  /// 注释 / 备注（ID3 的 COMM、Vorbis 的 COMMENT）。
  final String? comment;

  /// 扫描时文件里是否带内嵌歌词（不含歌词缓存、也不含播放时的在线歌词）。
  final bool hasLyric;

  /// 扫描时的内嵌歌词是否逐字歌词（YRC / QRC / KRC 等）。
  final bool hasWordLyric;

  /// 从收藏 / 歌单播放时优先使用的插件音源（`平台id@插件id`）。
  ///
  /// 收藏搜索结果时把「当时是哪个插件」记下来：播放时先用它解析地址，
  /// 优先级高于设置里给平台指定的「优先音源」；它失败后仍按原规则回退，
  /// 所以这里不做硬绑定（[source] 依旧是平台 id）。
  final String? preferredSource;

  /// B 站「充电专属 / 大会员专享」等会员专属作品标记。
  ///
  /// 来自插件音源列表接口的原始标记（如 bilibili 的 `is_charging_arc`），
  /// 用于歌曲列表显示「会员」标签；「隐藏B站会员专属歌曲」开启时，
  /// 插件返回的这类歌曲会被过滤掉，已收藏歌单详情也按开关隐藏展示。
  final bool isVipExclusive;

  /// 视频选集（分 P）数量。大于 1 时列表显示「分P」标签，
  /// 点击歌曲直接打开专辑页列出全部分 P。
  ///
  /// 只有插件在列表接口里显式给出时才有值（bilibili 搜索 / 歌单），
  /// 本地歌曲、专辑页里的单个分 P 始终为 0。
  final int partsCount;

  /// 平台返回的付费 / 版权状态（QQ、网易、酷我、酷狗数据源）。
  ///
  /// 只用于列表标签展示，不影响播放与过滤；B 站那套仍走 [isVipExclusive]。
  final SongAccess access;

  const Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    this.coverUrl,
    this.sourceUrl,
    this.lyricUrl,
    this.source,
    this.filePath,
    this.hasCover = false,
    this.coverKey,
    this.lrc,
    this.bitrate,
    this.sampleRate,
    this.channels,
    this.year,
    this.mediaStoreId,
    this.hash,
    this.lx,
    this.sourceHeaders,
    this.sourceQuality,
    this.genre,
    this.comment,
    this.hasLyric = false,
    this.hasWordLyric = false,
    this.preferredSource,
    this.isVipExclusive = false,
    this.partsCount = 0,
    this.access = SongAccess.free,
  });

  bool get isLocal => source == 'local';

  /// 是否 B 站音源的歌曲。
  ///
  /// 「隐藏B站会员专属歌曲」这个开关只对 B 站生效：别的平台（QQ / 网易 /
  /// 酷我 / 酷狗）的会员歌只是「需要会员」，未登录还能试听、换音源也可能
  /// 放得出来，不该被静默隐藏。
  bool get isBilibiliSource {
    final src = (displaySource ?? '').toLowerCase();
    return src.contains('bili');
  }

  /// 展示 / 徽标用的音源 id。
  ///
  /// 插件搜索出来的歌，[source] 只记平台 id（播放、歌词等仍按平台处理），
  /// 真正是哪个插件在提供记在 [preferredSource] 里；收藏时绑定的优先插件
  /// 同理。展示层要优先用它，否则「用元力KW 搜出来的歌」会被标成
  /// 「酷我音乐」，看起来像没走插件。
  String? get displaySource {
    final preferred = preferredSource?.trim() ?? '';
    return preferred.isNotEmpty ? preferred : source;
  }

  /// 歌词归属的音源 id。
  ///
  /// 歌词缓存、「删除歌词关联」标记、手动指定的歌词都按它绑定：同一首歌
  /// 换一个音源（插件变体）播放时，各用各的歌词，互不覆盖。和界面显示的
  /// 「当前音源」保持一致，用 [displaySource]。
  String get lyricSourceId => (displaySource ?? '').trim();

  String get displayDuration {
    if (duration <= 0) return '';
    final m = duration ~/ 60;
    final s = duration % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Song copyWith({
    String? id,
    String? title,
    String? artist,
    String? album,
    int? duration,
    String? coverUrl,
    String? sourceUrl,
    String? lyricUrl,
    String? source,
    String? filePath,
    bool? hasCover,
    String? coverKey,
    String? lrc,
    int? bitrate,
    int? sampleRate,
    int? channels,
    int? year,
    int? mediaStoreId,
    String? hash,
    Map<String, dynamic>? lx,
    Map<String, String>? sourceHeaders,
    String? sourceQuality,
    String? genre,
    String? comment,
    bool? hasLyric,
    bool? hasWordLyric,
    String? preferredSource,
    bool? isVipExclusive,
    int? partsCount,
    SongAccess? access,
    bool clearSourceUrl = false,
    bool clearSourceHeaders = false,
    bool clearSourceQuality = false,
    bool clearLrc = false,
    bool clearYear = false,
    bool clearCover = false,
    bool clearPreferredSource = false,
  }) {
    return Song(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      duration: duration ?? this.duration,
      coverUrl: clearCover ? null : coverUrl ?? this.coverUrl,
      sourceUrl: clearSourceUrl ? null : sourceUrl ?? this.sourceUrl,
      lyricUrl: lyricUrl ?? this.lyricUrl,
      source: source ?? this.source,
      filePath: filePath ?? this.filePath,
      hasCover: hasCover ?? this.hasCover,
      coverKey: coverKey ?? this.coverKey,
      lrc: clearLrc ? null : lrc ?? this.lrc,
      bitrate: bitrate ?? this.bitrate,
      sampleRate: sampleRate ?? this.sampleRate,
      channels: channels ?? this.channels,
      year: clearYear ? null : year ?? this.year,
      mediaStoreId: mediaStoreId ?? this.mediaStoreId,
      hash: hash ?? this.hash,
      lx: lx ?? this.lx,
      sourceHeaders: clearSourceHeaders
          ? null
          : sourceHeaders ?? this.sourceHeaders,
      sourceQuality: clearSourceQuality
          ? null
          : sourceQuality ?? this.sourceQuality,
      genre: genre ?? this.genre,
      comment: comment ?? this.comment,
      hasLyric: hasLyric ?? this.hasLyric,
      hasWordLyric: hasWordLyric ?? this.hasWordLyric,
      preferredSource: clearPreferredSource
          ? null
          : preferredSource ?? this.preferredSource,
      isVipExclusive: isVipExclusive ?? this.isVipExclusive,
      partsCount: partsCount ?? this.partsCount,
      access: access ?? this.access,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Song && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  /// Returns a JSON-safe LX payload while preserving nested lists and maps.
  static dynamic _sanitizeLxValue(dynamic value) {
    if (value == null || value is num || value is bool || value is String) {
      return value;
    }
    if (value is List) {
      return value.map(_sanitizeLxValue).toList();
    }
    if (value is Map) {
      final result = <String, dynamic>{};
      value.forEach((key, nested) {
        if (key is String) {
          result[key] = _sanitizeLxValue(nested);
        }
      });
      return result;
    }
    return null;
  }

  static Map<String, dynamic>? _sanitizeLx(Map<String, dynamic>? lx) {
    if (lx == null) return null;
    final value = _sanitizeLxValue(lx);
    return value is Map<String, dynamic> ? value : null;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'album': album,
      'duration': duration,
      'coverUrl': coverUrl,
      'sourceUrl': sourceUrl,
      'lyricUrl': lyricUrl,
      'source': source,
      'filePath': filePath,
      'hasCover': hasCover,
      'coverKey': coverKey,
      'lrc': lrc,
      'bitrate': bitrate,
      'sampleRate': sampleRate,
      'channels': channels,
      'year': year,
      'mediaStoreId': mediaStoreId,
      'hash': hash,
      'lx': _sanitizeLx(lx),
      'sourceHeaders': sourceHeaders,
      'sourceQuality': sourceQuality,
      'genre': genre,
      'comment': comment,
      'hasLyric': hasLyric,
      'hasWordLyric': hasWordLyric,
      'preferredSource': preferredSource,
      'isVipExclusive': isVipExclusive,
      'partsCount': partsCount,
      'access': access.raw,
    };
  }

  /// 持久化专用的瘦身版 JSON。
  ///
  /// [toJson] 会带上整段歌词（`lrc`，逐字歌词一条几十 KB）和请求头
  /// （`sourceHeaders`），落到 playlists.json / playback_state / 最近播放 /
  /// 本地歌曲表里只会让文件与行无谓膨胀，而且：
  ///
  /// * 歌词有专门的临时库缓存（LyricCache），播放时会重新取；
  /// * 请求头跟随播放地址，过期后没有意义。
  ///
  /// 导出 / 分享等需要完整数据的场景仍用 [toJson]。
  Map<String, dynamic> toPersistJson() {
    final json = toJson();
    json.remove('lrc');
    json.remove('sourceHeaders');
    return json;
  }

  factory Song.fromJson(Map<String, dynamic> json) {
    return Song(
      id: json['id'] ?? '',
      title: json['title'] ?? '',
      artist: json['artist'] ?? '',
      album: json['album'] ?? '',
      duration: json['duration'] ?? 0,
      coverUrl: json['coverUrl'],
      sourceUrl: json['sourceUrl'],
      lyricUrl: json['lyricUrl'],
      source: json['source'],
      filePath: json['filePath'],
      hasCover: json['hasCover'] ?? false,
      coverKey: json['coverKey'],
      lrc: json['lrc'],
      bitrate: json['bitrate'],
      sampleRate: json['sampleRate'],
      channels: json['channels'],
      year: json['year'],
      mediaStoreId: json['mediaStoreId'],
      hash: json['hash'],
      lx: json['lx'] is Map ? Map<String, dynamic>.from(json['lx']) : null,
      sourceHeaders: json['sourceHeaders'] is Map
          ? Map<String, String>.from(
              (json['sourceHeaders'] as Map).map(
                (key, value) => MapEntry(key.toString(), value.toString()),
              ),
            )
          : null,
      sourceQuality: json['sourceQuality']?.toString(),
      genre: json['genre']?.toString(),
      comment: json['comment']?.toString(),
      hasLyric: json['hasLyric'] == true,
      hasWordLyric: json['hasWordLyric'] == true,
      preferredSource: json['preferredSource']?.toString(),
      isVipExclusive: json['isVipExclusive'] == true,
      partsCount: (json['partsCount'] as num?)?.toInt() ?? 0,
      access: SongAccess.fromRaw(json['access']?.toString()),
    );
  }
}
