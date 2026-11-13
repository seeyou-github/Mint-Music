import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../storage/app_preferences.dart';

/// 歌单同步新协议（内容寻址 + 版本描述文件）。
///
/// 远端只保留一个很小的 [PlaylistMeta]（`playlists.meta.json`）作为唯一指针，
/// 真正的歌单数据放在以内容摘要命名的不可变快照里
/// （`playlists.<sha256>.json.gz`）。写入顺序固定为「先数据、后指针」，
/// 所以指针在任何时刻都指向一份完整数据，不会出现「版本已递增但数据没传完」。
const int playlistMetaSchema = 1;
const int playlistSnapshotSchema = 3;

const String playlistMetaFileName = 'playlists.meta.json';

final RegExp _digestPattern = RegExp(r'^[0-9a-f]{64}$');
final RegExp _snapshotNamePattern = RegExp(
  r'^playlists\.([0-9a-f]{64})\.json\.gz$',
);

String playlistSnapshotFileName(String digest) => 'playlists.$digest.json.gz';

/// 从快照文件名里取回 digest；不是新协议的快照文件返回 null。
///
/// 旧版 `playlists.json.gz` 不是 64 位十六进制，会被自然排除，GC / 恢复
/// 都不会误删它。
String? snapshotDigestOf(String fileName) =>
    _snapshotNamePattern.firstMatch(fileName)?.group(1);

bool isPlaylistSnapshotFile(String fileName) =>
    _snapshotNamePattern.hasMatch(fileName);

/// 远端版本描述文件来自更新版本的客户端，当前版本无法识别。
///
/// 与普通格式损坏区分开：前者不能尝试「重建指针」，否则会用旧格式覆盖新
/// 客户端的数据。
class PlaylistSchemaException extends FormatException {
  const PlaylistSchemaException(super.message);
}

/// 远端版本描述文件：约 200~300 字节，不压缩。
///
/// [etag] 只存在于内存中（来自 GET 响应头），用于条件写 `If-Match`，不写进 JSON。
class PlaylistMeta {
  const PlaylistMeta({
    required this.epoch,
    required this.revision,
    required this.digest,
    required this.size,
    required this.updatedAt,
    required this.writer,
    this.etag,
  });

  /// 数据集标识：远端被重置 / 换成另一个账号时换新值，避免旧基线误判。
  final String epoch;

  /// 单调递增的修订号（Lamport 时钟）：每次成功回推 +1。
  final int revision;

  /// 当前快照 gzip 字节的 sha256，同时是数据文件名的一部分。
  final String digest;

  /// 当前快照的字节数。
  final int size;

  final int updatedAt;
  final String writer;
  final String? etag;

  factory PlaylistMeta.fromText(String text, {String? etag}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (e) {
      throw const FormatException('版本描述文件不是有效的 JSON');
    }
    if (decoded is! Map) {
      throw const FormatException('版本描述文件不是 JSON 对象');
    }
    final schema = decoded['schema'];
    if (schema != playlistMetaSchema) {
      throw PlaylistSchemaException(
        '版本描述文件不兼容（schema=$schema），请升级客户端后再同步',
      );
    }
    final epoch = decoded['epoch'];
    final digest = decoded['digest'];
    final revision = decoded['revision'];
    final size = decoded['size'];
    if (epoch is! String || epoch.isEmpty) {
      throw const FormatException('版本描述文件缺少 epoch');
    }
    // digest 会拼进远端文件名，必须限定成 sha256 十六进制，避免异常数据把
    // 读取路径带到目录之外。
    if (digest is! String || !_digestPattern.hasMatch(digest)) {
      throw const FormatException('版本描述文件的 digest 非法');
    }
    if (revision is! int || revision < 1 || size is! int || size < 0) {
      throw const FormatException('版本描述文件的 revision / size 非法');
    }
    return PlaylistMeta(
      epoch: epoch,
      revision: revision,
      digest: digest,
      size: size,
      updatedAt: decoded['updatedAt'] is int ? decoded['updatedAt'] as int : 0,
      writer: '${decoded['writer'] ?? ''}',
      etag: etag,
    );
  }

