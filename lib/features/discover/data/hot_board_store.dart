import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../../../core/storage/app_database.dart';
import '../../../../core/storage/app_preferences.dart';
import '../domain/models/hot_board.dart';

/// 「热榜」数据（多个榜单 + 各自前 10 首歌）的本地存储。
///
/// 所有音源的榜单都保存在一起，展示时按当前音源过滤；这样切换音源时
/// 各音源添加过的热榜都不会丢。
///
/// ## 为什么放临时库而不是设置文件
///
/// 每个榜单带 10 首完整歌曲，5 个音源、15 个榜单就是 150 首歌、100KB 以上
/// （其中大半是插件的原始元数据）。旧版本把它塞进 `settings.json` 的
/// `hot_boards_v2` 键，占了设置文件的 96% —— 后果是每次改任何设置（哪怕只是
/// 切深色模式）都要把整份 180KB 设置重写一遍、再留一份同样大的 `.bak`。
///
/// 热榜对「设置」没有任何意义，且丢了能从插件重新添加，所以搬进临时库的
/// `hot_boards` 表（见 `AppDatabase`）。
///
/// 旧数据（`hot_boards_v2` / `hot_board_v1`）在首次读取时自动迁移进表并删掉
/// 旧键；备份包里仍然会带一份（`hotboards.json`），换设备还原后榜单还在。
class HotBoardStore {
  /// 旧版本的设置键（多榜单）：只用于迁移。
  static const String _legacyKey = 'hot_boards_v2';

  /// 更早版本的单榜单设置键：只用于迁移。
  static const String _legacySingleKey = 'hot_board_v1';

  /// 「哪些音源有用户新增的热榜」标志位：只存音源 id。
  ///
  /// 单独存一份而不是每次去数热榜数据，是为了切换音源时能**同步**判断：
  /// 榜单默认分类只依赖它，不用等整份热榜（里面带着所有歌曲）解析完，
  /// 也就不会出现「切过去先判成所有、数据回来又不纠正」。
  ///
  /// 它很小（几十字节），且必须同步可读，所以仍留在设置里。
  static const String _sourcesKey = 'hot_board_sources_v1';

  Future<List<HotBoard>> load() async {
    try {
      final db = await AppDatabase.cacheDatabase();
      await _migrateLegacy(db);
      final rows = await db.query(
        'hot_boards',
        orderBy: 'sort_order ASC, id ASC',
      );
      final boards = <HotBoard>[];
      for (final row in rows) {
        final data = AppDatabase.decodeMap(row['data']);
        if (data.isEmpty) continue;
        final board = HotBoard.fromJson(data);
        if (board.id.isEmpty && board.source.isEmpty) continue;
        boards.add(board);
      }
      return boards;
    } catch (e) {
      debugPrint('[HotBoardStore] 读取热榜失败: $e');
      return const [];
    }
  }

  Future<void> save(List<HotBoard> boards) async {
    try {
      final db = await AppDatabase.cacheDatabase();
      await _writeBoards(db, boards);
      // 热榜是用户主动挑的内容（加一次不容易），写完立刻 checkpoint，
      // 别让「刚加完榜单就关窗 / 断电」把 WAL 里的这行丢掉。
      await AppDatabase.checkpoint();
    } catch (e) {
      debugPrint('[HotBoardStore] 保存热榜失败: $e');
    }
  }

  Future<void> clear() async {
    try {
      final db = await AppDatabase.cacheDatabase();
      await db.delete('hot_boards');
      await AppDatabase.checkpoint();
      final prefs = await AppPreferences.getInstance();
      await prefs.remove(_legacyKey);
      await prefs.remove(_legacySingleKey);
      await prefs.remove(_sourcesKey);
    } catch (e) {
      debugPrint('[HotBoardStore] 清除热榜失败: $e');
    }
  }

  /// 把全部榜单编码成一份 JSON（备份包用）。
  Future<String> exportJson() async {
    final boards = await load();
    return encode(boards);
  }

  /// 用一份 JSON 覆盖全部榜单（还原备份用）；解析失败时保持原样。
  Future<void> importJson(String raw) async {
    final boards = decode(raw);
    await save(boards);
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

  /// 覆盖写入整张表（写入顺序即列表顺序）。
  static Future<void> _writeBoards(
    Database db,
    List<HotBoard> boards,
  ) async {
    await db.transaction((txn) async {
      await txn.delete('hot_boards');
      final batch = txn.batch();
      for (var i = 0; i < boards.length; i++) {
        final board = boards[i];
        batch.insert('hot_boards', {
          'id': board.id,
          'source': board.source,
          'name': board.name,
          'cover_url': board.coverUrl ?? '',
          'sort_order': i,
          'data': jsonEncode(board.toJson()),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  /// 把旧版本存在设置里的热榜搬进表，然后删掉旧键。
  ///
  /// 表里已有数据时也照样覆盖：这只会发生在「还原了老备份」的场景——
  /// 老备份的设置文件里带着 `hot_boards_v2`，语义上就该以备份为准。
  static Future<void> _migrateLegacy(Database db) async {
    final prefs = AppPreferences.maybeInstance;
    if (prefs == null) return;
    final legacy = prefs.getString(_legacyKey);
    final single = prefs.getString(_legacySingleKey);
    if (legacy == null && single == null) return;

    final boards = <HotBoard>[];
    if (legacy != null) {
      boards.addAll(decode(legacy));
    } else if (single != null && single.trim().isNotEmpty) {
      final decoded = jsonDecode(single);
      if (decoded is Map) {
        boards.add(HotBoard.fromJson(Map<String, dynamic>.from(decoded)));
      }
    }

    await _writeBoards(db, boards);
    // 只有真正落盘的库才删旧键：内存降级库里删了就等于把数据彻底丢掉。
    if (AppDatabase.isPersistent) {
      await prefs.remove(_legacyKey);
      await prefs.remove(_legacySingleKey);
      debugPrint('[HotBoardStore] 已把设置里的热榜迁移进临时库');
    }
  }
}
