import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../../core/storage/app_preferences.dart';
import '../domain/models/blacklist_data.dart';

export '../domain/models/blacklist_data.dart';

/// 黑名单的本地存储（设置文件里的一个 JSON 字段）。
class BlacklistStore {
  static const String _key = 'blacklist_v1';

  Future<BlacklistData> load() async {
    try {
      final prefs = await AppPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.trim().isEmpty) return const BlacklistData();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const BlacklistData();
      return BlacklistData.fromJson(Map<String, dynamic>.from(decoded));
    } catch (e) {
      debugPrint('[BlacklistStore] 读取黑名单失败: $e');
      return const BlacklistData();
    }
  }

  Future<void> save(BlacklistData data) async {
    try {
      final prefs = await AppPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(data.toJson()));
    } catch (e) {
      debugPrint('[BlacklistStore] 保存黑名单失败: $e');
    }
  }
}
