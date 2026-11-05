import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:path/path.dart' as p;

import '../../../core/storage/app_database.dart';
import '../../../core/storage/app_preferences.dart';
import '../../../shared/services/cover_cache_service.dart';
import '../../player/domain/models/song.dart';
import '../../player/domain/services/lyric_parser.dart';
import 'local_metadata_reader.dart';

class ScanProgress {
  final int processed;
  final int total;
  final bool running;

  const ScanProgress({
    this.processed = 0,
    this.total = 0,
    this.running = false,
  });

  ScanProgress copyWith({int? processed, int? total, bool? running}) {
    return ScanProgress(
      processed: processed ?? this.processed,
      total: total ?? this.total,
      running: running ?? this.running,
    );
  }
}

class BatchMatchProgress {
  final int processed;
  final int total;
  final int matched;
  final bool running;

  const BatchMatchProgress({
    this.processed = 0,
    this.total = 0,
    this.matched = 0,
    this.running = false,
  });

  BatchMatchProgress copyWith({
    int? processed,
    int? total,
    int? matched,
    bool? running,
  }) {
    return BatchMatchProgress(
      processed: processed ?? this.processed,
      total: total ?? this.total,
      matched: matched ?? this.matched,
      running: running ?? this.running,
    );
  }
}

typedef ScanProgressCallback = void Function(ScanProgress progress);
typedef BatchMatchProgressCallback = void Function(BatchMatchProgress progress);

class LocalMusicRepository {
  LocalMusicRepository() {
    AppDatabase.registerWriter(_writer);
  }

  /// 旧版把扫描目录 / 本地歌曲列表存在设置文件里的键（首次启动时迁移）。
  static const _dirsKey = 'local_music_dirs';
  static const _songsKey = 'local_music_songs';

  /// 当前平台是否有 MediaStore（Android/iOS）。
  ///
  /// 桌面端（Windows/macOS/Linux）没有 MediaStore，`on_audio_query` 插件不可用，
  /// 扫描目录时会抛 MissingPluginException，这里改用纯 Dart 遍历目录并解析
  /// 文件标签（见 [LocalMetadataReader]）。
  static bool get supportsMediaStore => Platform.isAndroid || Platform.isIOS;

  final OnAudioQuery _audioQuery = OnAudioQuery();

  final Set<String> _scannedDirs = {};
  final Map<String, Song> _songsMap = {};
  bool _initialized = false;
  bool _isScanning = false;
  ScanProgressCallback? onScanProgress;
  BatchMatchProgressCallback? onBatchMatchProgress;

  /// 本地歌曲列表属于「丢了可以重新扫描」的高频数据，写入走合并延迟写，
  /// 避免扫描 / 匹配过程中反复写盘。
  late final DeferredWriter _writer = DeferredWriter(() => _persistIndex());

  Future<void> init() async {
    if (_initialized) return;
    final db = await AppDatabase.cacheDatabase();

    // 扫描目录变动很少，存放在应用配置里（备份 / 还原会带上）。
    try {
      final prefs = await AppPreferences.getInstance();
      _scannedDirs.addAll(prefs.getStringList(_dirsKey) ?? const <String>[]);
    } catch (e) {
      debugPrint('[LocalMusic] 读取扫描目录失败: $e');
    }

    final songRows = await db.query('local_songs');
    for (final row in songRows) {
      final data = AppDatabase.decodeMap(row['data']);
      if (data.isEmpty) continue;
      try {
        final song = Song.fromJson(data);
        _songsMap[song.id] = song;
      } catch (_) {
        // 单条数据损坏就跳过
      }
    }

    if (!await AppDatabase.isMigrated('local_music')) {
      await _importLegacy();
      if (AppDatabase.isPersistent) {
        await AppDatabase.markMigrated('local_music');
      }
    }

    _initialized = true;
  }

  List<Song> getLocalSongs() {
    return List.unmodifiable(_songsMap.values.toList());
  }

  Song? getSongById(String id) {
    return _songsMap[id];
  }

  List<Song> searchLocal(String query) {
    if (query.isEmpty) return getLocalSongs();
    final q = query.toLowerCase();
    return _songsMap.values
        .where(
          (s) =>
              s.title.toLowerCase().contains(q) ||
              s.artist.toLowerCase().contains(q) ||
              s.album.toLowerCase().contains(q),
        )
        .toList();
  }

