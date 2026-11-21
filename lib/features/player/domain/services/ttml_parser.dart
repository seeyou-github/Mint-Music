import 'dart:isolate';

import 'package:xml/xml.dart';
import '../models/lyric_line.dart';
import 'lyric_sort.dart';

/// 短 TTML 不值得 spawn isolate（开销比 XML 解析本身还大），见
/// `parseLyricAutoInIsolate` 的同类阈值。
const int _isolateTtmlThreshold = 32 * 1024;

/// [parseTtml] 的 isolate 版本：TTML 文本可达数百 KB，XML 解析在主线程会
/// 卡住切歌瞬间的那一帧。输入 / 输出都是可直接跨 isolate 传递的数据。
Future<List<LyricLine>> parseTtmlInIsolate(String ttmlText) =>
    ttmlText.length < _isolateTtmlThreshold
    ? Future.value(parseTtml(ttmlText))
    : Isolate.run(() => parseTtml(ttmlText));

List<LyricLine> parseTtml(String ttmlText) {
  if (ttmlText.isEmpty) return [];

  try {
    final document = XmlDocument.parse(ttmlText);
    final body = document.findAllElements('body').firstOrNull;
    if (body == null) return [];

    final lines = <LyricLine>[];
    final divs = body.findAllElements('div');

    for (final div in divs) {
      final paragraphs = div.findElements('p');
      for (final p in paragraphs) {
        final line = _parseTtmlParagraph(p);
        if (line != null) lines.add(line);
      }
    }

    sortStableBy(lines, (line) => line.startTimeMs);
    return lines;
  } catch (e) {
    return [];
  }
}

class _SpanInfo {
  final String text;
  final int startTimeMs;
  final int endTimeMs;
  const _SpanInfo({
    required this.text,
    required this.startTimeMs,
    required this.endTimeMs,
  });
}

LyricLine? _parseTtmlParagraph(XmlElement p) {
  final beginAttr = p.getAttribute('begin');
  final endAttr = p.getAttribute('end');
  if (beginAttr == null) return null;

  final startTimeMs = _parseTtmlTime(beginAttr);
  final endTimeMs = endAttr != null
      ? _parseTtmlTime(endAttr)
      : startTimeMs + 3000;
  if (startTimeMs < 0) return null;

  final fullText = p.innerText.trim();
  if (fullText.isEmpty) return null;

  // Normalize: collapse all whitespace runs to single spaces
  final normalized = fullText.replaceAll(RegExp(r'\s+'), ' ');

  final children = p.children;
  final hasSpans = children.any((c) => c is XmlElement);

  final words = <LyricWord>[];
  final translations = <String>[];

  if (!hasSpans) {
    // No span children — treat full text as a single word
    words.add(
      LyricWord(
        word: normalized,
        startTimeMs: startTimeMs,
        endTimeMs: endTimeMs,
      ),
    );
  } else {
    // Collect span data from XmlElement children only (skip XmlText)
    final spans = <_SpanInfo>[];
    for (final child in children) {
      if (child is XmlElement) {
        // 翻译轨：`<span ttm:role="x-translation" xml:lang="zh-CN">…</span>`，
        // 没有 begin/end，时间跟着整行。它属于「翻译」而不是「唱的歌词」：
        // 以前被当成普通词 span 拼进正文，于是显示成
        // 「Once I was seven years old曾几何时，我七岁那年」这样中英混排，
        // 写进文件也是一行中英混在一起。
        if (_ttmlRoleOf(child) == 'x-translation') {
          final text = child.innerText.trim();
          if (text.isNotEmpty) translations.add(text);
          continue;
        }
        final text = child.innerText.trim();
        if (text.isEmpty) continue;
        final spanBegin = child.getAttribute('begin');
        final spanEnd = child.getAttribute('end');
        spans.add(
          _SpanInfo(
            text: text,
            startTimeMs: spanBegin != null
                ? _parseTtmlTime(spanBegin)
                : startTimeMs,
            endTimeMs: spanEnd != null ? _parseTtmlTime(spanEnd) : endTimeMs,
          ),
        );
      }
    }

    if (spans.isEmpty) return null;

    // Align span-concatenated text with fullText to find word boundaries.
    // Wherever fullText has a space, that's a word boundary.
    // Mark the preceding span to get a trailing space.
    final spanConcat = spans.map((s) => s.text).join();
    final boundaryAfter = List.filled(spans.length, false);

    int scPos = 0;
    for (
      int ftPos = 0;
      ftPos < normalized.length && scPos < spanConcat.length;
      ftPos++
    ) {
      if (normalized[ftPos] == ' ') {
        if (scPos > 0) {
          final spanIdx = _spanAtCharPos(scPos - 1, spans);
          if (spanIdx >= 0 && spanIdx < boundaryAfter.length) {
            boundaryAfter[spanIdx] = true;
          }
        }
      } else if (normalized[ftPos] == spanConcat[scPos]) {
        scPos++;
      }
    }

    // Build LyricWord list — add trailing space at word boundaries
    for (int i = 0; i < spans.length; i++) {
      final span = spans[i];
      final w = boundaryAfter[i] ? '${span.text} ' : span.text;
      words.add(
        LyricWord(
          word: w,
          startTimeMs: span.startTimeMs,
          endTimeMs: span.endTimeMs,
        ),
      );
    }
  }

  if (words.isEmpty) return null;

  return LyricLine(
    startTimeMs: startTimeMs,
    endTimeMs: endTimeMs,
    words: words,
    translatedLyric: translations.isEmpty ? null : translations.join(' '),
  );
}

