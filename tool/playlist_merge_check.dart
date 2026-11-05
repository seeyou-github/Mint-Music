// 逐首合并算法的自查脚本（纯 Dart，直接跑 lib 里的实现）。
//
//   dart run tool/playlist_merge_check.dart
//
// 想顺带用真实收藏文件跑一遍「不丢歌 + 耗时」，先设环境变量：
//   MINTMUSIC_PLAYLISTS=<playlists.json 路径>
//
// 覆盖：两端各加歌、删除传播、删后重加、改名不被加歌覆盖、双向合并收敛、
// 键顺序无关、以及用真实收藏数据跑一遍性能 / 不丢歌。
import 'dart:convert';
import 'dart:io';

import 'package:mintmusic/core/backup/playlist_merge.dart';

int _failures = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    stdout.writeln('  ✓ $name');
  } else {
    _failures++;
    stdout.writeln('  ✗ $name${detail == null ? '' : '  → $detail'}');
  }
}

Map<String, dynamic> song(String id, {int ts = 0}) => {
  'id': id,
  'title': '歌$id',
  'updatedAt': ts,
};

Map<String, dynamic> playlist({
  required String id,
  required String name,
  required int metaTs,
  required List<Map<String, dynamic>> songs,
  String updateTime = '2026-01-01T00:00:00.000',
}) => {
  'id': id,
  'name': name,
  'description': '',
  'coverImgUrl': '',
  'source': 'local',
  'createTime': '2026-01-01T00:00:00.000',
  'updateTime': updateTime,
  'meta': {playlistMetaUpdatedAtKey: metaTs},
  'songs': songs,
};

List<String> idsOf(List<Map<String, dynamic>> snapshot, [String id = 'p1']) {
  final p = snapshot.firstWhere((item) => item['id'] == id);
  return [for (final s in PlaylistMerge.songsOf(p)) '${s['id']}'];
}

List<Map<String, dynamic>> merge(
  List<Map<String, dynamic>> local,
  List<Map<String, dynamic>> remote, {
  Map<String, Map<String, int>> songTombstones = const {},
  Map<String, int> playlistTombstones = const {},
}) {
  return PlaylistMerge.mergeAll(
    local: local,
    remotePlaylists: remote,
    playlistTombstones: playlistTombstones,
    songTombstones: songTombstones,
  );
}