  List<String> getScannedDirectories() {
    return List.unmodifiable(_scannedDirs);
  }

  String _genId(String filePath) {
    final normalized = filePath.replaceAll('\\', '/');
    return md5.convert(utf8.encode(normalized)).toString().substring(0, 16);
  }

  String _genCoverKey(String filePath) {
    final normalized = filePath.replaceAll('\\', '/');
    return md5
        .convert(utf8.encode('cover_$normalized'))
        .toString()
        .substring(0, 16);
  }

  /// MediaStore 给的「专辑」是不是拿所在文件夹名顶替的。
  ///
  /// 文件里没有专辑标签时，Android 的 MediaStore 会用父目录名填 ALBUM 列
  /// （通话录音 = `Call Recordings`、下载目录 = `Download`…）。这种值不是
  /// 真实专辑，不能当成专辑信息显示。
  static bool _isFolderNameFallback(String album, String filePath) {
    final folderName = p.basename(p.dirname(filePath)).trim();
    if (folderName.isEmpty) return false;
    return album.toLowerCase() == folderName.toLowerCase();
  }

  /// 根据文件扩展名推断音频比特率（用于本地音乐音质显示）
  int? _inferBitrateFromExtension(String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    switch (ext) {
      case '.flac':
        return 1411000;
      case '.mp3':
        return 320000;
      case '.m4a':
      case '.aac':
        return 320000;
      case '.wav':
      case '.ape':
      case '.dsd':
      case '.dff':
      case '.dsf':
        return 1411000;
      case '.ogg':
      case '.wma':
        return 320000;
      default:
        return null;
    }
  }

  Future<void> addDirectory(String dirPath) async {
    await init();
    if (_scannedDirs.contains(dirPath)) return;
    _scannedDirs.add(dirPath);
    await _persistDirectories();
    await _flushIndex();
  }

  Future<void> removeDirectory(String dirPath) async {
    await init();
    _scannedDirs.remove(dirPath);
    final normalized = dirPath.replaceAll('\\', '/');
    _songsMap.removeWhere((_, s) {
      final fp = (s.filePath ?? '').replaceAll('\\', '/');
      return fp.startsWith(normalized);
    });
    await _persistDirectories();
    await _flushIndex();
  }

  Future<void> setDirectories(List<String> dirs) async {
    await init();
    _scannedDirs.clear();
    _scannedDirs.addAll(dirs.where((d) => d.isNotEmpty));
    await _persistDirectories();
    await _flushIndex();
  }

  Future<bool> requestPermission() async {
    if (!supportsMediaStore) return true;
    return await _audioQuery.permissionsRequest();
  }

  Future<bool> checkPermission() async {
    if (!supportsMediaStore) return true;
    return await _audioQuery.permissionsStatus();
  }