/// 取 `ttm:role` 的值（带命名空间前缀，按本地名匹配）。
String? _ttmlRoleOf(XmlElement element) {
  for (final attribute in element.attributes) {
    if (attribute.name.local == 'role') return attribute.value;
  }
  return null;
}

/// 只取 TTML 里的翻译轨，转成 `[mm:ss.mmm]译文` 的 LRC。
///
/// 给「音源先返回逐字歌词、TTML 迟到」的补翻译用：迟到那份 TTML 不参与
/// 选词（歌词主体还是音源的逐字），只把它自带的中文翻译合并到已有行上。
String ttmlTranslationLrc(List<LyricLine> lines) {
  final buffer = StringBuffer();
  for (final line in lines) {
    final text = line.translatedLyric?.trim() ?? '';
    if (text.isEmpty) continue;
    final total = line.startTimeMs < 0 ? 0 : line.startTimeMs;
    final mm = (total ~/ 60000).toString().padLeft(2, '0');
    final ss = ((total % 60000) ~/ 1000).toString().padLeft(2, '0');
    final xxx = (total % 1000).toString().padLeft(3, '0');
    buffer.writeln('[$mm:$ss.$xxx]$text');
  }
  return buffer.toString();
}

/// Find which span contains the character at [charPos] in the concatenated span text.
int _spanAtCharPos(int charPos, List<_SpanInfo> spans) {
  int pos = 0;
  for (int i = 0; i < spans.length; i++) {
    pos += spans[i].text.length;
    if (charPos < pos) return i;
  }
  return spans.length - 1;
}

int _parseTtmlTime(String timeStr) {
  if (timeStr.contains(':')) {
    final parts = timeStr.split(':');
    if (parts.length == 3) {
      final hours = int.tryParse(parts[0]) ?? 0;
      final minutes = int.tryParse(parts[1]) ?? 0;
      final seconds = _parseSeconds(parts[2]);
      return (hours * 3600 + minutes * 60) * 1000 + seconds;
    } else if (parts.length == 2) {
      final minutes = int.tryParse(parts[0]) ?? 0;
      final seconds = _parseSeconds(parts[1]);
      return (minutes * 60) * 1000 + seconds;
    }
  }

  final ms = int.tryParse(timeStr);
  if (ms != null) return ms;

  if (timeStr.endsWith('ms')) {
    return int.tryParse(timeStr.replaceAll('ms', '')) ?? -1;
  }
  if (timeStr.endsWith('s')) {
    final s = double.tryParse(timeStr.replaceAll('s', '')) ?? 0;
    return (s * 1000).round();
  }

  final fallback = double.tryParse(timeStr);
  if (fallback != null) return (fallback * 1000).round();

  return -1;
}

int _parseSeconds(String s) {
  if (s.contains('.')) {
    final parts = s.split('.');
    final wholeSeconds = int.tryParse(parts[0]) ?? 0;
    var fraction = parts.length > 1 ? parts[1] : '0';
    while (fraction.length < 3) {
      fraction += '0';
    }
    if (fraction.length > 3) {
      fraction = fraction.substring(0, 3);
    }
    final ms = int.tryParse(fraction) ?? 0;
    return wholeSeconds * 1000 + ms;
  }
  return (int.tryParse(s) ?? 0) * 1000;
}
