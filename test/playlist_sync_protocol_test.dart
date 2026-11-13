import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/backup/playlist_merge.dart';
import 'package:mintmusic/core/backup/playlist_sync_protocol.dart';

void main() {
  String metaText({
    int schema = playlistMetaSchema,
    int revision = 3,
    String digest =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    int size = 100,
  }) => jsonEncode({
    'schema': schema,
    'epoch': 'epoch-1',
    'revision': revision,
    'digest': digest,
    'size': size,
    'updatedAt': 1,
    'writer': 'device-a',
  });

  group('PlaylistMeta', () {
    test('解析并保留 ETag（ETag 不写进 JSON）', () {
      final meta = PlaylistMeta.fromText(metaText(), etag: '"etag-1"');
      expect(meta.revision, 3);
      expect(meta.epoch, 'epoch-1');
      expect(meta.size, 100);
      expect(meta.etag, '"etag-1"');
      expect(meta.toJson().containsKey('etag'), isFalse);
    });

    test('schema 不兼容时给出可读错误', () {
      expect(
        () => PlaylistMeta.fromText(metaText(schema: 99)),
        throwsA(isA<PlaylistSchemaException>()),
      );
    });

    test('缺字段 / 非法 revision 抛 FormatException', () {
      expect(
        () => PlaylistMeta.fromText(jsonEncode({'schema': 1})),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => PlaylistMeta.fromText(metaText(revision: 0)),
        throwsA(isA<FormatException>()),
      );
    });

    test('digest 必须是 64 位十六进制（会拼进文件名）', () {
      expect(
        () => PlaylistMeta.fromText(metaText(digest: 'abc')),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => PlaylistMeta.fromText(
          metaText(digest: '../../${'a' * 60}'),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('next 只递增 revision，并更新 digest / size', () {
      final meta = PlaylistMeta.fromText(metaText());
      final next = meta.next(
        digest:
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        size: 200,
        writer: 'device-b',
      );
      expect(next.revision, 4);
      expect(next.digest, startsWith('bbbb'));
      expect(next.size, 200);
      expect(next.epoch, meta.epoch);
      expect(next.etag, isNull);
    });
  });

  group('PlaylistSnapshot', () {
    Map<String, dynamic> playlist(String id, List<String> songIds) => {
      'id': id,
      'name': id,
      'songs': [
        for (final songId in songIds) {'id': songId, 'updatedAt': 1},
      ],
    };

    test('墓碑插入顺序不影响 JSON 与 digest', () {
      final a = PlaylistSnapshot.build(
        playlists: [
          playlist('p1', ['s1', 's2']),
        ],
        playlistTombstones: {'z': 2, 'a': 1},
        songTombstones: {
          'p2': {'y': 4, 'b': 3},
        },
      );
      final b = PlaylistSnapshot.build(
        playlists: [
          playlist('p1', ['s1', 's2']),
        ],
        playlistTombstones: {'a': 1, 'z': 2},
        songTombstones: {
          'p2': {'b': 3, 'y': 4},
        },
      );
      expect(jsonEncode(a), jsonEncode(b));
      expect(
        PlaylistSnapshot.digestOf(a),
        PlaylistSnapshot.digestOf(b),
      );
    });

    test('编码 / 解码往返', () {
      final snapshot = PlaylistSnapshot.build(
        playlists: [
          playlist('p1', ['s1']),
        ],
        playlistTombstones: {'gone': 10},
        songTombstones: {
          'p1': {'s9': 11},
        },
      );
      final decoded = PlaylistSnapshot.decode(
        PlaylistSnapshot.encode(snapshot),
      );
      expect(decoded['schema'], playlistSnapshotSchema);
      expect((decoded['playlists'] as List).length, 1);
      expect((decoded['deleted'] as List).length, 1);
      expect((decoded['deletedSongs'] as List).length, 1);
    });

    test('损坏的 gzip 抛 FormatException', () {
      expect(
        () => PlaylistSnapshot.decode(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<FormatException>()),
      );
    });

    test('digest 基于未压缩内容，解码后仍算回同一个摘要', () {
      final snapshot = PlaylistSnapshot.build(
        playlists: [
          playlist('p1', ['s1']),
        ],
        playlistTombstones: const {},
        songTombstones: const {},
      );
      final digest = PlaylistSnapshot.digestOf(snapshot);
      expect(digest, hasLength(64));
      expect(PlaylistSnapshot.fingerprintOf(snapshot), digest);
      // 下载后先解压再算摘要，压缩格式 / zlib 版本不影响校验结果。
      final decoded = PlaylistSnapshot.decode(
        PlaylistSnapshot.encode(snapshot),
      );
      expect(PlaylistSnapshot.digestOf(decoded), digest);
    });

    test('也认上一版按 gzip 字节算出的摘要（升级前写下的远端快照）', () {
      final snapshot = PlaylistSnapshot.build(
        playlists: [
          playlist('p1', ['s1']),
        ],
        playlistTombstones: const {},
        songTombstones: const {},
      );
      final bytes = PlaylistSnapshot.encode(snapshot);
      final legacyDigest = sha256.convert(bytes).toString();
      final contentDigest = PlaylistSnapshot.digestOf(snapshot);
      expect(legacyDigest, isNot(contentDigest));
      expect(
        PlaylistSnapshot.matchesDigest(snapshot, bytes, legacyDigest),
        isTrue,
      );
      expect(
        PlaylistSnapshot.matchesDigest(snapshot, bytes, contentDigest),
        isTrue,
      );
      expect(
        PlaylistSnapshot.matchesDigest(snapshot, bytes, 'a' * 64),
        isFalse,
      );
    });
  });

  group('快照文件名', () {
    test('从新协议文件名取回 digest', () {
      final digest = 'a' * 64;
      final name = playlistSnapshotFileName(digest);
      expect(name, 'playlists.$digest.json.gz');
      expect(snapshotDigestOf(name), digest);
      expect(isPlaylistSnapshotFile(name), isTrue);
    });

    test('旧版 / 异常文件名不被当成新协议快照', () {
      for (final name in [
        'playlists.json.gz',
        'playlists.json',
        'playlists.meta.json',
        'playlists.${'a' * 63}.json.gz',
        'playlists.${'A' * 64}.json.gz',
        'playlists.${'a' * 64}.json',
        'other.${'a' * 64}.json.gz',
      ]) {
        expect(isPlaylistSnapshotFile(name), isFalse, reason: name);
        expect(snapshotDigestOf(name), isNull, reason: name);
      }
    });
  });

  group('decideSyncAction', () {
    const meta = PlaylistMeta(
      epoch: 'e',
      revision: 5,
      digest: 'd',
      size: 1,
      updatedAt: 0,
      writer: 'w',
    );
    const state = PlaylistSyncState(
      epoch: 'e',
      revision: 5,
      digest: 'd',
      localFingerprint: 'f',
    );

    test('远端未初始化 → pushLocal', () {
      expect(
        decideSyncAction(meta: null, state: null, localDirty: true),
        SyncAction.pushLocal,
      );
    });

    test('没有本地基线 → pullAndMerge', () {
      expect(
        decideSyncAction(meta: meta, state: null, localDirty: false),
        SyncAction.pullAndMerge,
      );
    });

    test('epoch / revision / digest 任一不同 → pullAndMerge', () {
      expect(
        decideSyncAction(
          meta: meta,
          state: state.copyWith(epoch: 'other'),
          localDirty: false,
        ),
        SyncAction.pullAndMerge,
      );
      expect(
        decideSyncAction(
          meta: meta,
          state: state.copyWith(revision: 4),
          localDirty: false,
        ),
        SyncAction.pullAndMerge,
      );
      expect(
        decideSyncAction(
          meta: meta,
          state: state.copyWith(digest: 'x'),
          localDirty: false,
        ),
        SyncAction.pullAndMerge,
      );
    });

    test('版本一致 + 本地有改动 → pushLocal', () {
      expect(
        decideSyncAction(meta: meta, state: state, localDirty: true),
        SyncAction.pushLocal,
      );
    });

    test('版本一致 + 本地干净 → noop（不下载也不上传）', () {
      expect(
        decideSyncAction(meta: meta, state: state, localDirty: false),
        SyncAction.noop,
      );
    });

    test('版本一致 + 本地有改动但只剩空库 → 改走合并，避免覆盖远端', () {
      expect(
        decideSyncAction(
          meta: meta,
          state: state,
          localDirty: true,
          localHasContent: false,
        ),
        SyncAction.pullAndMerge,
      );
      expect(
        decideSyncAction(
          meta: meta,
          state: state,
          localDirty: false,
          localHasContent: false,
        ),
        SyncAction.noop,
      );
    });
  });

  group('PlaylistSyncState', () {
    final digest = 'a' * 64;

    test('JSON 往返保留全部字段', () {
      final state = PlaylistSyncState(
        epoch: 'e',
        revision: 2,
        digest: digest,
        localFingerprint: 'f',
      );
      final decoded = PlaylistSyncState.fromJson(
        jsonDecode(jsonEncode(state.toJson())) as Map,
      );
      expect(decoded.epoch, 'e');
      expect(decoded.revision, 2);
      expect(decoded.digest, digest);
      expect(decoded.localFingerprint, 'f');
    });

    test('字段非法抛 FormatException', () {
      expect(
        () => PlaylistSyncState.fromJson({'epoch': 'e'}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => PlaylistSyncState.fromJson({
          'epoch': 'e',
          'revision': 2,
          'digest': 'd',
          'localFingerprint': 'f',
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('PlaylistMerge.sameContentIgnoringOrder', () {
    Map<String, dynamic> song(String id, {int updatedAt = 1, String name = ''}) => {
      'id': id,
      'name': name,
      'updatedAt': updatedAt,
    };
    Map<String, dynamic> playlist(
      String id, {
      String name = '',
      List<Map<String, dynamic>> songs = const [],
    }) => {'id': id, 'name': name, 'songs': songs};

    test('歌单顺序 / 歌曲顺序不同视为相同', () {
      final a = [
        playlist('p1', songs: [song('s1'), song('s2')]),
        playlist('p2', songs: [song('s3')]),
      ];
      final b = [
        playlist('p2', songs: [song('s3')]),
        playlist('p1', songs: [song('s2'), song('s1')]),
      ];
      expect(PlaylistMerge.sameContentIgnoringOrder(a, b), isTrue);
    });

    test('缺歌单 / 缺歌 / 改名 / 属性变化都视为不同', () {
      final base = [
        playlist('p1', name: 'A', songs: [song('s1')]),
      ];
      expect(
        PlaylistMerge.sameContentIgnoringOrder(base, const []),
        isFalse,
      );
      expect(
        PlaylistMerge.sameContentIgnoringOrder(base, [
          playlist('p1', name: 'A', songs: [song('s1'), song('s2')]),
        ]),
        isFalse,
      );
      expect(
        PlaylistMerge.sameContentIgnoringOrder(base, [
          playlist('p1', name: 'B', songs: [song('s1')]),
        ]),
        isFalse,
      );
      expect(
        PlaylistMerge.sameContentIgnoringOrder(base, [
          playlist('p1', name: 'A', songs: [song('s1', updatedAt: 2)]),
        ]),
        isFalse,
      );
    });

    test('id 重复视为不同（不能靠去重掩盖数据问题）', () {
      final a = [
        playlist('p1', songs: [song('s1')]),
        playlist('p2', songs: [song('s2')]),
      ];
      final b = [
        playlist('p1', songs: [song('s1')]),
        playlist('p1', songs: [song('s2')]),
      ];
      expect(PlaylistMerge.sameContentIgnoringOrder(a, b), isFalse);
      expect(PlaylistMerge.sameContentIgnoringOrder(b, a), isFalse);
    });
  });
}
