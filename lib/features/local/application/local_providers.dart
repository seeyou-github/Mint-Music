import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../data/local_music_repository.dart';
import '../../player/domain/models/song.dart';
import '../../../shared/services/cover_cache_service.dart';

final localMusicRepositoryProvider = Provider<LocalMusicRepository>((ref) {
  // 保持单例：目录/歌曲索引存在内存里，若随监听者销毁重建，
  // 新实例不会自动 init，导致扫描目录设置"消失"。
  ref.keepAlive();
  return LocalMusicRepository();
});

final onAudioQueryProvider = Provider<OnAudioQuery>((ref) {
  return OnAudioQuery();
});

final coverCacheServiceProvider = Provider<CoverCacheService>((ref) {
  ref.keepAlive();
  return CoverCacheService();
});

final localPermissionProvider = StateProvider<AsyncValue<bool>>((ref) {
  return const AsyncValue.data(false);
});

final localSongsProvider = FutureProvider<List<Song>>((ref) async {
  final repo = ref.watch(localMusicRepositoryProvider);
  await repo.init();
  return repo.getLocalSongs();
});

final localSearchQueryProvider = StateProvider<String>((ref) => '');

final filteredLocalSongsProvider = Provider<List<Song>>((ref) {
  final query = ref.watch(localSearchQueryProvider);
  final songsAsync = ref.watch(localMusicNotifierProvider);
  return songsAsync.when(
    data: (songs) {
      final List<Song> result;
      if (query.isEmpty) {
        // 仓库返回的是不可变列表，排序前先复制一份。
        result = List<Song>.of(songs);
      } else {
        final q = query.toLowerCase();
        result = songs
            .where(
              (s) =>
                  s.title.toLowerCase().contains(q) ||
                  s.artist.toLowerCase().contains(q) ||
                  s.album.toLowerCase().contains(q),
            )
            .toList();
      }
      // 按歌手名称的第一个字排序，同名歌手再按歌名排。
      result.sort(compareSongByArtistFirstChar);
      return result;
    },
    loading: () => [],
    error: (_, _) => [],
  );
});

/// 按歌手名称的第一个字排序（同名歌手再按歌名排序）。
///
/// 本地音乐按歌手聚在一起更方便查找：以歌手名的首字符作为主键，
/// 首字符相同时比较完整歌手名，最后比较歌名，保证顺序稳定。
int compareSongByArtistFirstChar(Song a, Song b) {
  final artistA = a.artist.trim();
  final artistB = b.artist.trim();
  final firstA = artistA.isEmpty ? '' : artistA.substring(0, 1);
  final firstB = artistB.isEmpty ? '' : artistB.substring(0, 1);
  final firstCmp = firstA.compareTo(firstB);
  if (firstCmp != 0) return firstCmp;
  final artistCmp = artistA.toLowerCase().compareTo(artistB.toLowerCase());
  if (artistCmp != 0) return artistCmp;
  return a.title.toLowerCase().compareTo(b.title.toLowerCase());
}

/// 已保存的扫描目录。异步加载以确保从持久化恢复
/// （repo 为单例，init 后结果会缓存）。
final scannedDirectoriesProvider = FutureProvider<List<String>>((ref) async {
  final repo = ref.watch(localMusicRepositoryProvider);
  await repo.init();
  return repo.getScannedDirectories();
});

final scanProgressProvider = StateProvider<ScanProgress>((ref) {
  return const ScanProgress();
});

final batchMatchProgressProvider = StateProvider<BatchMatchProgress>((ref) {
  return const BatchMatchProgress();
});

class LocalMusicNotifier extends StateNotifier<AsyncValue<List<Song>>> {
  final Ref _ref;

  /// 本次运行是否已经做过「索引为空时自动补扫」，保证只自动扫描一次。
  bool _autoScanAttempted = false;

  LocalMusicNotifier(this._ref) : super(const AsyncValue.loading()) {
    _init();
  }

