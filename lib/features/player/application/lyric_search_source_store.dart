import '../../../core/storage/app_preferences.dart';

/// 搜索歌词 / 编辑标签-在线搜索的「上次使用的音源」。
///
/// 两处共用同一个偏好：在任意一处的音源切换按钮里选过的音源，下次打开时
/// 优先用它（其次跟随当前歌曲 / 当前音源）。退出页面时保存；与设置文件里
/// 已存的值相同则不写——设置写盘会触发自动备份链路，无谓的写入要避免。
class LyricSearchSourceStore {
  LyricSearchSourceStore._();

  static const String _key = 'lyric_search_source_id_v1';

  /// 上次使用的音源 id；没存过返回 null。
  static Future<String?> load() async {
    try {
      final prefs = await AppPreferences.getInstance();
      final value = prefs.getString(_key) ?? '';
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  /// 保存；与已存值相同则不写盘。
  static Future<void> save(String sourceId) async {
    final value = sourceId.trim();
    if (value.isEmpty) return;
    try {
      final prefs = await AppPreferences.getInstance();
      if ((prefs.getString(_key) ?? '') == value) return;
      await prefs.setString(_key, value);
    } catch (_) {}
  }
}