void main() {
  stdout.writeln('== 逐首合并 ==');

  // 1. 两端各加一首不同的歌
  final a1 = [
    playlist(id: 'p1', name: '歌单', metaTs: 100, songs: [song('s1')]),
  ];
  final b1 = [
    playlist(id: 'p1', name: '歌单', metaTs: 100, songs: [song('s2')]),
  ];
  var merged = merge(a1, b1);
  check('两端各加一首 → 并集', idsOf(merged).toSet().containsAll(['s1', 's2']),
      idsOf(merged).toString());

  // 2. 双向合并结果一致（收敛）
  final ab = merge(a1, b1);
  final ba = merge(b1, a1);
  check('A∪B 与 B∪A 完全一致',
      PlaylistMerge.samePlaylists(ab, ba));
  check('再合并一次是幂等的', PlaylistMerge.samePlaylists(merge(ab, ba), ab));

  // 3. 删除传播：B 端删掉了 s1，带墓碑
  final b3 = [
    playlist(id: 'p1', name: '歌单', metaTs: 100, songs: [song('s2')]),
  ];
  final merged3 = merge(
    a1,
    b3,
    songTombstones: {
      'p1': {'s1': 200},
    },
  );
  check('删除墓碑生效（s1 不再回来）', !idsOf(merged3).contains('s1'),
      idsOf(merged3).toString());
  check('s2 仍然在', idsOf(merged3).contains('s2'));

  // 4. 删掉之后又加回来（记录时间晚于删除时间）→ 保留
  final a4 = [
    playlist(
      id: 'p1',
      name: '歌单',
      metaTs: 100,
      songs: [song('s1', ts: 300), song('s2', ts: 50)],
    ),
  ];
  final merged4 = merge(
    a4,
    b3,
    songTombstones: {
      'p1': {'s1': 200},
    },
  );
  check('删后重加（更新时间更晚）→ 保留', idsOf(merged4).contains('s1'),
      idsOf(merged4).toString());

  // 5. 一端改名、另一端加歌 → 改名不能被加歌的 updateTime 覆盖
  final a5 = [
    playlist(
      id: 'p1',
      name: '新名字',
      metaTs: 500,
      songs: [song('s1')],
      updateTime: '2026-01-01T00:00:00.500',
    ),
  ];
  final b5 = [
    playlist(
      id: 'p1',
      name: '旧名字',
      metaTs: 100,
      songs: [song('s1'), song('s2')],
      updateTime: '2026-01-01T00:00:09.000',
    ),
  ];
  final merged5 = merge(a5, b5);
  check('改名保留（较新的 metaUpdatedAt 胜）', merged5.first['name'] == '新名字',
      '${merged5.first['name']}');
  check('另一端的歌也合进来', idsOf(merged5).toSet().containsAll(['s1', 's2']),
      idsOf(merged5).toString());

  // 6. 同一时间戳、不同顺序 → 两端选出同一个赢家
  final a6 = [
    playlist(id: 'p1', name: '歌单', metaTs: 100, songs: [song('s1'), song('s2')]),
  ];
  final b6 = [
    playlist(id: 'p1', name: '歌单', metaTs: 100, songs: [song('s2'), song('s1')]),
  ];
  final ab6 = merge(a6, b6);
  final ba6 = merge(b6, a6);
  check('时间戳相同、顺序不同 → 结果一致',
      PlaylistMerge.samePlaylists(ab6, ba6),
      '${idsOf(ab6)} vs ${idsOf(ba6)}');

  // 7. 歌单删除传播
  final merged7 = merge(
    a1,
    const [],
    playlistTombstones: {'p1': DateTime.now().millisecondsSinceEpoch},
  );
  check('歌单墓碑生效（整单被删）', merged7.isEmpty);

  // 8. 歌单删除时间早于歌单最后变化 → 说明是「删了又重建」，保留
  final merged8 = merge(a1, const [], playlistTombstones: {'p1': 1});
  check('墓碑比歌单旧 → 保留', merged8.length == 1);

  // 9. 键顺序不影响「内容是否相同」
  final reordered = [
    {
      'songs': [
        {'updatedAt': 0, 'title': '歌s1', 'id': 's1'},
      ],
      'meta': {playlistMetaUpdatedAtKey: 100},
      'updateTime': '2026-01-01T00:00:00.000',
      'createTime': '2026-01-01T00:00:00.000',
      'source': 'local',
      'coverImgUrl': '',
      'description': '',
      'name': '歌单',
      'id': 'p1',
    },
  ];
  check(
    '键顺序不同也判定为「内容相同」',
    PlaylistMerge.samePlaylists(a1, reordered),
    'A=${PlaylistMerge.canonical(a1.first)}\n     B=${PlaylistMerge.canonical(reordered.first)}',
  );

  // 10. 老客户端没带 updatedAt / metaUpdatedAt 也不崩
  final legacy = [
    {
      'id': 'p1',
      'name': '老歌单',
      'updateTime': '2025-12-01T00:00:00.000',
      'songs': [
        {'id': 's9'},
      ],
    },
  ];
  final merged10 = merge(legacy, const []);
  check('老数据（无 updatedAt/meta）可合并',
      merged10.length == 1 && idsOf(merged10).contains('s9'));

  // 11. 真实数据：895 首跑一遍，确认不丢歌 + 耗时
  final realPath = Platform.environment['MINTMUSIC_PLAYLISTS'] ?? '';
  final file = File(realPath);
  if (file.existsSync()) {
    final raw = jsonDecode(file.readAsStringSync());
    final real = [
      for (final item in raw as List)
        {
          ...(item as Map).map((key, value) => MapEntry('$key', value)),
          'meta': {
            playlistMetaUpdatedAtKey: DateTime.parse(
              (item['updateTime'] as String?) ?? '2026-01-01T00:00:00Z',
            ).millisecondsSinceEpoch,
          },
          'songs': [
            for (final s in (item['songs'] as List? ?? []))
              {
                ...(s as Map).map((key, value) => MapEntry('$key', value)),
                'updatedAt': 1000,
              },
          ],
        },
    ];
    final stopwatch = Stopwatch()..start();
    final mergedReal = merge(real, real);
    stopwatch.stop();
    final before = real.expand((p) => (p['songs'] as List)).length;
    final after = mergedReal.expand((p) => (p['songs'] as List)).length;
    check('真实数据自合并不丢歌（$before → $after）', before == after);
    check(
      '真实数据合并耗时 ${stopwatch.elapsedMilliseconds}ms（< 200ms）',
      stopwatch.elapsedMilliseconds < 200,
    );
  }

  stdout.writeln(_failures == 0 ? '\n全部通过' : '\n$_failures 项失败');
  exit(_failures == 0 ? 0 : 1);
}
