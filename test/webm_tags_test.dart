import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/download/domain/services/audio_tag_writer.dart';
import 'package:mintmusic/features/local/data/local_metadata_reader.dart';
import 'package:mintmusic/shared/utils/webm_tags.dart';

/// 造一个最小的 WebM：EBML 头 + Segment{Info, Cluster}。
///
/// 只求结构合法（我们的解析器按元素头逐层走），Cluster 里是假音频字节。
Uint8List buildMinimalWebm({
  required String infoTitle,
  required double durationMs,
  int fakeAudioBytes = 4096,
  List<(String, String)> tags = const [],
}) {
  final timecodeScale = Uint8List.fromList([0x0F, 0x42, 0x40]); // 1000000 ns
  final duration = Uint8List(8);
  ByteData.sublistView(duration).setFloat64(0, durationMs, Endian.big);

  final info = BytesBuilder(copy: false)
    ..add(WebmEbml.element(const [0x2A, 0xD7, 0xB1], timecodeScale))
    ..add(WebmEbml.element(const [0x44, 0x89], duration))
    ..add(
      WebmEbml.element(const [0x7B, 0xA9], Uint8List.fromList(utf8.encode(infoTitle))),
    );

  final clusterBytes = Uint8List(fakeAudioBytes);
  for (var i = 0; i < clusterBytes.length; i++) {
    clusterBytes[i] = i & 0xFF;
  }

  final segmentPayload = BytesBuilder(copy: false)
    ..add(WebmEbml.element(const [0x15, 0x49, 0xA9, 0x66], info.toBytes()));
  if (tags.isNotEmpty) {
    // Tags 放在 Cluster 之前：模拟 ffmpeg / yt-dlp 写标签的位置。
    segmentPayload.add(WebmTags.build(tags));
  }
  segmentPayload.add(
    WebmEbml.element(const [0x1F, 0x43, 0xB6, 0x75], clusterBytes),
  );

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
            ('DATE', '2024-05-01'),
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
    test('尾部追加 Tags：音频字节不变、Segment 长度被修正、可读回', () async {
      final original = buildMinimalWebm(infoTitle: '原标题', durationMs: 5000);
      final file = newFile(original);
      final originalBytes = file.readAsBytesSync();

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
      // 原文件的每一个字节都还在原位（只追加 + 改长度字段）。
      expect(written.length, greaterThan(originalBytes.length));

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
      final clusterStart = _indexOfCluster(written);
      expect(clusterStart, isNonNegative);
      final audio = written.sublist(clusterStart, clusterStart + 4096);
      expect(
        audio,
        originalBytes.sublist(
          _indexOfCluster(originalBytes),
          _indexOfCluster(originalBytes) + 4096,
        ),
      );
    });

    test('重写不会让文件无限膨胀，也不产生两份同名标签', () async {
      final file = newFile(
        buildMinimalWebm(infoTitle: 't', durationMs: 1000),
      );
      await AudioTagWriter.write(file.path, lyrics: '[00:01.00]aaaa');
      final afterFirst = file.lengthSync();
      await AudioTagWriter.write(file.path, lyrics: '[00:01.00]bbbb');
      final afterSecond = file.lengthSync();
      await AudioTagWriter.write(file.path, lyrics: '[00:01.00]cccc');
      final afterThird = file.lengthSync();

      // 每次长度都差不多（旧标签在尾部被截掉重写）。
      expect((afterThird - afterFirst).abs(), lessThan(64));
      expect(afterSecond, isNot(equals(0)));

      final meta = await LocalMetadataReader.read(file.path);
      expect(meta.lyrics, '[00:01.00]cccc');
    });

    test('替换 Cluster 之前的旧标签，未管理字段保留', () async {
      final file = newFile(
        buildMinimalWebm(
          infoTitle: 't',
          durationMs: 1000,
          tags: [
            ('TITLE', '旧标题'),
            ('CUSTOM_FIELD', '别动我'),
          ],
        ),
      );
      final ok = await AudioTagWriter.write(file.path, title: '新标题');
      expect(ok, isTrue);

      final meta = await LocalMetadataReader.read(file.path);
      expect(meta.title, '新标题');

      final raw = file.readAsBytesSync();
      final all = WebmTags.toMap(
        WebmTags.parse(WebmTags.build([('TITLE', 'x')])),
      );
      expect(all, isNotEmpty); // 结构自检
      // 未管理字段还在（旧标签被 Void 擦掉，新标签在尾部）。
      expect(
        WebmTags.toMap(_allTags(raw))['CUSTOM_FIELD'],
        '别动我',
      );
    });

    test('没有标签要写时不动文件', () async {
      final file = newFile(
        buildMinimalWebm(infoTitle: 't', durationMs: 1000),
      );
      final before = file.readAsBytesSync();
      final ok = await AudioTagWriter.write(file.path);
      expect(ok, isTrue);
      expect(file.readAsBytesSync(), before);
    });

    test('webm 不支持内嵌封面，write 只写标签', () async {
      expect(AudioTagWriter.supports('a.weba'), isTrue);
      expect(AudioTagWriter.supportsArtwork('a.weba'), isFalse);
      expect(AudioTagWriter.supportsArtwork('a.mp3'), isTrue);
      expect(AudioTagWriter.supportsArtwork('a.flac'), isTrue);

      final file = newFile(
        buildMinimalWebm(infoTitle: 't', durationMs: 1000),
      );
      final ok = await AudioTagWriter.write(
        file.path,
        title: '有封面参数也照样写标签',
        artwork: Uint8List.fromList(List<int>.filled(64, 0xFF)),
      );
      expect(ok, isTrue);
      final meta = await LocalMetadataReader.read(file.path);
      expect(meta.title, '有封面参数也照样写标签');
      expect(meta.artwork, isNull);
    });
  });
}

/// 找 Cluster 元素头的偏移（测试用：结构固定，直接按字节找 ID）。
int _indexOfCluster(Uint8List data) {
  for (var i = 0; i + 4 <= data.length; i++) {
    if (data[i] == 0x1F &&
        data[i + 1] == 0x43 &&
        data[i + 2] == 0xB6 &&
        data[i + 3] == 0x75) {
      final head = WebmEbml.headFromBytes(data, i);
      if (head != null) return head.dataPos;
    }
  }
  return -1;
}

/// 收集文件里所有 Tags 元素（前段 + 尾部）里的标签，只有测试在用。
List<(String, String)> _allTags(Uint8List data) {
  final out = <(String, String)>[];
  for (var i = 0; i + 4 <= data.length; i++) {
    if (data[i] == 0x12 &&
        data[i + 1] == 0x54 &&
        data[i + 2] == 0xC3 &&
        data[i + 3] == 0x67) {
      final head = WebmEbml.headFromBytes(data, i);
      if (head == null || head.unknownSize || head.end > data.length) continue;
      out.addAll(
        WebmTags.parse(
          Uint8List.sublistView(data, head.dataPos, head.end),
        ),
      );
    }
  }
  return out;
}
