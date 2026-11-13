import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../features/library/data/playlist_repository.dart';
import '../../features/library/data/playlist_store.dart';
import 'playlist_merge.dart';
import 'sync_timeout.dart';
import 'webdav_service.dart';

/// 歌单跨平台同步。
///
/// 远端用一个（gzip 压缩的）JSON 文件保存：
/// `<WebDAV 根路径>/playlists.json.gz`
///
/// 内容：
/// ```json
/// {
///   "version": 2,
///   "updatedAt": 1700000000000,
///   "deviceName": "手机",
///   "playlists": [
///     { "id": "...", "name": "...", "updateTime": "...",
///       "meta": { "metaUpdatedAt": 1700000000000 },
///       "songs": [ { "...": "...", "updatedAt": 1700000000000 } ] }
///   ],
///   "deleted": [ { "id": "...", "deletedAt": 1700000000000 } ],
///   "deletedSongs": [ { "playlistId": "...", "songId": "...", "deletedAt": 1 } ]
/// }
/// ```
///
/// 合并策略：
/// * **歌单**：按 id 对齐，删除的靠歌单级墓碑传播；
/// * **歌单信息**（名字 / 封面 / 描述）：看 `meta.metaUpdatedAt`（没有时回退
///   `updateTime`）取较新的一份，时间相同按内容比较，保证两端算出同一个赢家；
/// * **歌曲**：按 `songId` 求并集，同 id 取 `updatedAt` 较新的那份；排序用赢家
///   歌单的顺序，另一侧独有的歌按原顺序追加；
/// * **歌曲删除**靠歌曲级墓碑传播，否则「这台删了、那台还有」每次同步都会
///   把歌加回来。
///
/// 具体合并算法在 [PlaylistMerge]（纯 Dart，可直接单测）。
class PlaylistSyncService {
  const PlaylistSyncService._();

  static const String favoritesId = '__favorites__';

  /// 墓碑保留天数：过期后两端都已同步过删除，可以安全丢弃。
  static const int _tombstoneTtlDays = 90;

