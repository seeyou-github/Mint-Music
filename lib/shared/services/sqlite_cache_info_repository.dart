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

  /// 命中的条目多久续期一次「最后使用时间」。
  ///
  /// 每读一次就写一次太浪费：滚动列表时一屏能命中几十张图。一小时一次足够
  /// 让 30 天窗口按真实使用时间滚动，常用的图不会被误删。
  static const Duration _touchInterval = Duration(hours: 1);

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
    final object = _fromRow(rows.first);
    if (object == null) return null;

    // flutter_cache_manager 只在写入 / 更新时写 touched，读到缓存不会续期。
    // 不在这里续的话，「最后使用时间」永远是下载时间，常用老图也会被淘汰。
    final now = DateTime.now();
    final touched = object.touched;
    if (touched == null || now.difference(touched) >= _touchInterval) {
      try {
        await db.update(
          'cache_index',
          {'touched': now.millisecondsSinceEpoch},
          where: 'id = ?',
          whereArgs: [object.id],
        );
        return CacheObject(
          object.url,
          key: object.key,
          id: object.id,
          relativePath: object.relativePath,
          validTill: object.validTill,
          eTag: object.eTag,
          length: object.length,
          touched: now,
        );
      } catch (_) {
        // 续期失败不影响本次读取。
      }
    }
    return object;
  }

  @override
  Future<CacheObject> insert(
    CacheObject cacheObject, {
    bool setTouchedToNow = true,
  }) async {
    final db = await _database();
    final map = cacheObject.toMap(setTouchedToNow: setTouchedToNow);
    try {
      final id = await db.insert('cache_index', _row(map));
      return _fromDartMap({...map, CacheObject.columnId: id}) ??
          cacheObject.copyWith(id: id);
    } on DatabaseException catch (e) {
      // 同一张封面被多个列表同时请求时，两个协程会同时走到「不存在 → 插入」，
      // 后一个撞上 cache_key 的 UNIQUE 约束。这里改走更新，别把异常丢给
      // flutter_cache_manager —— 它会在每次清理时连着抛几百条。
      if (!e.isUniqueConstraintError()) rethrow;
      final rows = await db.query(
        'cache_index',
        where: 'cache_key = ?',
        whereArgs: [map[CacheObject.columnKey]],
        limit: 1,
      );
      if (rows.isEmpty) rethrow;
      final id = rows.first['id'] as int;
      await db.update(
        'cache_index',
        _row(map),
        where: 'id = ?',
        whereArgs: [id],
      );
      return _fromDartMap({...map, CacheObject.columnId: id}) ??
          cacheObject.copyWith(id: id);
    }
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
    return rows.map(_fromRow).whereType<CacheObject>().toList();
  }

  @override
  Future<List<CacheObject>> getObjectsOverCapacity(int capacity) async {
    final all = await getAllObjects();
    all.sort(
      (c1, c2) =>
          (c1.touched ?? DateTime(0)).compareTo(c2.touched ?? DateTime(0)),
    );
    if (all.length <= capacity) return <CacheObject>[];
    return all.getRange(0, all.length - capacity).toList();
  }

  @override
  Future<List<CacheObject>> getOldObjects(Duration maxAge) async {
    final oldestTimestamp = DateTime.now().subtract(maxAge);
    final all = await getAllObjects();
    return all
        .where(
          (element) =>
              (element.touched ?? DateTime(0)).isBefore(oldestTimestamp),
        )
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

  /// SQLite 行 → CacheObject。
  ///
  /// **注意列名不是 [CacheObject] 的那一套**：库里是 `id` / `cache_key` /
  /// `relative_path`，而 `CacheObject.columnId` 之类的常量是 `_id` / `key` /
  /// `relativePath`（那套是给 `toMap()` 用的）。之前这里直接用常量取行，
  /// 结果 id 恒为 null、relativePath 恒为空串：
  ///   * 清理缓存时 `_removeCachedFile` 里 `cacheObject.id!` 直接崩
  ///     （一次清理能连抛几百条 Null check operator）；
  ///   * 就算不崩，`io.File('')` 也删不掉任何文件，缓存永远清不掉；
  ///   * validTill 恒为 1970，所有缓存都被当成过期，每次启动都全量清理。
  CacheObject? _fromRow(Map<String, dynamic> row) {
    try {
      final id = row['id'] as int?;
      final key = (row['cache_key'] as String?)?.trim() ?? '';
      if (id == null || key.isEmpty) return null;
      return CacheObject(
        (row['url'] as String?) ?? '',
        key: key,
        relativePath: (row['relative_path'] as String?) ?? '',
        validTill: DateTime.fromMillisecondsSinceEpoch(
          (row['valid_till'] as int?) ?? 0,
        ),
        eTag: row['e_tag'] as String?,
        id: id,
        length: row['length'] as int?,
        touched: DateTime.fromMillisecondsSinceEpoch(
          (row['touched'] as int?) ?? 0,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// `CacheObject.toMap()` 的结果（Dart 驼峰键）→ CacheObject。
  CacheObject? _fromDartMap(Map<String, dynamic> map) {
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
          batch.insert('cache_index', {
            'cache_key': '$key',
            'url': map[CacheObject.columnUrl] ?? '',
            'relative_path': map[CacheObject.columnPath] ?? '',
            'e_tag': map[CacheObject.columnETag],
            'valid_till': map[CacheObject.columnValidTill] ?? 0,
            'length': map[CacheObject.columnLength],
            'touched': map[CacheObject.columnTouched] ?? 0,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        await batch.commit(noResult: true);
      }
      await file.delete();
    } catch (_) {
      // 迁移失败就保留旧文件，不影响缓存功能
    }
  }
}
