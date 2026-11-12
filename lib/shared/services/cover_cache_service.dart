import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:path/path.dart' as p;

import '../../features/player/domain/models/song.dart';
import 'cache_paths.dart';
import 'cover_memory_cache.dart';

/// 统一的封面缓存服务，管理内存 LRU 缓存和磁盘持久化缓存。
/// 解决 QueryArtworkWidget 每次独立查询 MediaStore 导致的加载缓慢问题。
class CoverCacheService {
  static final CoverCacheService _instance = CoverCacheService._();
  factory CoverCacheService() => _instance;
  CoverCacheService._();

  final OnAudioQuery _audioQuery = OnAudioQuery();

  /// 内存 LRU 缓存：songId → 封面字节数据（与网络封面共用一份字节预算）
  static final CoverMemoryCache _memCache = CoverMemoryCache.instance;

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
    final dir = await CachePaths.subDirectory(CachePaths.localSongsImageCache);
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
    return _memCache.get(songId);
  }

  /// 将封面字节放入内存缓存
  void _putMemCache(String songId, Uint8List bytes) {
    _memCache.put(songId, bytes);
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

  /// 确保封面已落盘，返回磁盘文件路径；没有封面时返回 null。
  ///
  /// 给系统媒体通知（`MediaItem.artUri`）用：它只认文件路径，不接受内存字节。
  /// 直接复用本地歌曲封面缓存里的 `<歌曲id>.jpg`，不再另外复制一份。
  ///
  /// 与 [getArtwork] 的区别是需要一个**已经写完**的文件：内存命中但磁盘还
  /// 没写（提取时是异步落盘）时，这里补写完再返回。
  Future<String?> ensureDiskFile(String songId, {int? mediaStoreId}) async {
    final path = await _diskPath(songId);
    try {
      final file = File(path);
      if (await file.exists() && await file.length() > 0) return path;
    } catch (_) {}

    final bytes = await getArtwork(songId, mediaStoreId: mediaStoreId);
    if (bytes == null || bytes.isEmpty) return null;
    try {
      final file = File(path);
      if (!await file.exists() || await file.length() == 0) {
        await file.writeAsBytes(bytes, flush: true);
      }
      return path;
    } catch (e) {
      debugPrint('[CoverCache] 封面落盘失败 $songId: $e');
      return null;
    }
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
    } catch (e) {
      debugPrint('[CoverCache] 磁盘写入失败 $songId: $e');
    }
  }

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
      futures.add(
        semaphore.enter(() async {
          try {
            await getArtwork(song.id, mediaStoreId: song.mediaStoreId);
          } catch (_) {
            // 忽略单首歌曲的错误
          } finally {
            completed++;
            onProgress?.call(completed, total);
            semaphore.leave();
          }
        }),
      );
    }

    await Future.wait(futures);
  }

  /// 检查磁盘缓存是否存在
  Future<bool> hasDiskCache(String songId) async {
    try {
      final path = await _diskPath(songId);
      return await File(path).exists();
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

  /// 删除「已经不属于任何本地歌曲」的封面图片，返回删除数量。
  ///
  /// 本地歌曲被移出扫描目录、音频文件被删掉之后，对应的 `<歌曲id>.jpg` 不会
  /// 再有人读取，留着只会占空间。以当前本地歌曲列表的 id 为准做差集。
  ///
  /// 只处理本缓存目录里的 `.jpg`（[putArtwork] / [getArtwork] 写出的唯一格式），
  /// 半成品临时文件不碰。
  Future<int> pruneToSongIds(Iterable<String> liveSongIds) async {
    var removed = 0;
    try {
      final live = liveSongIds.toSet();
      final dir = await _getCacheDir();
      if (!await dir.exists()) return 0;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.endsWith('.part') || name.endsWith('.tmp')) continue;
        final lower = name.toLowerCase();
        if (!lower.endsWith('.jpg')) continue;
        final songId = name.substring(0, name.length - 4);
        if (live.contains(songId)) continue;
        try {
          await entity.delete();
          _memCache.remove(songId);
          removed++;
        } catch (_) {
          // 单个文件删不掉（被占用）就留给下次扫描。
        }
      }
      if (removed > 0) {
        debugPrint('[CoverCache] 清理无主封面 $removed 张');
      }
    } catch (e) {
      debugPrint('[CoverCache] 清理无主封面失败: $e');
    }
    return removed;
  }

  /// 清除所有缓存
  Future<void> clearAll() async {
    _memCache.clear();
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
