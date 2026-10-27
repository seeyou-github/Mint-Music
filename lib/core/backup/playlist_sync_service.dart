import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../features/library/data/playlist_store.dart';
import 'webdav_service.dart';

/// 歌单跨平台实时同步。
///
/// 远端用一个 JSON 文件保存（不用压缩包，方便同步）：
/// `<WebDAV 根路径>/playlists.json`
///
/// 内容：
/// ```json
/// {
///   "updatedAt": 1700000000000,
///   "deviceName": "手机",
///   "playlists": [ ... ],
///   "deleted": [ { "id": "...", "deletedAt": 1700000000000 } ]
/// }
/// ```
///
/// 同步策略：
/// * 应用启动 / 手动同步时先拉取远端歌单并与本地合并；
/// * 同名歌单按 `updateTime` 取较新的一份；
/// * 删除通过墓碑（`deleted`）传播，避免被另一端的旧数据合并回来；
/// * 合并结果（含本地独有歌单）推回远端。
class PlaylistSyncService {
  const PlaylistSyncService._();

  static const String favoritesId = '__favorites__';

  /// 墓碑保留天数：过期后两端都已同步过删除，可以安全丢弃。
  static const int _tombstoneTtlDays = 90;

  /// 拉取远端歌单并与本地合并，然后把合并结果推回远端。
  ///
  /// 返回本地歌单是否发生了实际变化。
  static Future<bool> pullAndMerge(WebDavService webdav) async {
    // 远端不存在（404）时才返回 null；网络错误会抛异常，绝不能继续 push，
    // 否则会把「读取失败」误当成「远端没有数据」而覆盖远端。
    final remote = await webdav.readRemotePlaylists();
    final localPlaylists = await _readLocalPlaylists();
    final localTombstones = await PlaylistStore.readTombstones();

    final tombstones = <String, int>{...localTombstones};
    if (remote != null) {
      _parseRemoteTombstones(remote).forEach((id, deletedAt) {
        if (deletedAt > (tombstones[id] ?? 0)) tombstones[id] = deletedAt;
      });
    }
    _pruneTombstones(tombstones);

    if (remote == null) {
      final activeTombstones = _activeTombstones(tombstones, localPlaylists);
      await PlaylistStore.writeTombstones(activeTombstones);
      await _pushSnapshot(webdav, localPlaylists, activeTombstones);
      return true;
    }

    final remotePlaylists = remote['playlists'];
    final merged = <String, Map<String, dynamic>>{};

    // 先放入本地歌单；已经被删除（墓碑新于歌单更新时间）的跳过。
    for (final item in localPlaylists) {
      final json = _normalize(item);
      final id = _idOf(json);
      if (id.isEmpty) continue;
      final deletedAt = tombstones[id];
      if (deletedAt != null && deletedAt > _updatedAt(json)) continue;
      merged[id] = json;
    }

    // 合并远端歌单：本地没有的直接加入；两边都有时取较新的一份。
    if (remotePlaylists is List) {
      for (final item in remotePlaylists) {
        if (item is! Map) continue;
        final json = _normalize(item);
        final id = _idOf(json);
        if (id.isEmpty) continue;
        final deletedAt = tombstones[id];
        if (deletedAt != null && deletedAt > _updatedAt(json)) continue;

        final local = merged[id];
        if (local == null) {
          merged[id] = json;
          continue;
        }
        if (id == favoritesId) {
          merged[id] = _mergeFavorites(local, json);
        } else if (_updatedAt(json) > _updatedAt(local)) {
          merged[id] = json;
        }
      }
    }

    final mergedList = _ordered(merged);
    final changed = !_samePlaylists(localPlaylists, mergedList);
    if (changed) {
      await _writeLocalPlaylists(mergedList);
    }

    final activeTombstones = _activeTombstones(tombstones, mergedList);
    if (!_sameTombstones(localTombstones, activeTombstones)) {
      await PlaylistStore.writeTombstones(activeTombstones);
    }
    await _pushSnapshot(webdav, mergedList, activeTombstones);
    return changed;
  }

  static Timer? _debounceTimer;

