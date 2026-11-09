import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/local/data/local_metadata_reader.dart';
import 'package:mintmusic/features/local/data/local_quality_reader.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('local_quality_test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<File> write(String name, List<int> bytes) async {
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes);
    return file;
  }

  /// MPEG1 LayerIII 44100Hz 128kbps、joint stereo 帧头。
  const mp3FrameHeader = [0xFF, 0xFB, 0x90, 0x64];

  Uint8List flacFile(int bits, int sampleRate) {
    final info = Uint8List(18);
    info[10] = (sampleRate >> 12) & 0xFF;
    info[11] = (sampleRate >> 4) & 0xFF;
    info[12] = ((sampleRate & 0x0F) << 4) | (((bits - 1) >> 4) & 0x01);
    info[13] = ((bits - 1) & 0x0F) << 4;
    return Uint8List.fromList([
      0x66, 0x4C, 0x61, 0x43, // fLaC
      0x00, 0x00, 0x00, 0x22, // STREAMINFO, 34 字节
      ...info,
    ]);
  }

  test('CBR MP3 用首帧码率', () async {
    final file = await write('cbr.mp3', mp3FrameHeader);
    expect(await LocalMetadataReader.readMp3Bitrate(file.path), 128);
    expect(await LocalQualityReader.readLabel(file.path), '128K');
  });

  test('带 ID3 标签的 MP3 跳过标签再读码率', () async {
    final file = await write('tagged.mp3', [
      0x49, 0x44, 0x33, 0x03, 0x00, 0x00, // ID3v2.3
      0x00, 0x00, 0x00, 0x0A, // 标签体 10 字节
      ...List.filled(10, 0),
      ...mp3FrameHeader,
    ]);
    expect(await LocalMetadataReader.readMp3Bitrate(file.path), 128);
  });

  test('VBR MP3 用 Xing 头的平均码率', () async {
    const frames = 3840; // 3840 * 1152 / 44100 ≈ 100.3s
    const audioBytes = 4000000; // 4000000 * 8 / 100.3s ≈ 319kbps
    final bytes = <int>[
      ...mp3FrameHeader,
      ...List.filled(32, 0), // 立体声 side info
      0x58, 0x69, 0x6E, 0x67, // 'Xing'
      0x00, 0x00, 0x00, 0x03, // flags: 有 frames + bytes
      ..._be32(frames),
      ..._be32(audioBytes),
    ];
    final file = await write('vbr.mp3', bytes);
    expect(await LocalQualityReader.readLabel(file.path), '319K');
  });

  test('FLAC 按位深分级，不显示码率', () async {
    final cd = await write('cd.flac', flacFile(16, 44100));
    expect(await LocalQualityReader.readLabel(cd.path), 'Flac');

    final hiRes = await write('hires.flac', flacFile(24, 96000));
    expect(await LocalQualityReader.readLabel(hiRes.path), 'Flac24bit');

    final dsdLike = await write('dsd.flac', flacFile(32, 352800));
    expect(await LocalQualityReader.readLabel(dsdLike.path), 'HiRes');
  });

  test('WAV / APE 等无损格式显示 HiRes', () async {
    final wav = await write('a.wav', [0x52, 0x49, 0x46, 0x46]);
    expect(await LocalQualityReader.readLabel(wav.path), 'HiRes');

    final ape = await write('a.ape', [0x4D, 0x41, 0x43, 0x20]);
    expect(await LocalQualityReader.readLabel(ape.path), 'HiRes');
  });

  test('文件不存在时返回 null', () async {
    final missing = '${dir.path}${Platform.pathSeparator}nope.mp3';
    expect(await LocalQualityReader.readLabel(missing), isNull);
  });
}

List<int> _be32(int value) => [
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
];
