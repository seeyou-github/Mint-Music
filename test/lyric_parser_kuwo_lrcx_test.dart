import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/player/domain/services/lyric_parser.dart';

/// 酷我 newlyric 接口返回的真实 LRCX：GBK 解码后是
/// `[mm:ss.mmm]<a,b>字`，`[kuwo:037]` 给出换算除数，首字标签必为负数。
const _kuwoLrcx = '''
[kuwo:037]
[ti:稻香 (Live)]
[00:00.246]<52,-52>稻<208,104>香<364,260> <520,416>(<676,572>TF
[00:19.189]<208,-208>跌<848,400>倒<1560,1032>了
''';

void main() {
  group('parseLrcx 酷我编码', () {
    test('识别带负数的 LRCX 标签', () {
      expect(isLrcxFormat('[00:00.246]<52,-52>稻'), isTrue);
      expect(isLrcxFormat('[1000,500]<0,100>稻'), isTrue);
      expect(detectWordLyricFormat(_kuwoLrcx), 'LRCX');
    });

    test('按 [kuwo:XYZ] 除数还原逐字时间，不残留标签文本', () {
      final lines = parseLrcx(_kuwoLrcx);

      expect(lines, hasLength(2));

      final first = lines.first;
      expect(first.startTimeMs, 246);
      expect(first.words.map((w) => w.word).join(), '稻香 (TF');
      for (final word in first.words) {
        expect(word.word, isNot(contains('<')));
      }
      // 稻：|(52-52)/(3*2)| = 0 → 246..298
      expect(first.words[0].startTimeMs, 246);
      expect(first.words[0].endTimeMs, 298);
      // 香：起点 |(208+104)/6| = 52 → 298..350
      expect(first.words[1].startTimeMs, 298);
      expect(first.words[1].endTimeMs, 350);
      // TF：起点 |(676+572)/6| = 208 → 454..506
      expect(first.words.last.word, 'TF');
      expect(first.words.last.startTimeMs, 454);
      expect(first.words.last.endTimeMs, 506);

      final second = lines.last;
      expect(second.startTimeMs, 19189);
      expect(second.words.map((w) => w.word).join(), '跌倒了');
      expect(second.words[0].startTimeMs, 19189);
      expect(second.words[0].endTimeMs, 19397);
      expect(second.words.last.startTimeMs, 19621);
      expect(second.words.last.endTimeMs, 19885);
    });

    test('普通 LRCX（非负数标签）仍按 <起始,时长> 解析', () {
      final lines = parseLrcx('[00:12.005]<0,180>Stay<180,160>here');

      expect(lines, hasLength(1));
      expect(lines.first.words.first.word, 'Stay');
      expect(lines.first.words.first.startTimeMs, 12005);
      expect(lines.first.words.first.endTimeMs, 12185);
      expect(lines.first.words.last.word, 'here');
      expect(lines.first.words.last.startTimeMs, 12185);
      expect(lines.first.words.last.endTimeMs, 12345);
    });
  });
}
