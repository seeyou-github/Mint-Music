import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/player/domain/services/embedded_lyrics_extractor.dart';

/// 构造一个只带 ID3 标签的假 mp3：`TXXX:LYRICS` 里放歌词，后面跟几个字节的垃圾
/// 冒充音频数据（读取路径只看标签，不做解码）。
Uint8List _buildMp3({
  required String description,
  required String lyric,
  int encoding = 1,
}) {
  final frames = BytesBuilder();

  void addFrame(String id, Uint8List payload) {
    final header = BytesBuilder();
    header.add(ascii.encode(id));
    header.add([
      (payload.length >> 24) & 0xFF,
      (payload.length >> 16) & 0xFF,
      (payload.length >> 8) & 0xFF,
      payload.length & 0xFF,
    ]);
    header.add([0, 0]); // flags
    frames.add(header.takeBytes());
    frames.add(payload);
  }

  Uint8List textPayload(String value) {
    if (encoding == 1) {
      final body = BytesBuilder()
        ..add([0x01, 0xFF, 0xFE])
        ..add(_utf16Le(value));
      return body.takeBytes();
    }
    return Uint8List.fromList([0x03, ...utf8.encode(value)]);
  }

  // TXXX：[编码][描述符 0 结尾][内容]
  final txxx = BytesBuilder();
  if (encoding == 1) {
    txxx.add([0x01, 0xFF, 0xFE]);
    txxx.add(_utf16Le(description));
    txxx.add([0x00, 0x00]);
    txxx.add([0xFF, 0xFE]);
    txxx.add(_utf16Le(lyric));
  } else {
    txxx.add([0x03]);
    txxx.add(utf8.encode(description));
    txxx.add([0x00]);
    txxx.add(utf8.encode(lyric));
  }
  addFrame('TXXX', txxx.takeBytes());
  addFrame('TIT2', textPayload('Collide'));

  final body = frames.takeBytes();
  final out = BytesBuilder();
  out.add(ascii.encode('ID3'));
  out.add([3, 0, 0]); // v2.3, 无 flags
  out.add([
    (body.length >> 21) & 0x7F,
    (body.length >> 14) & 0x7F,
    (body.length >> 7) & 0x7F,
    body.length & 0x7F,
  ]);
  out.add(body);
  out.add(utf8.encode('AUDIODATA')); // 假音频
  return out.takeBytes();
}

List<int> _utf16Le(String value) {
  final bytes = <int>[];
  for (final unit in value.codeUnits) {
    bytes.add(unit & 0xFF);
    bytes.add((unit >> 8) & 0xFF);
  }
  return bytes;
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mint_lyrics_txxx');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<File> writeFile(String name, Uint8List bytes) async {
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  test('读取 TXXX:LYRICS（UTF-16）里的内嵌歌词', () async {
    final file = await writeFile(
      'a.mp3',
      _buildMp3(
        description: 'LYRICS',
        lyric: '[00:09.61] I was only seventeen\n[00:13.26] With a reckless heart\n',
      ),
    );

    final result = await EmbeddedLyricsExtractor.extract(file.path);
    expect(result, isNotNull);
    expect(result, contains('I was only seventeen'));
    expect(result, contains('[00:13.26] With a reckless heart'));
  });

  test('读取 TXXX:UNSYNCEDLYRICS（UTF-8）里的内嵌歌词', () async {
    final file = await writeFile(
      'b.mp3',
      _buildMp3(
        description: 'UNSYNCEDLYRICS',
        lyric: '[00:01.00] 第一行\n[00:05.00] 第二行\n',
        encoding: 3,
      ),
    );

    final result = await EmbeddedLyricsExtractor.extract(file.path);
    expect(result, contains('第一行'));
    expect(result, contains('第二行'));
  });
}