  /// 拉取远端歌单并与本地合并，然后把合并结果推回远端。
  ///
  /// 返回本地歌单是否发生了实际变化。
  ///
  /// [webdav] 带取消令牌时（见 `SyncAttempt`）：用户中途停止同步会让请求以
  /// `DioException(cancel)` 失败，这里会把已经写了一半的本地歌单 / 墓碑还原成
  /// 同步前的内容，再抛出异常，避免留下「合并到一半」的状态。
  static Future<bool> pullAndMerge(WebDavService webdav) async {
    // 远端不存在（404）时才返回 null；网络错误会抛异常，绝不能继续 push，
    // 否则会把「读取失败」误当成「远端没有数据」而覆盖远端。
    final remote = await webdav.readRemotePlaylists();
    _throwIfCancelled(webdav);

    final repo = PlaylistRepository();
    final localPlaylists = await repo.exportAll();
    final localPlaylistTombstones = await PlaylistStore.readTombstones();
    final localSongTombstones = await PlaylistStore.readSongTombstones();

    // 本次同步实际写下去的内容：中止回滚前用它确认「本地没被别处改过」。
    List<Map<String, dynamic>>? writtenPlaylists;
    Map<String, int>? writtenPlaylistTombstones;
    Map<String, Map<String, int>>? writtenSongTombstones;

    try {
      final playlistTombstones = <String, int>{...localPlaylistTombstones};
      final songTombstones = _copySongTombstones(localSongTombstones);

      if (remote != null) {
        _parsePlaylistTombstones(remote).forEach((id, deletedAt) {
          if (deletedAt > (playlistTombstones[id] ?? 0)) {
            playlistTombstones[id] = deletedAt;
          }
        });
        _parseSongTombstones(remote).forEach((playlistId, songs) {
          final target = songTombstones.putIfAbsent(playlistId, () => {});
          songs.forEach((songId, deletedAt) {
            if (deletedAt > (target[songId] ?? 0)) {
              target[songId] = deletedAt;
            }
          });
        });
      }
      _prunePlaylistTombstones(playlistTombstones);
      _pruneSongTombstones(songTombstones);

      // 远端还没有歌单文件：把本地这份原样推上去（首次同步）。
      if (remote == null) {
        final activePlaylists = _activePlaylistTombstones(
          playlistTombstones,
          localPlaylists,
        );
        final activeSongs = _activeSongTombstones(
          songTombstones,
          localPlaylists,
        );
        _throwIfCancelled(webdav);
        await PlaylistStore.writeTombstones(activePlaylists);
        writtenPlaylistTombstones = activePlaylists;
        await PlaylistStore.writeSongTombstones(activeSongs);
        writtenSongTombstones = activeSongs;
        await _pushSnapshot(
          webdav,
          localPlaylists,
          activePlaylists,
          activeSongs,
        );
        return true;
      }

      final merged = PlaylistMerge.mergeAll(
        local: localPlaylists,
        remotePlaylists: remote['playlists'],
        playlistTombstones: playlistTombstones,
        songTombstones: songTombstones,
        favoritesId: favoritesId,
      );

      // 写本地之前再确认一次没被停止：停止后不该再落盘。
      _throwIfCancelled(webdav);

      final changed = !PlaylistMerge.samePlaylists(localPlaylists, merged);
      if (changed) {
        await repo.importAll(merged);
        writtenPlaylists = merged;
      }

      final activePlaylistTombstones = _activePlaylistTombstones(
        playlistTombstones,
        merged,
      );
      if (!_samePlaylistTombstones(
        localPlaylistTombstones,
        activePlaylistTombstones,
      )) {
        _throwIfCancelled(webdav);
        await PlaylistStore.writeTombstones(activePlaylistTombstones);
        writtenPlaylistTombstones = activePlaylistTombstones;
      }
      final activeSongTombstones = _activeSongTombstones(
        songTombstones,
        merged,
      );
      if (!_sameSongTombstones(localSongTombstones, activeSongTombstones)) {
        _throwIfCancelled(webdav);
        await PlaylistStore.writeSongTombstones(activeSongTombstones);
        writtenSongTombstones = activeSongTombstones;
      }
      _throwIfCancelled(webdav);
      await _pushSnapshot(
        webdav,
        merged,
        activePlaylistTombstones,
        activeSongTombstones,
      );
      return changed;
    } catch (e) {
      // 只有「被取消 / 被停止」才回滚；普通网络失败保留已合并的结果
      // （和以前一致，避免把用户刚合并进来的远端歌单又丢掉）。
      if (webdav.isCancelled) {
        await _rollbackLocal(
          beforePlaylists: localPlaylists,
          beforePlaylistTombstones: localPlaylistTombstones,
          beforeSongTombstones: localSongTombstones,
          writtenPlaylists: writtenPlaylists,
          writtenPlaylistTombstones: writtenPlaylistTombstones,
          writtenSongTombstones: writtenSongTombstones,
        );
      }
      rethrow;
    }
  }

  /// 已取消（超时 / 用户停止）就立刻中止，不再继续写本地或推送远端。
  static void _throwIfCancelled(WebDavService webdav) {
    if (webdav.isCancelled) {
      throw const WebDavException('同步已停止');
    }
  }

