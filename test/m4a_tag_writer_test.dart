import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/download/domain/services/audio_tag_writer.dart';
import 'package:mintmusic/features/local/data/local_metadata_reader.dart';

/// M4A / MP4 标签写入。
///
/// 重点回归两件事：
/// 1. 写好之后 [LocalMetadataReader] 能原样读回来（标题 / 歌手 / 专辑 /
///    年份 / 流派 / 注释 / 歌词 / 封面）；
/// 2. moov 变大把 mdat 挤后移时，`stco` 的 chunk 偏移要跟着改——不改的话
///    标签读得出来，音频却会整体错位（播放器表现为噪音 / 卡死）。
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mint_m4a_tag');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('写入基础信息与歌词后能读回', () async {
    final path = '${dir.path}${Platform.pathSeparator}song.m4a';
    await File(path).writeAsBytes(_buildM4a());

    final ok = await AudioTagWriter.write(
      path,
      title: '做我老婆好不好',
      artist: '依渟',
      album: '收藏',
      albumArtist: '依渟',
      year: '2023',
      genre: '流行',
      comment: '备注',
      lyrics: '[00:01.000]第一行\n[00:02.000]第二行',
    );
    expect(ok, isTrue);

    final meta = await LocalMetadataReader.read(path);
    expect(meta.title, '做我老婆好不好');
    expect(meta.artist, '依渟');
    expect(meta.album, '收藏');
    expect(meta.year, 2023);
    expect(meta.genre, '流行');
    expect(meta.comment, '备注');
    expect(meta.lyrics, '[00:01.000]第一行\n[00:02.000]第二行');
  });

  test('封面能写进去，也能删掉', () async {
    final path = '${dir.path}${Platform.pathSeparator}cover.m4a';
    await File(path).writeAsBytes(_buildM4a());
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
      'z8AAAwAB/wH+9v0AAAAASUVORK5CYII=',
    );

    expect(await AudioTagWriter.write(path, artwork: png), isTrue);
    final withCover = await LocalMetadataReader.read(path);
    expect(withCover.artwork, isNotNull);
    expect(withCover.artwork, png);

    expect(await AudioTagWriter.write(path, removeArtwork: true), isTrue);
    final withoutCover = await LocalMetadataReader.read(path);
    expect(withoutCover.artwork, isNull);
  });

  test('moov 变大后 stco 偏移跟着修正，mdat 起点与 stco 一致', () async {
    final path = '${dir.path}${Platform.pathSeparator}shift.m4a';
    await File(path).writeAsBytes(_buildM4a());

    // 长歌词：新 moov 明显比原来（只有一个 trak）大，mdat 必须后移。
    final longLyric = List.generate(
      200,
      (i) => '[00:${(i ~/ 60).toString().padLeft(2, '0')}:'
          '${(i % 60).toString().padLeft(2, '0')}.000]第 $i 行歌词',
    ).join('\n');
    expect(await AudioTagWriter.write(path, lyrics: longLyric), isTrue);

    final bytes = await File(path).readAsBytes();
    final stcoOffset = _firstStcoOffset(bytes);
    final mdatStart = _mdatDataStart(bytes);

    expect(stcoOffset, isNotNull);
    expect(mdatStart, isNotNull);
    expect(
      stcoOffset,
      mdatStart,
      reason: 'stco 里的 chunk 偏移必须等于 mdat 的实际起点',
    );
    // 数据本身没被破坏：mdat 起始字节仍是构造时写入的那一帧。
    expect(bytes[mdatStart!], 0);
  });

  test('moov 在文件末尾时不动 stco，也能正常写入', () async {
    final path = '${dir.path}${Platform.pathSeparator}tail.m4a';
    await File(path).writeAsBytes(_buildM4a(moovAtEnd: true));
    final before = _firstStcoOffset(await File(path).readAsBytes());

    expect(
      await AudioTagWriter.write(
        path,
        lyrics: List.generate(80, (i) => '[00:0$i.000]行 $i').join('\n'),
      ),
      isTrue,
    );

    final after = _firstStcoOffset(await File(path).readAsBytes());
    expect(after, before, reason: 'moov 在 mdat 后面时音频数据没移动');
    expect((await LocalMetadataReader.read(path)).lyrics, contains('行 79'));
  });

  test('新 moov 更小时原地覆盖，文件大小不变', () async {
    final path = '${dir.path}${Platform.pathSeparator}inplace.m4a';
    await File(path).writeAsBytes(_buildM4a());
    await AudioTagWriter.write(
      path,
      title: '标题',
      lyrics: List.generate(120, (i) => '[00:0$i.000]很长的一行歌词 $i').join('\n'),
    );
    final sizeBefore = await File(path).length();

    // 只把歌词改短：新 moov 变小，用 free 补齐后原地覆盖，不该重写整个文件。
    expect(await AudioTagWriter.write(path, lyrics: '[00:01.000]短'), isTrue);
    final sizeAfter = await File(path).length();

    expect(sizeAfter, sizeBefore);
    final meta = await LocalMetadataReader.read(path);
    expect(meta.lyrics, '[00:01.000]短');
    // 标题这类没改的字段要保留。
    expect(meta.title, '标题');
  });

  test('清空字段时把对应 atom 一起删掉', () async {
    final path = '${dir.path}${Platform.pathSeparator}clear.m4a';
    await File(path).writeAsBytes(_buildM4a());
    await AudioTagWriter.write(path, title: '标题', genre: '流行', lyrics: '词');

    expect(
      await AudioTagWriter.write(
        path,
        title: '',
        genre: '',
        lyrics: '',
        removeEmptyFields: true,
      ),
      isTrue,
    );

    final meta = await LocalMetadataReader.read(path);
    expect(meta.title, isNull);
    expect(meta.genre, isNull);
    expect(meta.lyrics, isNull);
  });
}

