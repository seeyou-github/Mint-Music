import 'dart:async';
import 'dart:convert';

import '../../../core/storage/app_preferences.dart';
import '../domain/source_health.dart';

/// 音源健康状态（失败 / 超时）的本地存储。
///
/// ## 为什么单独存
///
/// 这份数据有两个读者、一个写者，生命周期和插件元数据完全不同：
///
/// * 写者：数据源自动换源链路（`MusicSourceManager.resolveViaDataSource`）
///   与播放器的音频层失败兜底（URL 拿到了但放不出来）；
/// * 读者：插件管理页（插件卡片上的红标）、`PlaybackController`（跳过坏源）。
///
/// 它属于「运行时观察结果」，混进 `installed_plugins` 会让那份 JSON 被频繁
/// 重写，且卸载重装后会残留脏数据，所以单独一个 key。
///
/// ## 存储格式
///
/// 单个 key `plugin_source_health`，值为 JSON：
/// ```json
/// {
///   "wy@1a2b3c": { "status": "timeout", "reason": "请求超时（10 秒）", "at": 1793000000000 },
///   "kw@4d5e6f": { "status": "failed",  "reason": "接口返回 404",       "at": 1793000001000 }
/// }
/// ```
///
/// 解析不了的单条记录直接丢弃（不阻塞其它记录，也不让界面崩）。
///
/// ## 内存缓存 + 版本号
///
/// 界面需要**同步**读取（`entryOf` / `entriesForPlugin`），所以加载后放进
/// 内存。任何写操作都会 `revision` 自增并广播，UI 用
/// `pluginSourceHealthRevisionProvider` 订阅后重建。
class SourceHealthStore {
  static const String _key = 'plugin_source_health';

  static final Map<String, SourceHealthEntry> _entries = {};
  static final StreamController<int> _changes =
      StreamController<int>.broadcast();

  static int _revision = 0;
  static Future<void>? _loading;

  /// 每次数据变化自增；UI 订阅它来重建。
  static Stream<int> get changes => _changes.stream;

  static int get revision => _revision;

  /// 只加载一次（并发调用共享同一个 Future）。
  static Future<void> ensureLoaded() => _loading ??= _load();

  static Future<void> _load() async {
    try {
      final prefs = await AppPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            final id = '$key'.trim();
            if (id.isEmpty) return;
            final entry = SourceHealthEntry.fromJson(id, value);
            if (entry != null) _entries[id] = entry;
          });
        }
      }
    } catch (_) {
      // 解析失败：当作没有任何标记，不影响播放。
      _loading = null;
    } finally {
      _emit();
    }
  }

  /// 某条音源当前是否带标记。
  static SourceHealthEntry? entryOf(String sourceId) =>
      _entries[sourceId.trim()];

  /// 某个插件下所有带标记的音源（按记录时间倒序，最新的在前）。
  static List<SourceHealthEntry> entriesForPlugin(String pluginId) {
    final result = [
      for (final entry in _entries.values)
        if (entry.pluginId == pluginId) entry,
    ]..sort((a, b) => b.at.compareTo(a.at));
    return result;
  }

  /// 全部标记（调试 / 统计用）。
  static List<SourceHealthEntry> get allEntries =>
      List<SourceHealthEntry>.unmodifiable(_entries.values);

  /// 打标：音源这次请求失败（[status] 区分「报错」与「超时」）。
  ///
  /// 幂等：状态与原因都没变时不写盘、不广播，避免自动换源循环里刷屏。
  static Future<void> markFailed(
    String sourceId, {
    required SourceHealthStatus status,
    String? reason,
  }) async {
    final id = sourceId.trim();
    if (id.isEmpty) return;
    await ensureLoaded();
    final normalized = _normalizeReason(reason);
    final previous = _entries[id];
    if (previous != null &&
        previous.status == status &&
        previous.reason == normalized) {
      // 只更新时间，不打搅界面。
      _entries[id] = previous.copyWith(at: DateTime.now());
      return;
    }
    _entries[id] = SourceHealthEntry(
      sourceId: id,
      status: status,
      reason: normalized,
      at: DateTime.now(),
    );
    await _persist();
    _emit();
  }

  /// 清除一条标记（手动清除 / 测试通过 / 播放成功）。
  ///
  /// 没有标记时是纯 no-op：播放成功路径每次都会调它，不能每次都写盘。
  static Future<void> clear(String sourceId) async {
    final id = sourceId.trim();
    if (id.isEmpty) return;
    await ensureLoaded();
    if (_entries.remove(id) == null) return;
    await _persist();
    _emit();
  }

  /// 清除一个插件下所有标记。
  static Future<void> clearForPlugin(String pluginId) async {
    await ensureLoaded();
    final before = _entries.length;
    _entries.removeWhere((_, entry) => entry.pluginId == pluginId);
    if (_entries.length == before) return;
    await _persist();
    _emit();
  }

  /// 清除全部标记。
  static Future<void> clearAll() async {
    await ensureLoaded();
    if (_entries.isEmpty) return;
    _entries.clear();
    await _persist();
    _emit();
  }

  static Future<void> _persist() async {
    try {
      final prefs = await AppPreferences.getInstance();
      if (_entries.isEmpty) {
        await prefs.remove(_key);
        return;
      }
      await prefs.setString(
        _key,
        jsonEncode({for (final e in _entries.entries) e.key: e.value.toJson()}),
      );
    } catch (_) {
      // 写盘失败只是标记丢了，不能影响播放。
    }
  }

  static String? _normalizeReason(String? reason) {
    final text = (reason ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return null;
    return text.length <= 120 ? text : '${text.substring(0, 120)}…';
  }

  static void _emit() {
    if (_changes.isClosed) return;
    _revision++;
    _changes.add(_revision);
  }
}
