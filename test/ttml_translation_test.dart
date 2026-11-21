import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/player/domain/services/ttml_parser.dart';

/// 真实 TTML 的结构（AMLL 词库 qq/000IvjwO1NYczE）：
/// 翻译是 `<p>` 里的 `<span ttm:role="x-translation" xml:lang="zh-CN">`，
/// 没有 begin/end —— 它是翻译，不是唱出来的词。
const _ttml = '''
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
  <body>
    <div begin="20.364" end="40.000">
      <p begin="20.364" end="24.753">
        <span begin="20.364" end="20.871">Once,</span>
        <span begin="20.871" end="21.163">I</span>
        <span begin="21.163" end="24.753">was</span><span ttm:role="x-translation" xml:lang="zh-CN">曾几何时，我七岁那年</span>
      </p>
      <p begin="24.854" end="28.256">
        <span begin="24.854" end="25.345">Go</span>
        <span begin="25.345" end="28.256">make</span><span ttm:role="x-translation" xml:lang="zh-CN">去交些朋友</span>
      </p>
      <p begin="30.000" end="31.000">
        <span begin="30.000" end="31.000">No translation here</span>
      </p>
    </div>
  </body>
</tt>
''';

void main() {
  group('parseTtml 翻译轨', () {
    test('x-translation 变成 translatedLyric，不拼进正文', () {
      final lines = parseTtml(_ttml);

      expect(lines, hasLength(3));
      expect(lines[0].translatedLyric, '曾几何时，我七岁那年');
      expect(lines[1].translatedLyric, '去交些朋友');
      expect(lines[2].translatedLyric, isNull, reason: '没有翻译轨的行保持空');

      for (final line in lines) {
        expect(
          line.plainText.contains('曾几何时'),
          isFalse,
          reason: '翻译不能混进原文（以前显示成「…seven years old曾几何时…」）',
        );
      }
    });

    test('逐字时间轴不受翻译轨影响', () {
      final lines = parseTtml(_ttml);
      expect(lines[0].words, hasLength(3));
      expect(lines[0].words.first.word.trim(), 'Once,');
      expect(lines[0].startTimeMs, 20364);
      expect(lines[0].endTimeMs, 24753);
    });

    test('中文文本不会把英文的词边界判断带偏', () {
      final lines = parseTtml(_ttml);
      // 原文两个词之间的空格要保留在词尾，逐字高亮才不会连着糊成一片。
      expect(lines[1].plainText.replaceAll(' ', ''), 'Gomake');
    });
  });

  group('ttmlTranslationLrc', () {
    test('只输出带翻译的行，时间戳跟着行起点', () {
      final lrc = ttmlTranslationLrc(parseTtml(_ttml));

      expect(lrc, contains('[00:20.364]曾几何时，我七岁那年'));
      expect(lrc, contains('[00:24.854]去交些朋友'));
      expect(lrc.contains('No translation here'), isFalse);
      expect(lrc.split('\n').where((l) => l.trim().isNotEmpty), hasLength(2));
    });

    test('没有翻译时返回空字符串', () {
      const noTranslation =
          '<tt xmlns="http://www.w3.org/ns/ttml"><body><div>'
          '<p begin="0:01.000" end="0:02.000"><span begin="0:01.000" end="0:02.000">hi</span></p>'
          '</div></body></tt>';
      expect(ttmlTranslationLrc(parseTtml(noTranslation)), isEmpty);
    });
  });
}
