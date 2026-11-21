import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../features/blacklist/data/blacklist_store.dart';
import '../../features/blacklist/domain/models/blacklist_entry.dart';
import '../../features/radio/data/radio_cover_cache.dart';
import '../../features/radio/data/radio_store.dart';
import '../../features/radio/domain/models/radio_station.dart';
import '../storage/app_preferences.dart';
import 'data_snapshot.dart';
import 'webdav_service.dart';

/// 附加数据同步：黑名单、电台。
///
/// 复用 [DataSnapshotMeta] 的内容寻址快照协议，远端文件：
/// * `extras.meta.json` / `extras.<sha256>.json.gz`
/// * `radio-covers/<sha256>.img`（电台封面，按内容寻址）
///
/// 变更时间不写进各业务模型，而是由 [_ExtrasJournal] 在每次同步时对比
/// 「当前内容」与「上次同步的内容」得出：
/// * 内容变了 → 记一条 changedAt；
/// * 上次有、这次没有 → 记一条删除墓碑。
/// 这样电台 / 黑名单的增删改入口不用逐个改，也不会因为忘了打标记
/// 而漏同步；删除在同步前被应用杀掉，下次同步仍能通过对比发现。
class ExtrasSyncService {
  const ExtrasSyncService._();

  static const String baseName = 'extras';
  static const String coversDir = 'radio-covers';
  static const int _maxSyncAttempts = 4;
  static const int _tombstoneTtlDays = 90;

  /// 串行化：自动同步 / 手动同步 / 设置写盘触发的同步可能同时进来。
  static Future<void> _chain = Future<void>.value();

