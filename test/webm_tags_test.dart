import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/download/domain/services/audio_tag_writer.dart';
import 'package:mintmusic/features/local/data/local_metadata_reader.dart';
import 'package:mintmusic/shared/utils/webm_tags.dart';

/// 造一个最小的 WebM：EBML 头 + Segment{Info, [Tags], Cluster, [Cues]}。
///
/// 只求结构合法（解析器按元素头逐层走），Cluster 里是假音频字节。
Uint8List buildMinimalWebm({
  required String infoTitle,
  required double durationMs,
  int fakeAudioBytes = 4096,
  List<(String, String)> tags = const [],
  bool withCues = false,
}) {
  final timecodeScale = Uint8List.fromList([0x0F, 0x42, 0x40]); // 1000000 ns
  final duration = Uint8List(8);
  ByteData.sublistView(duration).setFloat64(0, durationMs, Endian.big);

  final info = BytesBuilder(copy: false)
    ..add(WebmEbml.element(const [0x2A, 0xD7, 0xB1], timecodeScale))
    ..add(WebmEbml.element(const [0x44, 0x89], duration))
    ..add(
      WebmEbml.element(
        const [0x7B, 0xA9],
        Uint8List.fromList(utf8.encode(infoTitle)),
      ),
    );

  final clusterBytes = Uint8List(fakeAudioBytes);
  for (var i = 0; i < clusterBytes.length; i++) {
    clusterBytes[i] = i & 0xFF;
  }

  final segmentPayload = BytesBuilder(copy: false)
    ..add(WebmEbml.element(const [0x15, 0x49, 0xA9, 0x66], info.toBytes()));
  if (tags.isNotEmpty) {
    // 旧标签放在 Cluster 之前：模拟 ffmpeg / yt-dlp 写标签的位置。
    segmentPayload.add(WebmTags.build(tags));
  }
  // Cues 里的 Cluster 位置是「相对 Segment 数据区起点」的偏移。
  final clusterRelativePos = segmentPayload.length;
  segmentPayload.add(
    WebmEbml.element(const [0x1F, 0x43, 0xB6, 0x75], clusterBytes),
  );
  if (withCues) {
    final cuePoint = WebmEbml.elementById(
      WebmEbml.idCuePoint,
      WebmEbml.elementById(
        WebmEbml.idCueTrackPositions,
        WebmEbml.elementById(
          WebmEbml.idCueClusterPosition,
          WebmEbml.uintBytes(clusterRelativePos),
        ),
      ),
    );
    segmentPayload.add(
      WebmEbml.elementById(WebmEbml.idCues, cuePoint),
    );
  }

  final out = BytesBuilder(copy: false)
    ..add(
      WebmEbml.element(
        const [0x1A, 0x45, 0xDF, 0xA3],
        Uint8List.fromList(utf8.encode('webm')),
      ),
    )
    ..add(
      WebmEbml.element(const [0x18, 0x53, 0x80, 0x67], segmentPayload.toBytes()),
    );
  return out.toBytes();
}

