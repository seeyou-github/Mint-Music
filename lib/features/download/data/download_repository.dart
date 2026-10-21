import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/storage/app_preferences.dart';
import '../../../core/platform/download_paths.dart';
import '../../../core/platform/media_scanner.dart';
import '../../../core/platform/permission_helper.dart';
import '../../../shared/services/cover_fetcher.dart';
import '../domain/models/download_task.dart';
import '../domain/services/tag_write_service.dart';
import '../../player/domain/models/song.dart';
import '../../player/domain/models/lyric_line.dart';

/// 下载地址获取器。
///
/// 返回地址以及实际使用的音源 id（内置源会由插件解析地址，换源后下载列表
/// 里显示的来源也跟着变）。
typedef UrlFetcher =
    Future<({String url, String? source})?> Function(DownloadTask task);
typedef TagWriteOptionsFetcher = TagWriteOptions Function();
typedef LyricFetcher = Future<String?> Function(Song song);
typedef LyricResultFetcher = Future<LyricResult?> Function(Song song);
typedef CoverUrlFetcher = Future<String?> Function(Song song);
typedef QualityValidator = List<String> Function(String sourceId);

class TagWriteOptions {
  final bool basicInfo;
  final bool cover;
  final bool lyrics;
  final bool downloadLyrics;
  final String lyricFormat;

  const TagWriteOptions({
    this.basicInfo = true,
    this.cover = true,
    this.lyrics = true,
    this.downloadLyrics = false,
    this.lyricFormat = 'word-by-word',
  });
}

