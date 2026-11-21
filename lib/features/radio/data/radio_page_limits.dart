import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/storage/app_preferences.dart';

/// 空页之后下一个要试的页：直接回落到第 1 页。
///
/// 以前是「−5 / −1」线性回缩：随机到第 41 页、空了就 36、31…一路试到 1，
/// 一次抖动要发 9 条请求（实测 13 秒内 13 次失败，把 JS 引擎占满，同时
/// 切歌 / 歌词全部排队）。但这里是「插件返回空」而不是「服务端说没有这一
/// 页」，逐页试探没有任何信息量——第 1 页必然是最可能有数据的一页，直接
/// 跳过去即可，最多两次请求就能判断这一轮有没有歌单。
int nextPageAfterEmpty(int page) => page > 1 ? 1 : 0;

/// 电台随机页的「最大页数」记忆。
///
/// 分类 / 关键词翻页接口没有「总页数」可查，只能试：随机到某页返回空就回落
/// 到第 1 页，把「已知有数据的最大页」记下来（按「音源 + 分类 / 音源 + 关键词」
/// 区分），下次直接在这个范围内随机，少发空请求。
///
/// 存在设置文件里，重启后依然有效。
///
/// 上限的基本语义是「已知有数据的最大页」，只减不增；但**一次观测不作数**
/// （见 [record]）。
///
/// v2：v1 的取值是靠逐页回缩学出来的，出现过「一次抖动把上限记成 1」的
/// 脏数据，直接换 key 丢弃，重新学习。
class RadioPageLimits {
  const RadioPageLimits._();

  static const String _prefKey = 'radio_page_limits_v2';

  /// 还没记录过时的随机上限。
  static const int defaultMaxPage = 50;

  static Map<String, int> _limits = <String, int>{};

  /// 已观测到一次、等待第二次确认的收缩目标（见 [record]）。
  static final Map<String, int> _pending = <String, int>{};

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
  ///
  /// **同一档位要连续两次观测到才落盘**：插件「返回空」既可能是页码真的超
  /// 范围，也可能只是一次抖动 / 限流。以前一次就写盘且只减不增，一次抖动
  /// 就把某个关键词的上限永久压死（日志里 `华语 经典` 被压到第 1 页，之后
  /// 永远只翻第一页）。现在第一次只记进内存的 pending，第二次仍是同一档位
  /// 才认为「这页确实没有数据」。
  static Future<void> record(String key, int page) async {
    if (page <= 0) return;
    final current = _limits[key];
    if (current != null && current <= page) return;
    if (_pending[key] != page) {
      _pending[key] = page;
      return;
    }
    _pending.remove(key);
    _limits[key] = page;
    try {
      final prefs = await AppPreferences.getInstance();
      await prefs.setString(_prefKey, jsonEncode(_limits));
    } catch (e) {
      debugPrint('[RadioPageLimits] 保存失败: $e');
    }
  }
}