  /// 同步入口：拉取远端、合并，返回本地被应用了哪些数据。
  static Future<ExtrasSyncResult> pullAndMerge(WebDavService webdav) {
    final result = _chain.then((_) => _syncAllAttempts(webdav));
    _chain = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  static Future<ExtrasSyncResult> _syncAllAttempts(WebDavService webdav) async {
    final writer = await syncDeviceId();
    for (var attempt = 0; attempt < _maxSyncAttempts; attempt++) {
      try {
        return await _syncOnce(webdav, writer);
      } on WebDavException catch (e) {
        if (e.statusCode == 412 && attempt + 1 < _maxSyncAttempts) {
          _throwIfCancelled(webdav);
          debugPrint('[ExtrasSync] 云端版本被其它设备抢先更新，重新合并');
          continue;
        }
        rethrow;
      }
    }
    return ExtrasSyncResult.none;
  }

  static Future<ExtrasSyncResult> _syncOnce(
    WebDavService webdav,
    String writer,
  ) async {
    final local = await _LocalExtras.load();
    final journal = await _ExtrasJournal.load();
    // 「本地整体为空」必须在 record() 之前判断：record() 会为「基线里有、
    // 这次没读到」的条目补写墓碑，之后再检查 tombstones 就永远不为空，
    // 下面的空数据兜底会彻底失效（单个数据集读失败时会误把云端删空）。
    final localEmpty = local.scopes.values.every((scope) => scope.isEmpty);
    if (journal.record(_journalScopes(local.scopes))) {
      await journal.save();
    }

    final localScopes = journal.withStamps(local.scopes);
    final localDigest = DataSnapshotCodec.digestOf(
      _buildSnapshot(localScopes, journal.tombstones),
    );
    final state = await DataSyncStateStore.load(baseName);

    DataSnapshotMeta? meta;
    var metaCorrupt = false;
    try {
      meta = await webdav.readDataMeta(baseName);
    } on DataSnapshotSchemaException {
      rethrow;
    } on FormatException catch (e) {
      metaCorrupt = true;
      debugPrint('[ExtrasSync] 远端版本描述不可用: $e');
    }
    _throwIfCancelled(webdav);
    if (meta == null && metaCorrupt) {
      // 指针损坏时不猜远端内容，按「远端未初始化」处理会覆盖云端数据，
      // 这里直接报错让用户决定（与歌单的自动恢复不同：附加数据没有旧格式
      // 可回退，重建指针的目标不明确）。
      throw const WebDavException(
        '远端附加数据版本描述损坏，请删除远端 extras.meta.json 后重试',
      );
    }

    final baselineMatches =
        meta != null &&
        state != null &&
        state.epoch == meta.epoch &&
        state.revision == meta.revision &&
        state.digest == meta.digest;
    final localDirty = state == null || state.localFingerprint != localDigest;

    if (meta == null) {
      await _publish(
        webdav,
        writer,
        meta: null,
        scopes: localScopes,
        tombstones: journal.tombstones,
        uploadedCovers: local.covers,
        publishedCovers: const {},
      );
      return ExtrasSyncResult.none;
    }

    if (baselineMatches && !localDirty) return ExtrasSyncResult.none;

    // 内容与远端完全一致（常见于设置被清空 / 还原后基线丢了，但数据没变）：
    // 不用下载快照，直接把基线补上，下一次同步就能走「无改动」的早退。
    if (meta.digest == localDigest) {
      await _saveStateIfChanged(
        DataSyncState(
          epoch: meta.epoch,
          revision: meta.revision,
          digest: meta.digest,
          localFingerprint: localDigest,
        ),
      );
      unawaited(webdav.gcDataSnapshots(baseName, meta.digest));
      return ExtrasSyncResult.none;
    }

    // 本地为空却基线匹配、指纹不同：多半是设置文件读失败 / 被清空，
    // 不能把远端整份覆盖成空，强制走合并。合并仍会带上本机墓碑，
    // 所以「用户确实删光了」这条路径照样能把远端删干净。
    if (baselineMatches && localDirty && !localEmpty) {
      await _publish(
        webdav,
        writer,
        meta: meta,
        scopes: localScopes,
        tombstones: journal.tombstones,
        uploadedCovers: local.covers,
        publishedCovers: const {},
      );
      return ExtrasSyncResult.none;
    }

    final remote = await webdav.readDataSnapshot(baseName, meta);
    _throwIfCancelled(webdav);
    final parsed = _parseSnapshot(remote);

    final merged = <String, _MergedScope>{};
    for (final scope in _ExtrasScope.all) {
      merged[scope] = _mergeScope(
        local.scopes[scope] ?? const {},
        journal.tombstones[scope] ?? const {},
        parsed.scopes[scope] ?? const {},
        parsed.tombstones[scope] ?? const {},
      );
    }
    final mergedScopes = {
      for (final entry in merged.entries) entry.key: entry.value.items,
    };
    final mergedTombstones = {
      for (final entry in merged.entries)
        if (entry.value.tombstones.isNotEmpty)
          entry.key: entry.value.tombstones,
    };

    final absorbed = journal.absorbRemote(parsed.changedAt, parsed.tombstones);

    final outcome = await _apply(
      webdav,
      local: local,
      scopes: mergedScopes,
    );
    final applied = outcome.result;
    _throwIfCancelled(webdav);

    // 应用远端后本地内容已变：基线按「当前内容」重新记，不再重新打时间戳。
    final appliedLocal = await _LocalExtras.load();
    // 重建基线没有变化时不必写盘；但 absorbRemote 带回来的时间戳 / 墓碑
    // 变了还是要落盘，否则下次比较会拿旧时间戳。
    if (journal.record(
          _journalScopes(appliedLocal.scopes),
          stampChanges: false,
        ) ||
        absorbed) {
      await journal.save();
    }
    final knownCovers = _uploadedCovers()
        .union(parsed.coverDigests)
        .difference(outcome.missingCovers);
    if (!_sameSet(knownCovers, _uploadedCovers())) {
      await _saveUploadedCovers(knownCovers);
    }

    final snapshot = _buildSnapshot(mergedScopes, mergedTombstones);
    final fingerprint = DataSnapshotCodec.digestOf(snapshot);
    if (meta.digest == fingerprint) {
      await _saveStateIfChanged(
        DataSyncState(
          epoch: meta.epoch,
          revision: meta.revision,
          digest: meta.digest,
          localFingerprint: fingerprint,
        ),
      );
      unawaited(webdav.gcDataSnapshots(baseName, meta.digest));
      return applied;
    }

    await _publish(
      webdav,
      writer,
      meta: meta,
      scopes: mergedScopes,
      tombstones: mergedTombstones,
      uploadedCovers: appliedLocal.covers,
      publishedCovers: parsed.coverDigests,
      expectedFingerprint: fingerprint,
    );
    return applied;
  }

  // ------------------------------------------------------------ 发布

  static Future<void> _publish(
    WebDavService webdav,
    String writer, {
    required DataSnapshotMeta? meta,
    required Map<String, Map<String, Map<String, dynamic>>> scopes,
    required Map<String, Map<String, int>> tombstones,
    required Map<String, _LocalCover> uploadedCovers,
    required Set<String> publishedCovers,
    String? expectedFingerprint,
  }) async {
    final snapshot = _buildSnapshot(scopes, tombstones);
    final (bytes, digest) = await DataSnapshotCodec.encodeAndDigest(snapshot);
    _throwIfCancelled(webdav);

    final fingerprint = expectedFingerprint ?? digest;
    if (meta != null && meta.digest == digest) {
      await _saveStateIfChanged(
        DataSyncState(
          epoch: meta.epoch,
          revision: meta.revision,
          digest: meta.digest,
          localFingerprint: fingerprint,
        ),
      );
      unawaited(webdav.gcDataSnapshots(baseName, meta.digest));
      return;
    }

    // ① 先补传远端还没有的电台封面（内容寻址，重复 PUT 幂等）。
    final knownCovers = _uploadedCovers().union(publishedCovers);
    final referencedCovers = <String>{};
    for (final scope in [
      _ExtrasScope.radioStations,
      _ExtrasScope.radioRandom,
    ]) {
      final items = scopes[scope] ?? const <String, Map<String, dynamic>>{};
      for (final item in items.values) {
        final coverDigest = '${item['coverDigest'] ?? ''}';
        if (coverDigest.isEmpty) continue;
        referencedCovers.add(coverDigest);
        if (knownCovers.contains(coverDigest)) continue;
        final cover = uploadedCovers[coverDigest];
        if (cover == null) continue;
        Uint8List bytes;
        try {
          bytes = await File(cover.path).readAsBytes();
        } catch (e) {
          debugPrint('[ExtrasSync] 读取封面失败: $e');
          continue;
        }
        await webdav.ensureDataDir(coversDir);
        await webdav.writeDataFile('$coversDir/$coverDigest.img', bytes);
        knownCovers.add(coverDigest);
      }
    }
    _throwIfCancelled(webdav);

    // ② 再传快照、③ 最后条件写指针。
    final next = meta == null
        ? DataSnapshotMeta.initial(
            digest: digest,
            size: bytes.length,
            writer: writer,
          )
        : meta.next(digest: digest, size: bytes.length, writer: writer);
    await webdav.writeDataSnapshot(baseName, digest, bytes);
    _throwIfCancelled(webdav);
    await webdav.writeDataMeta(baseName, next, expected: meta);
    await DataSyncStateStore.save(
      baseName,
      DataSyncState(
        epoch: next.epoch,
        revision: next.revision,
        digest: next.digest,
        localFingerprint: fingerprint,
      ),
    );
    if (!_sameSet(knownCovers, _uploadedCovers())) {
      await _saveUploadedCovers(knownCovers);
    }
    unawaited(webdav.gcDataSnapshots(baseName, digest));
    unawaited(
      webdav.gcDataFiles(coversDir, {
        for (final value in referencedCovers) '$value.img',
      }),
    );
  }

  static Future<void> _saveStateIfChanged(DataSyncState next) async {
    final current = await DataSyncStateStore.load(baseName);
    if (current != null &&
        current.epoch == next.epoch &&
        current.revision == next.revision &&
        current.digest == next.digest &&
        current.localFingerprint == next.localFingerprint) {
      return;
    }
    await DataSyncStateStore.save(baseName, next);
  }

  static bool _sameSet(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  static void _throwIfCancelled(WebDavService webdav) {
    if (webdav.isCancelled) {
      throw const WebDavException('同步已停止');
    }
  }

  // ------------------------------------------------------------ 快照编解码

  static Map<String, dynamic> _buildSnapshot(
    Map<String, Map<String, Map<String, dynamic>>> scopes,
    Map<String, Map<String, int>> tombstones,
  ) {
    List<Map<String, dynamic>> listOf(String scope) {
      final items = scopes[scope] ?? const {};
      final keys = items.keys.toList()..sort();
      return [for (final key in keys) items[key]!];
    }

    final random = scopes[_ExtrasScope.radioRandom]?['random'];
    return {
      'schema': dataSnapshotSchema,
      'blacklist': {
        'songs': listOf(_ExtrasScope.blacklistSongs),
        'artists': listOf(_ExtrasScope.blacklistArtists),
        'whitelist': listOf(_ExtrasScope.blacklistWhitelist),
      },
      'radio': {
        'categories': listOf(_ExtrasScope.radioCategories),
        'stations': listOf(_ExtrasScope.radioStations),
        'random': ?random,
      },
      'tombstones': {
        for (final entry in tombstones.entries)
          if (entry.value.isNotEmpty)
            entry.key: {
              for (final item in (entry.value.keys.toList()..sort()))
                item: entry.value[item],
            },
      },
    };
  }

  /// 变更检测忽略封面摘要：它由本地文件内容算出，不参与「什么时候改的」
  /// 判定（换封面时 updateTime 一定会变），否则升级后的首次同步会把所有电台
  /// 都当成新改动，时间戳压过另一台设备已经同步好的封面。
  static Map<String, Map<String, Map<String, dynamic>>> _journalScopes(
    Map<String, Map<String, Map<String, dynamic>>> scopes,
  ) {
    Map<String, Map<String, dynamic>> stripDigest(
      Map<String, Map<String, dynamic>> items,
    ) =>
        {
          for (final entry in items.entries)
            entry.key: {
              for (final field in entry.value.entries)
                if (field.key != 'coverDigest') field.key: field.value,
            },
        };
    final result = {...scopes};
    for (final scope in [
      _ExtrasScope.radioStations,
      _ExtrasScope.radioRandom,
    ]) {
      final items = scopes[scope];
      if (items != null) result[scope] = stripDigest(items);
    }
    return result;
  }

  static _ParsedExtras _parseSnapshot(Map<String, dynamic> snapshot) {
    final scopes = {
      for (final scope in _ExtrasScope.all)
        scope: <String, Map<String, dynamic>>{},
    };
    final changedAt = {
      for (final scope in _ExtrasScope.all) scope: <String, int>{},
    };

    void add(String scope, String key, Map<String, dynamic> data) {
      if (key.isEmpty) return;
      final stamp = _asInt(data['changedAt']);
      if (stamp <= 0) data.remove('changedAt');
      scopes[scope]![key] = data;
      if (stamp > 0) changedAt[scope]![key] = stamp;
    }

    Map<String, dynamic> withStamp(
      Map<String, dynamic> data,
      Object? rawStamp,
    ) {
      final stamp = _asInt(rawStamp);
      if (stamp > 0) data['changedAt'] = stamp;
      return data;
    }

    final blacklist = snapshot['blacklist'];
    if (blacklist is Map) {
      final songs = blacklist['songs'];
      if (songs is List) {
        for (final item in songs) {
          if (item is! Map) continue;
          final data = Map<String, dynamic>.from(item);
          final title = '${data['title'] ?? ''}';
          final artist = '${data['artist'] ?? ''}';
          add(
            _ExtrasScope.blacklistSongs,
            _songKey(title, artist),
            withStamp({'title': title, 'artist': artist}, data['changedAt']),
          );
        }
      }
      final whitelist = blacklist['whitelist'];
      if (whitelist is List) {
        for (final item in whitelist) {
          if (item is! Map) continue;
          final data = Map<String, dynamic>.from(item);
          final title = '${data['title'] ?? ''}';
          final artist = '${data['artist'] ?? ''}';
          add(
            _ExtrasScope.blacklistWhitelist,
            _songKey(title, artist),
            withStamp({'title': title, 'artist': artist}, data['changedAt']),
          );
        }
      }
      final artists = blacklist['artists'];
      if (artists is List) {
        for (final item in artists) {
          if (item is! Map) continue;
          final data = Map<String, dynamic>.from(item);
          final name = '${data['name'] ?? ''}';
          add(
            _ExtrasScope.blacklistArtists,
            blacklistNormalize(name),
            withStamp({'name': name}, data['changedAt']),
          );
        }
      }
    }

    final radio = snapshot['radio'];
    if (radio is Map) {
      final categories = radio['categories'];
      if (categories is List) {
        for (final item in categories) {
          if (item is! Map) continue;
          final data = Map<String, dynamic>.from(item);
          final id = '${data['id'] ?? ''}';
          add(
            _ExtrasScope.radioCategories,
            id,
            withStamp({
              'id': id,
              'name': '${data['name'] ?? ''}',
            }, data['changedAt']),
          );
        }
      }
      final stations = radio['stations'];
      if (stations is List) {
        for (final item in stations) {
          if (item is! Map) continue;
          final data = Map<String, dynamic>.from(item);
          final id = '${data['id'] ?? ''}';
          add(
            _ExtrasScope.radioStations,
            id,
            withStamp(data, data['changedAt']),
          );
        }
      }
      final random = radio['random'];
      if (random is Map) {
        final data = Map<String, dynamic>.from(random);
        add(
          _ExtrasScope.radioRandom,
          'random',
          withStamp(data, data['changedAt']),
        );
      }
    }

    final tombstones = <String, Map<String, int>>{};
    final rawTombstones = snapshot['tombstones'];
    if (rawTombstones is Map) {
      for (final scope in _ExtrasScope.all) {
        final raw = rawTombstones[scope];
        if (raw is! Map) continue;
        final scopeMap = <String, int>{};
        raw.forEach((key, value) {
          final ts = _asInt(value);
          if (ts > 0) scopeMap['$key'] = ts;
        });
        if (scopeMap.isNotEmpty) tombstones[scope] = scopeMap;
      }
    }

    final coverDigests = <String>{
      for (final scope in [
        _ExtrasScope.radioStations,
        _ExtrasScope.radioRandom,
      ])
        for (final item in (scopes[scope] ?? const {}).values)
          if ('${item['coverDigest'] ?? ''}'.isNotEmpty)
            '${item['coverDigest']}',
    };

    return _ParsedExtras(
      scopes: scopes,
      changedAt: changedAt,
      tombstones: tombstones,
      coverDigests: coverDigests,
    );
  }

  // ------------------------------------------------------------ 合并

  static _MergedScope _mergeScope(
    Map<String, Map<String, dynamic>> local,
    Map<String, int> localTombstones,
    Map<String, Map<String, dynamic>> remote,
    Map<String, int> remoteTombstones,
  ) {
    final keys = <String>[...local.keys];
    for (final key in remote.keys) {
      if (!keys.contains(key)) keys.add(key);
    }
    final items = <String, Map<String, dynamic>>{};
    final tombstones = <String, int>{};
    final cutoff = _tombstoneCutoff();

    for (final key in keys) {
      final localItem = local[key];
      final remoteItem = remote[key];
      final localStamp = _stampOf(localItem, localTombstones[key]);
      final remoteStamp = _stampOf(remoteItem, remoteTombstones[key]);
      final localDeleted = localItem == null;
      final remoteDeleted = remoteItem == null;

      Map<String, dynamic>? winner;
      var deleted = false;
      int stamp;
      if (localStamp == remoteStamp) {
        // 时间戳相同（含首次同步的 0）：本地优先，远端只补充缺失的项。
        winner = localItem ?? remoteItem;
        deleted = winner == null;
        stamp = localStamp;
      } else if (localStamp > remoteStamp) {
        winner = localItem;
        deleted = localDeleted;
        stamp = localStamp;
      } else {
        winner = remoteItem;
        deleted = remoteDeleted;
        stamp = remoteStamp;
      }

      // 封面摘要不参与时间戳：本地只是改了别的字段（或还没缓存封面）时，
      // 不能把另一端已有的封面摘要一起覆盖掉；`coverUrl` 被清空才代表
      // 用户确实删了封面。
      if (winner != null && winner['coverUrl'] != null) {
        final winnerDigest = '${winner['coverDigest'] ?? ''}';
        final winnerUrl = '${winner['coverUrl'] ?? ''}'.trim();
        if (winnerDigest.isEmpty && winnerUrl.isNotEmpty) {
          final other = identical(winner, localItem)
              ? remoteItem
              : localItem;
          final otherDigest = '${other?['coverDigest'] ?? ''}';
          if (otherDigest.isNotEmpty) {
            winner = {...winner, 'coverDigest': otherDigest};
          }
        }
      }

      if (deleted) {
        if (stamp > cutoff) tombstones[key] = stamp;
        continue;
      }
      if (winner != null) items[key] = winner;
    }
    return _MergedScope(items: items, tombstones: tombstones);
  }

  static int _stampOf(Map<String, dynamic>? item, int? tombstone) {
    final itemStamp = _asInt(item?['changedAt']);
    final tomb = tombstone ?? 0;
    return itemStamp > tomb ? itemStamp : tomb;
  }

  // ------------------------------------------------------------ 应用到本地

  static Future<_ApplyOutcome> _apply(
    WebDavService webdav, {
    required _LocalExtras local,
    required Map<String, Map<String, Map<String, dynamic>>> scopes,
  }) async {
    var blacklist = false;
    var radio = false;
    bool scopeChanged(List<String> names) =>
        names.any((name) => !_sameItems(local.scopes[name], scopes[name]));

    if (scopeChanged([
      _ExtrasScope.blacklistSongs,
      _ExtrasScope.blacklistArtists,
      _ExtrasScope.blacklistWhitelist,
    ])) {
      await _applyBlacklist(scopes);
      blacklist = true;
    }
    final missingCovers = await _applyRadioIfNeeded(
      webdav,
      local,
      scopes,
      changed: scopeChanged([
        _ExtrasScope.radioCategories,
        _ExtrasScope.radioStations,
        _ExtrasScope.radioRandom,
      ]),
    );
    if (missingCovers != null) radio = true;
    return _ApplyOutcome(
      result: ExtrasSyncResult(blacklist: blacklist, radio: radio),
      missingCovers: missingCovers ?? const {},
    );
  }

  /// 应用电台数据；返回本次远端引用但下载失败的封面摘要。
  ///
  /// 返回 null 表示电台数据没变、没有写本地。
  static Future<Set<String>?> _applyRadioIfNeeded(
    WebDavService webdav,
    _LocalExtras local,
    Map<String, Map<String, Map<String, dynamic>>> scopes, {
    required bool changed,
  }) async {
    var needed = changed;
    if (!needed) {
      // 内容没变，但本地封面文件被清掉了（例如清理配置）：仍要下载补齐。
      for (final scope in [
        _ExtrasScope.radioStations,
        _ExtrasScope.radioRandom,
      ]) {
        for (final item in (scopes[scope] ?? const {}).values) {
          final digest = '${item['coverDigest'] ?? ''}';
          if (digest.isNotEmpty && !local.covers.containsKey(digest)) {
            needed = true;
            break;
          }
        }
        if (needed) break;
      }
    }
    if (!needed) return null;
    return _applyRadio(webdav, local, scopes);
  }

  /// 比较两份内容（忽略同步用的 `changedAt`）。
  static bool _sameItems(
    Map<String, Map<String, dynamic>>? a,
    Map<String, Map<String, dynamic>>? b,
  ) {
    final left = a ?? const {};
    final right = b ?? const {};
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      final other = right[entry.key];
      if (other == null) return false;
      if (!_sameFields(entry.value, other)) return false;
    }
    return true;
  }

  static bool _sameFields(Map<String, dynamic> a, Map<String, dynamic> b) {
    Map<String, dynamic> strip(Map<String, dynamic> source) => {
      for (final entry in source.entries)
        if (entry.key != 'changedAt') entry.key: entry.value,
    };
    return _sameJson(strip(a), strip(b));
  }

  static bool _sameJson(Object? a, Object? b) {
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final key in a.keys) {
        if (!b.containsKey(key)) return false;
        if (!_sameJson(a[key], b[key])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_sameJson(a[i], b[i])) return false;
      }
      return true;
    }
    if (a is num && b is num) return a == b;
    return a == b;
  }

  static Future<void> _applyBlacklist(
    Map<String, Map<String, Map<String, dynamic>>> scopes,
  ) async {
    final songs = scopes[_ExtrasScope.blacklistSongs]?.values ?? const [];
    final artists = scopes[_ExtrasScope.blacklistArtists]?.values ?? const [];
    final whitelist =
        scopes[_ExtrasScope.blacklistWhitelist]?.values ?? const [];
    final data = BlacklistData(
      songs: [
        for (final item in songs)
          BlacklistEntry(
            title: '${item['title'] ?? ''}',
            artist: '${item['artist'] ?? ''}',
          ),
      ].where((entry) => !entry.isEmpty).toList(growable: false),
      artists: [
        for (final item in artists)
          if ('${item['name'] ?? ''}'.trim().isNotEmpty)
            '${item['name']}'.trim(),
      ],
      whitelist: [
        for (final item in whitelist)
          BlacklistEntry(
            title: '${item['title'] ?? ''}',
            artist: '${item['artist'] ?? ''}',
          ),
      ].where((entry) => !entry.isEmpty).toList(growable: false),
    );
    await BlacklistStore().save(data);
  }

  static Future<Set<String>> _applyRadio(
    WebDavService webdav,
    _LocalExtras local,
    Map<String, Map<String, Map<String, dynamic>>> scopes,
  ) async {
    final oldPaths = {
      for (final station in local.radio.stations) station.id: station.coverPath,
      'random': local.radio.randomStation?.coverPath,
    };
    final missingCovers = <String>{};

    Future<bool> fileExists(String? path) async {
      final value = path?.trim() ?? '';
      if (value.isEmpty) return false;
      try {
        return File(value).exists();
      } catch (_) {
        return false;
      }
    }

    /// 远端条目 → 本地封面路径。
    ///
    /// `coverDigest` 为空表示远端没有封面（用户清空封面时 `coverUrl` 也会
    /// 被清空）；没有这个字段的是旧快照，沿用本地路径。
    Future<String?> resolveCover(String key, Map<String, dynamic> data) async {
      final current = oldPaths[key];
      if (!data.containsKey('coverDigest')) return current;
      final digest = '${data['coverDigest'] ?? ''}'.trim();
      if (digest.isEmpty) {
        return '${data['coverUrl'] ?? ''}'.trim().isEmpty ? null : current;
      }
      if (local.coverDigests[key] == digest && await fileExists(current)) {
        return current;
      }
      final bytes = await webdav.readOptionalDataFile(
        '$coversDir/$digest.img',
      );
      if (bytes != null &&
          bytes.isNotEmpty &&
          sha256.convert(bytes).toString() == digest) {
        final saved = await RadioCoverCache.saveSynced(digest, bytes);
        if (saved != null) return saved;
      }
      missingCovers.add(digest);
      if (await fileExists(current)) return current;
      // 封面文件取不到时，远端网络地址还有机会直接缓存。
      final url = '${data['coverUrl'] ?? ''}'.trim();
      if (url.startsWith('http://') || url.startsWith('https://')) {
        return RadioCoverCache.cache(url);
      }
      return null;
    }

    final categoryItems =
        scopes[_ExtrasScope.radioCategories]?.values.toList() ?? const [];
    final categoryIds = {for (final item in categoryItems) item['id']};
    final categories = <RadioCategory>[
      for (final category in local.radio.categories)
        if (categoryIds.contains(category.id))
          RadioCategory(
            id: category.id,
            name: '${scopes[_ExtrasScope.radioCategories]![category.id]!['name'] ?? category.name}',
          ),
      for (final item in categoryItems)
        if (!local.radio.categories.any((c) => c.id == item['id']))
          RadioCategory(id: '${item['id']}', name: '${item['name'] ?? ''}'),
    ];

    final stationItems =
        scopes[_ExtrasScope.radioStations] ?? const {};
    final coverPaths = <String, String?>{};
    for (final entry in stationItems.entries) {
      coverPaths[entry.key] = await resolveCover(entry.key, entry.value);
    }

    RadioStation parseStation(Map<String, dynamic> data, String? coverPath) {
      final json = Map<String, dynamic>.from(data);
      if (coverPath != null && coverPath.isNotEmpty) {
        json['coverPath'] = coverPath;
      }
      return RadioStation.fromJson(json);
    }

    final stations = <RadioStation>[
      for (final station in local.radio.stations)
        if (stationItems.containsKey(station.id))
          parseStation(stationItems[station.id]!, coverPaths[station.id]),
      for (final item in stationItems.values)
        if (!local.radio.stations.any((s) => s.id == item['id']))
          parseStation(item, coverPaths['${item['id']}']),
    ];

    final randomItem = scopes[_ExtrasScope.radioRandom]?['random'];
    final randomCover = randomItem == null
        ? null
        : await resolveCover('random', randomItem);
    final random = randomItem == null
        ? null
        : parseStation(randomItem, randomCover);

    await RadioStore().save(
      RadioData(
        categories: categories,
        stations: stations,
        randomStation: random,
      ),
    );

    // 换封面后删掉不再被引用的旧缓存文件。
    final usedPaths = {
      for (final path in coverPaths.values)
        if (path != null && path.isNotEmpty) path,
      if (randomCover != null && randomCover.isNotEmpty) randomCover,
    };
    for (final path in oldPaths.values) {
      final value = path?.trim() ?? '';
      if (value.isEmpty || usedPaths.contains(value)) continue;
      await RadioCoverCache.remove(value);
    }
    return missingCovers;
  }

  // ------------------------------------------------------------ 本地数据

  static int _tombstoneCutoff() => DateTime.now()
      .subtract(const Duration(days: _tombstoneTtlDays))
      .millisecondsSinceEpoch;

  static int _asInt(Object? value) =>
      value is int ? value : (value is num ? value.toInt() : 0);

  static String _songKey(String title, String artist) =>
      '${blacklistNormalize(title)}|${blacklistNormalize(artist)}';

  static Map<String, dynamic> _stationData(
    RadioStation station,
    String coverDigest,
  ) => {
    'id': station.id,
    'name': station.name,
    'coverUrl': station.coverUrl,
    'coverDigest': coverDigest,
    'categoryId': station.categoryId,
    'sourceIds': station.sourceIds,
    'tags': [for (final tag in station.tags) tag.toJson()],
    'keywords': station.keywords,
    'createTime': station.createTime.toIso8601String(),
    'updateTime': station.updateTime.toIso8601String(),
  };

  static String _hashOf(Map<String, dynamic> data) =>
      sha256.convert(utf8.encode(jsonEncode(data))).toString();

  // ------------------------------------------------------------ 已上传封面

  static const String _uploadedCoversKey = 'extras_uploaded_covers_v1';

  static Set<String> _uploadedCovers() => _readDigests(_uploadedCoversKey);

  static Future<void> _saveUploadedCovers(Set<String> digests) =>
      _writeDigests(_uploadedCoversKey, digests);

  static Set<String> _readDigests(String key) {
    final prefs = AppPreferences.maybeInstance;
    if (prefs == null) return {};
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return {};
      return {for (final item in decoded) '$item'};
    } catch (_) {
      return {};
    }
  }

  static Future<void> _writeDigests(String key, Set<String> digests) async {
    final prefs = await AppPreferences.getInstance();
    final list = digests.toList()..sort();
    await prefs.setString(key, jsonEncode(list));
  }
}

