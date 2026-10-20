import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:on_audio_query/on_audio_query.dart';

import '../../features/player/domain/models/song.dart';
import 'cache_paths.dart';

/// 统一的封面缓存服务，管理内存 LRU 缓存和磁盘持久化缓存。
/// 解决 QueryArtworkWidget 每次独立查询 MediaStore 导致的加载缓慢问题。
class CoverCacheService {
  static final CoverCacheService _instance = CoverCacheService._();
  factory CoverCacheService() => _instance;
  CoverCacheService._();

  final OnAudioQuery _audioQuery = OnAudioQuery();

  /// 内存 LRU 缓存：songId → 封面字节数据
  static final LinkedHashMap<String, Uint8List> _memCache = LinkedHashMap();
  static const int _maxMemBytes = 32 * 1024 * 1024; // 32MB
  static int _memBytes = 0;

  /// 磁盘缓存目录（懒初始化）
  Directory? _cacheDir;

  /// 正在进行的提取任务，防止重复提取
  final Map<String, Future<Uint8List?>> _pending = {};

  /// 获取磁盘缓存目录（跟随「设置 - 存储管理 - 缓存目录」）
  Future<Directory> _getCacheDir() async {
    final cached = _cacheDir;
    if (cached != null &&
        _cacheRoot == CachePaths.root &&
        await cached.exists()) {
      return cached;
    }
    final dir = await CachePaths.subDirectory('artwork_cache');
    _cacheDir = dir;
    _cacheRoot = CachePaths.root;
    return dir;
  }

  /// 当前缓存目录对应的根目录，用于感知「缓存目录」设置变化。
  String? _cacheRoot;

  /// 磁盘缓存文件路径
  Future<String> _diskPath(String songId) async {
    final dir = await _getCacheDir();
    return '${dir.path}/$songId.jpg';
  }

  /// 从内存缓存获取封面字节
  Uint8List? getFromMemCache(String songId) {
    final bytes = _memCache.remove(songId);
    if (bytes != null) {
      // 移到末尾（最近使用）
      _memCache[songId] = bytes;
      return bytes;
    }
    return null;
  }

  /// 将封面字节放入内存缓存
  void _putMemCache(String songId, Uint8List bytes) {
    if (bytes.length > _maxMemBytes) return; // 单个文件太大不缓存
    // 淘汰最旧的条目直到有空间
    while (_memBytes + bytes.length > _maxMemBytes && _memCache.isNotEmpty) {
      final oldestKey = _memCache.keys.first;
      final oldest = _memCache.remove(oldestKey);
      if (oldest != null) _memBytes -= oldest.length;
    }
    _memCache[songId] = bytes;
    _memBytes += bytes.length;
  }

