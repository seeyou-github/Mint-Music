import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../../core/storage/app_database.dart';
import '../../../../core/storage/app_preferences.dart';
import '../domain/models/hot_board.dart';

/// 「热榜」配置的本地存储：**只记「哪个音源加了哪个榜单」**。
///
/// 落盘位置就是 `settings.json` 里的 [prefsKey] 键，每条只有音源、榜单 id、
/// 名称、封面。榜单里的歌曲**不保存**——每次进入「榜单 → 热榜」都重新从插件
/// 取一遍，只留在内存里（见 `HotBoardsNotifier.refreshSongs`）。
///
/// ## 为什么不再连歌曲一起存
///
/// 每个榜单带 10 首完整歌曲，5 个音源、15 个榜单就是 150 首歌、100KB 以上
/// （其中大半是插件的原始元数据）。这些数据随时能从网络重取，存下来只会让
/// 每次改设置都把整份 settings.json 重写一遍，还要额外维护一张临时库表。
///
/// ## 旧数据迁移
///
/// 老版本先把它放在设置的 `hot_boards_v2` / `hot_board_v1` 键里，后来搬进临时
/// 库的 `hot_boards` 表。首次读取时（设置里还没有 [prefsKey]）会把这两处旧数据
/// 转成配置写进 settings.json，然后删掉旧键、删掉旧表（歌曲直接丢弃，进页面会
/// 重新拉取）。
class HotBoardStore {
  /// settings.json 里存热榜配置的键。
  static const String prefsKey = 'hot_boards_v3';

  /// 旧版本的设置键（多榜单）：只用于迁移。
  static const String _legacyKey = 'hot_boards_v2';

  /// 更早版本的单榜单设置键：只用于迁移。
  static const String _legacySingleKey = 'hot_board_v1';

  /// 更早版本的「有热榜的音源」标志位：现在直接从配置里算，删掉即可。
  static const String _legacySourcesKey = 'hot_board_sources_v1';

  /// 旧版本的临时库表名：只用于迁移。
  static const String _legacyTable = 'hot_boards';

  /// 读取全部榜单配置。
  ///
  /// 首次读取（设置里还没有 [prefsKey]）时会先把老数据迁移过来。
  Future<List<HotBoard>> load() async {
    final prefs = await AppPreferences.getInstance();
    if (prefs.getString(prefsKey) == null) {
      await _migrateLegacyTable(prefs);
      await _migrateLegacyKeys(prefs);
      // 迁移没搬出任何东西时也写一个空列表做标记，下次不再重复查旧表。
      if (prefs.getString(prefsKey) == null) {
        await prefs.setString(prefsKey, '[]');
      }
    }
    return decodeConfigs(prefs.getString(prefsKey));
  }

  /// 同步读取全部榜单配置（只读 settings.json 内存副本，不触发迁移）。
  ///
  /// 启动后 [load] 已经跑过一次，这里给「切换音源时同步判断有没有热榜」用。
  List<HotBoard> loadSync() {
    final prefs = AppPreferences.maybeInstance;
    if (prefs == null) return const [];
    return decodeConfigs(prefs.getString(prefsKey));
  }

  /// 覆盖写入全部榜单配置（新增 / 删除 / 排序后调用）。
  Future<void> save(List<HotBoard> boards) async {
    try {
      final prefs = await AppPreferences.getInstance();
      await prefs.setString(prefsKey, encodeConfigs(boards));
    } catch (e) {
      debugPrint('[HotBoardStore] 保存热榜配置失败: $e');
    }
  }

  Future<void> clear() async {
    try {
      final prefs = await AppPreferences.getInstance();
      await prefs.remove(prefsKey);
      await prefs.remove(_legacyKey);
      await prefs.remove(_legacySingleKey);
      await prefs.remove(_legacySourcesKey);
    } catch (e) {
      debugPrint('[HotBoardStore] 清除热榜配置失败: $e');
    }
  }

  /// 「哪些音源有用户添加的热榜」（音源 id 集合），同步可读。
  Set<String> loadSourceIdsSync() => {
    for (final board in loadSync())
      if (board.source.isNotEmpty) board.source,
  };

