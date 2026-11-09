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

  /// MPEG1 LayerIII 44100Hz 128kbps、joint stereo 帧头（每帧 417 字节）。
  const mp3FrameHeader = [0xFF, 0xFB, 0x90, 0x64];

  Uint8List mp3Frames(int count) {
    final frame = <int>[...mp3FrameHeader, ...List.filled(413, 0)];
    return Uint8List.fromList([
      for (var i = 0; i < count; i++) ...frame,
    ]);
  }

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

  /// 最小 M4A：mvhd 时长 + mdat（音频字节）。
  Uint8List mp4File({
    required int durationMs,
    required int audioBytes,
    List<int> extraMoov = const [],
  }) {
    final mvhd = _box('mvhd', [
      0x00, 0x00, 0x00, 0x00, // version 0 + flags
      ..._be32(0), // creation
      ..._be32(0), // modification
      ..._be32(1000), // timescale
      ..._be32(durationMs), // duration（timescale=1000 时即毫秒）
      ...List.filled(80, 0),
    ]);
    final moov = _box('moov', [...mvhd, ...extraMoov]);
    final mdat = _box('mdat', List.filled(audioBytes, 0));
    return Uint8List.fromList([
      ..._box('ftyp', [0x4D, 0x34, 0x41, 0x20, ..._be32(0)]),
      ...moov,
      ...mdat,
    ]);
  }

  /// ADTS(AAC)：44100Hz，每帧 1024 个采样。
  Uint8List adtsFile({int frames = 441, int frameLength = 400}) {
    final bytes = Uint8List(frames * frameLength);
    for (var f = 0; f < frames; f++) {
      final o = f * frameLength;
      bytes[o] = 0xFF;
      bytes[o + 1] = 0xF1; // sync + protection_absent
      bytes[o + 2] = 0x50; // profile 1 (AAC LC) + 采样率索引 4 (44100)
      bytes[o + 3] = (frameLength >> 11) & 0x03;
      bytes[o + 4] = (frameLength >> 3) & 0xFF;
      bytes[o + 5] = ((frameLength & 0x07) << 5) | 0x1F;
      bytes[o + 6] = 0xFC;
    }
    return bytes;
  }

  /// 最小 ASF(WMA) 头：File Properties 对象里声明 MaxBitrate。
  Uint8List wmaFile(int bitrate) {
    final bytes = Uint8List(30 + 104);
    bytes.setRange(0, 16, _asfHeaderGuid);
    bytes.setRange(16, 24, _le64(134));
    bytes.setRange(24, 28, _le32(1));
    bytes.setRange(30, 46, _asfFilePropsGuid);
    bytes.setRange(46, 54, _le64(104));
    bytes.setRange(130, 134, _le32(bitrate));
    return bytes;
  }

  test('CBR MP3 按体积 / 时长算平均码率', () async {
    final file = await write('cbr.mp3', mp3Frames(10));
    expect((await LocalMetadataReader.read(file.path)).durationMs, 260);
    expect(await LocalQualityReader.readLabel(file.path), '128K');
  });

  test('MP3 内嵌标签不计入音频字节', () async {
    final file = await write('tagged.mp3', [
      0x49, 0x44, 0x33, 0x03, 0x00, 0x00, // ID3v2.3
      ..._synchsafe(1000), // 标签体 1000 字节（封面放进来的场景）
      ...List.filled(1000, 0),
      ...mp3Frames(10),
    ]);
    expect(await LocalQualityReader.readLabel(file.path), '128K');
  });

  test('M4A(AAC) 用 mdat 字节 / mvhd 时长算码率', () async {
    final file = await write(
      'song.m4a',
      mp4File(durationMs: 10000, audioBytes: 320000),
    );
    expect((await LocalMetadataReader.read(file.path)).durationMs, 10000);
    expect(await LocalQualityReader.readLabel(file.path), '256K');
  });

  test('M4A 里装 ALAC 无损时只显示等级', () async {
    final file = await write(
      'lossless.m4a',
      mp4File(
        durationMs: 10000,
        audioBytes: 320000,
        extraMoov: _box('alac', [0, 0, 0, 0]),
      ),
    );
    expect(await LocalQualityReader.readLabel(file.path), 'HiRes');
  });

  test('AAC(ADTS) 按时长算码率', () async {
    final file = await write('song.aac', adtsFile());
    expect((await LocalMetadataReader.read(file.path)).durationMs, 10240);
    // 441 帧 × 400 字节 = 176400 字节 / 10.24s ≈ 138kbps
    expect(await LocalQualityReader.readLabel(file.path), '138K');
  });

  test('WMA 读 ASF 头里声明的码率', () async {
    final file = await write('song.wma', wmaFile(192000));
    expect(await LocalQualityReader.readLabel(file.path), '192K');
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

const _asfHeaderGuid = [
  0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, //
  0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C,
];

const _asfFilePropsGuid = [
  0xA1, 0xDC, 0xAB, 0x8C, 0x47, 0xA9, 0xCF, 0x11, //
  0x8E, 0xE4, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65,
];

List<int> _box(String type, List<int> payload) => [
  ..._be32(8 + payload.length),
  ...type.codeUnits,
  ...payload,
];

List<int> _be32(int value) => [
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
];

List<int> _le32(int value) => [
  value & 0xFF,
  (value >> 8) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 24) & 0xFF,
];

List<int> _le64(int value) => [
  ..._le32(value & 0xFFFFFFFF),
  ..._le32((value >> 32) & 0xFFFFFFFF),
];

List<int> _synchsafe(int value) => [
  (value >> 21) & 0x7F,
  (value >> 14) & 0x7F,
  (value >> 7) & 0x7F,
  value & 0x7F,
];