/// 1x1 透明 PNG，当封面用。
final Uint8List tinyPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('webm_tag_test');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  File newFile(Uint8List bytes, [String name = 'sample.weba']) {
    final file = File('${tempDir.path}${Platform.pathSeparator}$name');
    file.writeAsBytesSync(bytes);
    return file;
  }

  group('WebmTags 编解码', () {
    test('build / parse 往返，名称统一大写', () {
      final bytes = WebmTags.build([
        ('title', '标题'),
        ('ARTIST', '歌手'),
        ('LYRICS', '[00:01.00]第一行'),
      ]);
      final parsed = WebmTags.toMap(WebmTags.parse(bytes));
      expect(parsed['TITLE'], '标题');
      expect(parsed['ARTIST'], '歌手');
      expect(parsed['LYRICS'], '[00:01.00]第一行');
    });

    test('build 产出规范的 Tags > Tag > Targets + SimpleTag', () {
      final bytes = WebmTags.build([('TITLE', '标题')]);
      final tagsHead = WebmEbml.headFromBytes(bytes, 0)!;
      expect(tagsHead.id, WebmEbml.idTags);
      // 第一层必须是 Tag（之前直接挂 SimpleTag，ffmpeg 会整段忽略）。
      final tagHead = WebmEbml.headFromBytes(bytes, tagsHead.dataPos)!;
      expect(tagHead.id, WebmEbml.idTag);
      // Tag 里第一个子元素是 Targets，且带 TargetTypeValue。
      final targetsHead = WebmEbml.headFromBytes(bytes, tagHead.dataPos)!;
      expect(targetsHead.id, WebmEbml.idTargets);
      final typeHead = WebmEbml.headFromBytes(bytes, targetsHead.dataPos)!;
      expect(typeHead.id, WebmEbml.idTargetTypeValue);
      expect(WebmEbml.uintFrom(bytes, typeHead.dataPos, typeHead.end), 50);
    });

    test('toMapLast 后写的值覆盖先写的', () {
      final map = WebmTags.toMapLast(const [
        ('TITLE', '专辑级标题'),
        ('TITLE', '音轨级标题'),
      ]);
      expect(map['TITLE'], '音轨级标题');
    });

    test('Void 元素与旧标签等长', () {
      for (final total in [3, 9, 64, 300]) {
        final voidBytes = WebmTags.buildVoid(total);
        expect(voidBytes, isNotNull);
        expect(voidBytes!.length, total);
        final head = WebmEbml.headFromBytes(voidBytes, 0);
        expect(head?.id, WebmEbml.idVoid);
        expect(head?.end, total);
      }
    });

    test('长度字段编码不越界', () {
      expect(WebmEbml.encodeSize(0, 1), isNotNull);
      expect(WebmEbml.encodeSize(126, 1), isNotNull);
      // 1 字节的数值位全 1（127）是「未知大小」的保留值
      expect(WebmEbml.encodeSize(127, 1), isNull);
      expect(WebmEbml.encodeSize(26934648, 8)!.length, 8);
    });
  });

  group('WebM 读取', () {
    test('读 Info 的时长与标题', () async {
      final file = newFile(
        buildMinimalWebm(infoTitle: 'Info 标题', durationMs: 12500),
      );
      final meta = await LocalMetadataReader.read(file.path);
      expect(meta.durationMs, 12500);
      expect(meta.title, 'Info 标题');
      expect(meta.artwork, isNull);
    });

    test('读 Cluster 之前的 Tags', () async {
      final file = newFile(
        buildMinimalWebm(
          infoTitle: 'Info 标题',
          durationMs: 1000,
          tags: [
            ('TITLE', '标签标题'),
            ('ARTIST', '标签歌手'),
            ('ALBUM', '标签专辑'),
            ('DATE_RECORDED', '2024-05-01'),
            ('GENRE', 'ASMR'),
            ('COMMENT', '备注'),
            ('LYRICS', '[00:01.00]你好'),
          ],
        ),
      );
      final meta = await LocalMetadataReader.read(file.path);
      expect(meta.title, '标签标题');
      expect(meta.artist, '标签歌手');
      expect(meta.album, '标签专辑');
      expect(meta.year, 2024);
      expect(meta.genre, 'ASMR');
      expect(meta.comment, '备注');
      expect(meta.lyrics, '[00:01.00]你好');
      expect(await LocalMetadataReader.readLyrics(file.path), '[00:01.00]你好');
    });
  });

  group('WebM 写入', () {
    test('重建后标签排在 Cluster 之前、SeekHead 指向它、可读回', () async {
      final original = buildMinimalWebm(infoTitle: '原标题', durationMs: 5000);
      final file = newFile(original);

      final ok = await AudioTagWriter.write(
        file.path,
        title: '新标题',
        artist: '新歌手',
        album: '新专辑',
        year: '2025',
        genre: 'ASMR',
        comment: '备注',
        lyrics: '[00:02.00]第二行',
      );
      expect(ok, isTrue);

      final written = file.readAsBytesSync();
      final tagsHead = _firstElement(written, WebmEbml.idTags);
      final clusterHead = _firstElement(written, WebmEbml.idCluster);
      expect(tagsHead, isNotNull, reason: '应该写入 Tags');
      expect(clusterHead, isNotNull);
      expect(
        tagsHead!.dataPos < clusterHead!.dataPos,
        isTrue,
        reason: 'Tags 必须在第一个 Cluster 之前（ffmpeg / mpv 顺序读得到）',
      );

      // SeekHead 里有 Tags 条目，且指向的位置就是它。
      final seekHead = _firstElement(written, WebmEbml.idSeekHead);
      expect(seekHead, isNotNull);
      expect(
        _seekHeadEntries(written, seekHead!)[WebmEbml.idTags],
        tagsHead.dataPos - tagsHead.headerSize - _segmentDataPos(written),
      );

      final meta = await LocalMetadataReader.read(file.path);
      expect(meta.title, '新标题');
      expect(meta.artist, '新歌手');
      expect(meta.album, '新专辑');
      expect(meta.year, 2025);
      expect(meta.genre, 'ASMR');
      expect(meta.comment, '备注');
      expect(meta.lyrics, '[00:02.00]第二行');
      expect(meta.durationMs, 5000, reason: '时长不该被标签写入影响');

      // Cluster 里的假音频字节一个都没变。
      expect(
        written.sublist(clusterHead.dataPos, clusterHead.end),
        original.sublist(
          _firstElement(original, WebmEbml.idCluster)!.dataPos,
          _firstElement(original, WebmEbml.idCluster)!.end,
        ),
      );
    });

    test('Cues 里的 Cluster 位置跟着新布局平移', () async {
      final file = newFile(
        buildMinimalWebm(infoTitle: 't', durationMs: 1000, withCues: true),
      );
      expect(
        await AudioTagWriter.write(file.path, title: '新标题', lyrics: '[00:01.00]词'),
        isTrue,
      );
      final written = file.readAsBytesSync();
      final cues = _firstElement(written, WebmEbml.idCues);
      final cluster = _firstElement(written, WebmEbml.idCluster);
      expect(cues, isNotNull);
      expect(cluster, isNotNull);
      final cuePos = _cueClusterPosition(written, cues!);
      expect(
        cuePos,
        cluster!.dataPos - cluster.headerSize - _segmentDataPos(written),
        reason: 'Cues 必须指向 Cluster 的新位置，否则播放器跳转会错位',
      );
    });

    test('重写不会让文件无限膨胀，也不产生两份标签', () async {
      final file = newFile(buildMinimalWebm(infoTitle: 't', durationMs: 1000));
      await AudioTagWriter.write(file.path, lyrics: '[00:01.00]aaaa');
      final afterFirst = file.lengthSync();
      await AudioTagWriter.write(file.path, lyrics: '[00:01.00]bbbb');
      final afterSecond = file.lengthSync();
      await AudioTagWriter.write(file.path, lyrics: '[00:01.00]cccc');
      final afterThird = file.lengthSync();

      expect((afterThird - afterFirst).abs(), lessThan(64));
      expect(afterSecond, isNot(equals(0)));

      final meta = await LocalMetadataReader.read(file.path);
      expect(meta.lyrics, '[00:01.00]cccc');
      expect(_countElements(file.readAsBytesSync(), WebmEbml.idTags), 1);
    });

    test('替换旧标签时未管理字段保留、同义年份键去重', () async {
      final file = newFile(
        buildMinimalWebm(
          infoTitle: 't',
          durationMs: 1000,
          tags: [
            ('TITLE', '旧标题'),
            ('CUSTOM_FIELD', '别动我'),
            ('DATE', '1999'),
          ],
        ),
      );
      final ok = await AudioTagWriter.write(file.path, title: '新标题', year: '2026');
      expect(ok, isTrue);

      final meta = await LocalMetadataReader.read(file.path);
      expect(meta.title, '新标题');
      expect(meta.year, 2026);

      final tags = WebmTags.toMap(_allTags(file.readAsBytesSync()));
      expect(tags['CUSTOM_FIELD'], '别动我');
      expect(tags['DATE'], isNull, reason: 'DATE 被 DATE_RECORDED 取代');
      expect(tags['DATE_RECORDED'], '2026');
    });

    test('没有标签要写时不动文件', () async {
      final file = newFile(buildMinimalWebm(infoTitle: 't', durationMs: 1000));
      final before = file.readAsBytesSync();
      final ok = await AudioTagWriter.write(file.path);
      expect(ok, isTrue);
      expect(file.readAsBytesSync(), before);
    });

    test('webm 支持写入封面（Attachments 图片附件）', () async {
      expect(AudioTagWriter.supports('a.weba'), isTrue);
      expect(AudioTagWriter.supportsArtwork('a.weba'), isTrue);
      expect(AudioTagWriter.supportsArtwork('a.webm'), isTrue);

      final file = newFile(buildMinimalWebm(infoTitle: 't', durationMs: 1000));
      final ok = await AudioTagWriter.write(
        file.path,
        title: '带封面的歌',
        artwork: tinyPng,
      );
      expect(ok, isTrue);

      final meta = await LocalMetadataReader.read(file.path);
      expect(meta.title, '带封面的歌');
      expect(meta.artwork, tinyPng, reason: '封面应该能从 Attachments 读回来');

      final raw = file.readAsBytesSync();
      expect(_countElements(raw, WebmEbml.idAttachments), 1);

      // 换封面：只保留一张图片附件。
      final replaced = await AudioTagWriter.write(
        file.path,
        artwork: Uint8List.fromList(List<int>.filled(120, 0xAB)),
      );
      expect(replaced, isTrue);
      final refs = _readAttachments(file.readAsBytesSync());
      expect(refs.length, 1);
      expect(refs.single.$1, 'cover.jpg');

      // 删封面：附件整段消失。
      expect(await AudioTagWriter.write(file.path, removeArtwork: true), isTrue);
      expect(_countElements(file.readAsBytesSync(), WebmEbml.idAttachments), 0);
      expect((await LocalMetadataReader.read(file.path)).artwork, isNull);
    });
  });
}

