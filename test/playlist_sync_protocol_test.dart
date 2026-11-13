import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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
        throwsA(isA<FormatException>()),
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
        PlaylistSnapshot.digestOf(PlaylistSnapshot.encode(a)),
        PlaylistSnapshot.digestOf(PlaylistSnapshot.encode(b)),
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

    test('远端 digest 与本地指纹是两套稳定摘要', () {
      final snapshot = PlaylistSnapshot.build(
        playlists: [
          playlist('p1', ['s1']),
        ],
        playlistTombstones: const {},
        songTombstones: const {},
      );
      final bytes = PlaylistSnapshot.encode(snapshot);
      final digest = PlaylistSnapshot.digestOf(bytes);
      final fingerprint = PlaylistSnapshot.fingerprintOf(snapshot);
      expect(digest, hasLength(64));
      expect(fingerprint, hasLength(64));
      expect(digest, isNot(fingerprint));
      expect(PlaylistSnapshot.fingerprintOf(snapshot), fingerprint);
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
      lastSyncAt: 0,
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
  });

  group('PlaylistSyncState', () {
    test('JSON 往返保留全部字段', () {
      const state = PlaylistSyncState(
        epoch: 'e',
        revision: 2,
        digest: 'd',
        localFingerprint: 'f',
        lastSyncAt: 9,
      );
      final decoded = PlaylistSyncState.fromJson(
        jsonDecode(jsonEncode(state.toJson())) as Map,
      );
      expect(decoded.epoch, 'e');
      expect(decoded.revision, 2);
      expect(decoded.digest, 'd');
      expect(decoded.localFingerprint, 'f');
      expect(decoded.lastSyncAt, 9);
    });

    test('字段非法抛 FormatException', () {
      expect(
        () => PlaylistSyncState.fromJson({'epoch': 'e'}),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
