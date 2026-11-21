import 'dart:collection';
import 'dart:typed_data';

/// 封面字节的内存 LRU（全应用共用一个预算）。
///
/// 本地歌曲封面、网络封面、歌单 / 榜单封面以前各有一份 24MB / 32MB 的缓存，
/// 同一张图上不同页面还会各存一份；现在统一放这里，按「总字节数」淘汰最久
/// 没用过的条目，内存上限只有一份。
class CoverMemoryCache {
  CoverMemoryCache._();

  static final CoverMemoryCache instance = CoverMemoryCache._();

  /// 全部封面加起来的内存上限。
  static const int maxBytes = 32 * 1024 * 1024;

  final LinkedHashMap<String, Uint8List> _entries = LinkedHashMap();
  int _bytes = 0;

  /// 当前占用的字节数（调试 / 存储管理页用）。
  int get byteSize => _bytes;

  int get length => _entries.length;

  /// 读取并把条目移到「最近使用」。
  Uint8List? get(String key) {
    final bytes = _entries.remove(key);
    if (bytes == null) return null;
    _entries[key] = bytes;
    return bytes;
  }

  bool containsKey(String key) => _entries.containsKey(key);

  /// 写入（同 key 覆盖），超出预算时淘汰最久没用过的条目。
  void put(String key, Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxBytes) return;
    _removeEntry(key);
    while (_bytes + bytes.length > maxBytes && _entries.isNotEmpty) {
      final oldestKey = _entries.keys.first;
      final oldest = _entries.remove(oldestKey);
      if (oldest != null) _bytes -= oldest.length;
    }
    _entries[key] = bytes;
    _bytes += bytes.length;
  }

  Uint8List? remove(String key) => _removeEntry(key);

  void clear() {
    _entries.clear();
    _bytes = 0;
  }

  Uint8List? _removeEntry(String key) {
    final removed = _entries.remove(key);
    if (removed != null) _bytes -= removed.length;
    return removed;
  }
}
