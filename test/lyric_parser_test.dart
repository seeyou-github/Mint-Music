import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/player/domain/services/lyric_parser.dart';

void main() {
  group('parseLrc', () {
    test('removes inline timestamp tags from lyric text', () {
      final lines = parseLrc('[00:15.000]别一个人看喜剧[00:17.111]');

      expect(lines, hasLength(1));
      expect(lines.first.plainText, '别一个人看喜剧');
    });

    test('merges translation lyric into base lines via mergeTranslation', () {
      // 双语合并由 lyric_controller 调用 mergeTranslation 完成：
      // 基础歌词与翻译歌词（tlyric）分开解析，再按时间窗合并。
      final base = parseLrc(
        '[00:10.000]别一个人看喜剧\n[00:13.000]It echoes in the room',
      );
      final merged = mergeTranslation(
        base,
        '[00:10.000]Don\'t watch comedies alone\n[00:13.000]它在房间里回响',
      );

      expect(merged, hasLength(2));
      expect(merged.first.plainText, '别一个人看喜剧');
      expect(merged.first.translatedLyric, "Don't watch comedies alone");
      expect(merged.last.plainText, 'It echoes in the room');
      expect(merged.last.translatedLyric, '它在房间里回响');
    });

    test('parses Migu style lrcx word timings', () {
      final lines = parseLyricAuto('[00:12.005]<0,180>Stay<180,160>here');

      expect(lines, hasLength(1));
      expect(lines.first.isYrc, isTrue);
      expect(lines.first.words.first.word, 'Stay');
      expect(lines.first.words.first.startTimeMs, 12005);
      expect(lines.first.words.first.endTimeMs, 12185);
      expect(lines.first.words.last.word, 'here');
    });

    test('parses YRC style word timings used by wy kg and kw', () {
      final lines = parseLyricAuto(
        '[12005,340](12005,180,0)Stay(12185,160,0)here',
      );

      expect(lines, hasLength(1));
      expect(lines.first.isYrc, isTrue);
      expect(lines.first.startTimeMs, 12005);
      expect(lines.first.words.first.word, 'Stay');
      expect(lines.first.words.last.word, 'here');
    });

    test('parses interleaved word timestamps with line start tag', () {
      // `[00:12.00]我[00:12.30]感[00:13.00]觉`：词级时间轴，标签不再作为文本显示
      // （我@行首00:12.00，感@00:13.00，觉=尾段无标签用最后标签时间兜底）
      final lines = parseLyricAuto('[00:12.00]我[00:12.30]感[00:13.00]觉');

      expect(lines, hasLength(1));
      expect(lines.first.plainText, '我感觉');
      expect(lines.first.isYrc, isTrue);
      expect(lines.first.words.map((w) => w.word).toList(), ['我', '感', '觉']);
      expect(lines.first.words[0].startTimeMs, 12000);
      expect(lines.first.words[1].startTimeMs, 13000);
      expect(lines.first.words[2].startTimeMs, 13000);
    });

    test('parses interleaved word timestamps without line start tag', () {
      // 用户反馈样例：无行首时间戳的交错式标签，不能整行丢弃或显示标签
      final lines = parseLyricAuto('我[02:13.20]感[02:13.64]觉[02:14.53]');

      expect(lines, hasLength(1));
      expect(lines.first.plainText, '我感觉');
      expect(lines.first.isYrc, isTrue);
      expect(lines.first.words.map((w) => w.word).toList(), ['我', '感', '觉']);
      expect(lines.first.startTimeMs, 133200);
      expect(lines.first.words.last.startTimeMs, 134530);
    });

    test('strips single-digit millisecond interleaved tags', () {
      // 1 位毫秒标签（旧正则无法剥离，会残留成文本）
      final lines = parseLyricAuto('[00:15.000]别一个人看喜剧[00:17.1]');

      expect(lines, hasLength(1));
      expect(lines.first.plainText, '别一个人看喜剧');
    });

    test('yrc fallback strips inline lrc tags from raw content', () {
      // 混排/异常 YRC 行：无 (ms,dur) 词标签时整行作为 word 保存，
      // 必须先剥离内联 `[mm:ss.xx]` 标签再显示。
      final lines = parseYrc('[12005,340]我[02:13.20]感[02:13.64]觉');

      expect(lines, hasLength(1));
      expect(lines.first.plainText, '我感觉');
    });

    test('enhanced lrc and standard lrc coexist without tag leakage', () {
      // 混合行：标准时间戳行 + 交错式标签行，都应无标签残留
      final lines = parseLyricAuto(
        '[00:12.00]我[00:12.30]感[00:13.00]觉\n'
        '[00:15.000]别一个人看喜剧[00:17.111]',
      );

      expect(lines, hasLength(2));
      expect(lines[0].plainText, '我感觉');
      expect(lines[1].plainText, '别一个人看喜剧');
    });
  });
}
