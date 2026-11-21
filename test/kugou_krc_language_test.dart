import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/player/domain/models/lyric_line.dart';
import 'package:mintmusic/features/player/domain/services/lyric_parser.dart';

/// 酷狗 KRC 的 `[language:<base64>]`：翻译 / 音译靠它，位置在歌词头部元数据区。
///
/// 结构取自真实返回：`content` 里每一项的 `lyricContent` 与 KRC 的
/// `[start,dur]` 行按顺序一一对应，`[" "]` 是「这一行没有翻译」的占位。
const _languageBase64 =
    'eyJjb250ZW50IjpbeyJsYW5ndWFnZSI6MCwidHlwZSI6MSwibHlyaWNDb250ZW50IjpbWyIgIl0s'
    'WyLmiJHnnIvop4HkvaDlkozlpbkiXSxbIuWcqOmbqOS4rea8q+atpSJdXX0seyJsYW5ndWFnZSI6'
    'MCwidHlwZSI6MiwibHlyaWNDb250ZW50IjpbWyIgIl0sWyJ3byBrYW4gamlhbiBuaSBoZSB0YSJd'
    'LFsiemFpIHl1IHpob25nIG1hbiBidSJdXX1dLCJ2ZXJzaW9uIjoxfQ==';

/// 真实酷狗返回的样子：元数据几行 → `[language:]` → 逐字歌词。
const _krc =
    '[id:\$00000000]\n'
    '[ar:Samira]\n'
    '[ti:The Rain]\n'
    '[language:$_languageBase64]\n'
    '[0,55010]<0,3667,0>The<3667,3667,0> <7334,3667,0>Rain\n'
    '[55015,8070]<0,534,0>I <534,552,0>saw <1086,589,0>you\n'
    '[63085,2436]<0,369,0>You <369,376,0>were <745,943,0>holding\n';

void main() {
  group('splitKrcLanguage', () {
    test('译文从 base64 里解出来，按 KRC 行起点打时间轴', () {
      final split = splitKrcLanguage(_krc);

      expect(
        split.lyric.contains('[language:'),
        isFalse,
        reason: 'base64 要从文本里剥掉',
      );
      expect(split.translation, contains('[00:55.01]我看见你和她'));
      expect(split.translation, contains('[01:03.08]在雨中漫步'));
      expect(
        split.translation,
        isNot(contains('[00:00.00]')),
        reason: '首行是占位空行',
      );
      expect(split.roman, contains('[00:55.01]wo kan jian ni he ta'));
    });

    test('剥掉标签后的 KRC 仍能正常解析成逐字歌词', () {
      final split = splitKrcLanguage(_krc);
      final lines = parseKrc(split.lyric);

      expect(lines, hasLength(3));
      expect(lines[1].startTimeMs, 55015);
      expect(lines[1].plainText.replaceAll(' ', ''), 'Isawyou');
      expect(lines[1].words, hasLength(3), reason: '逐字时间轴不能丢');
    });

    test('没有 [language:] 的普通 KRC 原样返回', () {
      final split = splitKrcLanguage('[0,1000]<0,500,0>你<500,500,0>好\n');
      expect(split.translation, isNull);
      expect(split.roman, isNull);
      expect(split.lyric, contains('你'));
    });

    test('base64 坏掉时只剥标签，不让整份歌词失效', () {
      final split = splitKrcLanguage(
        '[language:not-base64!!]\n[0,1000]<0,500,0>你\n',
      );
      expect(split.translation, isNull);
      expect(split.lyric, isNot(contains('[language:')));
      expect(split.lyric, contains('你'));
    });
  });

  group('normalizeKrcLanguage', () {
    test('插件没解 language 时由宿主补上翻译', () {
      const result = LyricResult(crlyric: _krc, lrc: '');
      final normalized = normalizeKrcLanguage(result);

      expect(normalized.crlyric, isNot(contains('[language:')));
      expect(normalized.tlyric, contains('我看见你和她'));
      expect(normalized.rlyric, contains('wo kan jian ni he ta'));
    });

    test('插件已经给过翻译时不覆盖（插件那份优先）', () {
      const result = LyricResult(
        crlyric: _krc,
        tlyric: '[00:55.01]插件给的翻译',
        rlyric: '[00:55.01]gei de yin yi',
      );
      final normalized = normalizeKrcLanguage(result);

      expect(normalized.crlyric, same(result.crlyric), reason: '没东西可补就别动');
      expect(normalized.tlyric, '[00:55.01]插件给的翻译');
      expect(normalized.rlyric, '[00:55.01]gei de yin yi');
    });

    test('归一化后的结果能直接用于显示：逐字 + 翻译', () {
      final normalized = normalizeKrcLanguage(const LyricResult(crlyric: _krc));
      final lines = parseBestLyricText(normalized);

      expect(lines.any((line) => line.isYrc), isTrue);
      final merged = mergeTranslation(lines, normalized.tlyric);
      expect(
        merged.any((line) => line.translatedLyric == '我看见你和她'),
        isTrue,
        reason: '翻译要落到对应的逐字行上',
      );
    });
  });
}