  /// 扫描本地音乐。
  ///
  /// **只扫描「扫描目录设置」里已添加的目录**：一个目录都没设置时直接返回
  /// false，不做任何扫描。绝不回退成「扫描设备全部音乐」——Android 上刚拿到
  /// 存储权限就那样扫，会把整机（含外置存储）的音频一次性灌进曲库。
  /// 返回值表示「这次是否真的扫了」。
  Future<bool> scanAll({ScanProgressCallback? onProgress}) async {
    if (_isScanning) return false;
    await init();

    if (_scannedDirs.isEmpty) {
      debugPrint('[LocalMusic] 未设置扫描目录，跳过扫描');
      // 复位进度，避免界面上残留「扫描中」状态。
      final idle = ScanProgress(processed: 0, total: 0, running: false);
      onScanProgress?.call(idle);
      onProgress?.call(idle);
      return false;
    }

    _isScanning = true;

    try {
      if (!supportsMediaStore) {
        // 桌面端：没有 MediaStore，直接遍历目录解析文件标签。
        return await _scanDesktop(onProgress);
      }

      final alreadyGranted = await checkPermission();
      if (!alreadyGranted) {
        final hasPermission = await requestPermission();
        if (!hasPermission) return false;
      }

      final startProgress = ScanProgress(processed: 0, total: 0, running: true);
      onScanProgress?.call(startProgress);
      onProgress?.call(startProgress);

      try {
        final songs = await _audioQuery.querySongs(
          sortType: SongSortType.TITLE,
          orderType: OrderType.ASC_OR_SMALLER,
        );

        final musicSongs = songs
            .where((s) => s.isMusic == true || s.isMusic == null)
            .toList();

        final total = musicSongs.length;
        onScanProgress?.call(
          ScanProgress(processed: 0, total: total, running: true),
        );
        onProgress?.call(
          ScanProgress(processed: 0, total: total, running: true),
        );

        final newSongsMap = <String, Song>{};
        int processed = 0;

        for (final audio in musicSongs) {
          final filePath = audio.data;
          if (filePath.isEmpty) {
            processed++;
            continue;
          }

          final shouldFilter = _scannedDirs.isNotEmpty
              ? !_scannedDirs.any((dir) {
                  final normalized = filePath.replaceAll('\\', '/');
                  final normalizedDir = dir.replaceAll('\\', '/');
                  return normalized.startsWith(normalizedDir);
                })
              : false;

          if (shouldFilter) {
            processed++;
            continue;
          }

          // MediaStore 只提供标题 / 歌手 / 专辑 / 时长，年份、流派、注释、
          // 内嵌歌词、内嵌封面它都不给。不在这里补读一次文件标签，索引里这几个
          // 字段就永远是空的——表现是「文件明明带封面 / 年代 / 歌词，匹配歌曲页
          // 却显示 -，按『封面 有』筛选也筛不出来（反而出现在『无封面』里），
          // 编辑标签页还显示成无封面」；而列表能显示封面是因为封面图是走
          // MediaStore 单独取的，跟索引里的 hasCover 是两回事。
          //
          // 只在用户主动扫描时发生（进度条照常走），不是每次启动都读。
          final metadata = await LocalMetadataReader.read(filePath);

          final id = _genId(filePath);
          final title = audio.title.isNotEmpty
              ? audio.title
              : ((metadata.title?.isNotEmpty ?? false)
                    ? metadata.title!
                    : p.basenameWithoutExtension(filePath));
          final rawArtist = audio.artist ?? '';
          final artist = rawArtist.isEmpty || rawArtist == '<unknown>'
              ? ((metadata.artist?.isNotEmpty ?? false)
                    ? metadata.artist!
                    : '未知艺术家')
              : rawArtist;
          final rawAlbum = audio.album ?? '';
          // MediaStore 对没有专辑标签的文件（通话录音、下载的音频…）会拿
          // **所在文件夹名**当专辑（这里是 `Call Recordings`），看着像专辑信息，
          // 其实文件里根本没写。文件标签里读到专辑就以标签为准；标签里没有时，
          // 只有 MediaStore 给的值不像文件夹名才采用，否则按「无专辑」处理，
          // 与桌面端（读不到标签就是「未知专辑」）保持一致。
          final tagAlbum = metadata.album?.trim() ?? '';
          final mediaAlbum = rawAlbum.trim();
          final album = tagAlbum.isNotEmpty
              ? tagAlbum
              : (mediaAlbum.isEmpty ||
                        mediaAlbum == '<unknown>' ||
                        _isFolderNameFallback(mediaAlbum, filePath)
                    ? '未知专辑'
                    : mediaAlbum);
          final duration = (audio.duration ?? 0) ~/ 1000;

          // 内嵌歌词：记下「有没有」「是不是逐字」，快速匹配页据此筛选，
          // 不用为了看状态把每个文件再读一遍。
          final embeddedLyric = metadata.lyrics?.trim() ?? '';
          final hasEmbeddedLyric = embeddedLyric.isNotEmpty;
          final hasEmbeddedWordLyric =
              hasEmbeddedLyric && detectWordLyricFormat(embeddedLyric) != null;

          final song = Song(
            id: id,
            title: title,
            artist: artist,
            album: album,
            duration: duration > 0 ? duration : 0,
            source: 'local',
            filePath: filePath,
            sourceUrl: filePath,
            hasCover: metadata.artwork != null,
            coverKey: _genCoverKey(filePath),
            mediaStoreId: audio.id,
            bitrate: _inferBitrateFromExtension(filePath),
            year: metadata.year,
            genre: metadata.genre,
            comment: metadata.comment,
            hasLyric: hasEmbeddedLyric,
            hasWordLyric: hasEmbeddedWordLyric,
          );

          final existing = _songsMap[id];
          if (existing != null) {
            newSongsMap[id] = _mergePreferFilled(existing, song);
          } else {
            newSongsMap[id] = song;
          }

          processed++;
          if (processed % 20 == 0 || processed == total) {
            final progress = ScanProgress(
              processed: processed,
              total: total,
              running: true,
            );
            onScanProgress?.call(progress);
            onProgress?.call(progress);
          }
        }

        _songsMap.clear();
        _songsMap.addAll(newSongsMap);
        await _flushIndex();

        final doneProgress = ScanProgress(
          processed: total,
          total: total,
          running: false,
        );
        onScanProgress?.call(doneProgress);
        onProgress?.call(doneProgress);
        return true;
      } catch (e) {
        debugPrint('[LocalMusic] MediaStore 扫描失败: $e');
        final errorProgress = ScanProgress(
          processed: 0,
          total: 0,
          running: false,
        );
        onScanProgress?.call(errorProgress);
        onProgress?.call(errorProgress);
        return false;
      }
    } finally {
      _isScanning = false;
    }
  }

