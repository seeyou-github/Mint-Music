import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../../core/storage/app_preferences.dart';
import '../domain/models/hot_board.dart';

/// 「热榜」选择（榜单 + 前 10 首歌）的本地存储。
class HotBoardStore {
  static const String _key = 'hot_board_v1';

  Future<HotBoard?> load() async {
    try {
      final prefs = await AppPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return HotBoard.fromJson(Map<String, dynamic>.from(decoded));
    } catch (e) {
      debugPrint('[HotBoardStore] 读取热榜失败: $e');
      return null;
    }
  }

  Future<void> save(HotBoard board) async {
    try {
      final prefs = await AppPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(board.toJson()));
    } catch (e) {
      debugPrint('[HotBoardStore] 保存热榜失败: $e');
    }
  }

  Future<void> clear() async {
    try {
      final prefs = await AppPreferences.getInstance();
      await prefs.remove(_key);
    } catch (e) {
      debugPrint('[HotBoardStore] 清除热榜失败: $e');
    }
  }
}
