import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../features/player/data/play_progress_store.dart';
import '../storage/app_preferences.dart';
import 'data_snapshot.dart';
import 'webdav_service.dart';

/// 播放进度跨平台同步。
///
/// 远端布局与 [ExtrasSyncService] 相同：
/// `progress.meta.json` + `progress.<sha256>.json.gz`。
///
/// 合并规则比歌单简单：同一首歌取更大的 `ratio`（「最远听到哪」只增不减），
/// 时间戳只用来给「清空进度」划界（`clearedAt`），不做逐条 LWW。
///
/// 触发与节流由 [DataSyncCoordinator] 负责：切歌 / 暂停 / 停止 / 退出 /
/// 自然播完时才记录一次进度，自动推送最小间隔 10 分钟，失败后同样等 10 分钟。
class ProgressSyncService {
  const ProgressSyncService._();

  static const String baseName = 'progress';
  static const int _maxSyncAttempts = 4;

  /// 清空进度的时间（毫秒时间戳）：云端比它旧的记录全部作废。
  ///
  /// 存在 settings.json 里（用户主动操作，跟着设置一起备份 / 还原）。
  static const String clearedAtKey = 'play_progress_cleared_at_v1';

  /// 串行化：自动推送 / 手动同步可能同时进来。
  static Future<void> _chain = Future<void>.value();

  /// 同步入口：拉取远端、合并、必要时回推。返回本地数据库是否被改动。
  static Future<bool> pullAndMerge(WebDavService webdav) {
    final result = _chain.then((_) => _syncAllAttempts(webdav));
    _chain = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  static Future<bool> _syncAllAttempts(WebDavService webdav) async {
    final writer = await syncDeviceId();
    for (var attempt = 0; attempt < _maxSyncAttempts; attempt++) {
      try {
        return await _syncOnce(webdav, writer);
      } on WebDavException catch (e) {
        if (e.statusCode == 412 && attempt + 1 < _maxSyncAttempts) {
          _throwIfCancelled(webdav);
          debugPrint('[ProgressSync] 云端版本被其它设备抢先更新，重新合并');
          continue;
        }
        rethrow;
      }
    }
    return false;
  }

  static Future<bool> _syncOnce(WebDavService webdav, String writer) async {
    final clearedAt = await clearedAtOf();
    final localItems = await _localItems();
    // 本地音乐不保存播放进度：远端快照里可能还有旧版本写入的本地记录，
    // 合并时排除，回推的快照也就不再含它们——云端文件随之清理干净。
    final excludeIds = await PlayProgressStore.localSongIds();
    final localDigest = await DataSnapshotCodec.digestOfAsync(
      _buildSnapshot(localItems, clearedAt),
    );

    DataSnapshotMeta? meta;
    var metaCorrupt = false;
    try {
      meta = await webdav.readDataMeta(baseName);
    } on DataSnapshotSchemaException {
      rethrow;
    } on FormatException catch (e) {
      metaCorrupt = true;
      debugPrint('[ProgressSync] 远端版本描述不可用: $e');
    }
    _throwIfCancelled(webdav);
    if (meta == null && metaCorrupt) {
      throw const WebDavException('远端进度版本描述损坏，请删除远端 progress.meta.json 后重试');
    }

    // 远端没变且本地也没变：直接结束，不下载快照。
    if (meta != null && meta.digest == localDigest) return false;

    var mergedItems = localItems;
    var mergedClearedAt = clearedAt;
    if (meta != null) {
      final remote = await webdav.readDataSnapshot(baseName, meta);
      _throwIfCancelled(webdav);
      final parsed = _parseSnapshot(remote);
      mergedClearedAt = math.max(clearedAt, parsed.clearedAt);
      mergedItems = _mergeItems(
        localItems,
        parsed.items,
        clearedAt: mergedClearedAt,
        excludeSongIds: excludeIds,
      );
    }
    _throwIfCancelled(webdav);

    final changed = await PlayProgressStore.mergeRemote(
      mergedItems,
      clearedAt: mergedClearedAt,
    );
    // 远端清空时间更晚时写回本地：否则本机的 clearedAt 永远落后，
    // 每轮同步都要重下一份快照才能算出同样的摘要（不清空则不受影响）。
    if (mergedClearedAt > clearedAt) {
      await saveClearedAt(mergedClearedAt);
    }

    final snapshot = _buildSnapshot(mergedItems, mergedClearedAt);
    final digest = await DataSnapshotCodec.digestOfAsync(snapshot);
    if (meta != null && meta.digest == digest) return changed;

    // 先数据后指针：远端指向的快照永远完整可读。
    final (compressed, encodedDigest) = await DataSnapshotCodec.encodeAndDigest(
      snapshot,
    );
    _throwIfCancelled(webdav);
    final next = meta == null
        ? DataSnapshotMeta.initial(
            digest: encodedDigest,
            size: compressed.length,
            writer: writer,
          )
        : meta.next(
            digest: encodedDigest,
            size: compressed.length,
            writer: writer,
          );
    await webdav.writeDataSnapshot(baseName, encodedDigest, compressed);
    _throwIfCancelled(webdav);
    await webdav.writeDataMeta(baseName, next, expected: meta);
    unawaited(webdav.gcDataSnapshots(baseName, encodedDigest));
    return changed;
  }

  // ------------------------------------------------------------ 快照

  static Future<List<Map<String, dynamic>>> _localItems() async {
    final snapshot = await PlayProgressStore.exportSnapshot();
    return _parseItems(snapshot['progress']);
  }

  static Map<String, dynamic> _buildSnapshot(
    List<Map<String, dynamic>> items,
    int clearedAt,
  ) {
    final sorted = [...items]
      ..sort((a, b) => '${a['songId']}'.compareTo('${b['songId']}'));
    return {
      'schema': dataSnapshotSchema,
      'clearedAt': clearedAt,
      'items': sorted,
    };
  }

  static _ParsedProgress _parseSnapshot(Map<String, dynamic> snapshot) {
    final raw = snapshot['clearedAt'];
    return _ParsedProgress(
      clearedAt: raw is int && raw > 0 ? raw : 0,
      items: _parseItems(snapshot['items']),
    );
  }

  static List<Map<String, dynamic>> _parseItems(Object? raw) {
    if (raw is! List) return const [];
    final items = <Map<String, dynamic>>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final songId = '${item['songId'] ?? ''}';
      final ratio = (item['ratio'] as num?)?.toDouble() ?? 0;
      if (songId.isEmpty || ratio <= 0) continue;
      items.add({
        'songId': songId,
        'ratio': ratio.clamp(0.0, 1.0),
        'positionMs': (item['positionMs'] as num?)?.toInt() ?? 0,
        'durationMs': (item['durationMs'] as num?)?.toInt() ?? 0,
        'updatedAt': (item['updatedAt'] as num?)?.toInt() ?? 0,
      });
    }
    return items;
  }

