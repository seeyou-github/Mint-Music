import 'lyric_parser.dart';
import '../models/lyric_line.dart';

/// 把歌词整理成「可以写进歌曲标签 / 单独 .lrc 文件」的格式。
///
/// 三个写入场景共用这一套规则：
/// * 下载时把歌词写进标签（`TagWriteService`）；
/// * 播放页「搜索歌词」里手动指定一份歌词，顺手写回本地文件；
/// * 编辑标签页「在线搜索」匹配到的歌词。
///
/// 以前几处各写一套、各挑各自的字段：有的只认 `lrc`、有的只认 `crlyric`、
/// 全部丢了 `tlyric`。于是同一个音源的同一份歌词，播放页是 TTML + 翻译，
/// 搜索预览是 YRC + 翻译，写进文件的却是没有翻译的整行 LRC。现在统一成：
/// 先按显示用的规则解析成行（[parseBestLyricText]，逐字优先），合并翻译，
/// 再输出成同一种文本。
class LyricTextFormatter {
  const LyricTextFormatter._();

  /// 从一份歌词结果里挑出要写进文件的文本。
  ///
  /// 输出格式：
  /// * 有逐字时间轴的行 → 增强 LRC（`[mm:ss.mmm]<mm:ss.mmm>字`）；
  /// * 整行歌词 → 标准 LRC（`[mm:ss.mmm]整行`）；
  /// * 有翻译时，紧跟原文行再写一行同时间戳的译文。
  ///
  /// 增强 LRC 行首仍是标准 `[mm:ss]`，普通播放器至少能当整行歌词读；原文 +
  /// 同时间戳译文两行是双语歌词的通行写法，本应用读回来会重新合成「原文 +
  /// 翻译」（见 [splitTranslation]）。
  static String fromResult(LyricResult result) {
    var lines = parseBestLyricText(result);
    if (lines.isEmpty) return '';

    final tlyric = result.tlyric?.trim() ?? '';
    if (tlyric.isNotEmpty) {
      lines = stripTranslationFromWords(mergeTranslation(lines, tlyric));
    }
    return linesToText(lines);
  }

  /// 优先逐字：已经是增强 LRC 就原样返回，能识别出 TTML / YRC / QRC / KRC
  /// 就按其词级时间轴重排成增强 LRC；都做不到才退回标准 LRC。
  static String preferWordByWord(String lyric) {
    final text = extractEmbeddedLyricContent(lyric);
    if (text.isEmpty) return '';
    if (isEnhancedLrcFormat(text)) return text;

    final lines = parseLyricAuto(text);
    if (lines.isNotEmpty) {
      final converted = linesToText(lines);
      if (converted.isNotEmpty) return converted;
    }

    return _cleanRawLrc(text);
  }

  /// 标准 LRC：剥离词级时间标签，只留行首时间轴。
  static String toStandardLrc(String lyric) {
    final text = extractEmbeddedLyricContent(lyric);
    if (text.isEmpty) return '';

    final lines = parseLyricAuto(text);
    if (lines.isNotEmpty) {
      final converted = linesToText(lines, wordByWord: false);
      if (converted.isNotEmpty) return converted;
    }

    return _cleanRawLrc(text);
  }

  /// 歌词行 → 可写进文件的文本。
  static String linesToText(List<LyricLine> lines, {bool wordByWord = true}) {
    final buffer = StringBuffer();
    for (final line in lines) {
      final plain = line.plainText.trim();
      if (plain.isEmpty) continue;

      if (wordByWord && line.words.length > 1) {
        buffer.write(_formatTimestamp(line.startTimeMs));
        for (final word in line.words) {
          if (word.word.isEmpty) continue;
          buffer.write('<${_formatClock(word.startTimeMs)}>');
          buffer.write(word.word);
        }
        buffer.writeln();
      } else {
        buffer.writeln('${_formatTimestamp(line.startTimeMs)}$plain');
      }

      final translation = line.translatedLyric?.trim() ?? '';
      if (translation.isNotEmpty && translation != plain) {
        buffer.writeln('${_formatTimestamp(line.startTimeMs)}$translation');
      }
    }
    return buffer.toString().trim();
  }

