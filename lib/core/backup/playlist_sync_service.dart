import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../features/library/data/playlist_repository.dart';
import '../../features/library/data/playlist_store.dart';
import '../storage/app_database.dart';
import 'playlist_merge.dart';
import 'playlist_sync_protocol.dart';
import 'sync_timeout.dart';
import 'webdav_service.dart';

/// 歌单跨平台同步（内容寻址 + 版本描述文件）。
///
/// 远端不止一份「完整歌单」，而是一个很小的版本描述文件
/// `playlists.meta.json`（revision / digest / size / epoch）加上若干份以内容
/// 摘要命名的不可变快照 `playlists.<sha256>.json.gz`。写入顺序固定为
/// 「先传数据、后改指针」，所以指针永远指向一份完整数据。
///
/// 每次同步只读版本描述文件（约 200 B）就能判断要不要下载完整快照：
/// * **A 远端与本地基线一致、本地也没改** → 直接结束，不下载也不上传；
/// * **B 远端未变、只有本地改了** → 不下载，直接用本地数据生成新快照回推；
/// * **C 远端有变化 / 首次同步** → 下载完整快照、校验摘要、与本地合并，
///   合并结果与远端相同就只对齐本地基线，不再回推（避免同步风暴）。
///
/// 回推用 `If-Match` 条件写 meta；被别的设备抢先写入（412）会重新拉取合并。
/// 本地基线记在 [PlaylistSyncStateStore]，靠「本地数据指纹」识别本地改动，
/// 还原备份 / 清库 / 导入都会自动走全量路径，不依赖每个增删改点打标记。
///
/// 合并策略（按 id 对齐、meta 时间取新、歌曲取并集、墓碑传播删除）不变，
/// 具体算法在 [PlaylistMerge]。
class PlaylistSyncService {
  const PlaylistSyncService._();

  static const String favoritesId = '__favorites__';

  /// 墓碑保留天数：过期后两端都已同步过删除，可以安全丢弃。
  static const int _tombstoneTtlDays = 90;

  /// 同步最多尝试几次（含首次）：412 冲突后最多重新拉取合并 3 次。
  static const int _maxSyncAttempts = 4;

  /// 串行化同步请求：启动同步 / 手动同步 / 防抖自动同步可能同时触发，
  /// 并发执行会互相覆盖本地基线。后来的请求排队等前一个结束再跑。
  static Future<void> _chain = Future<void>.value();

