import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../platform/app_paths.dart';
import 'app_preferences.dart';

/// 应用本地数据库。
///
/// 应用的数据按「重要程度」分成两个库：
///
/// * **重要库**（Windows：`AppData\db\mintmusic.db`）
///   存放 *不能丢* 的数据：我的收藏、收藏歌单。
///   变更后立即落盘（SQLite 事务 + WAL + `synchronous=FULL`），
///   宁可多写几次也不能丢。
///
/// * **临时库**（Windows：`AppData\temp\db\mintmusic_cache.db`）
///   存放 *丢了可以重新生成* 的高频数据：本地歌曲列表、最近播放、下载列表、
///   搜索历史、缓存索引。这些数据变动频繁，统一走「合并延迟写」
///   （见 [DeferredWriter]），尽量减少 SSD 写入次数。
///
/// 其它平台沿用系统目录：重要库放在应用私有数据目录，临时库放在应用缓存目录。
class AppDatabase {
  AppDatabase._(this._important, this._cache);

  final Database _important;
  final Database _cache;

  /// 数据库是否真正落盘。
  ///
  /// false 表示打开失败后降级成了内存库：本次会话数据照常可用，
  /// 但不会跨重启保留（此时也不会删除旧配置文件里的数据）。
  bool get persistent => isPersistent;

  /// 数据库是否落盘（没落盘说明降级成了内存库）。
  static bool get isPersistent => _persistent;
  static bool _persistent = true;

  /// 重要库：我的收藏、收藏歌单。
  Database get important => _important;

  /// 临时库：本地歌曲列表、最近播放、下载列表、搜索历史、缓存索引。
  Database get cache => _cache;

  /// 清除临时库里的「缓存类」数据（歌词、图片缓存索引）。
  ///
  /// 「清除本地缓存」时调用：缓存文件被删了，索引也要一起清掉。
  /// 不影响本地歌曲列表、最近播放、下载列表这些数据。
  static Future<void> clearCacheData() async {
    try {
      final db = await cacheDatabase();
      await db.delete('lyrics');
      await db.delete('cache_index');
    } catch (e) {
      debugPrint('[AppDatabase] 清除缓存数据失败: $e');
    }
  }

  static AppDatabase? _instance;
  static Future<AppDatabase>? _pending;

  /// 打开彻底失败（比如桌面端缺 sqlite3.dll）时记下来，
  /// 避免每次访问数据库都重试一遍（那会非常慢）。
  static Object? _openError;

  /// 获取数据库单例（首次调用会打开 / 创建数据库文件）。
  static Future<AppDatabase> get instance async {
    final cached = _instance;
    if (cached != null) return cached;
    final error = _openError;
    if (error != null) throw error;
    final pending = _pending;
    if (pending != null) return pending;
    final future = _open();
    _pending = future;
    try {
      final created = await future;
      _instance = created;
      return created;
    } catch (e) {
      _openError = e;
      rethrow;
    } finally {
      _pending = null;
    }
  }

  /// 重要库：我的收藏、收藏歌单。
  static Future<Database> importantDatabase() async =>
      (await instance).important;

  /// 临时库：本地歌曲列表、最近播放、下载列表、搜索历史、缓存索引。
  static Future<Database> cacheDatabase() async => (await instance).cache;

  static Future<AppDatabase> _open() async {
    _initFactory();

    try {
      final important = await _openImportant();
      _openedImportant = important;
      final cache = await _openCache();
      _persistent = true;
      return AppDatabase._(important, cache);
    } catch (e) {
      // 打开失败不能让整个应用起不来：降级成内存库，界面照常工作，
      // 只是数据不会跨重启保留。
      debugPrint('[AppDatabase] 打开数据库失败，降级为内存库: $e');
      // 重要库可能已经打开了（只有临时库失败的情况），先关掉，
      // 否则会一直占着文件句柄。
      final opened = _openedImportant;
      _openedImportant = null;
      if (opened != null) {
        try {
          await opened.close();
        } catch (_) {}
      }
      try {
        final important = await _openImportant(inMemory: true);
        final cache = await _openCache(inMemory: true);
        _persistent = false;
        return AppDatabase._(important, cache);
      } catch (e2) {
        debugPrint('[AppDatabase] 内存数据库打开失败: $e2');
        rethrow;
      }
    }
  }

  /// 已经打开的重要库（降级时需要关掉，避免泄漏文件句柄）。
  static Database? _openedImportant;

  /// 桌面端用 FFI 实现（SQLite 走 sqlite3.dll），移动端用官方 sqflite。
  static bool _factoryReady = false;

  static void _initFactory() {
    if (_factoryReady) return;
    _factoryReady = true;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
  }