// ==================== 测试用的小工具 ====================

int _segmentDataPos(Uint8List data) {
  final ebml = WebmEbml.headFromBytes(data, 0)!;
  final segment = WebmEbml.headFromBytes(data, ebml.end)!;
  return segment.dataPos;
}

/// 按 ID 找第一个顶层元素（测试文件结构固定，顺序扫即可）。
WebmElementHead? _firstElement(Uint8List data, int id) {
  final segment = WebmEbml.headFromBytes(data, _segmentDataPos(data) - 5);
  var pos = _segmentDataPos(data);
  final end = segment == null ? data.length : segment.end;
  while (pos + 2 <= end) {
    final head = WebmEbml.headFromBytes(data, pos);
    if (head == null) return null;
    if (head.id == id) return head;
    final next = head.unknownSize ? end : head.end;
    if (next <= pos) return null;
    pos = next;
  }
  return null;
}

int _countElements(Uint8List data, int id) {
  var count = 0;
  var pos = _segmentDataPos(data);
  while (pos + 2 <= data.length) {
    final head = WebmEbml.headFromBytes(data, pos);
    if (head == null) break;
    if (head.id == id) count++;
    final next = head.unknownSize ? data.length : head.end;
    if (next <= pos) break;
    pos = next;
  }
  return count;
}

