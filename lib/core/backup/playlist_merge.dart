import 'dart:convert';

/// 歌单 meta 里记录「歌单信息最后修改时间」的键。
///
/// 逐首合并时：歌曲用各自的 `updatedAt` 判断，歌单信息（名字 / 封面 / 描述）
/// 用这个时间判断。不分开的话，「这台改了名、那台加了首歌」会让改名被
/// 较新的加歌时间覆盖掉。
const String playlistMetaUpdatedAtKey = 'metaUpdatedAt';

/// 歌单快照的合并算法（纯 Dart，方便单测 / 脚本直接验证）。
///
/// 输入输出都是「快照里的歌单 JSON Map」：
/// ```json
/// { "id": "...", "name": "...", "updateTime": "...",
///   "meta": { "metaUpdatedAt": 1 },
///   "songs": [ { "id": "...", "updatedAt": 1 } ] }
/// ```
class PlaylistMerge {
  const PlaylistMerge._();

  /// 合并本地与远端的全部歌单。
  ///
  /// * [playlistTombstones]：歌单级墓碑，删除时间晚于歌单最后变化 → 不保留；
  /// * [songTombstones]：歌曲级墓碑，`歌单id → (歌曲id → 删除时间)`。
  static List<Map<String, dynamic>> mergeAll({
    required List<Map<String, dynamic>> local,
    required Object? remotePlaylists,
    required Map<String, int> playlistTombstones,
    required Map<String, Map<String, int>> songTombstones,
    String favoritesId = '__favorites__',
  }) {
    final localById = <String, Map<String, dynamic>>{};
    for (final item in local) {
      final id = idOf(item);
      if (id.isNotEmpty) localById[id] = item;
    }
    final remoteById = <String, Map<String, dynamic>>{};
    if (remotePlaylists is List) {
      for (final item in remotePlaylists) {
        if (item is! Map) continue;
        final json = item.map((key, value) => MapEntry('$key', value));
        final id = idOf(json);
        if (id.isNotEmpty) remoteById[id] = json;
      }
    }

    final ids = <String>[
      ...localById.keys,
      ...remoteById.keys.where((id) => !localById.containsKey(id)),
    ];

    final merged = <Map<String, dynamic>>[];
    for (final id in ids) {
      final localJson = localById[id];
      final remoteJson = remoteById[id];
      Map<String, dynamic>? result;
      if (localJson == null) {
        result = remoteJson;
      } else if (remoteJson == null) {
        result = localJson;
      } else {
        result = mergePlaylist(
          localJson,
          remoteJson,
          songTombstones[id] ?? const {},
        );
      }
      if (result == null) continue;
      final deletedAt = playlistTombstones[id] ?? 0;
      if (deletedAt > 0 && deletedAt > latestTimestamp(result)) continue;
      merged.add(result);
    }

    // 「我的收藏」永远排在最前面。
    final index = merged.indexWhere((p) => idOf(p) == favoritesId);
    if (index > 0) {
      final favorites = merged.removeAt(index);
      merged.insert(0, favorites);
    }
    return merged;
  }

  /// 合并同一个歌单的两份数据（逐首）。
  static Map<String, dynamic> mergePlaylist(
    Map<String, dynamic> local,
    Map<String, dynamic> remote,
    Map<String, int> songTombstones,
  ) {
    final localSongs = songsOf(local);
    final remoteSongs = songsOf(remote);

    // 赢家决定「排序基准」和「歌单信息」（名字 / 封面 / 描述）。
    final remoteWins = compareVersion(local, remote) < 0;
    final winner = remoteWins ? remote : local;
    final winnerSongs = remoteWins ? remoteSongs : localSongs;
    final loserSongs = remoteWins ? localSongs : remoteSongs;

    // 逐首合并：同 id 取 updatedAt 较新的那份。
    final byId = <String, Map<String, dynamic>>{};
    for (final song in loserSongs) {
      final id = songIdOf(song);
      if (id.isEmpty) continue;
      byId[id] = song;
    }
    for (final song in winnerSongs) {
      final id = songIdOf(song);
      if (id.isEmpty) continue;
      final existing = byId[id];
      // 时间相同时以赢家那份为准（赢家在后，`>=` 覆盖）。
      if (existing == null || songTimestamp(song) >= songTimestamp(existing)) {
        byId[id] = song;
      }
    }

    // 删除墓碑：删除时间不早于这份记录的更新时间 → 这首歌确实已被删掉。
    byId.removeWhere((id, song) {
      final deletedAt = songTombstones[id];
      if (deletedAt == null) return false;
      return deletedAt >= songTimestamp(song);
    });

    final ordered = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final song in [...winnerSongs, ...loserSongs]) {
      final id = songIdOf(song);
      if (id.isEmpty || !seen.add(id)) continue;
      final kept = byId[id];
      if (kept != null) ordered.add(kept);
    }