// ---------------------------------------------------------------- 构造 / 解析

Uint8List _u32(int value) => Uint8List.fromList([
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
]);

Uint8List _atom(String type, List<int> payload) {
  final out = BytesBuilder();
  out.add(_u32(8 + payload.length));
  out.add(ascii.encode(type));
  out.add(payload);
  return out.toBytes();
}

/// 最小可解析的 m4a：`ftyp + moov(trak>mdia>minf>stbl>stco) + mdat`。
///
/// [moovAtEnd] 为 true 时把 moov 放到 mdat 之后（部分编码器的默认布局）。
Uint8List _buildM4a({int audioBytes = 4096, bool moovAtEnd = false}) {
  final audio = List<int>.generate(audioBytes, (i) => i % 251);
  final ftyp = _atom('ftyp', [
    ...ascii.encode('M4A '),
    ..._u32(0),
    ...ascii.encode('M4A '),
    ...ascii.encode('isom'),
  ]);
  Uint8List buildMoov(int chunkOffset) => _atom(
    'moov',
    _atom(
      'trak',
      _atom(
        'mdia',
        _atom(
          'minf',
          _atom(
            'stbl',
            _atom('stco', [
              ..._u32(0), // version + flags
              ..._u32(1), // entry count
              ..._u32(chunkOffset),
            ]),
          ),
        ),
      ),
    ),
  );

  final probe = buildMoov(0);
  final mdat = _atom('mdat', audio);
  final chunkOffset = moovAtEnd
      ? ftyp.length + 8
      : ftyp.length + probe.length + 8;
  final moov = buildMoov(chunkOffset);

  final out = BytesBuilder();
  out.add(ftyp);
  if (moovAtEnd) {
    out.add(mdat);
    out.add(moov);
  } else {
    out.add(moov);
    out.add(mdat);
  }
  return out.toBytes();
}

int _be32At(List<int> bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

int? _firstStcoOffset(List<int> bytes, [int? start, int? end]) {
  final from = start ?? 0;
  final to = end ?? bytes.length;
  var pos = from;
  while (pos + 8 <= to) {
    final size = _be32At(bytes, pos);
    if (size < 8 || pos + size > to) break;
    final type = latin1.decode(bytes.sublist(pos + 4, pos + 8));
    if (type == 'stco') return _be32At(bytes, pos + 16);
    if (const {'moov', 'trak', 'mdia', 'minf', 'stbl'}.contains(type)) {
      final inner = _firstStcoOffset(bytes, pos + 8, pos + size);
      if (inner != null) return inner;
    }
    pos += size;
  }
  return null;
}

int? _mdatDataStart(List<int> bytes) {
  var pos = 0;
  while (pos + 8 <= bytes.length) {
    final size = _be32At(bytes, pos);
    if (size < 8) break;
    final type = latin1.decode(bytes.sublist(pos + 4, pos + 8));
    if (type == 'mdat') return pos + 8;
    pos += size;
  }
  return null;
}