  /// 本地歌单增删改后的自动推送：5 秒防抖，连续操作只同步最后一次。
  ///
  /// [onStart] / [onFinish] 用于把同步状态同步给界面（窗口底部的同步提示）。
  static void schedulePush(
    WebDavService webdav, {
    void Function()? onStart,
    void Function(bool ok, Object? error)? onFinish,
  }) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(seconds: 5), () {
      _debounceTimer = null;
      unawaited(() async {
        onStart?.call();
        try {
          await push(webdav);
          onFinish?.call(true, null);
        } catch (e) {
          debugPrint('[PlaylistSyncService] 自动同步歌单失败: $e');
          onFinish?.call(false, e);
        }
      }());
    });
  }

  /// 把本地歌单推送到远端（用于本地增删改后的自动同步）。
  static Future<void> push(WebDavService webdav) async {
    final playlists = await _readLocalPlaylists();
    final tombstones = _activeTombstones(
      await PlaylistStore.readTombstones(),
      playlists,
    );
    await _pushSnapshot(webdav, playlists, tombstones);
  }

  static Future<void> _pushSnapshot(
    WebDavService webdav,
    List<Map<String, dynamic>> playlists,
    Map<String, int> tombstones,
  ) async {
    await webdav.writeRemotePlaylists({
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'playlists': playlists,
      'deleted': [
        for (final entry in tombstones.entries)
          {'id': entry.key, 'deletedAt': entry.value},
      ],
    });
  }

  /// 「我的收藏」取较新的一份；但一侧为空、另一侧有歌时保留非空的一侧，
  /// 避免新安装的设备用刚创建的空收藏把远端收藏覆盖掉。
  static Map<String, dynamic> _mergeFavorites(
    Map<String, dynamic> local,
    Map<String, dynamic> remote,
  ) {
    final localSongs = local['songs'] is List
        ? local['songs'] as List
        : const [];
    final remoteSongs = remote['songs'] is List
        ? remote['songs'] as List
        : const [];
    if (localSongs.isEmpty && remoteSongs.isNotEmpty) return remote;
    if (remoteSongs.isEmpty && localSongs.isNotEmpty) return local;
    return _updatedAt(remote) > _updatedAt(local) ? remote : local;
  }

  static List<Map<String, dynamic>> _ordered(
    Map<String, Map<String, dynamic>> byId,
  ) {
    final favorites = byId.remove(favoritesId);
    return [if (favorites != null) favorites, ...byId.values];
  }

  static Map<String, int> _activeTombstones(
    Map<String, int> tombstones,
    List<Map<String, dynamic>> playlists,
  ) {
    final ids = {for (final item in playlists) _idOf(item)};
    return {
      for (final entry in tombstones.entries)
        if (!ids.contains(entry.key)) entry.key: entry.value,
    };
  }

  static void _pruneTombstones(Map<String, int> tombstones) {
    final cutoff = DateTime.now()
        .subtract(const Duration(days: _tombstoneTtlDays))
        .millisecondsSinceEpoch;
    tombstones.removeWhere((_, deletedAt) => deletedAt < cutoff);
  }

  static Map<String, int> _parseRemoteTombstones(Map<String, dynamic> remote) {
    final result = <String, int>{};
    final raw = remote['deleted'];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final id = '${item['id'] ?? ''}';
        final deletedAt = _toMillis(item['deletedAt']);
        if (id.isNotEmpty && deletedAt != null) result[id] = deletedAt;
      }
    } else if (raw is Map) {
      raw.forEach((key, value) {
        final id = '$key';
        final deletedAt = _toMillis(value);
        if (id.isNotEmpty && deletedAt != null) result[id] = deletedAt;
      });
    }
    return result;
  }

  static int? _toMillis(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value');
  }

  static String _idOf(Map<String, dynamic> json) => '${json['id'] ?? ''}';

  static Map<String, dynamic> _normalize(Map<dynamic, dynamic> raw) {
    return raw.map((key, value) => MapEntry('$key', value));
  }

  static Future<List<Map<String, dynamic>>> _readLocalPlaylists() async {
    try {
      return await PlaylistStore.read();
    } catch (e) {
      debugPrint('[PlaylistSyncService] 读取本地歌单失败: $e');
      return const [];
    }
  }

  static Future<void> _writeLocalPlaylists(
    List<Map<String, dynamic>> playlists,
  ) async {
    try {
      await PlaylistStore.write(playlists);
    } catch (e) {
      debugPrint('[PlaylistSyncService] 写回本地歌单失败: $e');
    }
  }

  static bool _samePlaylists(
    List<Map<String, dynamic>> a,
    List<Map<String, dynamic>> b,
  ) {
    if (a.length != b.length) return false;
    final byId = {for (final item in b) _idOf(item): jsonEncode(item)};
    for (final item in a) {
      if (byId[_idOf(item)] != jsonEncode(item)) return false;
    }
    return true;
  }

  static bool _sameTombstones(Map<String, int> a, Map<String, int> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  static int _updatedAt(Map<String, dynamic> json) {
    final parsed = DateTime.tryParse('${json['updateTime'] ?? ''}');
    return parsed?.millisecondsSinceEpoch ?? 0;
  }
}
