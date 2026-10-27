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
        // 第一次进入「本地」分类自动补扫一次。没有扫描目录就不自动扫描，
        // 避免在桌面上无意间遍历整个系统音乐目录。
        final shouldAutoScan =
            songs.isEmpty &&
            !_autoScanAttempted &&
            repo.getScannedDirectories().isNotEmpty;
        if (shouldAutoScan) {
          _autoScanAttempted = true;
        }
        if (rescan || shouldAutoScan) {
          await repo.scanAll(
            onProgress: (progress) {
              _ref.read(scanProgressProvider.notifier).state = progress;
            },
          );
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
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  /// 目录变更后使扫描目录缓存失效，保证弹窗再次打开时读到最新列表。
  void _refreshScannedDirs() {
    _ref.invalidate(scannedDirectoriesProvider);
  }

  Future<void> scanAll() async {
    try {
      if (state.hasError) {
        state = const AsyncValue.loading();
      }
      final repo = _ref.read(localMusicRepositoryProvider);
      await repo.scanAll(
        onProgress: (progress) {
          _ref.read(scanProgressProvider.notifier).state = progress;
        },
      );
      state = AsyncValue.data(repo.getLocalSongs());

      // 后台预加载封面缓存
      _preloadCovers(repo.getLocalSongs());
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> clearIndex() async {
    try {
      final repo = _ref.read(localMusicRepositoryProvider);
      await repo.clearIndex();
      state = AsyncValue.data(repo.getLocalSongs());
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
