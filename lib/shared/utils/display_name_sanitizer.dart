/// 显示名清洗：把「花体 Unicode 混排」的插件 / 音源名转回常规字符。
///
/// 有些音源作者会用「花体字生成器」混淆插件名：数学字母（U+1D400~U+1D7FF）、
/// 全角、字距调整符号、加拿大盲文音节、西里尔同形字等混在一起。例如
/// `𝖧౿ᥣᥣ𝗈 Ԝ𝗈𝗋ᥣᑯ` 其实就是 hello world。应用字体没有这些字形，
/// 界面上整段显示成「豆腐块」（乱码）。
///
/// [sanitizeDisplayName] 把它们映射回常规拉丁字符；剔除零宽 / 双向控制符；
/// 无法识别的字符原样保留。全部被剔除时返回原文，避免把名字洗没了。
library;

const Map<int, String> _letterlike = {
  0x2102: 'C',
  0x210A: 'g',
  0x210B: 'H',
  0x210C: 'H',
  0x210D: 'H',
  0x210E: 'h',
  0x2110: 'I',
  0x2111: 'I',
  0x2112: 'L',
  0x2113: 'l',
  0x2115: 'N',
  0x2119: 'P',
  0x211A: 'Q',
  0x211B: 'R',
  0x211C: 'R',
  0x211D: 'R',
  0x2124: 'Z',
  0x2128: 'Z',
  0x212A: 'K',
  0x212C: 'B',
  0x212D: 'C',
  0x212F: 'e',
  0x2130: 'E',
  0x2131: 'F',
  0x2133: 'M',
  0x2134: 'o',
  0x2139: 'i',
  0x2145: 'D',
  0x2146: 'd',
  0x2147: 'e',
  0x2148: 'i',
  0x2149: 'j',
};

/// 「花体字生成器」常用的同形字 → 常规字符。
///
/// 数学字母区覆盖不到的几类：加拿大盲文音节 / 泰卢固 / 西里尔等同形字。
/// 取自实际遇到的混淆样本（如 `౿` 当 e、`ᥣ` 当 l、`ᑯ` 当 d、`Ԝ` 当 W）。
const Map<int, String> _homoglyphs = {
  0x0C7F: 'e', // ౿（泰卢固）
  0x051C: 'W', // Ԝ（西里尔）
  0x146F: 'd', // ᑯ（盲文音节）
  0x1963: 'l', // ᥣ（盲文音节）
  0x13A0: 'A', // Ꭰ（切罗基，部分生成器会用）
  0x13AB: 'K', // Ꭻ
  0x13AC: 'L', // Ꭼ
  0x13DB: 'V', // Ꮴ
  0x2102: 'C', // ℂ（同 Letterlike，便于统一查表）
  0x210E: 'h', // ℎ
};

/// 数学字母数字符号区（U+1D400 ~ U+1D7FF）：每段首码点 → 段内首字符。
/// 段内按序号偏移就是对应的常规字母 / 数字。
const List<(int, String)> _mathRanges = [
  (0x1D400, 'A'),
  (0x1D41A, 'a'),
  (0x1D434, 'A'),
  (0x1D44E, 'a'),
  (0x1D468, 'A'),
  (0x1D482, 'a'),
  (0x1D49C, 'A'),
  (0x1D4B6, 'a'),
  (0x1D4D0, 'A'),
  (0x1D4EA, 'a'),
  (0x1D504, 'A'),
  (0x1D51E, 'a'),
  (0x1D538, 'A'),
  (0x1D552, 'a'),
  (0x1D56C, 'A'),
  (0x1D586, 'a'),
  (0x1D5A0, 'A'),
  (0x1D5BA, 'a'),
  (0x1D5D4, 'A'),
  (0x1D5EE, 'a'),
  (0x1D608, 'A'),
  (0x1D622, 'a'),
  (0x1D63C, 'A'),
  (0x1D656, 'a'),
  (0x1D670, 'A'),
  (0x1D68A, 'a'),
  (0x1D7CE, '0'),
  (0x1D7D8, '0'),
  (0x1D7E2, '0'),
  (0x1D7EC, '0'),
  (0x1D7F6, '0'),
];

/// 单个字符的映射；返回 null 表示这个字符应当剔除（零宽 / 双向控制符）。
String? _mapRune(int rune) {
  // 零宽字符、双向控制符、软连字符：肉眼不可见，只会把名字搅乱。
  if ((rune >= 0x200B && rune <= 0x200F) ||
      (rune >= 0x202A && rune <= 0x202E) ||
      (rune >= 0x2060 && rune <= 0x206F) ||
      (rune >= 0x180B && rune <= 0x180E) ||
      rune == 0xFEFF ||
      rune == 0x00AD) {
    return null;
  }
  // 全角 → 半角。
  if (rune >= 0xFF01 && rune <= 0xFF5E) {
    return String.fromCharCode(rune - 0xFEE0);
  }
  if (rune == 0x3000) return ' ';
  // 数学字母数字符号（花体字生成器的主力：𝖧𝗈𝗋𝗹𝑑𝑒 这些）。
  if (rune >= 0x1D400 && rune <= 0x1D7FF) {
    for (final (start, first) in _mathRanges) {
      final length = first == '0' ? 10 : 26;
      if (rune >= start && rune < start + length) {
        final mapped = String.fromCharCode(
          first.codeUnitAt(0) + (rune - start),
        );
        // 段内保留码点（如 𝑈+1D455 的空位）算出来会越界成怪字符，
        // 它们在 Unicode 里本就未分配，原样保留即可。
        final code = mapped.codeUnitAt(0);
        final isAlnum =
            (code >= 0x30 && code <= 0x39) ||
            (code >= 0x41 && code <= 0x5A) ||
            (code >= 0x61 && code <= 0x7A);
        return isAlnum ? mapped : null;
      }
    }
  }
  final letterlike = _letterlike[rune];
  if (letterlike != null) return letterlike;
  final homoglyph = _homoglyphs[rune];
  if (homoglyph != null) return homoglyph;
  return String.fromCharCode(rune);
}

/// 清洗插件 / 音源的显示名。
String sanitizeDisplayName(String input) {
  if (input.isEmpty) return input;
  final buffer = StringBuffer();
  var changed = false;
  for (final rune in input.runes) {
    final mapped = _mapRune(rune);
    if (mapped == null) {
      changed = true;
      continue;
    }
    if (mapped.codeUnits.length != 1 || mapped.codeUnitAt(0) != rune) {
      changed = true;
    }
    buffer.write(mapped);
  }
  final result = buffer.toString().trim();
  if (result.isEmpty) return input;
  return changed ? result : input;
}
