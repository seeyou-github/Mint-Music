import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/download/domain/services/tag_write_service.dart';
import 'package:mintmusic/features/local/data/local_metadata_reader.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';

/// 下载写标签时要把歌曲年份写进文件。
///
/// 之前 `processSongFiles` 只传标题 / 歌手 / 专辑 / 专辑歌手 / 歌词 / 封面，
/// 年份（Song.year，来自平台返回的 year / publishTime）被丢掉了，下载下来的
/// 文件年份永远是空的。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tag_year_');
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Song song({int? year}) => Song(
    id: 'dl-year',
    title: '测试歌曲',
    artist: '测试歌手',
    album: '测试专辑',
    duration: 200,
    year: year,
  );

  test('有年份时写进 mp3（ID3 TYER），能读回', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final path = '${tempDir.path}${Platform.pathSeparator}year.mp3';
    await File(path).writeAsBytes(
      Uint8List.fromList(List<int>.generate(2048, (i) => i % 251)),
    );

    await TagWriteService().processSongFiles(
      path,
      song(year: 2013),
      basicInfo: true,
      cover: false,
      lyrics: false,
      downloadLyrics: false,
      lyricFormat: 'standard',
    );

    final meta = await LocalMetadataReader.read(path);
    expect(meta.title, '测试歌曲');
    expect(meta.year, 2013);
  });

  test('年份为空时不写，文件里保持原样', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final path = '${tempDir.path}${Platform.pathSeparator}noyear.mp3';
    await File(path).writeAsBytes(
      Uint8List.fromList(List<int>.generate(2048, (i) => i % 251)),
    );

    await TagWriteService().processSongFiles(
      path,
      song(),
      basicInfo: true,
      cover: false,
      lyrics: false,
      downloadLyrics: false,
      lyricFormat: 'standard',
    );

    final meta = await LocalMetadataReader.read(path);
    expect(meta.title, '测试歌曲');
    expect(meta.year, isNull);
  });

  test('basicInfo 关闭时不写年份（与其它基础信息一致）', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final path = '${tempDir.path}${Platform.pathSeparator}basicinfo.mp3';
    await File(path).writeAsBytes(
      Uint8List.fromList(List<int>.generate(2048, (i) => i % 251)),
    );

    await TagWriteService().processSongFiles(
      path,
      song(year: 2013),
      basicInfo: false,
      cover: false,
      lyrics: false,
      downloadLyrics: false,
      lyricFormat: 'standard',
    );

    final meta = await LocalMetadataReader.read(path);
    expect(meta.title, isNull);
    expect(meta.year, isNull);
  });
}