  /// 用一份 JSON 覆盖全部榜单（还原老备份的 `hotboards.json` 用）。
  ///
  /// 老备份里带着歌曲，这里只取配置，歌曲仍然等进页面时实时拉取。
  Future<void> importJson(String raw) async {
    final boards = decode(raw);
    await save(boards);
  }

  static String encodeConfigs(List<HotBoard> boards) =>
      jsonEncode([for (final board in boards) board.toConfigJson()]);

  static List<HotBoard> decodeConfigs(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (item is Map)
            HotBoard.fromConfigJson(Map<String, dynamic>.from(item)),
      ]..removeWhere((board) => board.id.isEmpty && board.source.isEmpty);
    } catch (e) {
      debugPrint('[HotBoardStore] 解析热榜配置失败: $e');
      return const [];
    }
  }

  /// 解析老数据（可能带 `songs`），只保留配置。
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

  /// 把临时库 `hot_boards` 表里的榜单配置搬进 settings.json，然后删表。
  ///
  /// 表里每行都带整份 `data`（含 10 首歌），这里只取配置字段；歌曲不保留，
  /// 用户进「热榜」时会重新拉。表在旧版本里只是缓存，删除不影响任何文件。
  static Future<void> _migrateLegacyTable(AppPreferences prefs) async {
    try {
      final db = await AppDatabase.cacheDatabase();
      final rows = await db.query(
        _legacyTable,
        orderBy: 'sort_order ASC, id ASC',
      );
      final boards = <HotBoard>[];
      for (final row in rows) {
        final data = AppDatabase.decodeMap(row['data']);
        if (data.isEmpty) continue;
        final board = HotBoard.fromConfigJson(data);
        if (board.id.isEmpty && board.source.isEmpty) continue;
        boards.add(
          HotBoard(
            id: board.id.isNotEmpty ? board.id : '${row['id'] ?? ''}',
            name: board.name.isNotEmpty ? board.name : '${row['name'] ?? ''}',
            source: board.source.isNotEmpty
                ? board.source
                : '${row['source'] ?? ''}',
            coverUrl: board.coverUrl,
          ),
        );
      }
      if (boards.isNotEmpty) {
        await prefs.setString(prefsKey, encodeConfigs(boards));
        debugPrint(
          '[HotBoardStore] 已把 ${boards.length} 个热榜配置迁移到 settings.json',
        );
      }
      await db.execute('DROP TABLE IF EXISTS $_legacyTable');
    } catch (e) {
      // 表不存在（全新安装 / 缓存库被清过）时会走到这里，属正常情况。
      debugPrint('[HotBoardStore] 旧热榜表迁移跳过: $e');
    }
  }

  /// 把更早版本存在设置里的热榜搬成配置，然后删掉旧键。
  static Future<void> _migrateLegacyKeys(AppPreferences prefs) async {
    try {
      final legacy = prefs.getString(_legacyKey);
      final single = prefs.getString(_legacySingleKey);
      if (legacy == null && single == null) {
        await prefs.remove(_legacySourcesKey);
        return;
      }
      final boards = <HotBoard>[];
      if (legacy != null) {
        boards.addAll(decode(legacy));
      } else if (single != null && single.trim().isNotEmpty) {
        final decoded = jsonDecode(single);
        if (decoded is Map) {
          boards.add(HotBoard.fromJson(Map<String, dynamic>.from(decoded)));
        }
      }
      // 旧表（上一版的位置）如果已经搬出了配置，以它为准：这几处同时存在
      // 只可能是一条从很老版本一路升级过来的链，表里的数据更新。
      if (boards.isNotEmpty && prefs.getString(prefsKey) == null) {
        await prefs.setString(prefsKey, encodeConfigs(boards));
        debugPrint('[HotBoardStore] 已把设置里的热榜迁移成配置');
      }
      await prefs.remove(_legacyKey);
      await prefs.remove(_legacySingleKey);
      await prefs.remove(_legacySourcesKey);
    } catch (e) {
      debugPrint('[HotBoardStore] 迁移旧热榜设置失败: $e');
    }
  }
}