/// 各数据集的 scope 名（同时作为快照里的 key 和墓碑分组）。
class _ExtrasScope {
  static const blacklistSongs = 'blacklist.songs';
  static const blacklistArtists = 'blacklist.artists';
  static const blacklistWhitelist = 'blacklist.whitelist';
  static const radioCategories = 'radio.categories';
  static const radioStations = 'radio.stations';
  static const radioRandom = 'radio.random';

  static const all = [
    blacklistSongs,
    blacklistArtists,
    blacklistWhitelist,
    radioCategories,
    radioStations,
    radioRandom,
  ];
}

class _LocalCover {
  const _LocalCover(this.path);

  final String path;
}

class _ApplyOutcome {
  const _ApplyOutcome({required this.result, required this.missingCovers});

  final ExtrasSyncResult result;

  /// 远端引用了、但下载失败的封面摘要（下次发布时允许重新补传）。
  final Set<String> missingCovers;
}

/// 本机的附加数据快照。
class _LocalExtras {
  const _LocalExtras({
    required this.blacklist,
    required this.radio,
    required this.scopes,
    required this.covers,
    required this.coverDigests,
  });

  final BlacklistData blacklist;
  final RadioData radio;

  /// scope → key → 内容（已带 `changedAt` 占位，由日志在 build 时补齐）。
  final Map<String, Map<String, Map<String, dynamic>>> scopes;

