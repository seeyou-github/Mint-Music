import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/storage/app_preferences.dart';

/// 空页之后下一个要试的页：
/// 先往前缩 5 页，缩到 5 页以内后每次缩 1 页。
int nextPageAfterEmpty(int page) => page > 5 ? page - 5 : page - 1;

/// 电台随机页的「最大页数」记忆。
///
/// 分类 / 关键词翻页接口没有「总页数」可查，只能试：随机到某页返回空就往前缩，
/// 缩到有数据的那一页说明真实页数不超过它。把这个上限记下来（按
/// 「音源 + 分类 / 音源 + 关键词」区分），下次直接在这个范围内随机，
/// 少发一堆空请求。
///
/// 存在设置文件里，重启后依然有效；上限只减不增。
class RadioPageLimits {
  const RadioPageLimits._();

  static const String _prefKey = 'radio_page_limits_v1';

  /// 还没记录过时的随机上限。
  static const int defaultMaxPage = 50;

  static Map<String, int> _limits = <String, int>{};
  static bool _loaded = false;
  static Future<void>? _loading;

  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    final pending = _loading;
    if (pending != null) return pending;
    final future = _load();
    _loading = future;
    try {
      await future;
    } finally {
      _loading = null;
    }
  }

  static Future<void> _load() async {
    try {
      final prefs = await AppPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw != null && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final limits = <String, int>{};
          decoded.forEach((key, value) {
            final page = value is num ? value.toInt() : int.tryParse('$value');
            if (page != null && page > 0) limits['$key'] = page;
          });
          _limits = limits;
        }
      }
    } catch (e) {
      debugPrint('[RadioPageLimits] 读取失败: $e');
    } finally {
      _loaded = true;
    }
  }

  /// 当前已知的最大页数（没记录过就是 [defaultMaxPage]）。
  static int limitFor(String key) {
    final value = _limits[key];
    if (value == null || value <= 0) return defaultMaxPage;
    return value > defaultMaxPage ? defaultMaxPage : value;
  }

  /// 记录一个更小的上限（只减不增），并异步落盘。
  static Future<void> record(String key, int page) async {
    if (page <= 0) return;
    final current = _limits[key];
    if (current != null && current <= page) return;
    _limits[key] = page;
    try {
      final prefs = await AppPreferences.getInstance();
      await prefs.setString(_prefKey, jsonEncode(_limits));
    } catch (e) {
      debugPrint('[RadioPageLimits] 保存失败: $e');
    }
  }
}