  /// 桌面端扫描：遍历已设置的目录，解析文件标签。
  ///
  /// 与 Android 端 MediaStore 扫描不同，这里直接读文件，所以能拿到内嵌封面，
  /// 并把它写进封面缓存供列表显示。
  Future<bool> _scanDesktop(ScanProgressCallback? onProgress) async {
    final startProgress = ScanProgress(processed: 0, total: 0, running: true);
    onScanProgress?.call(startProgress);
    onProgress?.call(startProgress);

    try {
      // 只扫已设置的目录：没有目录时上游 scanAll 已经拦住了，这里不再回退到
      // 「系统音乐目录」，避免用户没配目录却把整个 Music 文件夹扫进来。
      final dirs = _scannedDirs.toList();

      final files = <String>[];
      for (final dir in dirs) {
        files.addAll(await _listAudioFiles(dir));
      }

      final total = files.length;
      onScanProgress?.call(
        ScanProgress(processed: 0, total: total, running: true),
      );
      onProgress?.call(ScanProgress(processed: 0, total: total, running: true));

      final newSongsMap = <String, Song>{};
      var processed = 0;
      final coverCache = CoverCacheService();

      for (final filePath in files) {
        final metadata = await LocalMetadataReader.read(filePath);
        final id = _genId(filePath);
        final fileName = p.basenameWithoutExtension(filePath);

        final title = (metadata.title?.isNotEmpty ?? false)
            ? metadata.title!
            : fileName;
        final artist = (metadata.artist?.isNotEmpty ?? false)
            ? metadata.artist!
            : '未知艺术家';
        final album = (metadata.album?.isNotEmpty ?? false)
            ? metadata.album!
            : '未知专辑';

        // 内嵌歌词：记下「有没有」「是不是逐字」，快速匹配页据此筛选，
        // 不用为了看状态把每个文件再读一遍。
        final embeddedLyric = metadata.lyrics?.trim() ?? '';
        final hasEmbeddedLyric = embeddedLyric.isNotEmpty;
        final hasEmbeddedWordLyric =
            hasEmbeddedLyric && detectWordLyricFormat(embeddedLyric) != null;

        final song = Song(
          id: id,
          title: title,
          artist: artist,
          album: album,
          duration: metadata.durationSeconds ?? 0,
          source: 'local',
          filePath: filePath,
          sourceUrl: filePath,
          hasCover: metadata.artwork != null,
          coverKey: _genCoverKey(filePath),
          bitrate: _inferBitrateFromExtension(filePath),
          year: metadata.year,
          genre: metadata.genre,
          comment: metadata.comment,
          hasLyric: hasEmbeddedLyric,
          hasWordLyric: hasEmbeddedWordLyric,
        );

        final existing = _songsMap[id];
        newSongsMap[id] = existing != null
            ? _mergePreferFilled(existing, song)
            : song;

        // 内嵌封面写入封面缓存，列表与播放页即可显示。
        final artwork = metadata.artwork;
        if (artwork != null && artwork.isNotEmpty) {
          unawaited(coverCache.putArtwork(id, artwork));
        }

        processed++;
        if (processed % 10 == 0 || processed == total) {
          final progress = ScanProgress(
            processed: processed,
            total: total,
            running: true,
          );
          onScanProgress?.call(progress);
          onProgress?.call(progress);
        }
      }

      _songsMap.clear();
      _songsMap.addAll(newSongsMap);
      await _flushIndex();

      final doneProgress = ScanProgress(
        processed: total,
        total: total,
        running: false,
      );
      onScanProgress?.call(doneProgress);
      onProgress?.call(doneProgress);
      return true;
    } catch (e) {
      debugPrint('[LocalMusic] 桌面端扫描失败: $e');
      final errorProgress = ScanProgress(
        processed: 0,
        total: 0,
        running: false,
      );
      onScanProgress?.call(errorProgress);
      onProgress?.call(errorProgress);
      return false;
    }
  }