  /// 电台封面摘要 → 图片内容（用于补传远端缺失的封面）。
  final Map<String, _LocalCover> covers;

  /// 电台 key（电台 id / `random`）→ 本地封面摘要。
  final Map<String, String> coverDigests;

  static Future<_LocalExtras> load() async {
    final blacklist = await BlacklistStore().load();
    final radio = await RadioStore().load();

    final covers = <String, _LocalCover>{};
    final coverDigests = <String, String>{};
    Future<void> readCover(String key, RadioStation? station) async {
      final path = station?.coverPath?.trim() ?? '';
      if (path.isEmpty) {
        coverDigests[key] = '';
        return;
      }
      try {
        final file = File(path);
        if (!await file.exists()) {
          coverDigests[key] = '';
          return;
        }
        final bytes = await file.readAsBytes();
        final digest = sha256.convert(bytes).toString();
        coverDigests[key] = digest;
        covers[digest] = _LocalCover(path);
      } catch (e) {
        coverDigests[key] = '';
        debugPrint('[ExtrasSync] 读取电台封面失败: $e');
      }
    }

    for (final station in radio.stations) {
      await readCover(station.id, station);
    }
    final random = radio.randomStation;
    if (random != null) await readCover('random', random);

    final scopes = <String, Map<String, Map<String, dynamic>>>{
      _ExtrasScope.blacklistSongs: {
        for (final entry in blacklist.songs)
          entry.key: {'title': entry.title, 'artist': entry.artist},
      },
      _ExtrasScope.blacklistArtists: {
        for (final artist in blacklist.artists)
          blacklistNormalize(artist): {'name': artist},
      },
      _ExtrasScope.blacklistWhitelist: {
        for (final entry in blacklist.whitelist)
          entry.key: {'title': entry.title, 'artist': entry.artist},
      },
      _ExtrasScope.radioCategories: {
        for (final category in radio.categories)
          category.id: {'id': category.id, 'name': category.name},
      },
      _ExtrasScope.radioStations: {
        for (final station in radio.stations)
          station.id: ExtrasSyncService._stationData(
            station,
            coverDigests[station.id] ?? '',
          ),
      },
      _ExtrasScope.radioRandom: {
        if (radio.randomStation != null)
          'random': ExtrasSyncService._stationData(
            radio.randomStation!,
            coverDigests['random'] ?? '',
          ),
      },
    };

    return _LocalExtras(
      blacklist: blacklist,
      radio: radio,
      scopes: scopes,
      covers: covers,
      coverDigests: coverDigests,
    );
  }
}

