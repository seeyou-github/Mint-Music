import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../storage/app_preferences.dart';

/// 附加数据同步（`extras`）与播放进度同步（`progress`）共用的快照协议。
///
/// 与歌单同步（`playlist_sync_protocol.dart`）是同一套思路：远端只有一份很小的
/// 版本描述文件 `<base>.meta.json` 作为唯一指针，真实数据放在以内容摘要命名的
/// 不可变快照 `<base>.<sha256>.json.gz` 里，写入顺序固定为「先数据、后指针」。
///
/// 歌单协议保持原样不动：它有自己的 schema、墓碑格式和旧版迁移逻辑，抽成
/// 泛型只会把两边的兼容分支搅在一起。这里只覆盖新增的两份数据。
const int dataSnapshotSchema = 1;

final RegExp _digestPattern = RegExp(r'^[0-9a-f]{64}$');

String dataMetaFileName(String base) => '$base.meta.json';

String dataSnapshotFileName(String base, String digest) => '$base.$digest.json.gz';

String? dataSnapshotDigestOf(String base, String fileName) {
  final pattern = RegExp(
    '^${RegExp.escape(base)}\\.([0-9a-f]{64})\\.json\\.gz\$',
  );
  return pattern.firstMatch(fileName)?.group(1);
}

/// 远端版本描述文件来自不兼容的版本。
class DataSnapshotSchemaException extends FormatException {
  const DataSnapshotSchemaException(super.message);
}

/// 通用版本描述文件（约 200~300 字节，不压缩）。
class DataSnapshotMeta {
  const DataSnapshotMeta({
    required this.epoch,
    required this.revision,
    required this.digest,
    required this.size,
    required this.updatedAt,
    required this.writer,
    this.etag,
  });

  /// 数据集标识：远端被重置 / 换成另一个账号时换新值。
  final String epoch;

  /// 单调递增的修订号，每次成功回推 +1。
  final int revision;

  /// 当前快照 gzip 字节对应内容的 sha256（对未压缩 JSON 取摘要）。
  final String digest;

  final int size;
  final int updatedAt;
  final String writer;

  /// 仅存在于内存，来自 GET 响应头，用于 `If-Match`。
  final String? etag;

  factory DataSnapshotMeta.fromText(String text, {String? etag}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      throw const FormatException('版本描述文件不是有效的 JSON');
    }
    if (decoded is! Map) {
      throw const FormatException('版本描述文件不是 JSON 对象');
    }
    final schema = decoded['schema'];
    if (schema != dataSnapshotSchema) {
      throw DataSnapshotSchemaException(
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
    if (digest is! String || !_digestPattern.hasMatch(digest)) {
      throw const FormatException('版本描述文件的 digest 非法');
    }
    if (revision is! int || revision < 1 || size is! int || size < 0) {
      throw const FormatException('版本描述文件的 revision / size 非法');
    }
    return DataSnapshotMeta(
      epoch: epoch,
      revision: revision,
      digest: digest,
      size: size,
      updatedAt: decoded['updatedAt'] is int ? decoded['updatedAt'] as int : 0,
      writer: '${decoded['writer'] ?? ''}',
      etag: etag,
    );
  }

  DataSnapshotMeta next({
    required String digest,
    required int size,
    required String writer,
  }) => DataSnapshotMeta(
    epoch: epoch,
    revision: revision + 1,
    digest: digest,
    size: size,
    updatedAt: DateTime.now().millisecondsSinceEpoch,
    writer: writer,
  );

  static DataSnapshotMeta initial({
    required String digest,
    required int size,
    required String writer,
  }) => DataSnapshotMeta(
    epoch: const Uuid().v4(),
    revision: 1,
    digest: digest,
    size: size,
    updatedAt: DateTime.now().millisecondsSinceEpoch,
    writer: writer,
  );

  Map<String, dynamic> toJson() => {
    'schema': dataSnapshotSchema,
    'epoch': epoch,
    'revision': revision,
    'digest': digest,
    'size': size,
    'updatedAt': updatedAt,
    'writer': writer,
  };
}

/// 快照的编码 / 摘要 / 解码校验。
///
/// 摘要对**未压缩**的规范化 JSON 取 sha256（理由同歌单协议：gzip 字节依赖
/// zlib 实现，跨平台不稳定）。
class DataSnapshotCodec {
  const DataSnapshotCodec._();