    return <String, dynamic>{
      for (final entry in winner.entries)
        if (entry.key != 'songs') entry.key: entry.value,
      // 更新时间取两边较晚的一个，避免每次合并都往回缩。
      'updateTime': laterIso(local['updateTime'], remote['updateTime']),
      'songs': ordered,
    };
  }

  /// 比较两份歌单信息谁更新：> 0 表示 [a] 更新。
  ///
  /// 时间相同时按内容比较（稳定、可复现），保证两台设备算出同一个赢家，
  /// 不会各自保留自己的顺序来回覆盖。
  static int compareVersion(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
  ) {
    final at = metaTimestamp(a);
    final bt = metaTimestamp(b);
    if (at != bt) return at.compareTo(bt);
    return stableKey(a).compareTo(stableKey(b));
  }

  /// 用于「同一时间戳」时决出唯一赢家的稳定键。
  static String stableKey(Map<String, dynamic> json) {
    final fields = {
      'name': json['name'],
      'description': json['description'],
      'coverImgUrl': json['coverImgUrl'],
      'source': json['source'],
      'meta': json['meta'],
    };
    return '${jsonEncode(fields)}|'
        '${[for (final song in songsOf(json)) songIdOf(song)].join(',')}';
  }

  static List<Map<String, dynamic>> songsOf(Map<String, dynamic> json) {
    final raw = json['songs'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) item.map((key, value) => MapEntry('$key', value)),
    ];
  }

  static String idOf(Map<String, dynamic> json) => '${json['id'] ?? ''}';

  static String songIdOf(Map<String, dynamic> song) => '${song['id'] ?? ''}';

  static int songTimestamp(Map<String, dynamic> song) {
    final raw = song['updatedAt'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse('$raw') ?? 0;
  }

  /// 歌单信息最后修改时间（没有记录时回退 `updateTime`）。
  static int metaTimestamp(Map<String, dynamic> json) {
    final meta = json['meta'];
    if (meta is Map) {
      final millis = toMillis(meta[playlistMetaUpdatedAtKey]);
      if (millis != null) return millis;
    }
    return updatedAt(json);
  }

  /// 歌单最近一次变化的时间（信息或歌曲），用来判断删除墓碑是否更新。
  static int latestTimestamp(Map<String, dynamic> json) {
    var latest = updatedAt(json);
    for (final song in songsOf(json)) {
      final ts = songTimestamp(song);
      if (ts > latest) latest = ts;
    }
    return latest;
  }

  static String? laterIso(Object? a, Object? b) {
    final at = DateTime.tryParse('${a ?? ''}');
    final bt = DateTime.tryParse('${b ?? ''}');
    if (at == null) return b == null ? null : '$b';
    if (bt == null) return '$a';
    return (bt.isAfter(at) ? bt : at).toIso8601String();
  }

  static int updatedAt(Map<String, dynamic> json) {
    final parsed = DateTime.tryParse('${json['updateTime'] ?? ''}');
    return parsed?.millisecondsSinceEpoch ?? 0;
  }

  static int? toMillis(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value');
  }

  /// 两份快照内容是否一致（顺序也要一致）。
  ///
  /// 用「键排序后的规范字符串」比较：快照经过一次「导出 → 导入 → 导出」后
  /// 键顺序可能变化，直接 `jsonEncode` 比较会误判成「有变化」，导致每次同步
  /// 都白写一遍本地并重推远端。
  static bool samePlaylists(
    List<Map<String, dynamic>> a,
    List<Map<String, dynamic>> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (canonical(a[i]) != canonical(b[i])) return false;
    }
    return true;
  }

  /// 忽略「歌单顺序 / 歌曲顺序」比较两份内容是否相同。
  ///
  /// 各端都保留自己的展示顺序，排序差异不该触发回推（否则两台设备会互相
  /// 推版本）。但歌单、歌曲、歌单信息的任何增减改都必须报不同，这样远端
  /// 被清空或被旧备份覆盖后，还能靠干净设备把缺失内容补回去。
  static bool sameContentIgnoringOrder(
    List<Map<String, dynamic>> a,
    List<Map<String, dynamic>> b,
  ) {
    if (a.length != b.length) return false;
    final byId = <String, String>{
      for (final playlist in a) idOf(playlist): contentKeyOf(playlist),
    };
    if (byId.length != a.length) return false;
    for (final playlist in b) {
      final key = byId.remove(idOf(playlist));
      if (key == null || key != contentKeyOf(playlist)) return false;
    }
    return byId.isEmpty;
  }

  /// 单个歌单的内容键：歌单字段 + 歌曲内容，两层都不看顺序。
  static String contentKeyOf(Map<String, dynamic> playlist) {
    final songKeys = [
      for (final song in songsOf(playlist)) '${songIdOf(song)}|${canonical(song)}',
    ]..sort();
    final playlistFields = <String, dynamic>{
      for (final entry in playlist.entries)
        if (entry.key != 'songs') entry.key: entry.value,
    };
    return '${canonical(playlistFields)}|${songKeys.join('\n')}';
  }

  static String canonical(Object? value, [StringBuffer? buffer]) {
    final out = buffer ?? StringBuffer();
    if (value is Map) {
      final entries = [
        for (final entry in value.entries)
          MapEntry('${entry.key}', entry.value),
      ]..sort((x, y) => x.key.compareTo(y.key));
      out.write('{');
      for (var i = 0; i < entries.length; i++) {
        if (i > 0) out.write(',');
        out.write(jsonEncode(entries[i].key));
        out.write(':');
        canonical(entries[i].value, out);
      }
      out.write('}');
    } else if (value is List) {
      out.write('[');
      for (var i = 0; i < value.length; i++) {
        if (i > 0) out.write(',');
        canonical(value[i], out);
      }
      out.write(']');
    } else {
      out.write(jsonEncode(value));
    }
    return buffer == null ? out.toString() : '';
  }
}