  /// 获取封面字节数据（内存 → 磁盘 → MediaStore 提取 → 保存）。
  /// [songId] 歌曲唯一 ID
  /// [mediaStoreId] Android MediaStore ID（本地歌曲）
  Future<Uint8List?> getArtwork(String songId, {int? mediaStoreId}) async {
    // 1. 内存缓存命中
    final memHit = getFromMemCache(songId);
    if (memHit != null) return memHit;

    // 2. 磁盘缓存命中
    try {
      final path = await _diskPath(songId);
      final file = File(path);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) {
          _putMemCache(songId, bytes);
          return bytes;
        }
      }
    } catch (e) {
      debugPrint('[CoverCache] 磁盘读取失败 $songId: $e');
    }

    // 3. 从 MediaStore 提取
    if (mediaStoreId == null) return null;

    // 防止重复提取
    if (_pending.containsKey(songId)) {
      return _pending[songId]!;
    }

    final future = _extractAndCache(songId, mediaStoreId);
    _pending[songId] = future;

    try {
      return await future;
    } finally {
      _pending.remove(songId);
    }
  }

  /// 直接缓存封面字节（桌面端从音频文件内嵌封面提取时使用）。
  Future<void> putArtwork(String songId, Uint8List bytes) async {
    if (bytes.isEmpty) return;
    _putMemCache(songId, bytes);
    await _writeToDisk(songId, bytes);
  }

  /// 从 MediaStore 提取封面并缓存到内存 + 磁盘
  Future<Uint8List?> _extractAndCache(String songId, int mediaStoreId) async {
    try {
      final bytes = await _audioQuery.queryArtwork(
        mediaStoreId,
        ArtworkType.AUDIO,
        quality: 100,
        size: 1024,
      );

      if (bytes != null && bytes.isNotEmpty) {
        _putMemCache(songId, bytes);

        // 异步写入磁盘（不阻塞返回）
        _writeToDisk(songId, bytes);

        return bytes;
      }
    } catch (e) {
      debugPrint('[CoverCache] 提取封面失败 $songId: $e');
    }
    return null;
  }

  /// 异步写入磁盘缓存
  Future<void> _writeToDisk(String songId, Uint8List bytes) async {
    try {
      final path = await _diskPath(songId);
      await File(path).writeAsBytes(bytes, flush: false);
      // 每写入 20 张封面检查一次缓存上限，避免频繁遍历目录。
      _writeCount++;
      if (_writeCount % 20 == 0 && CachePaths.maxBytes > 0) {
        await CachePaths.enforceLimit();
      }
    } catch (e) {
      debugPrint('[CoverCache] 磁盘写入失败 $songId: $e');
    }
  }

  int _writeCount = 0;

  /// 批量预加载封面（在后台并发执行，带进度回调）。
  /// 用于本地音乐扫描完成后预热缓存。
  Future<void> preloadBatch(
    List<Song> songs, {
    int concurrency = 8,
    void Function(int completed, int total)? onProgress,
  }) async {
    int completed = 0;
    final total = songs.length;
    final semaphore = _Semaphore(concurrency);

    final futures = <Future<void>>[];
    for (final song in songs) {
      if (song.mediaStoreId == null) {
        completed++;
        continue;
      }
      futures.add(semaphore.enter(() async {
        try {
          await getArtwork(song.id, mediaStoreId: song.mediaStoreId);
        } catch (_) {
          // 忽略单首歌曲的错误
        } finally {
          completed++;
          onProgress?.call(completed, total);
          semaphore.leave();
        }
      }));
    }

    await Future.wait(futures);
  }

  /// 检查磁盘缓存是否存在
  Future<bool> hasDiskCache(String songId) async {
    try {
      final path = await _diskPath(songId);
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// 使特定歌曲的缓存失效
  void invalidate(String songId) {
    _memCache.remove(songId);
    _diskPath(songId).then((path) {
      File(path).exists().then((exists) {
        if (exists) File(path).delete();
      });
    });
  }

  /// 清除所有缓存
  Future<void> clearAll() async {
    _memCache.clear();
    _memBytes = 0;
    try {
      final dir = await _getCacheDir();
      if (await dir.exists()) {
        await dir.delete(recursive: true);
        await dir.create(recursive: true);
      }
    } catch (e) {
      debugPrint('[CoverCache] 清除缓存失败: $e');
    }
  }

  /// 获取磁盘缓存大小（字节）
  Future<int> getDiskCacheSize() async {
    try {
      final dir = await _getCacheDir();
      if (!await dir.exists()) return 0;
      int size = 0;
      await for (final entity in dir.list()) {
        if (entity is File) {
          size += await entity.length();
        }
      }
      return size;
    } catch (_) {
      return 0;
    }
  }
}

/// 简单的信号量，控制并发数
class _Semaphore {
  final int _maxCount;
  int _currentCount = 0;
  final Queue<Completer<void>> _queue = Queue();

  _Semaphore(this._maxCount);

  Future<void> enter(Future<void> Function() task) async {
    if (_currentCount >= _maxCount) {
      final completer = Completer<void>();
      _queue.add(completer);
      await completer.future;
    }
    _currentCount++;
    try {
      return await task();
    } finally {
      _currentCount--;
    }
  }

  void leave() {
    if (_queue.isNotEmpty) {
      _queue.removeFirst().complete();
    }
  }
}