  Future<void> _init({bool rescan = false}) async {
    try {
      // 之前是错误状态时先切到加载中，点击「重试」能看到明确的反馈。
      if (state.hasError) {
        state = const AsyncValue.loading();
      }
      final repo = _ref.read(localMusicRepositoryProvider);
      await repo.init();

      final hasPermission = await repo.checkPermission();
      if (hasPermission) {
        final songs = repo.getLocalSongs();
        // 临时数据库被删除 / 本地歌曲为空，但设置里仍保存着扫描目录时，
        // 第一次进入「本地」分类自动补扫一次；没有扫描目录就不自动扫描
        // （扫描只认「扫描目录设置」里的目录，任何平台都不再遍历整机存储）。
        final shouldAutoScan =
            songs.isEmpty &&
            !_autoScanAttempted &&
            repo.getScannedDirectories().isNotEmpty;
        if (shouldAutoScan) {
          _autoScanAttempted = true;
        }
        if (rescan || shouldAutoScan) {
          final scanned = await repo.scanAll(
            onProgress: (progress) {
              _ref.read(scanProgressProvider.notifier).state = progress;
            },
          );
          // 列表已经更新：本地歌曲列表里没有的歌，其封面图片一并删掉。
          if (scanned) await _pruneCovers(repo.getLocalSongs());
        }
      }

      state = AsyncValue.data(repo.getLocalSongs());

      // 后台预加载封面缓存（不阻塞 UI）
      _preloadCovers(repo.getLocalSongs());
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  /// 后台预加载所有本地歌曲的封面到缓存（内存 + 磁盘）。
  /// 首次访问时从 MediaStore 提取，后续直接从缓存读取。
  void _preloadCovers(List<Song> songs) {
    if (songs.isEmpty) return;
    final cache = _ref.read(coverCacheServiceProvider);
    unawaited(
      cache.preloadBatch(
        songs,
        concurrency: 10,
        onProgress: (completed, total) {
          if (completed % 20 == 0 || completed == total) {
            debugPrint('[LocalMusic] 封面预加载进度: $completed/$total');
          }
        },
      ),
    );
  }

  /// 扫描完成后清理封面缓存：当前本地歌曲列表里没有的歌曲，封面图片删掉。
  ///
  /// 只在扫描**成功**后调用（列表确实更新了）：没设目录、扫描失败、正在扫描
  /// 时 `scanAll` 返回 false，这时列表是旧的，不能按它删图片。
  Future<void> _pruneCovers(List<Song> songs) async {
    try {
      await _ref
          .read(coverCacheServiceProvider)
          .pruneToSongIds(songs.map((s) => s.id));
    } catch (e) {
      debugPrint('[LocalMusic] 清理无主封面失败: $e');
    }
  }

  Future<bool> requestPermissionAndScan() async {
    try {
      final repo = _ref.read(localMusicRepositoryProvider);
      final alreadyGranted = await repo.checkPermission();
      if (!alreadyGranted) {
        final granted = await repo.requestPermission();
        _ref.read(localPermissionProvider.notifier).state = AsyncValue.data(
          granted,
        );
        if (!granted) return false;
      }
      // 授权后只扫「已设置的扫描目录」；一个目录都没设就什么都不扫，
      // 由界面引导用户去添加目录（不再默认遍历整机存储）。
      await scanAll();
      return true;
    } catch (e, st) {
      _ref.read(localPermissionProvider.notifier).state = AsyncValue.error(
        e,
        st,
      );
      return false;
    }
  }

  Future<void> addDirectory(String dirPath) async {
    try {
      final repo = _ref.read(localMusicRepositoryProvider);
      await repo.addDirectory(dirPath);
      _refreshScannedDirs();
      state = AsyncValue.data(repo.getLocalSongs());
      await _pruneCovers(repo.getLocalSongs());
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> removeDirectory(String dirPath) async {
    try {
      final repo = _ref.read(localMusicRepositoryProvider);
      await repo.removeDirectory(dirPath);
      _refreshScannedDirs();
      state = AsyncValue.data(repo.getLocalSongs());
      // 目录里的歌已经从索引移除，对应封面一起删掉。
      await _pruneCovers(repo.getLocalSongs());
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> setDirectories(List<String> dirs) async {
    try {
      final repo = _ref.read(localMusicRepositoryProvider);
      await repo.setDirectories(dirs);
      _refreshScannedDirs();
      state = AsyncValue.data(repo.getLocalSongs());
      // 清空目录 / 删除单条目录后索引会立即变短（不需要等下一次扫描），
      // 这里顺手把不再使用的封面删掉。
      await _pruneCovers(repo.getLocalSongs());
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  /// 只重排扫描目录（集合不变）：不重算歌曲归属，目录栏立刻按新顺序显示。
  Future<void> reorderDirectories(List<String> dirs) async {
    await _ref.read(localMusicRepositoryProvider).reorderDirectories(dirs);
    _refreshScannedDirs();
  }

  /// 目录变更后使扫描目录缓存失效，保证弹窗再次打开时读到最新列表。
  void _refreshScannedDirs() {
    _ref.invalidate(scannedDirectoriesProvider);
  }

  /// 扫描本地音乐。返回 false 表示没有扫描目录、这次什么都没扫。
  ///
  /// 没有配置扫描目录时**不会**退化成「扫描整机音乐」，只提示用户先加目录。
  Future<bool> scanAll() async {
    try {
      if (state.hasError) {
        state = const AsyncValue.loading();
      }
      final repo = _ref.read(localMusicRepositoryProvider);
      final scanned = await repo.scanAll(
        onProgress: (progress) {
          _ref.read(scanProgressProvider.notifier).state = progress;
        },
      );
      state = AsyncValue.data(repo.getLocalSongs());

      if (scanned) {
        // 列表已经更新：本地歌曲列表里没有的歌，其封面图片一并删掉，
        // 然后再预热新列表的封面。
        await _pruneCovers(repo.getLocalSongs());
        _preloadCovers(repo.getLocalSongs());
      }
      return scanned;
    } catch (e, st) {
      state = AsyncValue.error(e, st);
      return false;
    }
  }

  Future<void> clearIndex() async {
    try {
      final repo = _ref.read(localMusicRepositoryProvider);
      await repo.clearIndex();
      state = AsyncValue.data(repo.getLocalSongs());
      // 索引清空后没有任何歌再用这些封面，整批删掉。
      await _pruneCovers(repo.getLocalSongs());
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> upsertSong(Song song, {bool forceOverwrite = false}) async {
    try {
      final repo = _ref.read(localMusicRepositoryProvider);
      await repo.upsertSong(song, forceOverwrite: forceOverwrite);
      state = AsyncValue.data(repo.getLocalSongs());
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  /// 删除本地歌曲。返回是否成功移除。
  Future<bool> deleteSong(Song song) async {
    try {
      final repo = _ref.read(localMusicRepositoryProvider);
      final ok = await repo.deleteSong(song.id);
      if (ok) {
        state = AsyncValue.data(repo.getLocalSongs());
        // 歌已经从列表里移除，封面一并删掉（不用等下次扫描）。
        await _pruneCovers(repo.getLocalSongs());
      }
      return ok;
    } catch (e, st) {
      state = AsyncValue.error(e, st);
      return false;
    }
  }

  /// 批量删除本地歌曲。返回实际移除的数量。
  Future<int> deleteSongs(List<Song> songs) async {
    if (songs.isEmpty) return 0;
    try {
      final repo = _ref.read(localMusicRepositoryProvider);
      final removed = await repo.deleteSongs(songs.map((s) => s.id));
      if (removed > 0) {
        state = AsyncValue.data(repo.getLocalSongs());
        await _pruneCovers(repo.getLocalSongs());
      }
      return removed;
    } catch (e, st) {
      state = AsyncValue.error(e, st);
      return 0;
    }
  }

  /// 重新扫描并刷新列表（本地页「重试」按钮）。
  void refresh() {
    _init(rescan: true);
  }
}

final localMusicNotifierProvider =
    StateNotifierProvider<LocalMusicNotifier, AsyncValue<List<Song>>>((ref) {
      return LocalMusicNotifier(ref);
    });