  /// 把「原文行 + 紧随其后同时间戳的译文行」拆回原文与翻译两份 LRC。
  ///
  /// 这是 [linesToText] 的逆向操作：写进歌曲文件的双语歌词再读出来时，
  /// 译文不会被当成另一行歌词滚上去，而是回到歌词行的翻译位置显示。
  ///
  /// 只把「紧跟在原文后面、时间戳完全相同、自身没有词级标签」的行当译文，
  /// 所以本来就带逐字时间轴的双行歌词不会被误拆。
  static ({String lyric, String? translation}) splitTranslation(String text) {
    final source = extractEmbeddedLyricContent(text);
    if (source.isEmpty) return (lyric: '', translation: null);

    final lyricLines = <String>[];
    final translationLines = <String>[];
    int? lastStartMs;
    var lastWasLyric = false;

    for (final rawLine in source.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      final match = _timestampPrefixRegExp.firstMatch(line);
      if (match == null) {
        lyricLines.add(line);
        lastWasLyric = false;
        lastStartMs = null;
        continue;
      }

      final startMs = _parseTimestamp(match);
      final body = line.substring(match.end);
      final isTranslation =
          lastWasLyric && startMs == lastStartMs && !body.contains('<');

      if (isTranslation) {
        translationLines.add('${_formatTimestamp(startMs)}$body');
        lastWasLyric = false;
        lastStartMs = null;
      } else {
        lyricLines.add(line);
        lastWasLyric = true;
        lastStartMs = startMs;
      }
    }

    if (translationLines.isEmpty) {
      return (lyric: source, translation: null);
    }
    return (
      lyric: lyricLines.join('\n'),
      translation: translationLines.join('\n'),
    );
  }

  /// 文本里有没有「至少一行带时间轴」。
  ///
  /// 只认 `[mm:ss]` / `[mm:ss.xx]` / `[mm:ss.xxx]`。用来把「平台返回的曲目信息」
  /// 和「真歌词」区分开（前者一个时间轴都没有，写进标签没有意义）。
  ///
  /// 注意：必须用 [preferWordByWord] / [toStandardLrc] 整理**之后**的文本判断。
  /// 逐字歌词的原文（QRC / YRC）行首是 `[起点,时长]`，这里会判成没有时间轴。
  static bool hasTimeline(String text) =>
      RegExp(r'\[\s*\d{1,3}\s*:\s*\d{1,2}').hasMatch(text);

  static final RegExp _timestampPrefixRegExp = RegExp(
    r'^\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]',
  );

  static int _parseTimestamp(RegExpMatch match) {
    final minutes = int.tryParse(match.group(1) ?? '0') ?? 0;
    final seconds = int.tryParse(match.group(2) ?? '0') ?? 0;
    var msText = match.group(3) ?? '0';
    if (msText.length == 2) msText = '${msText}0';
    if (msText.length > 3) msText = msText.substring(0, 3);
    return minutes * 60000 + seconds * 1000 + (int.tryParse(msText) ?? 0);
  }

  /// 解析失败时的兜底清洗：保留行首时间戳，剥离所有词级标记，
  /// 避免普通播放器把标签当歌词文本显示。
  static String _cleanRawLrc(String lyric) {
    final buffer = StringBuffer();
    final lineRegExp = RegExp(r'^\[(\d{1,2}):(\d{2})[.:](\d{1,3})\](.*)$');
    for (final rawLine in lyric.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final match = lineRegExp.firstMatch(line);
      if (match == null) continue;
      final head = line.substring(0, match.group(0)!.indexOf(']') + 1);
      final text = match
          .group(4)!
          .replaceAll(RegExp(r'[(（]\d+[,，]\d+(?:[,，]\d+)?[)）]'), '')
          .replaceAll(RegExp(r'<-?\d+(?:,-?\d+)+>'), '')
          .replaceAll(
            RegExp(r'[\[\［]\d{1,2}:\d{1,2}(?:[.:]\d{1,3})?[\]\］]'),
            '',
          )
          .trim();
      if (text.isEmpty) continue;
      buffer.writeln('$head$text');
    }
    return buffer.toString().trim();
  }

  static String _formatTimestamp(int ms) {
    final total = ms < 0 ? 0 : ms;
    final mm = (total ~/ 60000).toString().padLeft(2, '0');
    final ss = ((total % 60000) ~/ 1000).toString().padLeft(2, '0');
    final xxx = (total % 1000).toString().padLeft(3, '0');
    return '[$mm:$ss.$xxx]';
  }

  static String _formatClock(int ms) {
    final total = ms < 0 ? 0 : ms;
    final mm = (total ~/ 60000).toString().padLeft(2, '0');
    final ss = ((total % 60000) ~/ 1000).toString().padLeft(2, '0');
    final xxx = (total % 1000).toString().padLeft(3, '0');
    return '$mm:$ss.$xxx';
  }
}
