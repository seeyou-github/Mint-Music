/// 插件 / 接口给的年份字段 → 4 位年份（解析不出来返回 null）。
///
/// 实际遇到过这些形态：
/// * `2020`（直接就是年份）
/// * `'2020'` / `'2020-05-01'` / `'2020/5/1'`（发布日期）
/// * `1059580800`（秒级时间戳，QQ 的 `pubtime`）
/// * `1733068800000`（毫秒级时间戳，网易的 `publishTime`）
int? parseSongYear(dynamic value) {
  if (value == null) return null;
  if (value is num) {
    final raw = value.toInt();
    if (raw <= 0) return null;
    if (raw >= 1900 && raw <= 2999) return raw;
    final ms = raw < 100000000000 ? raw * 1000 : raw;
    final year = DateTime.fromMillisecondsSinceEpoch(ms).year;
    return year > 1900 && year < 3000 ? year : null;
  }
  final text = value.toString().trim();
  if (text.isEmpty) return null;
  final dateMatch = RegExp(r'^(\d{4})[-/]').firstMatch(text);
  if (dateMatch != null) return int.tryParse(dateMatch.group(1)!);
  final direct = int.tryParse(text);
  if (direct != null) return parseSongYear(direct);
  return null;
}

/// 从发行日期文本里取年份（`2020`、`2020-05-01`、`2020年` 都认）。
int? yearFromDateText(String? date) {
  final text = (date ?? '').trim();
  if (text.isEmpty) return null;
  final match = RegExp(r'(?:19|20)\d{2}').firstMatch(text);
  if (match == null) return null;
  return int.tryParse(match.group(0)!);
}