/// 一次同步把哪些数据集写回了本地（用于只刷新相关 provider）。
class ExtrasSyncResult {
  const ExtrasSyncResult({this.blacklist = false, this.radio = false});

  final bool blacklist;
  final bool radio;

  bool get changed => blacklist || radio;

  static const none = ExtrasSyncResult();
}

/// 合并结果：展示项 + 仍然有效的删除墓碑。
class _MergedScope {
  const _MergedScope({required this.items, required this.tombstones});

  final Map<String, Map<String, dynamic>> items;
  final Map<String, int> tombstones;
}

class _ParsedExtras {
  const _ParsedExtras({
    required this.scopes,
    required this.changedAt,
    required this.tombstones,
    required this.coverDigests,
  });

  final Map<String, Map<String, Map<String, dynamic>>> scopes;
  final Map<String, Map<String, int>> changedAt;
  final Map<String, Map<String, int>> tombstones;
  final Set<String> coverDigests;
}

/// 本地变更日志：只记「哪条数据什么时候变的 / 什么时候删的」。
///
/// 数据本身（settings.json）仍然是唯一的事实来源，这里只是给
/// 合并提供时间戳；日志丢失时最多退化成「本地优先」，不会丢数据。
class _ExtrasJournal {
  _ExtrasJournal({
    required this.baseline,
    required this.changedAt,
    required this.tombstones,
  });

