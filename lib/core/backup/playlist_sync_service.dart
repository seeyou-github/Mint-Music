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
/// { "updatedAt": 1700000000000, "deviceName": "手机", "playlists": [ ... ] }
/// ```
///
/// 同步策略：
/// * 应用启动时先拉取远端歌单并与本地合并（远端同一首歌单更新则覆盖本地）；
/// * 之后任何一端对歌单增删改，都会把合并结果推回远端。
class PlaylistSyncService {
  const PlaylistSyncService._();

  /// 拉取远端歌单并与本地合并。
  ///
  /// 返回是否发生了实际变化（用于决定要不要回推远端）。
  static Future<bool> pullAndMerge(WebDavService webdav) async {
    final remote = await webdav.readRemotePlaylists();
    if (remote == null) {
      // 远端还没有歌单文件：把本地的推上去。
      await push(webdav);
      return true;
    }

    final remotePlaylists = (remote['playlists'] as List?) ?? const [];
    final localPlaylists = await _readLocalPlaylists();

    final localById = <String, Map<String, dynamic>>{
      for (final item in localPlaylists) '${item['id'] ?? ''}': item,
    };

    var changed = false;
    final merged = <Map<String, dynamic>>[];

    // 远端优先：远端更新的歌单覆盖本地。
    for (final item in remotePlaylists) {
      if (item is! Map) continue;
      final json = item.map((k, v) => MapEntry('$k', v));
      final id = '${json['id'] ?? ''}';
      if (id.isEmpty) continue;
      final local = localById[id];
      if (local == null) {
        merged.add(json);
        changed = true;
        continue;
      }
      if (_updatedAt(json) > _updatedAt(local)) {
        merged.add(json);
        changed = true;
      } else {
        merged.add(local);
      }
      localById.remove(id);
    }

    // 只在本地有的歌单也保留（稍后一起推回远端）。
    merged.addAll(localById.values);

    if (changed) {
      await _writeLocalPlaylists(merged);
    }
    // 合并结果推回远端（保证另一端能拿到本地的歌单）。
    await push(webdav);
    return changed;
  }

  /// 把本地歌单推送到远端。
  static Future<void> push(WebDavService webdav) async {
    final playlists = await _readLocalPlaylists();
    await webdav.writeRemotePlaylists({
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'playlists': playlists,
    });
  }

  /// 读取本地歌单（收藏 JSON 文件）。
  static Future<List<Map<String, dynamic>>> _readLocalPlaylists() async {
    try {
      return await PlaylistStore.read();
    } catch (e) {
      debugPrint('[PlaylistSyncService] 读取本地歌单失败: $e');
      return const [];
    }
  }

  /// 把合并结果写回本地收藏文件。
  static Future<void> _writeLocalPlaylists(
    List<Map<String, dynamic>> playlists,
  ) async {
    try {
      await PlaylistStore.write(playlists);
    } catch (e) {
      debugPrint('[PlaylistSyncService] 写回本地歌单失败: $e');
    }
  }

  static int _updatedAt(Map<String, dynamic> json) {
    final parsed = DateTime.tryParse('${json['updateTime'] ?? ''}');
    return parsed?.millisecondsSinceEpoch ?? 0;
  }
}
