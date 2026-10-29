import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../../core/storage/app_preferences.dart';
import '../domain/models/hot_board.dart';

/// 「热榜」数据（多个榜单 + 各自前 10 首歌）的本地存储。
///
/// 所有音源的榜单都保存在一起，展示时按当前音源过滤；这样切换音源时
/// 各音源添加过的热榜都不会丢。
class HotBoardStore {
  static const String _key = 'hot_boards_v2';
  static const String _legacyKey = 'hot_board_v1';

  /// 「哪些音源有用户新增的热榜」标志位：只存音源 id。
  ///
  /// 单独存一份而不是每次去数热榜数据，是为了切换音源时能**同步**判断：
  /// 榜单默认分类只依赖它，不用等整份热榜（里面带着所有歌曲）解析完，
  /// 也就不会出现「切过去先判成所有、数据回来又不纠正」。
  static const String _sourcesKey = 'hot_board_sources_v1';

  Future<List<HotBoard>> load() async {
    try {
      final prefs = await AppPreferences.getInstance();
      final raw = prefs.getString(_key);
      // 已经保存过多榜单（哪怕是空列表）就不再读旧版单榜单，
      // 否则把热榜全部移除后旧榜单会被重新迁移出来。
      if (raw != null) return decode(raw);

      final legacy = prefs.getString(_legacyKey);
      if (legacy == null || legacy.trim().isEmpty) return const [];
      final board = _decodeSingle(legacy);
      return board == null ? const [] : [board];
    } catch (e) {
      debugPrint('[HotBoardStore] 读取热榜失败: $e');
      return const [];
    }
  }

  Future<void> save(List<HotBoard> boards) async {
    try {
      final prefs = await AppPreferences.getInstance();
      await prefs.setString(_key, encode(boards));
    } catch (e) {
      debugPrint('[HotBoardStore] 保存热榜失败: $e');
    }
  }

  Future<void> clear() async {
    try {
      final prefs = await AppPreferences.getInstance();
      await prefs.remove(_key);
      await prefs.remove(_legacyKey);
      await prefs.remove(_sourcesKey);
    } catch (e) {
      debugPrint('[HotBoardStore] 清除热榜失败: $e');
    }
  }

  /// 同步读「有热榜的音源」标志位。
  ///
  /// 返回 null 表示还没记录过（首次启动 / 从老版本升级上来），调用方需要
  /// 按已有榜单数据补写一次；空集合表示确实一个音源都没有热榜。
  Set<String>? loadSourceIdsSync() {
    final prefs = AppPreferences.maybeInstance;
    if (prefs == null) return null;
    return prefs.getStringList(_sourcesKey)?.toSet();
  }

  Future<void> saveSourceIds(Set<String> sourceIds) async {
    try {
      final prefs = await AppPreferences.getInstance();
      await prefs.setStringList(_sourcesKey, sourceIds.toList()..sort());
    } catch (e) {
      debugPrint('[HotBoardStore] 保存热榜标志位失败: $e');
    }
  }

  static String encode(List<HotBoard> boards) =>
      jsonEncode([for (final board in boards) board.toJson()]);

  static List<HotBoard> decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (item is Map) HotBoard.fromJson(Map<String, dynamic>.from(item)),
      ];
    } catch (e) {
      debugPrint('[HotBoardStore] 解析热榜失败: $e');
      return const [];
    }
  }

  static HotBoard? _decodeSingle(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return HotBoard.fromJson(Map<String, dynamic>.from(decoded));
    } catch (e) {
      debugPrint('[HotBoardStore] 解析旧版热榜失败: $e');
      return null;
    }
  }
}
