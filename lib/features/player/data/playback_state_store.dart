import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../../core/storage/app_database.dart';
import '../../../core/storage/app_preferences.dart';

/// 播放状态（当前歌曲 + 进度 + 播放队列）的持久化。
///
/// 播放中每 5 秒就会保存一次，属于高频写入，因此：
///
/// * 放在**临时库**（丢了只是不恢复播放进度，不影响任何重要数据）；
/// * 拆成两行写：
///   - `current`：当前歌曲 + 进度（几百字节，每次都写）；
///   - `queue`：完整队列（几十 KB，**只在队列变化时**才写）。
///   这样高频保存只动那一行小数据，不会每次重写整个队列。
class PlaybackStateStore {
  PlaybackStateStore() {
    AppDatabase.registerWriter(_writer);
  }

  /// 当前歌曲 + 进度。
  static const String _stateKey = 'current';

  /// 完整播放队列。
  static const String _queueKey = 'queue';

  /// 旧版把播放状态存在设置文件里的键（首次启动时迁移）。
  static const String _legacyKey = 'last_playback_state';

  Map<String, dynamic>? _current;
  List<dynamic>? _queue;

  /// 上次写进数据库的队列内容，用来判断队列有没有变。
  String? _savedQueueJson;

  late final DeferredWriter _writer = DeferredWriter(
    () => _persist(),
    interval: const Duration(seconds: 3),
  );

  /// 启动时把上次的状态读进内存（恢复播放会话时同步读取）。
  Future<void> load() async {
    try {
      final db = await AppDatabase.cacheDatabase();
      final rows = await db.query('playback_state');
      for (final row in rows) {
        final key = '${row['key']}';
        final raw = '${row['data']}';
        if (raw.isEmpty) continue;
        final decoded = jsonDecode(raw);
        if (key == _stateKey && decoded is Map) {
          _current = decoded.map((k, v) => MapEntry('$k', v));
        } else if (key == _queueKey && decoded is List) {
          _queue = decoded;
        }
      }
    } catch (e) {
      debugPrint('[PlaybackStateStore] 读取播放状态失败: $e');
    }

    if (_current == null && !await AppDatabase.isMigrated('playback_state')) {
      await _importLegacy();
      if (AppDatabase.isPersistent) {
        await AppDatabase.markMigrated('playback_state');
        await AppDatabase.removeLegacyKey(_legacyKey);
      }
    }
  }

  /// 保存播放状态（合并写盘）。
  void save(Map<String, dynamic> data) {
    _current = {
      'song': data['song'],
      'positionMs': data['positionMs'],
      'currentIndex': data['currentIndex'],
      'currentQuality': data['currentQuality'],
    };
    final queue = data['queue'];
    if (queue is List) _queue = queue;
    _writer.schedule();
  }

  /// 供「恢复上次播放会话」同步读取。
  Map<String, dynamic>? restore() {
    final current = _current;
    if (current == null) return null;
    final result = Map<String, dynamic>.from(current);
    final queue = _queue;
    if (queue != null) result['queue'] = queue;
    return result;
  }

  /// 清除播放状态（用户主动起播 / 切歌后就不再恢复旧进度）。
  void clear() {
    _current = null;
    _queue = null;
    _savedQueueJson = null;
    unawaited(_delete());
  }

  Future<void> _persist() async {
    final current = _current;
    final queue = _queue;
    if (current == null && queue == null) return;
    try {
      final db = await AppDatabase.cacheDatabase();
      final now = DateTime.now().millisecondsSinceEpoch;
      final queueJson = queue == null ? null : jsonEncode(queue);
      await db.transaction((txn) async {
        if (current != null) {
          await txn.insert(
            'playback_state',
            {
              'key': _stateKey,
              'data': jsonEncode(current),
              'updated_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        // 队列没变就不写，避免每 5 秒重写几十 KB。
        if (queueJson != null && queueJson != _savedQueueJson) {
          await txn.insert(
            'playback_state',
            {
              'key': _queueKey,
              'data': queueJson,
              'updated_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          _savedQueueJson = queueJson;
        }
      });
    } catch (e) {
      debugPrint('[PlaybackStateStore] 保存播放状态失败: $e');
    }
  }

  Future<void> _delete() async {
    try {
      final db = await AppDatabase.cacheDatabase();
      await db.delete('playback_state');
    } catch (e) {
      debugPrint('[PlaybackStateStore] 清除播放状态失败: $e');
    }
  }

  /// 首次启动：把旧设置文件里的播放状态导入数据库。
  Future<void> _importLegacy() async {
    try {
      final prefs = await AppPreferences.getInstance();
      final raw = prefs.getString(_legacyKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      _current = {
        'song': decoded['song'],
        'positionMs': decoded['positionMs'],
        'currentIndex': decoded['currentIndex'],
        'currentQuality': decoded['currentQuality'],
      };
      final queue = decoded['queue'];
      if (queue is List) _queue = queue;
      await _persist();
    } catch (e) {
      debugPrint('[PlaybackStateStore] 迁移旧播放状态失败: $e');
    }
  }
}
