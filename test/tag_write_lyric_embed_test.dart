import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/download/domain/services/tag_write_service.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';
import 'package:mintmusic/features/player/domain/services/embedded_lyrics_extractor.dart';
import 'package:mintmusic/features/player/domain/services/lyric_parser.dart';

/// 下载写标签：逐字歌词不能被「有没有时间轴」的判断误杀。
///
/// 回归的是这样一个问题：QQ / 网易返回的逐字歌词原文是 QRC / YRC，行首是
/// `[起点,时长]`，没有 `[mm:ss]`。原实现拿原文去判时间轴，判成「不是歌词」，
/// 于是整首歌的歌词都不写进文件（日志里 `lrc=has 3265 / crlyric=has 10114`
/// 但 `hasLyrics=false`）。
void main() {
  // 写标签会走一次原生通道（测试里没有实现，随即回退纯 Dart），
  // 没有绑定的话 MethodChannel 调用会抛「Binding has not yet been initialized」。
  TestWidgetsFlutterBinding.ensureInitialized();

  const qrc = '[ti:测试]\n'
      '[0,1000](0,200,0)Hello (200,300,0)world (500,500,0)again\n'
      '[1000,800](1000,300,0)second (1300,500,0)line';

  Song song({String? lrc}) => Song(
    id: 'dl-1',
    title: '测试歌曲',
    artist: '测试歌手',
    album: '测试专辑',
    duration: 200,
    lrc: lrc,
  );

  test('逐字歌词（QRC）能写进下载文件的标签', () async {
    final dir = await Directory.systemTemp.createTemp('mint_tag_write');
    final file = File('${dir.path}${Platform.pathSeparator}song.mp3');
    try {
      await file.writeAsBytes(
        Uint8List.fromList(List<int>.generate(2048, (i) => i % 251)),
      );

      final ok = await TagWriteService().processSongFiles(
        file.path,
        song(lrc: qrc),
        basicInfo: true,
        cover: false,
        lyrics: true,
        downloadLyrics: false,
        lyricFormat: 'word-by-word',
      );
      expect(ok, isTrue);

      final embedded = await EmbeddedLyricsExtractor.extract(file.path);
      expect(embedded, isNotNull, reason: '歌词必须写进文件，不能被跳过');
      expect(isEnhancedLrcFormat(embedded!), isTrue);
      final lines = parseLyricAuto(embedded);
      expect(lines.first.isYrc, isTrue);
      expect(lines.first.plainText, 'Hello world again');
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('曲目信息（作曲 : xxx）仍然不写歌词', () async {
    final dir = await Directory.systemTemp.createTemp('mint_tag_write_info');
    final file = File('${dir.path}${Platform.pathSeparator}song2.mp3');
    try {
      await file.writeAsBytes(
        Uint8List.fromList(List<int>.generate(2048, (i) => i % 251)),
      );

      await TagWriteService().processSongFiles(
        file.path,
        song(lrc: '作曲 : Fenty\n风格：嘻哈说唱'),
        basicInfo: true,
        cover: false,
        lyrics: true,
        downloadLyrics: false,
        lyricFormat: 'word-by-word',
      );

      final embedded = await EmbeddedLyricsExtractor.extract(file.path);
      expect(
        embedded == null || embedded.trim().isEmpty,
        isTrue,
        reason: '没有时间轴的曲目信息不该写进标签',
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
