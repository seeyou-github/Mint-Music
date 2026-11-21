import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/player/domain/models/lyric_line.dart';
import 'package:mintmusic/features/player/domain/services/lyric_parser.dart';
import 'package:mintmusic/features/player/domain/services/lyric_text_formatter.dart';

/// 歌词来源、显示格式、写入文件三处必须一致。
///
/// 回归的场景：同一首网易的歌，播放页显示 TTML + 中文翻译，搜索歌词预览是
/// YRC + 翻译，编辑标签页「在线搜索」拿到的却是不带翻译的 YRC，写进歌曲文件
/// 的又是没有翻译的整行 LRC。根因是三处各调各的接口、各挑各的字段。
void main() {
  // 网易 TTML：逐字时间落在 <span> 上。
  const ttml =
      '<tt xmlns="http://www.w3.org/ns/ttml"><body><div>'
      '<p begin="00:00:20.500" end="00:00:25.030">'
      '<span begin="00:00:20.500" end="00:00:20.880">Once </span>'
      '<span begin="00:00:20.880" end="00:00:21.120">I </span>'
      '<span begin="00:00:21.120" end="00:00:21.300">was</span>'
      '</p></div></body></tt>';

  // 同一首歌的在线歌词：整行 LRC + 中文翻译。
  const plainLrc = '[00:20.50]Once I was\n[00:25.04]Go make yourself';
  const tlyric = '[00:20.50]那年我七岁\n[00:25.04]去交些朋友';

  // 在线逐字歌词（YRC）+ 翻译。
  const yrc =
      '[20500,4530](20500,630,0)Once (20880,240,0)I (21120,180,0)was\n'
      '[25040,3480](25040,480,0)Go (25260,420,0)make';

  group('统一取词：TTML 词库与音源歌词合成一份', () {
    test('在线只有整行歌词时用 TTML（逐字质量更高），翻译跟着音源', () {
      final result = pickBestLyric(
        ttmlText: ttml,
        online: const LyricResult(lrc: plainLrc, tlyric: tlyric),
      );

      expect(result, isNotNull);
      expect(result!.lrc, ttml, reason: '选中的应该是 TTML 原文');
      expect(result.crlyric, isNull, reason: '只留一份主文本，避免两处各挑一份');
      expect(result.tlyric, tlyric, reason: 'TTML 词库只有原文，翻译来自音源');
    });

    test('在线本身是逐字歌词时优先用在线那份（TTML 只有整行时）', () {
      const lineOnlyTtml =
          '<tt><body><div><p begin="00:00:20.500" end="00:00:23.000">'
          'Once I was</p></div></body></tt>';

      final result = pickBestLyric(
        ttmlText: lineOnlyTtml,
        online: const LyricResult(crlyric: yrc, lrc: plainLrc, tlyric: tlyric),
      );

      expect(result!.crlyric, yrc);
      expect(result.tlyric, tlyric);
    });

    test('没有 TTML 时原样用音源结果；两边都没有返回 null', () {
      final result = pickBestLyric(
        online: const LyricResult(lrc: plainLrc, tlyric: tlyric),
      );
      expect(result!.lrc, plainLrc);
      expect(pickBestLyric(), isNull);
    });
  });

  group('写入文件：逐字 + 翻译', () {
    test('TTML + 翻译写出来是增强 LRC，紧跟同时间戳译文行', () {
      final result = pickBestLyric(
        ttmlText: ttml,
        online: const LyricResult(lrc: plainLrc, tlyric: tlyric),
      );
      final text = LyricTextFormatter.fromResult(result!);

      expect(text, contains('[00:20.500]<00:20.500>Once '));
      expect(text, contains('[00:20.500]那年我七岁'));
      expect(LyricTextFormatter.hasTimeline(text), isTrue);

      // 读回来的流程：先把译文行拆出去，再按「原文 + 翻译」合并（与
      // LyricController.loadLyrics 对本地歌曲文件的做法一致）。
      final split = LyricTextFormatter.splitTranslation(text);
      final lines = mergeTranslation(
        parseLyricAuto(split.lyric),
        split.translation,
      );
      expect(lines.any((line) => line.isYrc), isTrue, reason: '逐字时间轴要保留');
      expect(lines.first.translatedLyric, '那年我七岁', reason: '写进文件的翻译读回来要回到翻译位置');
    });

    test('YRC + 翻译写出来同样是逐字 + 译文行', () {
      final text = LyricTextFormatter.fromResult(
        const LyricResult(crlyric: yrc, tlyric: tlyric),
      );

      expect(text, contains('<00:20.500>Once'));
      expect(text, contains('[00:20.500]那年我七岁'));
    });

    test('同一份歌词，播放显示与写入文件用的是同一套解析', () {
      const result = LyricResult(crlyric: yrc, lrc: plainLrc, tlyric: tlyric);
      final text = LyricTextFormatter.fromResult(result);
      final written = parseLyricAuto(text);

      final displayed = parseBestLyricText(result);
      expect(
        displayed.first.plainText,
        written.first.plainText,
        reason: '预览里的整行文字和写进文件的必须一致',
      );
    });
  });

  group('双语歌词读回来：译文回到翻译位置，而不是另一行', () {
    test('拆分「原文行 + 同时间戳译文行」', () {
      const text =
          '[00:20.500]<00:20.500>Once <00:20.880>I\n'
          '[00:20.500]那年我七岁\n'
          '[00:25.040]Go make yourself\n'
          '[00:25.040]去交些朋友';

      final split = LyricTextFormatter.splitTranslation(text);

      expect(split.translation, contains('[00:20.500]那年我七岁'));
      expect(split.translation, contains('[00:25.040]去交些朋友'));
      expect(split.lyric, isNot(contains('那年我七岁')));
      expect(split.lyric, contains('[00:20.500]<00:20.500>Once'));
    });

    test('行首带词标签的同时间戳行不当译文（逐字歌词不会被误拆）', () {
      const text = '[00:01.000]<00:01.000>你\n[00:01.000]<00:01.400>好';

      final split = LyricTextFormatter.splitTranslation(text);

      expect(split.translation, isNull);
      expect(split.lyric, text);
    });

    test('没有译文时原样返回', () {
      const text = '[00:01.000]Hello\n[00:02.000]World';
      final split = LyricTextFormatter.splitTranslation(text);
      expect(split.translation, isNull);
      expect(split.lyric, text);
    });
  });
}