  /// 把本地还原成同步前的内容（用于同步被中途停止）。
  ///
  /// 只有「当前内容仍等于本次同步写下去的内容」才还原：这期间如果在别的页面
  /// 又改了歌单（或同步前那次本地读取本身就不完整），就保持现状不动，
  /// 不能拿旧快照把用户的新改动一起抹掉。
  static Future<void> _rollbackLocal({
    required List<Map<String, dynamic>> beforePlaylists,
    required Map<String, int> beforePlaylistTombstones,
    required Map<String, Map<String, int>> beforeSongTombstones,
    required List<Map<String, dynamic>>? writtenPlaylists,
    required Map<String, int>? writtenPlaylistTombstones,
    required Map<String, Map<String, int>>? writtenSongTombstones,
  }) async {
    if (writtenPlaylists != null) {
      final current = await PlaylistRepository().exportAll();
      if (PlaylistMerge.samePlaylists(current, writtenPlaylists)) {
        debugPrint('[PlaylistSyncService] 同步被停止，还原本地歌单');
        await PlaylistRepository().importAll(beforePlaylists);
      } else {
        debugPrint('[PlaylistSyncService] 本地歌单已被其它改动覆盖，跳过还原');
      }
    }
    if (writtenPlaylistTombstones != null) {
      final current = await PlaylistStore.readTombstones();
      if (_samePlaylistTombstones(current, writtenPlaylistTombstones)) {
        try {
          await PlaylistStore.writeTombstones(beforePlaylistTombstones);
        } catch (e) {
          debugPrint('[PlaylistSyncService] 还原歌单墓碑失败: $e');
        }
      }
    }
    if (writtenSongTombstones != null) {
      final current = await PlaylistStore.readSongTombstones();
      if (_sameSongTombstones(current, writtenSongTombstones)) {
        try {
          await PlaylistStore.writeSongTombstones(beforeSongTombstones);
        } catch (e) {
          debugPrint('[PlaylistSyncService] 还原歌曲墓碑失败: $e');
        }
      }
    }
  }

  static Timer? _debounceTimer;