class DownloadRepository {
  static const _maxRetries = 3;

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(minutes: 10),
  ));
  final List<DownloadTask> _tasks = [];
  final Map<String, CancelToken> _cancelTokens = {};
  final Map<String, DateTime> _lastProgressTime = {};
  final Map<String, int> _lastProgressBytes = {};
  final StreamController<List<DownloadTask>> _taskController =
      StreamController<List<DownloadTask>>.broadcast();

  int _maxConcurrent = 3;
  int _activeDownloads = 0;
  final Set<String> _initializingTasks = {};
  final Map<String, bool> _fileLocks = {};
  Future<void>? _initFuture;
  String _downloadDir = defaultDownloadDirSync();

  /// 运行期是否通过 [updateSettings] 显式指定过下载目录。
  ///
  /// 为 true 时初始化不会再从持久化配置里覆盖，避免刚在设置里改完目录、
  /// 下载器初始化恰好晚一步时被旧值覆盖。
  bool _dirFromSettings = false;
  bool _wifiOnly = false;
  UrlFetcher? _urlFetcher;
  void Function(String dirPath)? onDirectoryChanged;
  final TagWriteService _tagWriteService = TagWriteService();
  TagWriteOptionsFetcher? _tagWriteOptionsFetcher;
  LyricFetcher? _lyricFetcher;
  LyricResultFetcher? _lyricResultFetcher;
  CoverUrlFetcher? _coverFetcher;
  QualityValidator? _qualityValidator;

  void Function(DownloadTask task, {Color? backgroundColor})? onTaskStarted;
  void Function(DownloadTask task, {Color? backgroundColor})? onTaskCompleted;
  void Function(DownloadTask task, String error, {Color? backgroundColor})? onTaskError;

  Stream<List<DownloadTask>> get taskStream async* {
    yield List.unmodifiable(_tasks);
    yield* _taskController.stream;
  }
  int get maxConcurrent => _maxConcurrent;
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  void setUrlFetcher(UrlFetcher fetcher) => _urlFetcher = fetcher;
  void setTagWriteOptionsFetcher(TagWriteOptionsFetcher fetcher) => _tagWriteOptionsFetcher = fetcher;
  void setLyricFetcher(LyricFetcher fetcher) => _lyricFetcher = fetcher;
  void setLyricResultFetcher(LyricResultFetcher fetcher) => _lyricResultFetcher = fetcher;
  void setCoverFetcher(CoverUrlFetcher fetcher) => _coverFetcher = fetcher;
  void setQualityValidator(QualityValidator validator) => _qualityValidator = validator;

  Future<void> init({
    String? downloadDir,
    bool? wifiOnly,
    int? maxConcurrent,
  }) {
    // 只初始化一次；并发调用方（provider 的异步初始化与首次下载的
    // _ensureInitialized）共享同一个 Future，避免目录被重复改写。
    return _initFuture ??= _init(
      downloadDir: downloadDir,
      wifiOnly: wifiOnly,
      maxConcurrent: maxConcurrent,
    );
  }

  Future<void> _init({
    String? downloadDir,
    bool? wifiOnly,
    int? maxConcurrent,
  }) async {
    if (!_dirFromSettings) {
      if (downloadDir != null && downloadDir.isNotEmpty) {
        _downloadDir = downloadDir;
      } else {
        // 没有显式传入目录时（例如设置初始化失败 / 超时），直接从持久化
        // 配置里读取，绝不能把硬编码的 Android 默认路径当成真实目录。
        _downloadDir = await _readPersistedDownloadDir();
      }
    }
    onDirectoryChanged?.call(_downloadDir);
    if (wifiOnly != null) _wifiOnly = wifiOnly;
    if (maxConcurrent != null) _maxConcurrent = maxConcurrent;

    // 下载列表只保存在运行内存里：退出应用就清空，不再落库。

    // 修正旧版本写错的路径：先迁移桌面上被写到 Android 默认目录里的
    // 已完成文件，再让所有未完成任务跟随当前下载目录。
    await _migrateLegacyCompletedFiles();
    _retargetUnfinishedTasks();

    // 验证已完成任务的文件是否存在
    for (int i = 0; i < _tasks.length; i++) {
      if (_tasks[i].status == DownloadStatus.completed) {
        final file = File(_tasks[i].filePath);
        if (!await file.exists()) {
          // 文件被删除 / 移动：单独状态，界面上显示「文件已删除」而不是「失败」
          _tasks[i] = _tasks[i].copyWith(
            status: DownloadStatus.fileMissing,
            error: '文件已删除或移动',
          );
        }
      }
    }

    _emitUpdate();
    _processQueue();
  }

  /// 保证构建文件路径前已经拿到真实的下载目录。
  ///
  /// [downloadRepositoryProvider] 的初始化是异步的，首次点下载时可能还没
  /// 执行到 [init]；此时直接从持久化设置读取目录，避免用默认值写到错误位置。
  Future<void> _ensureInitialized() async {
    final existing = _initFuture;
    if (existing != null) {
      try {
        await existing;
      } catch (e) {
        debugPrint('[DownloadRepository] 初始化失败: $e');
      }
      return;
    }
    await init();
  }

  Future<String> _readPersistedDownloadDir() async {
    try {
      final prefs = await AppPreferences.getInstance();
      final persisted = prefs.getString('download_dir');
      if (persisted != null && persisted.isNotEmpty) return persisted;
    } catch (e) {
      debugPrint('[DownloadRepository] 读取下载目录失败: $e');
    }
    return defaultDownloadDirSync();
  }

  /// 旧版本在桌面端把下载目录解析成了 `/storage/emulated/...`。把仍然存在
  /// 的文件移动到当前下载目录，并修正对应任务路径。
  Future<void> _migrateLegacyCompletedFiles() async {
    if (Platform.isAndroid) return;
    var changed = false;
    for (var i = 0; i < _tasks.length; i++) {
      final task = _tasks[i];
      if (task.status != DownloadStatus.completed) continue;
      final normalized = task.filePath.replaceAll('\\', '/');
      if (!normalized.startsWith(legacyAndroidDownloadDir)) continue;
      if (_isPathInDownloadDir(task.filePath)) continue;

      final targetPath = DownloadTask.buildFilePathSync(
        downloadDir: _downloadDir,
        title: task.song.title,
        artist: task.song.artist,
        quality: task.quality,
        extension: _extensionOf(task.filePath),
      );
      try {
        final source = File(task.filePath);
        if (!await source.exists()) continue;
        final target = File(targetPath);
        // 不覆盖已有文件，避免误删用户数据。
        if (await target.exists()) continue;
        await target.parent.create(recursive: true);
        await source.rename(targetPath);
        _tasks[i] = task.copyWith(filePath: targetPath);
        changed = true;
      } catch (e) {
        debugPrint('[DownloadRepository] 迁移旧下载文件失败: $e');
      }
    }
    if (changed) {
      unawaited(_saveTasks());
      _emitUpdate();
    }
  }

  /// 未完成任务的路径跟随当前下载目录。
  ///
  /// 旧版本遗留的任务（例如指向 `/storage/emulated/...`）如果继续重试，
  /// 会一直写到错误位置，因此启动恢复或目录变化时统一重算路径。
  void _retargetUnfinishedTasks() {
    var changed = false;
    for (var i = 0; i < _tasks.length; i++) {
      final next = _retargeted(_tasks[i]);
      if (!identical(next, _tasks[i])) {
        _tasks[i] = next;
        changed = true;
      }
    }
    if (changed) {
      unawaited(_saveTasks());
      _emitUpdate();
    }
  }

  /// 返回路径已对齐当前下载目录的任务；无需调整时原样返回。
  DownloadTask _retargeted(DownloadTask task) {
    // 正在下载的任务路径已经被 _downloadFile 使用，中途修改会与临时文件
    // 不一致，交给下次启动或重试时处理。
    if (task.status == DownloadStatus.completed ||
        task.status == DownloadStatus.downloading ||
        task.filePath.isEmpty ||
        _isPathInDownloadDir(task.filePath)) {
      return task;
    }
    return task.copyWith(
      filePath: DownloadTask.buildFilePathSync(
        downloadDir: _downloadDir,
        title: task.song.title,
        artist: task.song.artist,
        quality: task.quality,
        extension: _extensionOf(task.filePath),
      ),
    );
  }

  /// 从旧路径取扩展名（不带点，与 [DownloadTask.buildFilePath] 的约定一致）。
  String _extensionOf(String filePath) {
    final ext = p.extension(filePath);
    return ext.startsWith('.') ? ext.substring(1) : ext;
  }

  bool _isPathInDownloadDir(String filePath) {
    String normalize(String value) =>
        value.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    final dir = normalize(_downloadDir);
    final file = normalize(filePath);
    return dir.isNotEmpty && file.startsWith('$dir/');
  }

  void updateSettings({String? downloadDir, bool? wifiOnly, int? maxConcurrent}) {
    if (downloadDir != null &&
        downloadDir.isNotEmpty &&
        downloadDir != _downloadDir) {
      _downloadDir = downloadDir;
      _dirFromSettings = true;
      // 下载目录改变后，未完成的任务改写到新目录，避免重试时继续写旧位置。
      _retargetUnfinishedTasks();
      onDirectoryChanged?.call(_downloadDir);
    }
    if (wifiOnly != null) _wifiOnly = wifiOnly;
    if (maxConcurrent != null) {
      _maxConcurrent = maxConcurrent;
      _processQueue();
    }
  }

  // ==================== 核心操作 ====================

  /// 检查存储权限。公共目录需要 MANAGE_EXTERNAL_STORAGE。
  Future<bool> _ensureStoragePermission() async {
    if (!isPublicDirectory(_downloadDir)) return true;
    final hasAccess = await hasWriteAccess(_downloadDir);
    if (hasAccess) return true;
    final granted = await requestManageStorage();
    return granted;
  }

  /// 添加下载任务（照搬 CeruMusic downloadSingleSong + addTask 逻辑）
  Future<String> addTask({
    required Song song,
    String? url,
    String quality = '320k',
    int priority = 0,
  }) async {
    // 首次下载时 provider 的异步初始化可能尚未完成，先确保下载目录已就绪，
    // 避免任务路径落到默认目录（Windows 上会变成 <盘符>:\storage\...）。
    await _ensureInitialized();

    // 检查存储权限
    if (!await _ensureStoragePermission()) {
      throw Exception('没有存储权限，请在系统设置中允许「所有文件访问权限」');
    }

    // 检查 WiFi 限制
    if (_wifiOnly) {
      final results = await Connectivity().checkConnectivity();
      if (results.contains(ConnectivityResult.none)) {
        throw Exception('当前无网络连接');
      }
    }

    // 验证音质是否受当前音源支持
    final sourceId = song.source ?? 'wy';
    final supportedQualities = _qualityValidator?.call(sourceId) ??
        (sourceId == 'local' ? <String>[] : ['128k', '320k', 'flac']);
    if (sourceId != 'local' && !supportedQualities.contains(quality)) {
      throw Exception('UNSUPPORTED_QUALITY:$quality');
    }

    // 构建文件路径
    final filePath = await DownloadTask.buildFilePath(
      downloadDir: _downloadDir,
      title: song.title,
      artist: song.artist,
      quality: quality,
    );

    // 重复检测（照搬 CeruMusic 逻辑）
    for (final existing in _tasks) {
      if (existing.filePath == filePath) {
        if (existing.status == DownloadStatus.completed) {
          final file = File(filePath);
          if (await file.exists()) {
            throw Exception('歌曲已下载完成');
          }
        }
        if (existing.status == DownloadStatus.downloading ||
            existing.status == DownloadStatus.queued ||
            existing.status == DownloadStatus.paused) {
          throw Exception('歌曲正在下载中');
        }
      }
    }

    // 照搬 CeruMusic downloadSingleSong：先获取 URL，再创建任务
    String resolvedUrl = url ?? '';
    var taskSong = song;
    if (resolvedUrl.isEmpty && _urlFetcher != null) {
      final tempTask = DownloadTask(
        id: '',
        song: song,
        url: '',
        quality: quality,
        filePath: filePath,
        priority: priority,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      final fetched = await _urlFetcher!(tempTask);
      if (fetched != null && fetched.url.isNotEmpty) {
        resolvedUrl = fetched.url;
        // 换源后（内置源改用其它插件解析）同步歌曲来源，下载列表里显示出来。
        final resolvedSource = fetched.source;
        if (resolvedSource != null &&
            resolvedSource.isNotEmpty &&
            resolvedSource != song.source) {
          taskSong = song.copyWith(source: resolvedSource);
        }
      }
    }

    final task = DownloadTask(
      id: DownloadTask.generateId(),
      song: taskSong,
      url: resolvedUrl,
      quality: quality,
      filePath: filePath,
      priority: priority,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );

    _tasks.add(task);
    await _flushTasks();
    _emitUpdate();
    _processQueue();
    onTaskStarted?.call(task);
    return task.id;
  }

  /// 批量添加下载任务
  Future<void> addTasks(List<({Song song, String quality})> items) async {
    for (int i = 0; i < items.length; i++) {
      try {
        await addTask(
          song: items[i].song,
          quality: items[i].quality,
          priority: i,
        );
      } catch (e) {
        debugPrint('[DownloadRepository] 批量添加失败: $e');
      }
    }
  }

  /// 暂停任务
  Future<void> pauseTask(String taskId) async {
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index == -1) return;

    final task = _tasks[index];
    if (task.status != DownloadStatus.downloading &&
        task.status != DownloadStatus.queued) {
      return;
    }

    _initializingTasks.remove(taskId);
    _fileLocks.remove(task.filePath);
    _cancelTokens[taskId]?.cancel();
    _cancelTokens.remove(taskId);
    _lastProgressTime.remove(taskId);
    _lastProgressBytes.remove(taskId);

    if (task.status == DownloadStatus.downloading) {
      _activeDownloads--;
    }

    _tasks[index] = task.copyWith(status: DownloadStatus.paused);
    await _flushTasks();
    _emitUpdate();
    _processQueue();
  }

  /// 恢复任务（照搬 CeruMusic resumeTask：放入队列头部）
  Future<void> resumeTask(String taskId) async {
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index == -1) return;

    final task = _tasks[index];
    if (task.status != DownloadStatus.paused &&
        task.status != DownloadStatus.error &&
        task.status != DownloadStatus.cancelled &&
        task.status != DownloadStatus.fileMissing) {
      return;
    }

    _initializingTasks.remove(taskId);
    _fileLocks.remove(task.filePath);

    _tasks[index] = _retargeted(task).copyWith(
      status: DownloadStatus.queued,
      retries: 0,
      error: null,
    );
    await _flushTasks();
    _emitUpdate();
    _processQueue();
  }

  /// 重试任务
  Future<void> retryTask(String taskId) async {
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index == -1) return;

    final task = _tasks[index];
    _initializingTasks.remove(taskId);
    _fileLocks.remove(task.filePath);

    _tasks[index] = _retargeted(task).copyWith(
      status: DownloadStatus.queued,
      progress: 0,
      downloadedSize: 0,
      speed: 0,
      remainingTime: null,
      retries: 0,
      error: null,
    );
    await _flushTasks();
    _emitUpdate();
    _processQueue();
  }

  /// 取消任务
  Future<void> cancelTask(String taskId) async {
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index == -1) return;

    final task = _tasks[index];
    _initializingTasks.remove(taskId);
    _fileLocks.remove(task.filePath);

    if (task.status == DownloadStatus.downloading) {
      _cancelTokens[taskId]?.cancel();
      _cancelTokens.remove(taskId);
      _lastProgressTime.remove(taskId);
      _lastProgressBytes.remove(taskId);
      _activeDownloads--;

      final tempFile = File('${task.filePath}.temp');
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }

    _tasks[index] = task.copyWith(status: DownloadStatus.cancelled);
    await _flushTasks();
    _emitUpdate();
    _processQueue();
  }

  /// 删除任务
  Future<void> deleteTask(String taskId, {bool deleteFile = false}) async {
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index == -1) return;

    final task = _tasks[index];

    _initializingTasks.remove(taskId);
    _fileLocks.remove(task.filePath);

    if (task.status == DownloadStatus.downloading) {
      _cancelTokens[taskId]?.cancel();
      _cancelTokens.remove(taskId);
      _lastProgressTime.remove(taskId);
      _lastProgressBytes.remove(taskId);
      _activeDownloads--;
    }

    if (deleteFile) {
      final file = File(task.filePath);
      if (await file.exists()) {
        await file.delete();
      }
      final tempFile = File('${task.filePath}.temp');
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }

    _tasks.removeAt(index);
    await _flushTasks();
    _emitUpdate();
    _processQueue();
  }

  /// 暂停所有任务
  Future<void> pauseAllTasks() async {
    for (int i = 0; i < _tasks.length; i++) {
      final task = _tasks[i];
      if (task.status == DownloadStatus.downloading) {
        _cancelTokens[task.id]?.cancel();
        _cancelTokens.remove(task.id);
        _lastProgressTime.remove(task.id);
        _lastProgressBytes.remove(task.id);
        _activeDownloads--;
        _initializingTasks.remove(task.id);
        _fileLocks.remove(task.filePath);
        _tasks[i] = task.copyWith(status: DownloadStatus.paused);
      } else if (task.status == DownloadStatus.queued) {
        _initializingTasks.remove(task.id);
        _fileLocks.remove(task.filePath);
        _tasks[i] = task.copyWith(status: DownloadStatus.paused);
      }
    }
    await _saveTasks();
    _emitUpdate();
    _processQueue();
  }

  /// 恢复所有暂停的任务
  Future<void> resumeAllTasks() async {
    final pausedTasks = _tasks
        .where((t) => t.status == DownloadStatus.paused)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (final task in pausedTasks) {
      await resumeTask(task.id);
    }
  }

  /// 清空任务
  Future<void> clearTasks(String type) async {
    final toRemove = <String>[];
    for (final task in _tasks) {
      switch (type) {
        case 'queue':
          if (task.status == DownloadStatus.downloading ||
              task.status == DownloadStatus.queued ||
              task.status == DownloadStatus.paused) {
            toRemove.add(task.id);
          }
          break;
        case 'completed':
          if (task.status == DownloadStatus.completed) {
            toRemove.add(task.id);
          }
          break;
        case 'failed':
          if (task.status == DownloadStatus.error ||
              task.status == DownloadStatus.cancelled ||
              task.status == DownloadStatus.fileMissing) {
            toRemove.add(task.id);
          }
          break;
        case 'all':
          toRemove.add(task.id);
          break;
      }
    }
    _initializingTasks.clear();
    _fileLocks.clear();
    _activeDownloads = 0;
    for (final id in toRemove) {
      await deleteTask(id);
    }
  }

  /// 设置最大并发数
  void setMaxConcurrent(int max) {
    _maxConcurrent = max;
    _processQueue();
  }

  // ==================== 队列处理 ====================

  void _processQueue() {
    while (_activeDownloads + _initializingTasks.length < _maxConcurrent) {
      int bestIndex = -1;
      int bestPriority = 999999;
      for (int i = 0; i < _tasks.length; i++) {
        if (_tasks[i].status == DownloadStatus.queued) {
          if (_tasks[i].priority < bestPriority) {
            bestPriority = _tasks[i].priority;
            bestIndex = i;
          }
        }
      }
      if (bestIndex == -1) break;

      final task = _tasks[bestIndex];
      _startTask(task.id);
    }
  }

  Future<void> _startTask(String taskId) async {
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index == -1) return;

    _initializingTasks.add(taskId);

    _tasks[index] = _tasks[index].copyWith(status: DownloadStatus.downloading);
    _emitUpdate();

    try {
      var task = _tasks[index];
      String url = task.url;
      if (url.isEmpty && _urlFetcher != null) {
        final fetched = await _urlFetcher!(task);
        if (fetched == null || fetched.url.isEmpty) {
          _initializingTasks.remove(taskId);
          _markError(taskId, '无法获取播放链接');
          return;
        }
        url = fetched.url;
        task = task.copyWith(url: url);
        final resolvedSource = fetched.source;
        if (resolvedSource != null &&
            resolvedSource.isNotEmpty &&
            resolvedSource != task.song.source) {
          task = task.copyWith(song: task.song.copyWith(source: resolvedSource));
        }
        _tasks[index] = task;
      }

      if (url.isEmpty) {
        _initializingTasks.remove(taskId);
        _markError(taskId, '无法获取播放链接');
        return;
      }

      if (_fileLocks.containsKey(task.filePath)) {
        _initializingTasks.remove(taskId);
        _markError(taskId, '歌曲正在下载中');
        return;
      }
      _fileLocks[task.filePath] = true;

      _initializingTasks.remove(taskId);
      _activeDownloads++;

      await _downloadFile(taskId, url);
    } catch (e) {
      debugPrint('[DownloadRepository] 下载失败: $e');
      _initializingTasks.remove(taskId);
      final idx = _tasks.indexWhere((t) => t.id == taskId);
      final filePath = idx != -1 ? _tasks[idx].filePath : '';
      _handleError(taskId, e.toString(), tempFilePath: filePath);
    }
  }

  void _markError(String taskId, String error) {
    final idx = _tasks.indexWhere((t) => t.id == taskId);
    if (idx != -1) {
      _tasks[idx] = _tasks[idx].copyWith(
        status: DownloadStatus.error,
        error: error,
        speed: 0,
      );
      unawaited(_flushTasks());
      _emitUpdate();
    }
    _processQueue();
  }

  Future<void> _downloadFile(String taskId, String url) async {
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index == -1) return;

    final task = _tasks[index];
    final filePath = task.filePath;
    final tempPath = '$filePath.temp';

    final cancelToken = CancelToken();
    _cancelTokens[taskId] = cancelToken;
    _lastProgressTime[taskId] = DateTime.now();
    _lastProgressBytes[taskId] = 0;

    try {
      // 检查是否有已下载的部分（支持断点续传）
      final tempFile = File(tempPath);
      int startByte = 0;
      if (await tempFile.exists()) {
        startByte = await tempFile.length();
        _tasks[index] = _tasks[index].copyWith(
          downloadedSize: startByte,
        );
        _emitUpdate();
      }

      final headers = <String, String>{};
      if (startByte > 0) {
        headers['Range'] = 'bytes=$startByte-';
      }

      final response = await _dio.download(
        url,
        tempPath,
        cancelToken: cancelToken,
        deleteOnError: false,
        options: Options(headers: headers),
        onReceiveProgress: (received, total) {
          final totalWithOffset = total > 0 ? total + startByte : 0;
          final receivedWithOffset = received + startByte;

          // 计算速度
          final now = DateTime.now();
          final lastTime = _lastProgressTime[taskId];
          final lastBytes = _lastProgressBytes[taskId] ?? 0;

          double speed = 0;
          int? remainingTime;
          if (lastTime != null && totalWithOffset > 0) {
            final elapsed = now.difference(lastTime).inMilliseconds;
            if (elapsed > 0) {
              final bytesDiff = receivedWithOffset - lastBytes;
              speed = bytesDiff * 1000 / elapsed; // bytes/s
              final remaining = totalWithOffset - receivedWithOffset;
              if (speed > 0) {
                remainingTime = (remaining / speed).round();
              }
            }
          }

          _lastProgressTime[taskId] = now;
          _lastProgressBytes[taskId] = receivedWithOffset;

          final progress = totalWithOffset > 0
              ? receivedWithOffset / totalWithOffset
              : 0.0;

          final idx = _tasks.indexWhere((t) => t.id == taskId);
          if (idx != -1) {
            _tasks[idx] = _tasks[idx].copyWith(
              progress: progress.clamp(0.0, 1.0),
              totalSize: totalWithOffset,
              downloadedSize: receivedWithOffset,
              speed: speed,
              remainingTime: remainingTime,
            );
            _emitUpdate();
          }
        },
      );

      if (response.statusCode == 200 || response.statusCode == 206) {
        final tempFile = File(tempPath);
        if (await tempFile.exists()) {
          await tempFile.rename(filePath);
        }

        String finalPath = filePath;
        try {
          final detected = await _detectAudioFormat(filePath);
          final shouldExt = _extForFormat(detected);
          final curExt = filePath.substring(filePath.lastIndexOf('.'));
          if (shouldExt.isNotEmpty && shouldExt != curExt) {
            final baseNoExt = filePath.substring(0, filePath.lastIndexOf('.'));
            var proposed = '$baseNoExt$shouldExt';
            if (await File(proposed).exists()) {
              proposed = '$baseNoExt.${DateTime.now().millisecondsSinceEpoch}$shouldExt';
            }
            await File(filePath).rename(proposed);
            finalPath = proposed;
          }
        } catch (_) {}

        // 写入标签（对齐 CeruMusic processSongFiles 逻辑）
        var coverOk = true;
        try {
          final tagOpts = _tagWriteOptionsFetcher?.call() ?? const TagWriteOptions();
          Song songForTag = task.song;
          debugPrint('[DownloadRepository] 标签写入选项: basicInfo=${tagOpts.basicInfo}, cover=${tagOpts.cover}, lyrics=${tagOpts.lyrics}, downloadLyrics=${tagOpts.downloadLyrics}, lyricFormat=${tagOpts.lyricFormat}');
          debugPrint('[DownloadRepository] 歌词获取器: ${_lyricFetcher != null}, song.lrc: ${songForTag.lrc != null ? "has ${songForTag.lrc!.length} chars" : "null"}');
          if ((tagOpts.lyrics || tagOpts.downloadLyrics) && _lyricResultFetcher != null) {
            try {
              final lyricResult = await _lyricResultFetcher!(songForTag);
              debugPrint('[DownloadRepository] 歌词获取结果: lrc=${lyricResult?.lrc != null ? "has ${lyricResult!.lrc!.length} chars" : "null"}, crlyric=${lyricResult?.crlyric != null ? "has ${lyricResult!.crlyric!.length} chars" : "null"}');
              if (lyricResult != null) {
                // 优先使用逐字歌词（crlyric），否则使用标准歌词（lrc）
                final preferredLyric = tagOpts.lyricFormat == 'word-by-word'
                    ? (lyricResult.crlyric?.isNotEmpty == true ? lyricResult.crlyric : lyricResult.lrc)
                    : lyricResult.lrc;
                if (preferredLyric != null && preferredLyric.isNotEmpty) {
                  songForTag = songForTag.copyWith(lrc: preferredLyric);
                }
              }
            } catch (e) {
              debugPrint('[DownloadRepository] 获取歌词失败: $e');
            }
          } else if ((tagOpts.lyrics || tagOpts.downloadLyrics) && _lyricFetcher != null) {
            try {
              final lrc = await _lyricFetcher!(songForTag);
              debugPrint('[DownloadRepository] 歌词获取结果: ${lrc != null ? "has ${lrc.length} chars" : "null"}');
              if (lrc != null && lrc.isNotEmpty) {
                songForTag = songForTag.copyWith(lrc: lrc);
              }
            } catch (e) {
              debugPrint('[DownloadRepository] 获取歌词失败: $e');
            }
          }
          // 收集封面地址候选：歌曲自带封面 + 高清封面接口返回的地址。
          final coverCandidates = <String>[];
          void addCover(String? url) {
            if (url == null || url.isEmpty) return;
            if (!coverCandidates.contains(url)) coverCandidates.add(url);
          }

          addCover(songForTag.coverUrl);

          // 优先使用列表里已经加载并缓存好的封面：命中缓存就不再请求高清
          // 封面地址，也不再走网络下载。
          var cachedCover = tagOpts.cover
              ? await CoverFetcher.fetchCached(songForTag.coverUrl)
              : null;
          debugPrint('[DownloadRepository] 本地缓存封面: '
              '${cachedCover != null ? "${cachedCover.length} bytes" : "未命中"}');

          if (tagOpts.cover &&
              cachedCover == null &&
              _coverFetcher != null) {
            try {
              final highResCover = await _coverFetcher!(songForTag);
              debugPrint('[DownloadRepository] 高清封面获取结果: ${highResCover != null ? highResCover.substring(0, highResCover.length.clamp(0, 80)) : "null"}');
              if (highResCover != null && highResCover.isNotEmpty) {
                songForTag = songForTag.copyWith(coverUrl: highResCover);
                addCover(highResCover);
                cachedCover = await CoverFetcher.fetchCached(highResCover);
              }
            } catch (e) {
              debugPrint('[DownloadRepository] 获取高清封面失败: $e');
            }
          }
          final coverWritten = await _tagWriteService.processSongFiles(
            finalPath,
            songForTag,
            basicInfo: tagOpts.basicInfo,
            cover: tagOpts.cover,
            lyrics: tagOpts.lyrics,
            downloadLyrics: tagOpts.downloadLyrics,
            lyricFormat: tagOpts.lyricFormat,
            coverUrls: coverCandidates,
            preloadedCover: cachedCover,
          );
          coverOk = coverWritten;
        } catch (e) {
          debugPrint('[DownloadRepository] 标签写入失败: $e');
        }

        final idx = _tasks.indexWhere((t) => t.id == taskId);
        if (idx != -1) {
          _tasks[idx] = _tasks[idx].copyWith(
            progress: 1.0,
            status: DownloadStatus.completed,
            speed: 0,
            remainingTime: 0,
            filePath: finalPath,
            // 封面没拿到不影响下载成功，只在列表里提示。
            coverMissing: !coverOk,
          );
          await _flushTasks();
          _emitUpdate();
          onTaskCompleted?.call(_tasks[idx]);
          // 通知 MediaStore 扫描新文件，使其在本地音乐中可见
          scanFileInMediaStore(finalPath);
        }
        _fileLocks.remove(filePath);
        _activeDownloads--;
        _processQueue();
      } else {
        final tempFile = File(tempPath);
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
        _handleError(taskId, '下载失败: HTTP ${response.statusCode}', tempFilePath: filePath);
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) return;

      final idx = _tasks.indexWhere((t) => t.id == taskId);
      if (idx != -1) {
        final task = _tasks[idx];
        if (task.retries < _maxRetries) {
          _tasks[idx] = task.copyWith(
            status: DownloadStatus.queued,
            retries: task.retries + 1,
          );
          await _saveTasks();
          _emitUpdate();
          _fileLocks.remove(task.filePath);
          _activeDownloads--;
          _processQueue();
          return;
        }
        final tempFile = File(tempPath);
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
        _handleError(taskId, e.message ?? '下载失败', tempFilePath: task.filePath);
      }
    } catch (e) {
      final idx = _tasks.indexWhere((t) => t.id == taskId);
      if (idx != -1) {
        final task = _tasks[idx];
        if (task.retries < _maxRetries) {
          _tasks[idx] = task.copyWith(
            status: DownloadStatus.queued,
            retries: task.retries + 1,
          );
          await _saveTasks();
          _emitUpdate();
          _fileLocks.remove(task.filePath);
          _activeDownloads--;
          _processQueue();
          return;
        }
        final tempFile = File(tempPath);
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
        _handleError(taskId, e.toString(), tempFilePath: task.filePath);
      }
    } finally {
      _cancelTokens.remove(taskId);
      _lastProgressTime.remove(taskId);
      _lastProgressBytes.remove(taskId);
    }
  }

  void _handleError(String taskId, String error, {String? tempFilePath}) {
    final idx = _tasks.indexWhere((t) => t.id == taskId);
    if (idx != -1) {
      _fileLocks.remove(_tasks[idx].filePath);
      _tasks[idx] = _tasks[idx].copyWith(
        status: DownloadStatus.error,
        error: error,
        speed: 0,
      );
      unawaited(_flushTasks());
      _emitUpdate();
      onTaskError?.call(_tasks[idx], error);
    }
    if (tempFilePath != null) {
      final tempFile = File('$tempFilePath.temp');
      if (tempFile.existsSync()) {
        tempFile.delete();
      }
    }
    _activeDownloads--;
    _processQueue();
  }

  // ==================== 查询 ====================

  List<DownloadTask> getDownloadTasks() => List.unmodifiable(_tasks);

  List<DownloadTask> getTasksByStatus(DownloadStatus status) {
    return _tasks.where((t) => t.status == status).toList();
  }

  bool isSongDownloaded(String songId) {
    return _tasks.any((t) =>
        t.song.id == songId && t.status == DownloadStatus.completed);
  }

  String? getDownloadedPath(String songId) {
    final task = _tasks.cast<DownloadTask?>().firstWhere(
          (t) => t!.song.id == songId && t.status == DownloadStatus.completed,
          orElse: () => null,
        );
    if (task != null) {
      final file = File(task.filePath);
      if (file.existsSync()) return task.filePath;
    }
    return null;
  }

  // ==================== 持久化 ====================

  /// 标记任务列表有变化。
  ///
  /// 下载列表只保存在运行内存里（退出应用即清空），这里不需要落库。
  Future<void> _saveTasks() async {}

  /// 下载列表不落库（只保留在内存里），这里保留调用点是为了少改代码。
  Future<void> _flushTasks() async {}

  /// 下载列表不落库：这里保留一个空实现，方便以后要恢复持久化时再接回来。
  Future<void> _persistTasks() async {}

  void _emitUpdate() {
    if (!_taskController.isClosed) {
      _taskController.add(List.unmodifiable(_tasks));
    }
  }

  // ==================== 格式检测（照搬 CeruMusic detectFormat） ====================

  Future<String> _detectAudioFormat(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return '';
      final raf = await file.open(mode: FileMode.read);
      final header = await raf.read(64);
      await raf.close();

      if (header.length < 4) return '';

      final s3 = String.fromCharCodes(header.sublist(0, 3));
      final s4 = String.fromCharCodes(header.sublist(0, 4));
      final sFtyp = header.length >= 12
          ? String.fromCharCodes(header.sublist(4, 8))
          : '';

      if (s3 == 'ID3') return 'mp3';
      if (s4 == 'fLaC') return 'flac';
      if (header[0] == 0x4f && header[1] == 0x67 && header[2] == 0x67 && header[3] == 0x53) return 'ogg';
      if (header[0] == 0x30 && header[1] == 0x26 && header[2] == 0xb2 && header[3] == 0x75) return 'wma';
      if (header[0] == 0x52 && header[1] == 0x49 && header[2] == 0x46 && header[3] == 0x46 &&
          header[8] == 0x57 && header[9] == 0x41 && header[10] == 0x56 && header[11] == 0x45) {
        return 'wav';
      }
      if (sFtyp == 'ftyp') return 'm4a';
      if (header[0] == 0xff && (header[1] & 0xe0) == 0xe0) return 'mp3';

      return '';
    } catch (_) {
      return '';
    }
  }

  String _extForFormat(String format) {
    switch (format) {
      case 'mp3': return '.mp3';
      case 'flac': return '.flac';
      case 'm4a': return '.m4a';
      case 'wav': return '.wav';
      case 'ogg': return '.ogg';
      case 'wma': return '.wma';
      default: return '';
    }
  }

  void dispose() {
    _dio.close();
    _taskController.close();
  }
}
