import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/download/domain/services/tag_write_service.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';

/// 写不进内嵌封面 / 歌词的格式（桌面端的 m4a、aac，所有平台的 wav…）：
///
/// * 判定为「不支持」→ 下载时不会再调歌词接口、也不会下封面图；
/// * 下载目录里不会多出一个同名 `.lrc` 和一个同名封面图。
void main() {
  // 写标签会走 MethodChannel，测试里没有原生实现时会抛 MissingPluginException
  // 并回落到纯 Dart；先初始化绑定，避免抛「binding 未初始化」这种无关噪声。
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tag_unsupported_');
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('supportsEmbeddedTags', () {
    test('桌面端：只有 mp3 / flac 能写', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(TagWriteService.supportsEmbeddedTags('a/b/song.mp3'), isTrue);
      expect(TagWriteService.supportsEmbeddedTags('a/b/song.MP3'), isTrue);
      expect(TagWriteService.supportsEmbeddedTags('a/b/song.flac'), isTrue);
      expect(TagWriteService.supportsEmbeddedTags('a/b/song.m4a'), isFalse);
      expect(TagWriteService.supportsEmbeddedTags('a/b/song.aac'), isFalse);
      expect(TagWriteService.supportsEmbeddedTags('a/b/song.ogg'), isFalse);
      expect(TagWriteService.supportsEmbeddedTags('a/b/song.wma'), isFalse);
      expect(TagWriteService.supportsEmbeddedTags('a/b/song.wav'), isFalse);
    });

    test('Android：m4a / ogg / wma 由 jaudiotagger 写，aac / wav 不行', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(TagWriteService.supportsEmbeddedTags('song.m4a'), isTrue);
      expect(TagWriteService.supportsEmbeddedTags('song.mp4'), isTrue);
      expect(TagWriteService.supportsEmbeddedTags('song.ogg'), isTrue);
      expect(TagWriteService.supportsEmbeddedTags('song.wma'), isTrue);
      // 纯 Dart 只认 mp3 / flac，原生写不了的照样算不支持。
      expect(TagWriteService.supportsEmbeddedTags('song.aac'), isFalse);
      expect(TagWriteService.supportsEmbeddedTags('song.wav'), isFalse);
    });

    test('iOS：只多认 m4a / mp4 / aac', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(TagWriteService.supportsEmbeddedTags('song.m4a'), isTrue);
      expect(TagWriteService.supportsEmbeddedTags('song.aac'), isTrue);
      expect(TagWriteService.supportsEmbeddedTags('song.ogg'), isFalse);
      expect(TagWriteService.supportsEmbeddedTags('song.wma'), isFalse);
    });
  });

  group('processSongFiles 对不支持的格式', () {
    test('m4a：不写 lrc、不留封面图、不碰网络', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final songPath = '${tempDir.path}${Platform.pathSeparator}song.m4a';
      await File(songPath).writeAsBytes(Uint8List.fromList([0, 1, 2, 3]));

      final ok = await TagWriteService().processSongFiles(
        songPath,
        Song(
          id: 'x',
          title: '测试',
          artist: '歌手',
          album: '专辑',
          duration: 200,
          lrc: '[00:01.000]第一行\n[00:02.000]第二行',
        ),
        basicInfo: true,
        cover: true,
        lyrics: true,
        downloadLyrics: true,
        lyricFormat: 'standard',
        // 故意给一个连不上的地址 + 预加载封面：不支持内嵌时必须一个都不用。
        coverUrls: const ['http://127.0.0.1:1/cover.jpg'],
        preloadedCover: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]),
      );

      // 格式写不进去不是「下载失败」，下载列表不该提示「无封面」。
      expect(ok, isTrue);

      final names = tempDir
          .listSync()
          .map((e) => e.path.split(Platform.pathSeparator).last)
          .toList()
        ..sort();
      expect(names, ['song.m4a'], reason: '不应生成伴生的 .lrc / 封面文件');

      // 音频文件本身也不该被改动。
      expect(await File(songPath).readAsBytes(), [0, 1, 2, 3]);
    });

    test('支持的格式仍然照常写 lrc', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final songPath = '${tempDir.path}${Platform.pathSeparator}song.mp3';
      await File(songPath).writeAsBytes(Uint8List.fromList([0, 1, 2, 3]));

      await TagWriteService().processSongFiles(
        songPath,
        Song(
          id: 'y',
          title: '测试',
          artist: '歌手',
          album: '专辑',
          duration: 200,
          lrc: '[00:01.000]第一行\n[00:02.000]第二行',
        ),
        basicInfo: true,
        cover: false,
        lyrics: false,
        downloadLyrics: true,
        lyricFormat: 'standard',
      );

      final lrc = File('${tempDir.path}${Platform.pathSeparator}song.lrc');
      expect(await lrc.exists(), isTrue);
      expect(await lrc.readAsString(), contains('第一行'));
    });
  });
}
