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
    this.preferredSource,
    this.isVipExclusive = false,
    this.partsCount = 0,
  });

  bool get isLocal => source == 'local';

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
    String? preferredSource,
    bool? isVipExclusive,
    int? partsCount,
    bool clearSourceUrl = false,
    bool clearSourceHeaders = false,
    bool clearSourceQuality = false,
    bool clearLrc = false,
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
      year: year ?? this.year,
      mediaStoreId: mediaStoreId ?? this.mediaStoreId,
      hash: hash ?? this.hash,
      lx: lx ?? this.lx,
      sourceHeaders: clearSourceHeaders
          ? null
          : sourceHeaders ?? this.sourceHeaders,
      sourceQuality: clearSourceQuality
          ? null
          : sourceQuality ?? this.sourceQuality,
      preferredSource: clearPreferredSource
          ? null
          : preferredSource ?? this.preferredSource,
      isVipExclusive: isVipExclusive ?? this.isVipExclusive,
      partsCount: partsCount ?? this.partsCount,
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
      'preferredSource': preferredSource,
      'isVipExclusive': isVipExclusive,
      'partsCount': partsCount,
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
      preferredSource: json['preferredSource']?.toString(),
      isVipExclusive: json['isVipExclusive'] == true,
      partsCount: (json['partsCount'] as num?)?.toInt() ?? 0,
    );
  }
}