  static Future<Database> _openImportant({bool inMemory = false}) async {
    final path = inMemory
        ? inMemoryDatabasePath
        : p.join(
            (await AppPaths.databaseDirectory()).path,
            'mintmusic.db',
          );
    return openDatabase(
      path,
      version: 2,
      onConfigure: (db) async {
        // WAL：写入不阻塞读取；synchronous=FULL：断电也不会丢已提交的事务。
        await db.execute('PRAGMA journal_mode=WAL');
        await db.execute('PRAGMA synchronous=FULL');
        await db.execute('PRAGMA foreign_keys=ON');
      },
      onCreate: (db, version) async {
        await _createImportantSchema(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // 建表语句都写成 IF NOT EXISTS，重复执行安全。
        await _createImportantSchema(db);
      },
    );
  }

  /// 重要库的建表语句（幂等）。
  static Future<void> _createImportantSchema(Database db) async {
    await db.execute('''
          CREATE TABLE IF NOT EXISTS playlists (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL DEFAULT '',
            description TEXT NOT NULL DEFAULT '',
            cover_url TEXT NOT NULL DEFAULT '',
            source TEXT NOT NULL DEFAULT 'local',
            create_time INTEGER NOT NULL DEFAULT 0,
            update_time INTEGER NOT NULL DEFAULT 0,
            meta TEXT NOT NULL DEFAULT '{}',
            data TEXT NOT NULL DEFAULT '{}'
          )
        ''');
    await db.execute('''
          CREATE TABLE IF NOT EXISTS playlist_songs (
            playlist_id TEXT NOT NULL,
            song_id TEXT NOT NULL,
            sort_order INTEGER NOT NULL DEFAULT 0,
            added_at INTEGER NOT NULL DEFAULT 0,
            data TEXT NOT NULL DEFAULT '{}',
            PRIMARY KEY (playlist_id, song_id)
          )
        ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_playlist_songs_order '
      'ON playlist_songs (playlist_id, sort_order)',
    );
  }

  static Future<Database> _openCache({bool inMemory = false}) async {
    final path = inMemory
        ? inMemoryDatabasePath
        : p.join(
            (await AppPaths.cacheDatabaseDirectory()).path,
            'mintmusic_cache.db',
          );
    return openDatabase(
      path,
      version: 2,
      onConfigure: (db) async {
        // 临时库不需要绝对安全：NORMAL 足够，少一次 fsync。
        await db.execute('PRAGMA journal_mode=WAL');
        await db.execute('PRAGMA synchronous=NORMAL');
      },
      onCreate: (db, version) async {
        await _createCacheSchema(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // 图片缓存索引只是缓存，直接重建；其余表用 IF NOT EXISTS 补齐。
        await db.execute('DROP TABLE IF EXISTS cache_index');
        await _createCacheSchema(db);
      },
    );
  }

  /// 临时库的建表语句（幂等）。
  static Future<void> _createCacheSchema(Database db) async {
    await db.execute('''
          CREATE TABLE IF NOT EXISTS local_songs (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL DEFAULT '',
            artist TEXT NOT NULL DEFAULT '',
            album TEXT NOT NULL DEFAULT '',
            file_path TEXT NOT NULL DEFAULT '',
            source TEXT NOT NULL DEFAULT 'local',
            updated_at INTEGER NOT NULL DEFAULT 0,
            data TEXT NOT NULL DEFAULT '{}'
          )
        ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_local_songs_artist ON local_songs (artist)',
    );
    await db.execute('''
          CREATE TABLE IF NOT EXISTS local_dirs (
            path TEXT PRIMARY KEY,
            added_at INTEGER NOT NULL DEFAULT 0
          )
        ''');
    await db.execute('''
          CREATE TABLE IF NOT EXISTS recently_played (
            song_id TEXT PRIMARY KEY,
            played_at INTEGER NOT NULL DEFAULT 0,
            play_count INTEGER NOT NULL DEFAULT 1,
            data TEXT NOT NULL DEFAULT '{}'
          )
        ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_recently_played_time '
      'ON recently_played (played_at DESC)',
    );
    await db.execute('''
          CREATE TABLE IF NOT EXISTS download_tasks (
            id TEXT PRIMARY KEY,
            status TEXT NOT NULL DEFAULT '',
            file_path TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL DEFAULT 0,
            data TEXT NOT NULL DEFAULT '{}'
          )
        ''');
    await db.execute('''
          CREATE TABLE IF NOT EXISTS search_history (
            keyword TEXT PRIMARY KEY,
            searched_at INTEGER NOT NULL DEFAULT 0
          )
        ''');
    await db.execute('''
          CREATE TABLE IF NOT EXISTS lyrics (
            cache_key TEXT PRIMARY KEY,
            lrc TEXT,
            crlyric TEXT,
            tlyric TEXT,
            rlyric TEXT,
            ttml TEXT,
            updated_at INTEGER NOT NULL DEFAULT 0
          )
        ''');
    await db.execute('''
          CREATE TABLE IF NOT EXISTS playback_state (
            key TEXT PRIMARY KEY,
            data TEXT NOT NULL DEFAULT '{}',
            updated_at INTEGER NOT NULL DEFAULT 0
          )
        ''');
    await db.execute('''
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
  }

  // ---------------------------------------------------------------- 迁移标记

  static const String _migrationPrefix = 'db_migrated_';

  /// 所有已注册的延迟写盘器。
  static final List<DeferredWriter> _writers = [];

  /// 注册一个延迟写盘器（应用切后台 / 退出时统一 flush）。
  static void registerWriter(DeferredWriter writer) {
    if (!_writers.contains(writer)) {
      _writers.add(writer);
    }
  }

  /// 把所有延迟写盘器的内容立即落盘。
  ///
  /// 在应用切后台 / 退出前调用，保证高频数据不会因为进程被杀而丢失。
  static Future<void> flushAll() async {
    for (final writer in List<DeferredWriter>.of(_writers)) {
      try {
        await writer.flush();
      } catch (e) {
        debugPrint('[AppDatabase] flush 失败: $e');
      }
    }
  }

  /// 某个模块是否已经从旧的配置文件迁移过来。
  static Future<bool> isMigrated(String module) async {
    try {
      final prefs = await AppPreferences.getInstance();
      return prefs.getBool('$_migrationPrefix$module') ?? false;
    } catch (e) {
      debugPrint('[AppDatabase] 读取迁移标记失败: $e');
      return false; // 读不到就当作没迁移，迁移是幂等的，重复执行没有副作用
    }
  }

  /// 标记某个模块已完成迁移（只写一次）。
  static Future<void> markMigrated(String module) async {
    try {
      final prefs = await AppPreferences.getInstance();
      await prefs.setBool('$_migrationPrefix$module', true);
    } catch (e) {
      debugPrint('[AppDatabase] 写入迁移标记失败: $e');
    }
  }

  /// 迁移完成后删掉旧设置文件里的键。
  ///
  /// 降级模式（数据库没落盘）下不删，避免旧数据被清掉后无法恢复。
  static Future<void> removeLegacyKey(String key) async {
    if (!_persistent) return;
    try {
      final prefs = await AppPreferences.getInstance();
      await prefs.remove(key);
    } catch (e) {
      debugPrint('[AppDatabase] 删除旧键失败: $e');
    }
  }

  // ---------------------------------------------------------------- 小工具

  /// 把数据库里存的一段 JSON 文本解析成 Map。
  static Map<String, dynamic> decodeMap(Object? raw) {
    if (raw is Map) {
      return raw.map((k, v) => MapEntry('$k', v));
    }
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return decoded.map((k, v) => MapEntry('$k', v));
        }
      } catch (_) {
        // 数据损坏时按空处理
      }
    }
    return <String, dynamic>{};
  }
}

