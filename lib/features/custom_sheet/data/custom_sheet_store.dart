import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../../core/storage/app_preferences.dart';
import '../domain/models/custom_sheet.dart';

/// 自定义歌单（分类 + 歌单）的本地存储。
class CustomSheetStore {
  static const String _key = 'custom_sheets_v1';

  Future<CustomSheetData> load() async {
    try {
      final prefs = await AppPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.trim().isEmpty) return const CustomSheetData();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const CustomSheetData();
      return CustomSheetData.fromJson(Map<String, dynamic>.from(decoded));
    } catch (e) {
      debugPrint('[CustomSheetStore] 读取自定义歌单失败: $e');
      return const CustomSheetData();
    }
  }

  Future<void> save(CustomSheetData data) async {
    try {
      final prefs = await AppPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(data.toJson()));
    } catch (e) {
      debugPrint('[CustomSheetStore] 保存自定义歌单失败: $e');
    }
  }
}