  /// 本地歌单增删改后的自动同步：5 秒防抖，连续操作只同步最后一次。
  ///
  /// 与收藏页顶部的同步按钮走同一条路径（拉取远端 + 合并 + 回推），而不是
  /// 「只把本地推上去」——只推的话，另一台设备刚加的收藏永远拉不下来。
  ///
  /// [onStart] / [onFinish] 用于把同步状态同步给界面（窗口底部的同步提示）。
  static void scheduleSync(
    WebDavConfig config, {
    void Function()? onStart,
    void Function(bool ok, Object? error)? onFinish,
  }) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(seconds: 5), () {
      _debounceTimer = null;
      unawaited(() async {
        onStart?.call();
        // 与手动同步一致：整次操作套 2 分钟超时，超时会取消底层请求。
        final op = SyncAttempt(1);
        final webdav = WebDavService(config, cancelToken: op.cancelToken);
        op.attachDiagnosis(() => webdav.diagnosis);
        try {
          await op.run(pullAndMerge(webdav));
          onFinish?.call(true, null);
        } catch (e) {
          debugPrint('[PlaylistSyncService] 自动同步歌单失败: $e');
          onFinish?.call(false, e);
        }
      }());
    });
  }

  static Future<void> _pushSnapshot(
    WebDavService webdav,
    List<Map<String, dynamic>> playlists,
    Map<String, int> playlistTombstones,
    Map<String, Map<String, int>> songTombstones,
  ) async {
    await webdav.writeRemotePlaylists({
      'version': 2,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'playlists': playlists,
      'deleted': [
        for (final entry in playlistTombstones.entries)
          {'id': entry.key, 'deletedAt': entry.value},
      ],
      'deletedSongs': [
        for (final entry in songTombstones.entries)
          for (final song in entry.value.entries)
            {
              'playlistId': entry.key,
              'songId': song.key,
              'deletedAt': song.value,
            },
      ],
    });
  }

  // ---------------------------------------------------------------- 墓碑

  /// 只保留「歌单确实已经不在了」的墓碑。
  static Map<String, int> _activePlaylistTombstones(
    Map<String, int> tombstones,
    List<Map<String, dynamic>> playlists,
  ) {
    final ids = {for (final item in playlists) PlaylistMerge.idOf(item)};
    return {
      for (final entry in tombstones.entries)
        if (!ids.contains(entry.key)) entry.key: entry.value,
    };
  }

  /// 只保留「歌单里确实没有这首歌」的歌曲墓碑。
  ///
  /// 歌被重新加回来（更新时间不早于删除时间）后墓碑就没用了，留着只会让
  /// 另一端的合并反复把歌删掉。
  static Map<String, Map<String, int>> _activeSongTombstones(
    Map<String, Map<String, int>> tombstones,
    List<Map<String, dynamic>> playlists,
  ) {
    final songsByPlaylist = <String, Set<String>>{
      for (final playlist in playlists)
        PlaylistMerge.idOf(playlist): {
          for (final song in PlaylistMerge.songsOf(playlist))
            PlaylistMerge.songIdOf(song),
        },
    };
    final result = <String, Map<String, int>>{};
    tombstones.forEach((playlistId, songs) {
      final present = songsByPlaylist[playlistId] ?? const <String>{};
      final kept = <String, int>{
        for (final entry in songs.entries)
          if (!present.contains(entry.key)) entry.key: entry.value,
      };
      if (kept.isNotEmpty) result[playlistId] = kept;
    });
    return result;
  }

  static void _prunePlaylistTombstones(Map<String, int> tombstones) {
    final cutoff = DateTime.now()
        .subtract(const Duration(days: _tombstoneTtlDays))
        .millisecondsSinceEpoch;
    tombstones.removeWhere((_, deletedAt) => deletedAt < cutoff);
  }

  static void _pruneSongTombstones(Map<String, Map<String, int>> tombstones) {
    final cutoff = DateTime.now()
        .subtract(const Duration(days: _tombstoneTtlDays))
        .millisecondsSinceEpoch;
    tombstones.removeWhere((_, songs) {
      songs.removeWhere((_, deletedAt) => deletedAt < cutoff);
      return songs.isEmpty;
    });
  }

  static Map<String, Map<String, int>> _copySongTombstones(
    Map<String, Map<String, int>> source,
  ) {
    return {
      for (final entry in source.entries) entry.key: {...entry.value},
    };
  }

  static Map<String, int> _parsePlaylistTombstones(
    Map<String, dynamic> remote,
  ) {
    final result = <String, int>{};
    final raw = remote['deleted'];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final id = '${item['id'] ?? ''}';
        final deletedAt = PlaylistMerge.toMillis(item['deletedAt']);
        if (id.isNotEmpty && deletedAt != null) result[id] = deletedAt;
      }
    } else if (raw is Map) {
      raw.forEach((key, value) {
        final id = '$key';
        final deletedAt = PlaylistMerge.toMillis(value);
        if (id.isNotEmpty && deletedAt != null) result[id] = deletedAt;
      });
    }
    return result;
  }

  static Map<String, Map<String, int>> _parseSongTombstones(
    Map<String, dynamic> remote,
  ) {
    final result = <String, Map<String, int>>{};
    final raw = remote['deletedSongs'];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final playlistId = '${item['playlistId'] ?? ''}';
        final songId = '${item['songId'] ?? ''}';
        final deletedAt = PlaylistMerge.toMillis(item['deletedAt']);
        if (playlistId.isEmpty || songId.isEmpty || deletedAt == null) continue;
        result.putIfAbsent(playlistId, () => {})[songId] = deletedAt;
      }
    } else if (raw is Map) {
      raw.forEach((playlistId, value) {
        if (value is! Map) return;
        value.forEach((songId, deletedAt) {
          final millis = PlaylistMerge.toMillis(deletedAt);
          if (millis == null) return;
          result.putIfAbsent('$playlistId', () => {})['$songId'] = millis;
        });
      });
    }
    return result;
  }

  static bool _samePlaylistTombstones(Map<String, int> a, Map<String, int> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  static bool _sameSongTombstones(
    Map<String, Map<String, int>> a,
    Map<String, Map<String, int>> b,
  ) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      final other = b[entry.key];
      if (other == null || other.length != entry.value.length) return false;
      for (final song in entry.value.entries) {
        if (other[song.key] != song.value) return false;
      }
    }
    return true;
  }
}
