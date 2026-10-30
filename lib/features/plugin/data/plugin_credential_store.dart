import 'dart:convert';

import '../../../core/storage/app_preferences.dart';

/// 插件凭据（cookie / api key / 卡密）的本地存储。
///
/// ## 为什么要单独一个类
///
/// 凭据要在两个地方用：插件加载时注入 JS 运行时（[PluginService]），以及
/// 插件管理页里让用户填写（UI）。它不属于插件元数据，也不该混进
/// `installed_plugins`（那份 JSON 会被频繁重写，容易意外丢字段）。
///
/// ## 存储格式
///
/// 单个 key `plugin_credentials`，值为 JSON：
/// ```json
/// { "1a2b3c": { "MUSIC_U": "xxxx" }, "4d5e6f": { "ikun_key": "yyyy" } }
/// ```
///
/// ## 安全说明（已与用户确认）
///
/// 凭据**会随备份文件一起导出**（WebDAV / 本地备份），因此备份文件里是明文
/// cookie。UI 上必须固定提示「凭据会包含在备份文件中，请勿分享备份」；
/// 任何日志都不能打印凭据的值。
class PluginCredentialStore {
  static const String _key = 'plugin_credentials';

  /// 读取某个插件的全部凭据；没填过返回空 Map（绝不返回 null）。
  static Future<Map<String, String>> load(String pluginId) async {
    final all = await loadAll();
    return all[pluginId] ?? const {};
  }

  /// 读取所有插件的凭据，解析失败时返回空 Map（旧数据 / 手工改坏都不崩）。
  static Future<Map<String, Map<String, String>>> loadAll() async {
    try {
      final prefs = await AppPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.trim().isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final result = <String, Map<String, String>>{};
      decoded.forEach((key, value) {
        if (value is! Map) return;
        final values = <String, String>{};
        value.forEach((k, v) {
          if (v == null) return;
          final text = '$v';
          if (text.isEmpty) return;
          values['$k'] = text;
        });
        if (values.isNotEmpty) result['$key'] = values;
      });
      return result;
    } catch (_) {
      return {};
    }
  }

  /// 保存某个插件的凭据。
  ///
  /// 传空 Map 等价于清空该插件的凭据（不会留下空对象）。
  static Future<void> save(String pluginId, Map<String, String> values) async {
    if (values.isEmpty) {
      await remove(pluginId);
      return;
    }
    try {
      final prefs = await AppPreferences.getInstance();
      final all = await loadAll();
      all[pluginId] = Map<String, String>.from(values);
      await prefs.setString(_key, jsonEncode(all));
    } catch (_) {
      // 存储失败不应该让保存流程崩掉：用户会看到「未保存」的提示。
    }
  }

  /// 删除某个插件的凭据（卸载插件时调用）。
  static Future<void> remove(String pluginId) async {
    try {
      final prefs = await AppPreferences.getInstance();
      final all = await loadAll();
      if (!all.containsKey(pluginId)) return;
      all.remove(pluginId);
      await prefs.setString(_key, jsonEncode(all));
    } catch (_) {}
  }
}