  /// 生成下一版：只在数据文件上传成功之后调用。
  PlaylistMeta next({
    required String digest,
    required int size,
    required String writer,
  }) => PlaylistMeta(
    epoch: epoch,
    revision: revision + 1,
    digest: digest,
    size: size,
    updatedAt: DateTime.now().millisecondsSinceEpoch,
    writer: writer,
  );

  static PlaylistMeta initial({
    required String epoch,
    required String digest,
    required int size,
    required String writer,
  }) => PlaylistMeta(
    epoch: epoch,
    revision: 1,
    digest: digest,
    size: size,
    updatedAt: DateTime.now().millisecondsSinceEpoch,
    writer: writer,
  );

  Map<String, dynamic> toJson() => {
    'schema': playlistMetaSchema,
    'epoch': epoch,
    'revision': revision,
    'digest': digest,
    'size': size,
    'updatedAt': updatedAt,
    'writer': writer,
  };
}

/// 快照的构建 / 编码 / 摘要。
///
/// 规范化很重要：`updatedAt`、`deviceName` 这类每次都变的字段不进快照，
/// 墓碑按 key 排序，语义相同的内容才会算出同一个 digest；否则「什么都没改」
/// 也会产生新文件、白白递增 revision。歌单与歌曲的顺序是用户数据，原样保留。
class PlaylistSnapshot {
  const PlaylistSnapshot._();

  static Map<String, dynamic> build({
    required List<Map<String, dynamic>> playlists,
    required Map<String, int> playlistTombstones,
    required Map<String, Map<String, int>> songTombstones,
  }) {
    final playlistIds = playlistTombstones.keys.toList()..sort();
    final deleted = <Map<String, dynamic>>[
      for (final id in playlistIds)
        {'id': id, 'deletedAt': playlistTombstones[id]},
    ];
    final playlistKeys = songTombstones.keys.toList()..sort();
    final deletedSongs = <Map<String, dynamic>>[];
    for (final playlistId in playlistKeys) {
      final songs = songTombstones[playlistId] ?? const <String, int>{};
      final songIds = songs.keys.toList()..sort();
      for (final songId in songIds) {
        deletedSongs.add({
          'playlistId': playlistId,
          'songId': songId,
          'deletedAt': songs[songId],
        });
      }
    }
    return {
      'schema': playlistSnapshotSchema,
      'playlists': playlists,
      'deleted': deleted,
      'deletedSongs': deletedSongs,
    };
  }

  static Uint8List encode(Map<String, dynamic> snapshot) =>
      Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode(snapshot))));

  /// 内容摘要：对**未压缩**的规范化 JSON 取 sha256。
  ///
  /// 不用 gzip 字节：压缩结果依赖 zlib 实现 / 版本，跨平台或升级引擎后同样
  /// 的内容可能算出不同摘要，会让「合并结果与远端相同」的判断失效。下载
  /// 校验时先解压再算，同样与压缩格式无关。
  static String digestOf(Map<String, dynamic> snapshot) =>
      sha256.convert(utf8.encode(jsonEncode(snapshot))).toString();

  /// 本地数据指纹：与 [digestOf] 是同一份摘要，语义上表示
  /// 「本地自上次同步后有没有变」。
  static String fingerprintOf(Map<String, dynamic> snapshot) =>
      digestOf(snapshot);

  /// 快照内容是否对应 [digest]。
  ///
  /// 额外接受上一版「对 gzip 字节取 sha256」的摘要：升级前写到远端的快照
  /// 只有这种摘要，不认它会让这些快照永远无法下载（下次推送会自动换成新摘要）。
  static bool matchesDigest(
    Map<String, dynamic> snapshot,
    Uint8List bytes,
    String digest,
  ) {
    if (digestOf(snapshot) == digest) return true;
    return sha256.convert(bytes).toString() == digest;
  }

  static Map<String, dynamic> decode(Uint8List bytes) {
    final List<int> raw;
    try {
      raw = gzip.decode(bytes);
    } catch (e) {
      throw const FormatException('远端歌单快照不是有效的 gzip 数据');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(raw));
    } catch (e) {
      throw const FormatException('远端歌单快照不是有效的 JSON');
    }
    if (decoded is! Map ||
        decoded['schema'] != playlistSnapshotSchema ||
        decoded['playlists'] is! List) {
      throw const FormatException('远端歌单快照格式不兼容');
    }
    return decoded.map((key, value) => MapEntry('$key', value));
  }
}