  /// 递归列出目录下的音频文件。
  Future<List<String>> _listAudioFiles(String dir) async {
    final result = <String>[];
    try {
      final directory = Directory(dir);
      if (!await directory.exists()) return result;
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final path = entity.path;
        if (!LocalMetadataReader.isAudioFile(path)) continue;
        result.add(path);
      }
    } catch (e) {
      debugPrint('[LocalMusic] 扫描目录失败 $dir: $e');
    }
    result.sort();
    return result;
  }

  Future<Uint8List?> getCoverData(int mediaStoreId) async {
    try {
      return await _audioQuery.queryArtwork(
        mediaStoreId,
        ArtworkType.AUDIO,
        quality: 100,
        size: 1024,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> clearIndex() async {
    await init();
    _songsMap.clear();
    await _flushIndex();
  }

  /// [forceOverwrite] 为 true 时直接覆盖所有字段（用于精准匹配等用户主动操作），
  /// 为 false 时使用合并策略保留已有非空值（用于批量匹配等自动操作）。
  Future<void> upsertSong(Song song, {bool forceOverwrite = false}) async {
    await init();
    if (forceOverwrite) {
      _songsMap[song.id] = song;
    } else {
      final existing = _songsMap[song.id];
      if (existing != null) {
        _songsMap[song.id] = _mergePreferFilled(existing, song);
      } else {
        _songsMap[song.id] = song;
      }
    }
    await _saveIndex();
  }

  /// 从本地音乐库删除歌曲，并尽力删除磁盘上的音频文件。
  /// 磁盘文件删除失败（如权限不足）不影响索引移除，返回是否成功从索引移除。
  Future<bool> deleteSong(String id) async {
    await init();
    final song = _songsMap[id];
    if (song == null) return false;
    _songsMap.remove(id);
    await _flushIndex();

    final filePath = song.filePath;
    if (filePath != null && filePath.isNotEmpty) {
      try {
        final file = File(filePath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        debugPrint('[LocalMusic] 删除文件失败: $filePath ($e)');
      }
    }
    return true;
  }

  /// 批量删除本地歌曲，返回实际从索引中移除的数量。
  ///
  /// 与逐首调用 [deleteSong] 的区别：索引只写一次。批量删除时逐首写盘会让
  /// 耗时随数量线性放大。
  Future<int> deleteSongs(Iterable<String> ids) async {
    await init();
    final filePaths = <String>[];
    var removed = 0;
    for (final id in ids) {
      final song = _songsMap.remove(id);
      if (song == null) continue;
      removed++;
      final filePath = song.filePath;
      if (filePath != null && filePath.isNotEmpty) filePaths.add(filePath);
    }
    if (removed == 0) return 0;

    await _flushIndex();
    for (final filePath in filePaths) {
      try {
        final file = File(filePath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        debugPrint('[LocalMusic] 删除文件失败: $filePath ($e)');
      }
    }
    return removed;
  }

  Song _mergePreferFilled(Song a, Song b) {
    String pick(String? x, String? y, [String fallback = '']) {
      if (x != null &&
          x.isNotEmpty &&
          x != '未知艺术家' &&
          x != '未知曲目' &&
          x != '未知专辑')
        return x;
      if (y != null &&
          y.isNotEmpty &&
          y != '未知艺术家' &&
          y != '未知曲目' &&
          y != '未知专辑')
        return y;
      return fallback;
    }

    return Song(
      id: a.id,
      title: pick(a.title, b.title, '未知曲目'),
      artist: pick(a.artist, b.artist, '未知艺术家'),
      album: pick(a.album, b.album, '未知专辑'),
      duration: a.duration > 0 ? a.duration : b.duration,
      coverUrl: a.coverUrl ?? b.coverUrl,
      sourceUrl: a.sourceUrl ?? b.sourceUrl,
      lyricUrl: a.lyricUrl ?? b.lyricUrl,
      source: a.source ?? b.source ?? 'local',
      filePath: a.filePath ?? b.filePath,
      hasCover: a.hasCover || b.hasCover,
      coverKey: a.coverKey ?? b.coverKey,
      lrc: a.lrc ?? b.lrc,
      bitrate: a.bitrate ?? b.bitrate,
      sampleRate: a.sampleRate ?? b.sampleRate,
      channels: a.channels ?? b.channels,
      year: a.year ?? b.year,
      mediaStoreId: a.mediaStoreId ?? b.mediaStoreId,
      genre: a.genre ?? b.genre,
      comment: a.comment ?? b.comment,
      hasLyric: a.hasLyric || b.hasLyric,
      hasWordLyric: a.hasWordLyric || b.hasWordLyric,
    );
  }

  /// 标记索引有变化（延迟落盘：攒一批再写，避免高频写盘）。
  Future<void> _saveIndex() async {
    _writer.schedule();
  }

  /// 立刻把索引写入数据库（扫描完成 / 用户主动操作后调用）。
  ///
  /// 写完再 checkpoint 一次：应用退出时进程会被直接结束，不 checkpoint
  /// 的话刚扫描出来的歌曲会丢（重启后本地页面是空的）。
  Future<void> _flushIndex() async {
    await _writer.writeNow();
    await AppDatabase.checkpoint();
  }

  /// 扫描目录立即写入设置文件（`AppData/config/settings.json`）。
  ///
  /// 目录是用户主动添加的配置，不能等歌曲索引的延迟写：临时数据库打不开时
  /// 也要保证下次启动能靠设置里的路径自动重新扫描。
  Future<void> _persistDirectories() async {
    try {
      final prefs = await AppPreferences.getInstance();
      await prefs.setStringList(_dirsKey, _scannedDirs.toList());
    } catch (e) {
      debugPrint('[LocalMusic] 保存扫描目录失败: $e');
    }
  }

  Future<void> _persistIndex() async {
    await _persistDirectories();
    final db = await AppDatabase.cacheDatabase();
    final songs = _songsMap.values.toList();
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.transaction((txn) async {
      await txn.delete('local_songs');
      final batch = txn.batch();
      for (final song in songs) {
        batch.insert('local_songs', {
          'id': song.id,
          'title': song.title,
          'artist': song.artist,
          'album': song.album,
          'file_path': song.filePath ?? '',
          'source': song.source ?? 'local',
          'updated_at': now,
          'data': jsonEncode(song.toPersistJson()),
        });
      }
      await batch.commit(noResult: true);
    });
  }

  /// 首次启动：把旧设置文件里的扫描目录 / 本地歌曲列表导入数据库。
  Future<void> _importLegacy() async {
    try {
      final prefs = await AppPreferences.getInstance();
      final dirsJson = prefs.getStringList(_dirsKey) ?? [];
      _scannedDirs.addAll(dirsJson);

      // 旧版本把扫描目录放在数据库的 local_dirs 表里，一并搬回设置。
      try {
        final db = await AppDatabase.cacheDatabase();
        final dirRows = await db.query('local_dirs', orderBy: 'added_at ASC');
        for (final row in dirRows) {
          _scannedDirs.add('${row['path']}');
        }
      } catch (_) {
        // 表不存在（老版本数据库）时忽略。
      }

      final songsJson = prefs.getString(_songsKey);
      if (songsJson != null) {
        final list = jsonDecode(songsJson) as List;
        for (final s in list) {
          final song = Song.fromJson(s as Map<String, dynamic>);
          _songsMap[song.id] = song;
        }
      }

      if (dirsJson.isNotEmpty || _songsMap.isNotEmpty) {
        await _persistIndex();
        // 只有真正落盘了才删旧数据，避免降级模式下索引丢失。
        await AppDatabase.removeLegacyKey(_songsKey);
        debugPrint('[LocalMusic] 已从旧设置迁移本地音乐索引');
      }
    } catch (e) {
      debugPrint('[LocalMusic] 迁移旧索引失败: $e');
    }
  }
}