  /// 逐歌取较大进度；`updatedAt <= clearedAt` 的记录已被清空，不保留；
  /// [excludeSongIds] 里的本地歌曲（升级前同步文件可能还留着）同样不保留。
  static List<Map<String, dynamic>> _mergeItems(
    List<Map<String, dynamic>> local,
    List<Map<String, dynamic>> remote, {
    required int clearedAt,
    required Set<String> excludeSongIds,
  }) {
    final byId = <String, Map<String, dynamic>>{
      for (final item in local) '${item['songId']}': item,
    };
    for (final item in remote) {
      final songId = '${item['songId']}';
      if (excludeSongIds.contains(songId)) continue;
      final current = byId[songId];
      if (current == null) {
        byId[songId] = item;
        continue;
      }
      final currentRatio = (current['ratio'] as num?)?.toDouble() ?? 0;
      final ratio = (item['ratio'] as num?)?.toDouble() ?? 0;
      final currentUpdated = (current['updatedAt'] as num?)?.toInt() ?? 0;
      final updated = (item['updatedAt'] as num?)?.toInt() ?? 0;
      if (ratio > currentRatio ||
          (ratio == currentRatio && updated > currentUpdated)) {
        byId[songId] = item;
      }
    }
    byId.removeWhere(
      (_, item) => ((item['updatedAt'] as num?)?.toInt() ?? 0) <= clearedAt,
    );
    return byId.values.toList(growable: false);
  }

  // ------------------------------------------------------------ 清空

  /// 「最近播放」页清空进度时调用：记下时间，云端旧记录同时作废。
  static Future<void> markCleared() async {
    final prefs = await AppPreferences.getInstance();
    await prefs.setInt(clearedAtKey, DateTime.now().millisecondsSinceEpoch);
  }

  /// 合并时远端 `clearedAt` 更晚：把本地划界同步过来，避免每轮重复下载。
  static Future<void> saveClearedAt(int timestamp) async {
    final prefs = await AppPreferences.getInstance();
    await prefs.setInt(clearedAtKey, timestamp);
  }

  static Future<int> clearedAtOf() async {
    final prefs = await AppPreferences.getInstance();
    return prefs.getInt(clearedAtKey) ?? 0;
  }

  static void _throwIfCancelled(WebDavService webdav) {
    if (webdav.isCancelled) {
      throw const WebDavException('同步已停止');
    }
  }
}

class _ParsedProgress {
  const _ParsedProgress({required this.clearedAt, required this.items});

  final int clearedAt;
  final List<Map<String, dynamic>> items;
}