  /// scope → key → 上次同步时的内容摘要。
  final Map<String, Map<String, String>> baseline;

  /// scope → key → 最后一次变化时间。
  final Map<String, Map<String, int>> changedAt;

  /// scope → key → 删除时间。
  final Map<String, Map<String, int>> tombstones;

  static const String _key = 'extras_sync_journal_v1';

  static Future<_ExtrasJournal> load() async {
    final prefs = await AppPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return _ExtrasJournal._empty();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return _ExtrasJournal._empty();
      return _ExtrasJournal(
        baseline: _readStringMap(decoded['baseline']),
        changedAt: _readIntMap(decoded['changedAt']),
        tombstones: _readIntMap(decoded['tombstones']),
      );
    } catch (_) {
      return _ExtrasJournal._empty();
    }
  }

  static _ExtrasJournal _empty() => _ExtrasJournal(
    baseline: {},
    changedAt: {},
    tombstones: {},
  );

  static Map<String, Map<String, String>> _readStringMap(Object? raw) {
    final result = <String, Map<String, String>>{};
    if (raw is! Map) return result;
    raw.forEach((scope, value) {
      if (value is! Map) return;
      result['$scope'] = {
        for (final entry in value.entries) '${entry.key}': '${entry.value}',
      };
    });
    return result;
  }

  static Map<String, Map<String, int>> _readIntMap(Object? raw) {
    final result = <String, Map<String, int>>{};
    if (raw is! Map) return result;
    raw.forEach((scope, value) {
      if (value is! Map) return;
      result['$scope'] = {
        for (final entry in value.entries)
          if (entry.value is num)
            '${entry.key}': (entry.value as num).toInt(),
      };
    });
    return result;
  }

  /// 两个 scope 的内容摘要表是否完全一致（用于判断重建基线有没有变化）。
  static bool _sameBaseline(
    Map<String, String>? previous,
    Map<String, String> next,
  ) {
    final left = previous ?? const <String, String>{};
    if (left.length != next.length) return false;
    for (final entry in next.entries) {
      if (left[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// 对比当前内容与上次基线：新增 / 修改打时间戳，消失的记墓碑。
  ///
  /// [stampChanges] 为 false 时只刷新基线（应用完远端数据后调用），
  /// 不会把远端带来的变更误标成本地新改动。
  ///
  /// 返回日志是否有变化（没有变化就不要写 settings.json，避免反向触发自动备份）。
  bool record(
    Map<String, Map<String, Map<String, dynamic>>> current, {
    bool stampChanges = true,
    int? now,
  }) {
    if (!stampChanges) {
      // 应用远端后只需重建基线。内容与旧基线一致时返回 false：
      // 每次合并都写一次 settings.json 会连带触发一次整包配置备份。
      var dirty = false;
      for (final entry in current.entries) {
        final next = {
          for (final item in entry.value.entries)
            item.key: ExtrasSyncService._hashOf(item.value),
        };
        if (!_sameBaseline(baseline[entry.key], next)) dirty = true;
        baseline[entry.key] = next;
      }
      return dirty;
    }

    var dirty = false;
    final ts = now ?? DateTime.now().millisecondsSinceEpoch;
    final cutoff = DateTime.now()
        .subtract(const Duration(days: ExtrasSyncService._tombstoneTtlDays))
        .millisecondsSinceEpoch;
    for (final entry in current.entries) {
      final scope = entry.key;
      final previous = baseline[scope] ?? const <String, String>{};
      final changed = changedAt.putIfAbsent(scope, () => {});
      final tombs = tombstones.putIfAbsent(scope, () => {});
      final nextBaseline = <String, String>{};
      for (final item in entry.value.entries) {
        final hash = ExtrasSyncService._hashOf(item.value);
        nextBaseline[item.key] = hash;
        if (previous[item.key] != hash) {
          changed[item.key] = ts;
          tombs.remove(item.key);
          dirty = true;
        }
      }
      for (final key in previous.keys) {
        if (nextBaseline.containsKey(key)) continue;
        tombs[key] = ts;
        changed.remove(key);
        dirty = true;
      }
      tombs.removeWhere((_, value) => value < cutoff);
      baseline[scope] = nextBaseline;
      if (changed.isEmpty) changedAt.remove(scope);
      if (tombs.isEmpty) tombstones.remove(scope);
    }
    return dirty;
  }

  /// 给本地内容补上变更时间，供快照编码（未变过的条目不带 changedAt）。
  Map<String, Map<String, Map<String, dynamic>>> withStamps(
    Map<String, Map<String, Map<String, dynamic>>> local,
  ) {
    return {
      for (final entry in local.entries)
        entry.key: {
          for (final item in entry.value.entries)
            item.key: {
              ...item.value,
              if ((changedAt[entry.key]?[item.key] ?? 0) > 0 &&
                  !item.value.containsKey('changedAt'))
                'changedAt': changedAt[entry.key]![item.key],
            },
        },
    };
  }

  /// 把远端的时间戳 / 墓碑并进来（取较大值）；返回是否真的有变化。
  bool absorbRemote(
    Map<String, Map<String, int>> remoteChangedAt,
    Map<String, Map<String, int>> remoteTombstones,
  ) {
    var dirty = false;

    void absorb(
      Map<String, Map<String, int>> target,
      Map<String, Map<String, int>> source,
    ) {
      source.forEach((scope, items) {
        final targetScope = target.putIfAbsent(scope, () => {});
        items.forEach((key, value) {
          final existing = targetScope[key] ?? 0;
          if (value > existing) {
            targetScope[key] = value;
            dirty = true;
          }
        });
      });
    }

    absorb(changedAt, remoteChangedAt);
    absorb(tombstones, remoteTombstones);
    return dirty;
  }

  Future<void> save() async {
    final prefs = await AppPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode({
        'baseline': baseline,
        'changedAt': changedAt,
        'tombstones': tombstones,
      }),
    );
  }
}