Map<int, int> _seekHeadEntries(Uint8List data, WebmElementHead seekHead) {
  final out = <int, int>{};
  var pos = seekHead.dataPos;
  while (pos < seekHead.end) {
    final seek = WebmEbml.headFromBytes(data, pos);
    if (seek == null) break;
    int? id;
    int? value;
    var itemPos = seek.dataPos;
    while (itemPos < seek.end) {
      final item = WebmEbml.headFromBytes(data, itemPos);
      if (item == null) break;
      if (item.id == WebmEbml.idSeekId) {
        id = WebmEbml.uintFrom(data, item.dataPos, item.end);
      } else if (item.id == WebmEbml.idSeekPosition) {
        value = WebmEbml.uintFrom(data, item.dataPos, item.end);
      }
      itemPos = item.end;
    }
    if (id != null && value != null) out[id] = value;
    pos = seek.end;
  }
  return out;
}

int _cueClusterPosition(Uint8List data, WebmElementHead cues) {
  int? found;
  void walk(int start, int end) {
    var pos = start;
    while (pos < end) {
      final head = WebmEbml.headFromBytes(data, pos);
      if (head == null) return;
      if (head.id == WebmEbml.idCueClusterPosition) {
        found ??= WebmEbml.uintFrom(data, head.dataPos, head.end);
      } else if (head.id == WebmEbml.idCuePoint ||
          head.id == WebmEbml.idCueTrackPositions) {
        walk(head.dataPos, head.end);
      }
      pos = head.end;
    }
  }

  walk(cues.dataPos, cues.end);
  return found ?? -1;
}

List<(String, String)> _readAttachments(Uint8List data) {
  final out = <(String, String)>[];
  final attachments = _firstElement(data, WebmEbml.idAttachments);
  if (attachments == null) return out;
  var pos = attachments.dataPos;
  while (pos < attachments.end) {
    final file = WebmEbml.headFromBytes(data, pos);
    if (file == null) break;
    if (file.id == WebmEbml.idAttachedFile) {
      var itemPos = file.dataPos;
      String name = '';
      while (itemPos < file.end) {
        final item = WebmEbml.headFromBytes(data, itemPos);
        if (item == null) break;
        if (item.id == WebmEbml.idFileName) {
          name = utf8.decode(
            Uint8List.sublistView(data, item.dataPos, item.end),
            allowMalformed: true,
          );
        }
        itemPos = item.end;
      }
      out.add((name, ''));
    }
    pos = file.end;
  }
  return out;
}

/// 收集文件里所有 Tags 元素里的标签，只有测试在用。
List<(String, String)> _allTags(Uint8List data) {
  final out = <(String, String)>[];
  var pos = _segmentDataPos(data);
  while (pos + 4 <= data.length) {
    final head = WebmEbml.headFromBytes(data, pos);
    if (head == null) break;
    if (head.id == WebmEbml.idTags && !head.unknownSize) {
      out.addAll(
        WebmTags.parse(Uint8List.sublistView(data, head.dataPos, head.end)),
      );
    }
    final next = head.unknownSize ? data.length : head.end;
    if (next <= pos) break;
    pos = next;
  }
  return out;
}