/// 本机记录的「上次成功同步基线」。
class PlaylistSyncState {
  const PlaylistSyncState({
    required this.epoch,
    required this.revision,
    required this.digest,
    required this.localFingerprint,
  });

  final String epoch;
  final int revision;
  final String digest;

  /// 上次同步结束时本地数据的规范化摘要；重算后不同就说明本地有改动
  /// （还原备份 / 清库 / 导入都算），不依赖每个增删改调用点打标记。
  final String localFingerprint;

  factory PlaylistSyncState.fromJson(Map<dynamic, dynamic> json) {
    final epoch = json['epoch'];
    final digest = json['digest'];
    final fingerprint = json['localFingerprint'];
    final revision = json['revision'];
    if (epoch is! String ||
        digest is! String ||
        !_digestPattern.hasMatch(digest) ||
        fingerprint is! String ||
        revision is! int ||
        revision < 1) {
      throw const FormatException('本地同步状态格式非法');
    }
    return PlaylistSyncState(
      epoch: epoch,
      revision: revision,
      digest: digest,
      localFingerprint: fingerprint,
    );
  }

  Map<String, dynamic> toJson() => {
    'epoch': epoch,
    'revision': revision,
    'digest': digest,
    'localFingerprint': localFingerprint,
  };

  PlaylistSyncState copyWith({
    String? epoch,
    int? revision,
    String? digest,
    String? localFingerprint,
  }) => PlaylistSyncState(
    epoch: epoch ?? this.epoch,
    revision: revision ?? this.revision,
    digest: digest ?? this.digest,
    localFingerprint: localFingerprint ?? this.localFingerprint,
  );
}

class PlaylistSyncStateStore {
  const PlaylistSyncStateStore._();

  static const String _stateKey = 'playlist_sync_state_v3';
  static const String _deviceKey = 'playlist_sync_device_id';

  static Future<PlaylistSyncState?> load() async {
    final prefs = await AppPreferences.getInstance();
    final raw = prefs.getString(_stateKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return PlaylistSyncState.fromJson(decoded);
    } catch (_) {
      // 状态损坏就当作「没有基线」，下次同步会走全量合并，不会误判无变化。
      return null;
    }
  }

  static Future<void> save(PlaylistSyncState state) async {
    final prefs = await AppPreferences.getInstance();
    await prefs.setString(_stateKey, jsonEncode(state.toJson()));
  }

  /// 稳定的设备 id（`deviceName` 用户可改、可重复，不能当 writer）。
  static Future<String> deviceId() async {
    final prefs = await AppPreferences.getInstance();
    final existing = prefs.getString(_deviceKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final id = const Uuid().v4();
    await prefs.setString(_deviceKey, id);
    return id;
  }
}

/// 一次同步要走哪条路径（纯函数，方便单测）。
enum SyncAction {
  /// 远端与本地基线一致、本地也没有改动：连完整快照都不用下载。
  noop,

  /// 远端与本地基线一致、只有本地有改动：直接用本地数据生成新快照回推。
  pushLocal,

  /// 远端有变化（或首次同步）：下载完整快照、合并、按需回推。
  pullAndMerge,
}

/// [localHasContent] 表示本地是否真的有歌单内容（歌曲或自建歌单）。
///
/// 本地只剩一张空收藏、却有「本地有改动」的基线时，不能直接回推：那通常
/// 意味着数据库降级成内存库 / 数据被清空，推上去会把远端歌单整份覆盖掉。
/// 这种可疑情况强制走合并，由远端内容兜底。
SyncAction decideSyncAction({
  required PlaylistMeta? meta,
  required PlaylistSyncState? state,
  required bool localDirty,
  bool localHasContent = true,
}) {
  if (meta == null) return SyncAction.pushLocal;
  if (state == null ||
      state.epoch != meta.epoch ||
      state.revision != meta.revision ||
      state.digest != meta.digest) {
    return SyncAction.pullAndMerge;
  }
  if (!localDirty) return SyncAction.noop;
  return localHasContent ? SyncAction.pushLocal : SyncAction.pullAndMerge;
}
