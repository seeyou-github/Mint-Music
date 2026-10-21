import 'dart:convert';
import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/storage/app_database.dart';

/// 基于 SQLite 的图片缓存索引。
///
/// 之前索引是一个 JSON 文件：每新增 / 淘汰一张图片都要把整个文件重写一遍
/// （最多 800 条、几十 KB），浏览页面时写盘很频繁。放进临时库之后，
/// 每次只写一行，浏览时几乎不产生磁盘写入。
class SqliteCacheInfoRepository extends CacheInfoRepository {
  SqliteCacheInfoRepository({this.legacyJsonPath});

  /// 旧版索引 JSON 文件的路径（首次启动时迁移过来）。
  final String? legacyJsonPath;

  Database? _db;

  Future<Database> _database() async {
    final db = _db;
    if (db != null) return db;
    final appDb = await AppDatabase.instance;
    final database = appDb.cache;
    await database.execute('''
      CREATE TABLE IF NOT EXISTS cache_index (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        cache_key TEXT NOT NULL UNIQUE,
        url TEXT NOT NULL DEFAULT '',
        relative_path TEXT NOT NULL DEFAULT '',
        e_tag TEXT,
        valid_till INTEGER NOT NULL DEFAULT 0,
        length INTEGER,
        touched INTEGER NOT NULL DEFAULT 0
      )
    ''');
    _db = database;
    return database;
  }

  @override
  Future<bool> exists() async {
    try {
      final db = await _database();
      final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM cache_index');
      return ((rows.first['c'] as int?) ?? 0) > 0;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> open() async {
    await _database();
    await _migrateLegacyIndex();
    return true;
  }

  @override
  Future<CacheObject?> get(String key) async {
    final db = await _database();
    final rows = await db.query(
      'cache_index',
      where: 'cache_key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _toObject(rows.first);
  }

  @override
  Future<CacheObject> insert(
    CacheObject cacheObject, {
    bool setTouchedToNow = true,
  }) async {
    final db = await _database();
    final map = cacheObject.toMap(setTouchedToNow: setTouchedToNow);
    final id = await db.insert('cache_index', _row(map));
    return _toObject({...map, CacheObject.columnId: id}) ??
        cacheObject.copyWith(id: id);
  }

  @override
  Future<int> update(
    CacheObject cacheObject, {
    bool setTouchedToNow = true,
  }) async {
    final id = cacheObject.id;
    if (id == null) return 0;
    final db = await _database();
    final map = cacheObject.toMap(setTouchedToNow: setTouchedToNow);
    return db.update(
      'cache_index',
      _row(map),
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<dynamic> updateOrInsert(CacheObject cacheObject) {
    return cacheObject.id == null ? insert(cacheObject) : update(cacheObject);
  }

  @override
  Future<int> delete(int id) async {
    final db = await _database();
    return db.delete('cache_index', where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<int> deleteAll(Iterable<int> ids) async {
    var deleted = 0;
    for (final id in ids) {
      deleted += await delete(id);
    }
    return deleted;
  }

  @override
  Future<List<CacheObject>> getAllObjects() async {
    final db = await _database();
    final rows = await db.query('cache_index');
    return rows.map(_toObject).whereType<CacheObject>().toList();
  }

  @override
  Future<List<CacheObject>> getObjectsOverCapacity(int capacity) async {
    final all = await getAllObjects();
    all.sort((c1, c2) => (c1.touched ?? DateTime(0)).compareTo(c2.touched ?? DateTime(0)));
    if (all.length <= capacity) return <CacheObject>[];
    return all.getRange(0, all.length - capacity).toList();
  }

  @override
  Future<List<CacheObject>> getOldObjects(Duration maxAge) async {
    final oldestTimestamp = DateTime.now().subtract(maxAge);
    final all = await getAllObjects();
    return all
        .where((element) =>
            (element.touched ?? DateTime(0)).isBefore(oldestTimestamp))
        .toList();
  }

  @override
  Future<bool> close() async {
    // 临时库是全局共享的，这里不能真的关闭数据库。
    return false;
  }

  @override
  Future<void> deleteDataFile() async {
    final db = await _database();
    await db.delete('cache_index');
  }

  // ---------------------------------------------------------------- 内部

  Map<String, Object?> _row(Map<String, dynamic> map) {
    return {
      'cache_key': map[CacheObject.columnKey],
      'url': map[CacheObject.columnUrl],
      'relative_path': map[CacheObject.columnPath],
      'e_tag': map[CacheObject.columnETag],
      'valid_till': map[CacheObject.columnValidTill] ?? 0,
      'length': map[CacheObject.columnLength],
      'touched': map[CacheObject.columnTouched] ?? 0,
    };
  }

  CacheObject? _toObject(Map<String, dynamic> map) {
    try {
      return CacheObject(
        (map[CacheObject.columnUrl] as String?) ?? '',
        key: map[CacheObject.columnKey] as String?,
        relativePath: (map[CacheObject.columnPath] as String?) ?? '',
        validTill: DateTime.fromMillisecondsSinceEpoch(
          (map[CacheObject.columnValidTill] as int?) ?? 0,
        ),
        eTag: map[CacheObject.columnETag] as String?,
        id: map[CacheObject.columnId] as int?,
        length: map[CacheObject.columnLength] as int?,
        touched: DateTime.fromMillisecondsSinceEpoch(
          (map[CacheObject.columnTouched] as int?) ?? 0,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// 首次启动：把旧版 JSON 索引导入数据库，之后删掉那个文件。
  Future<void> _migrateLegacyIndex() async {
    final path = legacyJsonPath;
    if (path == null || path.isEmpty) return;
    final file = File(path);
    if (!await file.exists()) return;
    try {
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is List && decoded.isNotEmpty) {
        final db = await _database();
        final batch = db.batch();
        for (final element in decoded) {
          if (element is! Map) continue;
          final map = element.map((k, v) => MapEntry('$k', v));
          final key = map[CacheObject.columnKey] ?? map[CacheObject.columnUrl];
          if (key == null) continue;
          batch.insert(
            'cache_index',
            {
              'cache_key': '$key',
              'url': map[CacheObject.columnUrl] ?? '',
              'relative_path': map[CacheObject.columnPath] ?? '',
              'e_tag': map[CacheObject.columnETag],
              'valid_till': map[CacheObject.columnValidTill] ?? 0,
              'length': map[CacheObject.columnLength],
              'touched': map[CacheObject.columnTouched] ?? 0,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
        await batch.commit(noResult: true);
      }
      await file.delete();
    } catch (_) {
      // 迁移失败就保留旧文件，不影响缓存功能
    }
  }
}
