/// 按时间戳稳定排序：时间戳相同的行保持原顺序。
///
/// 默认的 `List.sort` 在长列表上是不稳定排序，而「原文行 + 紧随其后同时间戳
/// 的翻译行」正是靠原顺序区分的（见 `LyricTextFormatter.splitTranslation`），
/// 一旦被打乱就会出现「翻译跑到原文上面」。
void sortStableBy<T>(List<T> items, int Function(T item) startOf) {
  final indexed = <MapEntry<int, T>>[
    for (var i = 0; i < items.length; i++) MapEntry(i, items[i]),
  ];
  indexed.sort((a, b) {
    final byTime = startOf(a.value).compareTo(startOf(b.value));
    return byTime != 0 ? byTime : a.key.compareTo(b.key);
  });
  for (var i = 0; i < indexed.length; i++) {
    items[i] = indexed[i].value;
  }
}