  static String digestOf(Map<String, dynamic> snapshot) =>
      sha256.convert(utf8.encode(jsonEncode(snapshot))).toString();

  /// 与 [digestOf] 结果一致，但把 `jsonEncode + sha256` 丢到后台 isolate。
  ///
  /// 播放进度快照可能上万条，主 isolate 上编码 + 摘要会有肉眼可见的卡顿
  /// （同步可能在播放过程中触发）。附加数据很小，用同步版即可。
  static Future<String> digestOfAsync(Map<String, dynamic> snapshot) =>
      Isolate.run(() => digestOf(snapshot));

  static Future<(Uint8List, String)> encodeAndDigest(
    Map<String, dynamic> snapshot,
  ) {
    return Isolate.run(() {
      final json = jsonEncode(snapshot);
      return (
        Uint8List.fromList(gzip.encode(utf8.encode(json))),
        sha256.convert(utf8.encode(json)).toString(),
      );
    });
  }

  static Map<String, dynamic> decode(Uint8List bytes, {required int schema}) {
    final List<int> raw;
    try {
      raw = gzip.decode(bytes);
    } catch (_) {
      throw const FormatException('远端快照不是有效的 gzip 数据');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(raw));
    } catch (_) {
      throw const FormatException('远端快照不是有效的 JSON');
    }
    if (decoded is! Map || decoded['schema'] != schema) {
      throw const FormatException('远端快照格式不兼容');
    }
    return decoded.map((key, value) => MapEntry('$key', value));
  }

  static Future<Map<String, dynamic>> decodeAndVerify(
    Uint8List bytes,
    String digest, {
    required int schema,
    String mismatchMessage = '快照内容摘要不匹配',
  }) {
    return Isolate.run(() {
      final snapshot = decode(bytes, schema: schema);
      if (digestOf(snapshot) != digest) {
        throw FormatException(mismatchMessage);
      }
      return snapshot;
    });
  }
}

/// 本机记录的「上次成功同步基线」。
class DataSyncState {
  const DataSyncState({
    required this.epoch,
    required this.revision,
    required this.digest,
    required this.localFingerprint,
  });

  final String epoch;
  final int revision;
  final String digest;

  /// 上次同步结束时本地数据的规范化摘要；重算后不同就说明本地有改动。
  final String localFingerprint;

  factory DataSyncState.fromJson(Map<dynamic, dynamic> json) {
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
    return DataSyncState(
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
}

/// 按数据集名保存基线（`extras_sync_state_v1` / `progress_sync_state_v1`）。
class DataSyncStateStore {
  const DataSyncStateStore._();

  static String _key(String kind) => '${kind}_sync_state_v1';

  static Future<DataSyncState?> load(String kind) async {
    final prefs = await AppPreferences.getInstance();
    final raw = prefs.getString(_key(kind));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return DataSyncState.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(String kind, DataSyncState state) async {
    final prefs = await AppPreferences.getInstance();
    await prefs.setString(_key(kind), jsonEncode(state.toJson()));
  }
}

/// 稳定的设备 id（歌手 / 附加数据与歌单共用同一个）。
Future<String> syncDeviceId() async {
  final prefs = await AppPreferences.getInstance();
  const key = 'playlist_sync_device_id';
  final existing = prefs.getString(key);
  if (existing != null && existing.isNotEmpty) return existing;
  final id = const Uuid().v4();
  await prefs.setString(key, id);
  return id;
}