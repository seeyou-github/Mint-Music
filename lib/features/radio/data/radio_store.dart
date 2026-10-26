import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../../core/storage/app_preferences.dart';
import '../domain/models/radio_station.dart';

/// 电台（分类 + 电台配置）的本地存储。
class RadioStore {
  static const String _key = 'radio_v1';

  Future<RadioData> load() async {
    try {
      final prefs = await AppPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.trim().isEmpty) return const RadioData();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const RadioData();
      return RadioData.fromJson(Map<String, dynamic>.from(decoded));
    } catch (e) {
      debugPrint('[RadioStore] 读取电台失败: $e');
      return const RadioData();
    }
  }

  Future<void> save(RadioData data) async {
    try {
      final prefs = await AppPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(data.toJson()));
    } catch (e) {
      debugPrint('[RadioStore] 保存电台失败: $e');
    }
  }
}
