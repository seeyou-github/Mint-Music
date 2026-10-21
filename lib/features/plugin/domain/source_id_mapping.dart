/// 插件音源名称与内置音源 id 之间的归一化映射。
///
/// 澜音（cr）/ 洛雪（lx）插件直接声明 `sourceId`，而 MusicFree 插件只声明一个
/// `platform` 名称（例如「网易128k」「bilibili」）。为了让「搜索源选择器」拿到
/// 的 id 与插件内部声明的 id 完全一致，名称到 id 的推导规则必须同时存在于两侧：
///
/// * Dart：本文件；
/// * JS：`assets/plugin_modules/musicfree_adapter.js` 的 `__mfSourceIdFromName`。
///
/// 两者的匹配顺序与关键字表必须保持同步，否则会出现「界面列出音源，但搜索
/// 传下去的 id 找不到对应宿主」的问题。
class SourceIdMapping {
  const SourceIdMapping._();

  /// 已知音源 id → 展示名。
  static const Map<String, String> idToName = {
    'wy': '网易云音乐',
    'kg': '酷狗音乐',
    'kw': '酷我音乐',
    'tx': 'QQ音乐',
    'mg': '咪咕音乐',
    'qsvip': '汽水VIP',
  };

  /// 精确名称别名表（键统一小写）。
  static const Map<String, String> aliases = {
    'wy': 'wy',
    '网易': 'wy',
    '网易云': 'wy',
    '网易云音乐': 'wy',
    'netease': 'wy',
    'neteasemusic': 'wy',
    'kg': 'kg',
    '酷狗': 'kg',
    '酷狗音乐': 'kg',
    'kugou': 'kg',
    'kw': 'kw',
    '酷我': 'kw',
    '酷我音乐': 'kw',
    'kuwo': 'kw',
    'tx': 'tx',
    'qq': 'tx',
    'qq音乐': 'tx',
    'qqmusic': 'tx',
    'mg': 'mg',
    '咪咕': 'mg',
    '咪咕音乐': 'mg',
    'migu': 'mg',
    'qsvip': 'qsvip',
    '汽水': 'qsvip',
    '汽水音乐': 'qsvip',
    '汽水vip': 'qsvip',
    // 落雪脚本用 'qs' 表示汽水音乐。
    'qs': 'qsvip',
  };

  /// 关键字（模糊）别名表，顺序敏感：先命中者优先。
  static const List<List<String>> _keywordAliases = [
    ['网易', 'wy'],
    ['netease', 'wy'],
    ['163', 'wy'],
    ['酷狗', 'kg'],
    ['kugou', 'kg'],
    ['酷我', 'kw'],
    ['kuwo', 'kw'],
    ['qq', 'tx'],
    ['咪咕', 'mg'],
    ['migu', 'mg'],
    ['汽水', 'qsvip'],
    ['qsvip', 'qsvip'],
  ];

  /// 名称 → 已知音源 id；无法识别时返回 null。
  ///
  /// [name] 既可能是内置源的规范名称（如「网易云音乐」），也可能是插件声明的
  /// platform（如「网易128k」「MiguMusic」）。
  static String? knownId(String name) {
    final lower = name.trim().toLowerCase();
    if (lower.isEmpty) return null;

    final exact = aliases[lower];
    if (exact != null) return exact;

    for (final entry in _keywordAliases) {
      if (lower.contains(entry[0])) return entry[1];
    }
    return null;
  }

  /// 名称 → 最终音源 id。
  ///
  /// 优先级：已知别名 → 名称中的 ASCII 片段 → 原始名称（保证 id 永远可用）。
  /// 与 `musicfree_adapter.js` 中 `__mfSourceIdFromName` 的行为一致。
  static String deriveId(String name) {
    final known = knownId(name);
    if (known != null) return known;

    final trimmed = name.trim();
    final ascii = trimmed.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (ascii.isNotEmpty) return ascii;
    return trimmed.isEmpty ? 'src' : trimmed;
  }
}