  /// 同步入口：返回本地歌单是否发生了实际变化。
  ///
  /// [webdav] 带取消令牌时（见 `SyncAttempt`）：中途停止会让请求以
  /// `DioException(cancel)` 失败，这里把已经写了一半的本地歌单 / 墓碑还原。
  static Future<bool> pullAndMerge(WebDavService webdav) {
    final result = _chain.then((_) => _syncAllAttempts(webdav));
    _chain = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  static Future<bool> _syncAllAttempts(WebDavService webdav) async {
    final writer = await PlaylistSyncStateStore.deviceId();
    for (var attempt = 0; attempt < _maxSyncAttempts; attempt++) {
      try {
        return await _syncOnce(webdav, writer);
      } on WebDavException catch (e) {
        if (e.statusCode == 412 && attempt + 1 < _maxSyncAttempts) {
          _throwIfCancelled(webdav);
          debugPrint('[PlaylistSyncService] 云端版本被其它设备抢先更新，重新合并');
          continue;
        }
        rethrow;
      }
    }
    return false;
  }

  static Future<bool> _syncOnce(WebDavService webdav, String writer) async {
    final repo = PlaylistRepository();
    final localPlaylists = await repo.exportAll();
    final localPT = await PlaylistStore.readTombstones();
    final localST = await PlaylistStore.readSongTombstones();
    // exportAll 会打开数据库：只有走到这里才能确定它有没有降级成内存库。
    if (!AppDatabase.isPersistent) {
      throw const WebDavException(
        '本地收藏数据库未能落盘（已降级为内存库），本次跳过歌单同步，'
        '以免用空数据覆盖云端',
      );
    }
    final fingerprint = _fingerprintOf(localPlaylists, localPT, localST);
    final state = await PlaylistSyncStateStore.load();
    // 指纹不同就说明本地自上次成功同步后有改动（含还原 / 清库 / 导入）。
    final dirty = state == null || state.localFingerprint != fingerprint;

    PlaylistMeta? meta;
    var metaCorrupt = false;
    try {
      meta = await webdav.readPlaylistMeta();
    } on PlaylistSchemaException {
      // 远端数据来自更新版本，不能按旧格式重建，直接提示升级。
      rethrow;
    } on FormatException catch (e) {
      metaCorrupt = true;
      debugPrint('[PlaylistSyncService] 远端版本描述不可用，尝试恢复: $e');
    }
    _throwIfCancelled(webdav);

    if (meta == null && metaCorrupt) {
      // 描述损坏时优先用远端现存快照重建指针；失败再退回旧版数据文件。
      meta = await webdav.recoverPlaylistMeta(
        writer: writer,
        epoch: const Uuid().v4(),
      );
      _throwIfCancelled(webdav);
    }

    if (meta == null) {
      // 远端还没初始化（或描述损坏且无法恢复）。旧版数据文件只读一次做
      // 迁移，避免升级后把已有歌单当成「空」覆盖掉；之后不再写旧文件。
      final legacy = await webdav.readLegacyPlaylists();
      _throwIfCancelled(webdav);
      if (legacy != null) {
        return _mergeAndPublish(
          webdav,
          writer,
          meta: null,
          remote: legacy,
          localPlaylists: localPlaylists,
          localPT: localPT,
          localST: localST,
        );
      }
      return _publishLocalOnly(
        webdav,
        writer,
        localPlaylists,
        localPT,
        localST,
      );
    }

    switch (decideSyncAction(
      meta: meta,
      state: state,
      localDirty: dirty,
      localHasContent: _hasLocalContent(localPlaylists),
    )) {
      case SyncAction.noop:
        // 远端没变、本地也没变：连完整快照都不用下载，更不用回推。
        return false;

      case SyncAction.pushLocal:
        // 远端与本地基线一致，本地就是全部改动，不必再下载完整快照。
        return _publishLocalOnly(
          webdav,
          writer,
          localPlaylists,
          localPT,
          localST,
          meta: meta,
        );

      case SyncAction.pullAndMerge:
        final remote = await webdav.readPlaylistSnapshot(meta);
        _throwIfCancelled(webdav);
        return _mergeAndPublish(
          webdav,
          writer,
          meta: meta,
          remote: remote,
          localPlaylists: localPlaylists,
          localPT: localPT,
          localST: localST,
        );
    }
  }

  /// 只有本地有内容需要上传时走这里（远端未初始化 / 本地确实有改动）。
  static Future<bool> _publishLocalOnly(
    WebDavService webdav,
    String writer,
    List<Map<String, dynamic>> playlists,
    Map<String, int> localPT,
    Map<String, Map<String, int>> localST, {
    PlaylistMeta? meta,
  }) async {
    final pt = {...localPT};
    final st = _copySongTombstones(localST);
    _prunePlaylistTombstones(pt);
    _pruneSongTombstones(st);
    await _publish(
      webdav,
      writer,
      meta: meta,
      playlists: playlists,
      pt: _activePlaylistTombstones(pt, playlists),
      st: _activeSongTombstones(st, playlists),
    );
    return false;
  }

  /// 本地是否有真正的内容：歌曲，或除「我的收藏」之外的歌单。
  ///
  /// 只剩一张空收藏却判定「本地有改动」，多半意味着数据库降级 / 数据被清，
  /// 这时不能直接回推。
  static bool _hasLocalContent(List<Map<String, dynamic>> playlists) {
    for (final playlist in playlists) {
      if (PlaylistMerge.songsOf(playlist).isNotEmpty) return true;
    }
    return playlists.length > 1;
  }

  /// C 路径：合并远端快照 → 写本地（可回滚）→ 按需回推。
  static Future<bool> _mergeAndPublish(
    WebDavService webdav,
    String writer, {
    required PlaylistMeta? meta,
    required Map<String, dynamic> remote,
    required List<Map<String, dynamic>> localPlaylists,
    required Map<String, int> localPT,
    required Map<String, Map<String, int>> localST,
  }) async {
    final playlistTombstones = <String, int>{...localPT};
    final songTombstones = _copySongTombstones(localST);
    _parsePlaylistTombstones(remote).forEach((id, deletedAt) {
      if (deletedAt > (playlistTombstones[id] ?? 0)) {
        playlistTombstones[id] = deletedAt;
      }
    });
    _parseSongTombstones(remote).forEach((playlistId, songs) {
      final target = songTombstones.putIfAbsent(playlistId, () => {});
      songs.forEach((songId, deletedAt) {
        if (deletedAt > (target[songId] ?? 0)) target[songId] = deletedAt;
      });
    });
    _prunePlaylistTombstones(playlistTombstones);
    _pruneSongTombstones(songTombstones);

    final merged = PlaylistMerge.mergeAll(
      local: localPlaylists,
      remotePlaylists: remote['playlists'],
      playlistTombstones: playlistTombstones,
      songTombstones: songTombstones,
      favoritesId: favoritesId,
    );

    final rawRemotePlaylists = remote['playlists'];
    final remotePlaylists = <Map<String, dynamic>>[
      if (rawRemotePlaylists is List)
        for (final item in rawRemotePlaylists)
          if (item is Map) item.map((key, value) => MapEntry('$key', value)),
    ];

    List<Map<String, dynamic>>? writtenPlaylists;
    Map<String, int>? writtenPT;
    Map<String, Map<String, int>>? writtenST;
    try {
      _throwIfCancelled(webdav);
      final changed = !PlaylistMerge.samePlaylists(localPlaylists, merged);
      if (changed) {
        await PlaylistRepository().importAll(merged);
        writtenPlaylists = merged;
      }
      final activePT = _activePlaylistTombstones(playlistTombstones, merged);
      if (!_samePlaylistTombstones(localPT, activePT)) {
        _throwIfCancelled(webdav);
        await PlaylistStore.writeTombstones(activePT);
        writtenPT = activePT;
      }
      final activeST = _activeSongTombstones(songTombstones, merged);
      if (!_sameSongTombstones(localST, activeST)) {
        _throwIfCancelled(webdav);
        await PlaylistStore.writeSongTombstones(activeST);
        writtenST = activeST;
      }
      _throwIfCancelled(webdav);
      if (meta != null &&
          PlaylistMerge.sameContentIgnoringOrder(merged, remotePlaylists)) {
        // 内容与远端一致（忽略两端的展示顺序差异）：只对齐基线，不再回推，
        // 避免两台设备因排序差异互相推版本。真正缺内容时会走到下面回推，
        // 保证远端被清空 / 被旧备份覆盖后还能补回来。
        await _saveState(meta, publishedPlaylists: merged);
        return changed;
      }
      await _publish(
        webdav,
        writer,
        meta: meta,
        playlists: merged,
        pt: activePT,
        st: activeST,
      );
      return changed;
    } catch (e) {
      // 只有「被取消 / 被停止」才回滚；412 冲突保留已合并的本地结果，
      // 下一轮会基于新的远端快照再合并一次，不会丢改动。
      if (webdav.isCancelled) {
        await _rollbackLocal(
          beforePlaylists: localPlaylists,
          beforePlaylistTombstones: localPT,
          beforeSongTombstones: localST,
          writtenPlaylists: writtenPlaylists,
          writtenPlaylistTombstones: writtenPT,
          writtenSongTombstones: writtenST,
        );
      }
      rethrow;
    }
  }

  /// 生成新快照并回推；内容没变则只对齐本地基线。
  static Future<void> _publish(
    WebDavService webdav,
    String writer, {
    required PlaylistMeta? meta,
    required List<Map<String, dynamic>> playlists,
    required Map<String, int> pt,
    required Map<String, Map<String, int>> st,
  }) async {
    final snapshot = PlaylistSnapshot.build(
      playlists: playlists,
      playlistTombstones: pt,
      songTombstones: st,
    );
    final bytes = PlaylistSnapshot.encode(snapshot);
    final digest = PlaylistSnapshot.digestOf(snapshot);
    _throwIfCancelled(webdav);

    if (meta != null && meta.digest == digest) {
      // 合并结果与远端完全一致：不传数据、不递增 revision，只把基线追上，
      // 否则两台设备会互相看到「对方又推了一版」而无限回推。
      await _saveState(meta, publishedPlaylists: playlists);
      return;
    }

    final next = meta == null
        ? PlaylistMeta.initial(
            epoch: const Uuid().v4(),
            digest: digest,
            size: bytes.length,
            writer: writer,
          )
        : meta.next(digest: digest, size: bytes.length, writer: writer);
    // ① 先传数据（不可变文件，重复 PUT 幂等）② 再条件写指针。
    await webdav.writePlaylistSnapshot(digest, bytes);
    _throwIfCancelled(webdav);
    await webdav.writePlaylistMeta(next, expected: meta);
    await _saveState(next, publishedPlaylists: playlists);
    // 清理旧快照放在最后，且不阻塞同步结果（失败也不影响本次同步）。
    unawaited(webdav.gcPlaylistSnapshots(digest));
  }

  /// 同步成功后记录基线。
  ///
  /// 指纹基于「落盘后的本地内容」重算；一旦发现它和本次实际发布的数据
  /// 不一致，说明同步过程中用户又改了歌单——这时保留旧基线，让下次同步
  /// 重新合并，绝不能把这次并发编辑误标成「已同步」。
  static Future<void> _saveState(
    PlaylistMeta meta, {
    List<Map<String, dynamic>>? publishedPlaylists,
  }) async {
    final playlists = await PlaylistRepository().exportAll();
    if (publishedPlaylists != null &&
        !PlaylistMerge.samePlaylists(playlists, publishedPlaylists)) {
      debugPrint('[PlaylistSyncService] 同步期间本地歌单又被改动，保留旧基线等待下次同步');
      return;
    }
    final pt = await PlaylistStore.readTombstones();
    final st = await PlaylistStore.readSongTombstones();
    await PlaylistSyncStateStore.save(
      PlaylistSyncState(
        epoch: meta.epoch,
        revision: meta.revision,
        digest: meta.digest,
        localFingerprint: _fingerprintOf(playlists, pt, st),
      ),
    );
  }

  static String _fingerprintOf(
    List<Map<String, dynamic>> playlists,
    Map<String, int> pt,
    Map<String, Map<String, int>> st,
  ) => PlaylistSnapshot.fingerprintOf(
    PlaylistSnapshot.build(
      playlists: playlists,
      playlistTombstones: pt,
      songTombstones: st,
    ),
  );

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
  /// 与收藏页顶部的同步按钮走同一条路径；因为新协议会自动比对本地指纹，
  /// 这里不需要额外打「本地已改动」标记。
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
