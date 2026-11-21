import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/player/domain/models/lyric_line.dart';
import 'package:mintmusic/features/player/domain/services/embedded_lyrics_extractor.dart';
import 'package:mintmusic/features/player/domain/services/embedded_lyrics_writer.dart';
import 'package:mintmusic/features/player/domain/services/lyric_parser.dart';
import 'package:mintmusic/features/player/domain/services/lyric_text_formatter.dart';

/// 「搜索歌词」里选中的那份歌词，写进文件的内容必须和预览看到的保持一致。
///
/// 回归的是这样一个 bug：QQ 这类音源的同一份结果里，`lrc` 是整行时间轴、
/// `crlyric` 才是逐字歌词。预览按 `crlyric` 显示逐字，写文件时却按 `lrc`
/// 写了整行，于是编辑标签界面再打开就看不到逐字时间轴了。
void main() {
  // QQ / QRC：行头是 [行起点,行时长]，词标签是 (词起点,词时长,0)，字在标签后面。
  const qrc = '[ti:测试]\n'
      '[0,1000](0,200,0)Hello (200,300,0)world (500,500,0)again\n'
      '[1000,800](1000,300,0)second (1300,500,0)line';

  const plainLrc = '[00:00.00]Hello world again\n[00:01.00]second line';

  test('逐字歌词写进文件时保留逐字时间轴（增强 LRC）', () {
    final text = LyricTextFormatter.preferWordByWord(qrc);

    expect(text, contains('<00:00.000>Hello'));
    expect(text, contains('<00:00.200>world'));
    expect(
      isEnhancedLrcFormat(text),
      isTrue,
      reason: '写进文件的应该是增强 LRC，不是剥掉词标签的整行 LRC',
    );
  });

  test('写进文件的文本能被本应用重新解析成逐字歌词', () {
    final text = LyricTextFormatter.preferWordByWord(qrc);
    final lines = parseLyricAuto(text);

    expect(lines, isNotEmpty);
    expect(lines.first.isYrc, isTrue, reason: '重新读回来必须还是逐字歌词');
    expect(lines.first.plainText, 'Hello world again');
    expect(lines.first.words.length, 3);
  });

  test('一份结果同时有整行 lrc 和逐字 crlyric 时优先写逐字', () {
    final text = LyricTextFormatter.fromResult(
      const LyricResult(lrc: plainLrc, crlyric: qrc),
    );

    expect(text, contains('<00:00.000>Hello'));
    expect(isEnhancedLrcFormat(text), isTrue);
  });

  test('只有整行歌词时写标准 LRC，不带词级标签', () {
    final text = LyricTextFormatter.fromResult(
      const LyricResult(lrc: plainLrc, crlyric: ''),
    );

    expect(text, contains('[00:00.000]Hello world again'));
    expect(text, isNot(contains('<')));
  });

  test('已经是增强 LRC 的文本原样保留', () {
    const enhanced = '[00:00.000]<00:00.000>Hello <00:00.200>world';
    expect(LyricTextFormatter.preferWordByWord(enhanced), enhanced);
  });

  test('YRC 也能转成增强 LRC（字在词标签前面）', () {
    const yrc = '[0,1000]Hello(0,200,0) world(200,300,0) again(500,500,0)';
    final text = LyricTextFormatter.preferWordByWord(yrc);

    expect(isEnhancedLrcFormat(text), isTrue);
    expect(parseLyricAuto(text).first.words.length, 3);
  });

  // 下载写标签时的判断顺序：先整理成「要写进文件的文本」，再判有没有时间轴。
  // 顺序反了就会把逐字歌词当「不是歌词」整段丢掉（日志里的
  // `lrc=has 3265 / crlyric=has 10114` 却写不进去，就是这个原因）。
  group('时间轴判定要用整理后的文本', () {
    test('逐字歌词原文（QRC）本身没有 [mm:ss] 时间轴', () {
      expect(
        LyricTextFormatter.hasTimeline(qrc),
        isFalse,
        reason: 'QRC 行首是 [起点,时长]，先判时间轴会把整首歌判成没有歌词',
      );
    });

    test('整理之后就有时间轴了，可以写进标签', () {
      final text = LyricTextFormatter.preferWordByWord(qrc);
      expect(LyricTextFormatter.hasTimeline(text), isTrue);
    });

    test('真正的「曲目信息」还是会被拦下', () {
      const info = '作曲 : Fenty\n风格：嘻哈说唱';
      final text = LyricTextFormatter.preferWordByWord(info);
      expect(text, isEmpty);
      expect(LyricTextFormatter.hasTimeline(text), isFalse);
    });
  });

  test('写进 mp3 标签再读回来仍是逐字歌词', () async {
    final dir = await Directory.systemTemp.createTemp('mint_lyric_test');
    final file = File('${dir.path}${Platform.pathSeparator}song.mp3');
    try {
      // 没有 ID3 标签的「音频」（写标签时会新建 v2.3 标签）。
      await file.writeAsBytes(
        Uint8List.fromList(List<int>.generate(2048, (i) => i % 251)),
      );

      final text = LyricTextFormatter.fromResult(
        const LyricResult(lrc: plainLrc, crlyric: qrc),
      );
      expect(await EmbeddedLyricsWriter.write(file.path, text), isTrue);

      final embedded = await EmbeddedLyricsExtractor.extract(file.path);
      expect(embedded, isNotNull);
      final lines = parseLyricAuto(embedded!);
      expect(lines, isNotEmpty, reason: '写进文件的歌词必须还能被解析出来');
      expect(lines.first.isYrc, isTrue, reason: '标签里的必须是逐字歌词');
      expect(lines.first.plainText, 'Hello world again');
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