/// 延迟写盘调度器。
///
/// 高频数据（本地歌曲列表、最近播放、下载列表、搜索历史）用它把连续多次的
/// 变更合并成一次落盘：先在内存里改，等一段时间（或应用切后台 / 退出）再
/// 统一写进数据库，避免每次改动都写一次硬盘。
class DeferredWriter {
  DeferredWriter(this._write, {this.interval = const Duration(seconds: 8)});

  final Future<void> Function() _write;

  /// 合并窗口：这段时间内的多次变更会合并成一次写入。
  final Duration interval;

  Timer? _timer;
  bool _dirty = false;

  /// 正在进行的写入（用于让并发的 flush 等待同一次写入）。
  Future<void>? _inFlight;

  /// 标记数据已变化，安排一次落盘。
  void schedule() {
    _dirty = true;
    _timer ??= Timer(interval, () {
      unawaited(flush());
    });
  }

  /// 立即把当前数据写盘（不管之前有没有排期）。
  Future<void> writeNow() async {
    _dirty = true;
    await flush();
  }

  /// 立即落盘（应用切后台 / 退出、下载完成等时机调用）。
  ///
  /// 如果已经有一次写入在进行，会等它结束（写入过程中产生的新变更会被
  /// 那次写入一起带上去）。
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;

    final inFlight = _inFlight;
    if (inFlight != null) {
      await inFlight;
      if (!_dirty) return;
    }
    if (!_dirty) return;

    _dirty = false;
    final future = _doWrite();
    _inFlight = future;
    try {
      await future;
    } finally {
      if (identical(_inFlight, future)) _inFlight = null;
    }
  }

  Future<void> _doWrite() async {
    // 写入过程中如果又有了新变更，就再写一轮。
    while (_dirty) {
      _dirty = false;
      try {
        await _write();
      } catch (e) {
        // 写失败不重试（避免一直失败时无限循环），数据还在内存里，
        // 下一次变更会重新写。
        debugPrint('[DeferredWriter] 落盘失败: $e');
        _dirty = false;
      }
    }
  }
}
