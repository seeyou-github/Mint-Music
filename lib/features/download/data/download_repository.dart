import 'dart:async';
import 'dart:io';
import 'dart:ui' show Color;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/storage/app_preferences.dart';
import '../../../core/platform/app_paths.dart';
import '../../../core/platform/download_paths.dart';
import '../../../core/platform/media_scanner.dart';
import '../../../core/platform/permission_helper.dart';
import '../../../shared/services/cover_fetcher.dart';
import '../domain/models/download_task.dart';
import '../domain/services/download_speed_meter.dart';
import '../domain/services/tag_write_service.dart';
import '../../player/domain/models/song.dart';
import '../../player/domain/models/lyric_line.dart';

/// 插件解析出来的下载地址。
///
/// [headers] 是这条地址要求的请求头（B 站 / 网易 CDN 都会校验 Referer），
/// 拿去下载时必须原样带上，否则播放能出声、下载却是 403。
/// [error] 在拿不到地址时给用户看的原因（插件报错 / 音源没给地址）。
class DownloadUrlResult {
  const DownloadUrlResult({
    required this.url,
    this.source,
    this.headers = const <String, String>{},
    this.error,
  });

  final String url;
  final String? source;
  final Map<String, String> headers;
  final String? error;
}

/// 下载地址获取器。
///
/// 返回地址以及实际使用的音源 id（平台歌曲会由插件解析地址，换源后下载列表
/// 里显示的来源也跟着变）。
typedef UrlFetcher = Future<DownloadUrlResult?> Function(DownloadTask task);
typedef TagWriteOptionsFetcher = TagWriteOptions Function();
typedef LyricFetcher = Future<String?> Function(Song song);
typedef LyricResultFetcher = Future<LyricResult?> Function(Song song);
typedef CoverUrlFetcher = Future<String?> Function(Song song);

/// 下载音质校验：按**整首歌**判断，而不是只按 `song.source`。
///
/// 数据源歌曲的 `source` 是数据源插件（不提供播放 / 下载），真正出面解析地址
/// 的是配置的播放源；两者声明的下载音质可能不同（如数据源没有「超清母带」、
/// 播放源有），只按 `song.source` 判断会把能下的档位误判成不支持。
typedef QualityValidator = List<String> Function(Song song);

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
  DownloadRepository();

  static const _maxRetries = 3;

  /// 重试退避：失败后等固定 5 秒再重试，不立刻三连发打同一个地址。
  static const _retryDelay = Duration(seconds: 5);

  /// 任务 id → 最早可重试时间。退避只停失败的那一首，其他任务照常调度。
  final Map<String, DateTime> _retryNotBefore = {};

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 10),
    ),
  );
  final List<DownloadTask> _tasks = [];

  /// 任务 id → 在 [_tasks] 中的下标。
  ///
  /// 分片回调、状态更新都要按 id 找到任务；列表最多几十上百条时，
  /// 每个分片做一次 `indexWhere` 线性扫描属于纯粹的浪费。删除任务时
  /// 重建一次索引（删除本身是 O(n)），其余操作都是 O(1)。
  final Map<String, int> _taskIndex = {};
  final Map<String, CancelToken> _cancelTokens = {};

  /// 每个任务一个速度采样器（按时间窗口取平均，避免速度在「有值 / -」之间闪）。
  final Map<String, DownloadSpeedMeter> _speedMeters = {};

  /// 每个任务上次把进度推给 UI 的时间，用于节流（见 [_progressEmitIntervalMs]）。
  final Map<String, DateTime> _lastProgressEmit = {};

  /// 进度推送节流：分片回调可达每秒数百次，全推给 UI 会让整页列表反复重建。
  static const int _progressEmitIntervalMs = 100;

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
  final TagWriteService _tagWriteService = TagWriteService();
  TagWriteOptionsFetcher? _tagWriteOptionsFetcher;
  LyricFetcher? _lyricFetcher;
  LyricResultFetcher? _lyricResultFetcher;
  CoverUrlFetcher? _coverFetcher;
  QualityValidator? _qualityValidator;

  void Function(DownloadTask task, {Color? backgroundColor})? onTaskStarted;
  void Function(DownloadTask task, {Color? backgroundColor})? onTaskCompleted;
  void Function(DownloadTask task, String error, {Color? backgroundColor})?
  onTaskError;

  Stream<List<DownloadTask>> get taskStream async* {
    yield List.unmodifiable(_tasks);
    yield* _taskController.stream;
  }

  int get maxConcurrent => _maxConcurrent;
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  void setUrlFetcher(UrlFetcher fetcher) => _urlFetcher = fetcher;
  void setTagWriteOptionsFetcher(TagWriteOptionsFetcher fetcher) =>
      _tagWriteOptionsFetcher = fetcher;
  void setLyricFetcher(LyricFetcher fetcher) => _lyricFetcher = fetcher;
  void setLyricResultFetcher(LyricResultFetcher fetcher) =>
      _lyricResultFetcher = fetcher;
  void setCoverFetcher(CoverUrlFetcher fetcher) => _coverFetcher = fetcher;
  void setQualityValidator(QualityValidator validator) =>
      _qualityValidator = validator;

  Future<void> init({String? downloadDir, bool? wifiOnly, int? maxConcurrent}) {
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
    if (wifiOnly != null) _wifiOnly = wifiOnly;
    if (maxConcurrent != null) _maxConcurrent = maxConcurrent;

    // 下载任务只保存在内存里：软件退出即清空，下次启动从空列表开始
    // （已下载的文件不受影响，仍在下载目录里）。

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
      if (persisted != null && persisted.isNotEmpty) {
        // 旧默认目录（`AppData\music`）跟着目录结构改成 `download_music`。
        return AppPaths.normalizeLegacyPath(persisted);
      }
    } catch (e) {
      debugPrint('[DownloadRepository] 读取下载目录失败: $e');
    }
    return defaultDownloadDirSync();
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

  void updateSettings({
    String? downloadDir,
    bool? wifiOnly,
    int? maxConcurrent,
  }) {
    if (downloadDir != null &&
        downloadDir.isNotEmpty &&
        downloadDir != _downloadDir) {
      _downloadDir = downloadDir;
      _dirFromSettings = true;
      // 下载目录改变后，未完成的任务改写到新目录，避免重试时继续写旧位置。
      _retargetUnfinishedTasks();
    }
    if (wifiOnly != null) _wifiOnly = wifiOnly;
    if (maxConcurrent != null) {
      _maxConcurrent = maxConcurrent;
      _processQueue();
    }
  }

  // ==================== 任务列表索引 ====================

  int _indexOfTask(String taskId) => _taskIndex[taskId] ?? -1;

  void _addTask(DownloadTask task) {
    _taskIndex[task.id] = _tasks.length;
    _tasks.add(task);
  }

  void _removeTaskAt(int index) {
    _tasks.removeAt(index);
    _reindexTasks(from: index);
  }

  void _reindexTasks({int from = 0}) {
    _taskIndex.removeWhere((_, index) => index >= from);
    for (var i = from; i < _tasks.length; i++) {
      _taskIndex[_tasks[i].id] = i;
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

    // 验证音质是否受当前音源支持。
    // 交给注入的校验器按整首歌判断（数据源歌曲要看真正的播放源声明了什么），
    // 没注入时退回旧的三档默认。
    final supportedQualities =
        _qualityValidator?.call(song) ??
        (song.isLocal ? <String>[] : ['128k', '320k', 'flac']);
    if (!song.isLocal && !supportedQualities.contains(quality)) {
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

    // 先入队、立刻显示在下载管理里；播放地址留空，由 _startTask 异步解析，
    // 避免解析耗时期间列表里看不到刚点的这首歌。
    final task = DownloadTask(
      id: DownloadTask.generateId(),
      song: song,
      url: url ?? '',
      quality: quality,
      filePath: filePath,
      priority: priority,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );

    _addTask(task);
    // 先把任务推给界面再落盘：下载管理页立刻就能看到这条记录，
    // 不用等数据库写完（以前是先解析播放地址再入队，网络慢时要等好几秒）。
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
    final index = _indexOfTask(taskId);
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
    _speedMeters.remove(taskId);
    _lastProgressEmit.remove(taskId);

    if (task.status == DownloadStatus.downloading) {
      _activeDownloads--;
    }

    _tasks[index] = task.copyWith(status: DownloadStatus.paused);
    _emitUpdate();
    _processQueue();
  }

  /// 恢复任务（照搬 CeruMusic resumeTask：放入队列头部）
  Future<void> resumeTask(String taskId) async {
    final index = _indexOfTask(taskId);
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
    // 用户手动恢复/重试应当立刻开始，不受自动重试的退避影响。
    _retryNotBefore.remove(taskId);

    _tasks[index] = _retargeted(
      task,
    ).copyWith(status: DownloadStatus.queued, retries: 0, error: null);
    _emitUpdate();
    _processQueue();
  }

  /// 重试任务
  Future<void> retryTask(String taskId) async {
    final index = _indexOfTask(taskId);
    if (index == -1) return;

    final task = _tasks[index];
    _initializingTasks.remove(taskId);
    _fileLocks.remove(task.filePath);
    // 用户手动恢复/重试应当立刻开始，不受自动重试的退避影响。
    _retryNotBefore.remove(taskId);

    // 插件给的直链是有时效的（B 站约 2 小时、网易云也会过期），失败后点
    // 「重试」如果再拿老地址去下，只会重复同一个 403 / 404。这里把地址和
    // 请求头清掉，让 _startTask 重新解析一次。
    // 本地歌曲的地址是文件路径，不能清。
    final retryFromScratch =
        task.url.isNotEmpty && (task.song.source ?? '') != 'local';

    _tasks[index] = _retargeted(task).copyWith(
      status: DownloadStatus.queued,
      progress: 0,
      downloadedSize: 0,
      speed: 0,
      remainingTime: null,
      retries: 0,
      error: null,
      url: retryFromScratch ? '' : null,
      headers: retryFromScratch ? const <String, String>{} : null,
    );
    _emitUpdate();
    _processQueue();
  }

  /// 取消任务
  Future<void> cancelTask(String taskId) async {
    final index = _indexOfTask(taskId);
    if (index == -1) return;

    final task = _tasks[index];
    _initializingTasks.remove(taskId);
    _fileLocks.remove(task.filePath);

    if (task.status == DownloadStatus.downloading) {
      _cancelTokens[taskId]?.cancel();
      _cancelTokens.remove(taskId);
      _speedMeters.remove(taskId);
      _lastProgressEmit.remove(taskId);
      _activeDownloads--;

      final tempFile = File('${task.filePath}.temp');
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }

    _tasks[index] = task.copyWith(status: DownloadStatus.cancelled);
    _emitUpdate();
    _processQueue();
  }

  /// 删除任务
  Future<void> deleteTask(String taskId, {bool deleteFile = false}) async {
    final index = _indexOfTask(taskId);
    if (index == -1) return;

    final task = _tasks[index];

    _initializingTasks.remove(taskId);
    _fileLocks.remove(task.filePath);

    if (task.status == DownloadStatus.downloading) {
      _cancelTokens[taskId]?.cancel();
      _cancelTokens.remove(taskId);
      _speedMeters.remove(taskId);
      _lastProgressEmit.remove(taskId);
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

    _removeTaskAt(index);
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
        _speedMeters.remove(task.id);
        _lastProgressEmit.remove(task.id);
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
    _emitUpdate();
    _processQueue();
  }

  /// 恢复所有暂停的任务
  Future<void> resumeAllTasks() async {
    final pausedTasks =
        _tasks.where((t) => t.status == DownloadStatus.paused).toList()
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
    final now = DateTime.now();
    while (_activeDownloads + _initializingTasks.length < _maxConcurrent) {
      int bestIndex = -1;
      int bestPriority = 999999;
      for (int i = 0; i < _tasks.length; i++) {
        if (_tasks[i].status != DownloadStatus.queued) continue;
        // 退避中的任务到点前不参与调度；到点后由 _scheduleRetry 的定时器
        // 再叫一次 _processQueue，这里顺手把过期记录清掉。
        final notBefore = _retryNotBefore[_tasks[i].id];
        if (notBefore != null) {
          if (notBefore.isAfter(now)) continue;
          _retryNotBefore.remove(_tasks[i].id);
        }
        if (_tasks[i].priority < bestPriority) {
          bestPriority = _tasks[i].priority;
          bestIndex = i;
        }
      }
      if (bestIndex == -1) break;

      final task = _tasks[bestIndex];
      _startTask(task.id);
    }
  }

  /// 只给失败任务挂退避：到点前它不参与调度，队列里其他任务立刻继续跑。
  /// 到点后主动再叫一次 [_processQueue]，避免没人触发调度时任务一直卡着。
  void _scheduleRetry(String taskId) {
    _retryNotBefore[taskId] = DateTime.now().add(_retryDelay);
    unawaited(
      Future<void>.delayed(_retryDelay, () {
        _retryNotBefore.remove(taskId);
        _processQueue();
      }),
    );
  }

  Future<void> _startTask(String taskId) async {
    final index = _indexOfTask(taskId);
    if (index == -1) return;

    _initializingTasks.add(taskId);

    _tasks[index] = _tasks[index].copyWith(status: DownloadStatus.downloading);
    _emitUpdate();

    var activeCounted = false;
    try {
      var task = _tasks[index];
      String url = task.url;
      if (url.isEmpty && _urlFetcher != null) {
        final fetched = await _urlFetcher!(task);
        if (fetched == null || fetched.url.isEmpty) {
          _initializingTasks.remove(taskId);
          _markError(
            taskId,
            (fetched?.error ?? '').trim().isNotEmpty
                ? fetched!.error!.trim()
                : '无法获取播放链接',
          );
          return;
        }
        url = fetched.url;
        // 请求头和地址一起收下：下载 / 重试都要用（播放侧一直是这么做的，
        // 下载侧漏了这一步，B 站这类校验 Referer 的 CDN 就必然 403）。
        task = task.copyWith(url: url, headers: fetched.headers);
        final resolvedSource = fetched.source;
        if (resolvedSource != null &&
            resolvedSource.isNotEmpty &&
            resolvedSource != task.song.source) {
          task = task.copyWith(
            song: task.song.copyWith(source: resolvedSource),
          );
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
      activeCounted = true;

      await _downloadFile(taskId, url);
    } catch (e) {
      debugPrint('[DownloadRepository] 下载失败: $e');
      _initializingTasks.remove(taskId);
      final idx = _indexOfTask(taskId);
      final filePath = idx != -1 ? _tasks[idx].filePath : '';
      final message = _cleanErrorMessage(e);
      if (activeCounted) {
        _handleError(taskId, message, tempFilePath: filePath);
      } else {
        // 还没占到并发位（解析地址阶段就抛了）：只标失败，不能减计数，
        // 否则并发额度会被越减越多。
        _markError(taskId, message);
      }
    }
  }

  void _markError(String taskId, String error) {
    final idx = _indexOfTask(taskId);
    if (idx != -1) {
      _tasks[idx] = _tasks[idx].copyWith(
        status: DownloadStatus.error,
        error: error,
        speed: 0,
      );
      _emitUpdate();
    }
    _processQueue();
  }

  Future<void> _downloadFile(String taskId, String url) async {
    final index = _indexOfTask(taskId);
    if (index == -1) return;

    final task = _tasks[index];
    final filePath = task.filePath;
    final tempPath = '$filePath.temp';

    final cancelToken = CancelToken();
    _cancelTokens[taskId] = cancelToken;
    _lastProgressEmit[taskId] = DateTime.fromMillisecondsSinceEpoch(0);

    try {
      // 检查是否有已下载的部分（支持断点续传）
      final tempFile = File(tempPath);
      int startByte = 0;
      if (await tempFile.exists()) {
        startByte = await tempFile.length();
        _tasks[index] = _tasks[index].copyWith(downloadedSize: startByte);
        _emitUpdate();
      }
      // 采样起点落在续传点上，否则第一个窗口会把已有字节算成新流量。
      _speedMeters[taskId] = DownloadSpeedMeter(startBytes: startByte);

      final headers = _downloadHeaders(task.headers);
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

          final now = DateTime.now();
          final idx = _indexOfTask(taskId);
          // 速度按时间窗口取平均：窗口没到就沿用上一次的值，不会归零，
          // 界面上也就不会在「有值 / -」之间来回闪。
          final speed =
              _speedMeters[taskId]?.sample(receivedWithOffset, now) ?? 0.0;
          final remainingTime = speed > 0 && totalWithOffset > 0
              ? ((totalWithOffset - receivedWithOffset) / speed).round()
              : null;

          final progress = totalWithOffset > 0
              ? receivedWithOffset / totalWithOffset
              : 0.0;

          if (idx != -1) {
            _tasks[idx] = _tasks[idx].copyWith(
              progress: progress.clamp(0.0, 1.0),
              totalSize: totalWithOffset,
              downloadedSize: receivedWithOffset,
              speed: speed,
              remainingTime: remainingTime,
            );
            // 数据每片都更新，但最快 100ms 才推一次 UI：分片回调可达每秒
            // 数百次，全量推送会让整页列表反复重建，进度条看着也在抖。
            final lastEmit = _lastProgressEmit[taskId];
            if (lastEmit == null ||
                now.difference(lastEmit).inMilliseconds >=
                    _progressEmitIntervalMs) {
              _lastProgressEmit[taskId] = now;
              _emitUpdate();
            }
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
              proposed =
                  '$baseNoExt.${DateTime.now().millisecondsSinceEpoch}$shouldExt';
            }
            await File(filePath).rename(proposed);
            finalPath = proposed;
          }
        } catch (_) {}

        // 写入标签（对齐 CeruMusic processSongFiles 逻辑）
        var coverOk = true;
        try {
          final tagOpts =
              _tagWriteOptionsFetcher?.call() ?? const TagWriteOptions();
          Song songForTag = task.song;
          debugPrint(
            '[DownloadRepository] 标签写入选项: basicInfo=${tagOpts.basicInfo}, cover=${tagOpts.cover}, lyrics=${tagOpts.lyrics}, downloadLyrics=${tagOpts.downloadLyrics}, lyricFormat=${tagOpts.lyricFormat}',
          );
          debugPrint(
            '[DownloadRepository] 歌词获取器: ${_lyricFetcher != null}, song.lrc: ${songForTag.lrc != null ? "has ${songForTag.lrc!.length} chars" : "null"}',
          );
          if ((tagOpts.lyrics || tagOpts.downloadLyrics) &&
              _lyricResultFetcher != null) {
            try {
              final lyricResult = await _lyricResultFetcher!(songForTag);
              debugPrint(
                '[DownloadRepository] 歌词获取结果: lrc=${lyricResult?.lrc != null ? "has ${lyricResult!.lrc!.length} chars" : "null"}, crlyric=${lyricResult?.crlyric != null ? "has ${lyricResult!.crlyric!.length} chars" : "null"}',
              );
              if (lyricResult != null) {
                // 优先使用逐字歌词（crlyric），否则使用标准歌词（lrc）
                final preferredLyric = tagOpts.lyricFormat == 'word-by-word'
                    ? (lyricResult.crlyric?.isNotEmpty == true
                          ? lyricResult.crlyric
                          : lyricResult.lrc)
                    : lyricResult.lrc;
                if (preferredLyric != null && preferredLyric.isNotEmpty) {
                  songForTag = songForTag.copyWith(lrc: preferredLyric);
                }
              }
            } catch (e) {
              debugPrint('[DownloadRepository] 获取歌词失败: $e');
            }
          } else if ((tagOpts.lyrics || tagOpts.downloadLyrics) &&
              _lyricFetcher != null) {
            try {
              final lrc = await _lyricFetcher!(songForTag);
              debugPrint(
                '[DownloadRepository] 歌词获取结果: ${lrc != null ? "has ${lrc.length} chars" : "null"}',
              );
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
          debugPrint(
            '[DownloadRepository] 本地缓存封面: '
            '${cachedCover != null ? "${cachedCover.length} bytes" : "未命中"}',
          );

          if (tagOpts.cover && cachedCover == null && _coverFetcher != null) {
            try {
              final highResCover = await _coverFetcher!(songForTag);
              debugPrint(
                '[DownloadRepository] 高清封面获取结果: ${highResCover != null ? highResCover.substring(0, highResCover.length.clamp(0, 80)) : "null"}',
              );
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

        final idx = _indexOfTask(taskId);
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
        _handleError(
          taskId,
          _describeHttpStatus(response.statusCode ?? 0),
          tempFilePath: filePath,
        );
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) return;

      final idx = _indexOfTask(taskId);
      if (idx != -1) {
        final task = _tasks[idx];
        // 断点位置失效（服务器换了文件 / 临时文件已经损坏）：删掉临时文件
        // 从头下一次，而不是把「HTTP 416」丢给用户。
        if (e.response?.statusCode == 416) {
          final tempFile = File(tempPath);
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
        }
        // 403 / 404 这类重试多少次都是同一个结果，直接报错，别让用户等三轮。
        if (task.retries < _maxRetries && _isRetryableDownloadError(e)) {
          _tasks[idx] = task.copyWith(
            status: DownloadStatus.queued,
            retries: task.retries + 1,
          );
          _emitUpdate();
          _fileLocks.remove(task.filePath);
          _activeDownloads--;
          _scheduleRetry(task.id);
          _processQueue();
          return;
        }
        final tempFile = File(tempPath);
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
        _handleError(
          taskId,
          _describeDownloadError(e, url: url),
          tempFilePath: task.filePath,
        );
      }
    } catch (e) {
      final idx = _indexOfTask(taskId);
      if (idx != -1) {
        final task = _tasks[idx];
        if (task.retries < _maxRetries) {
          _tasks[idx] = task.copyWith(
            status: DownloadStatus.queued,
            retries: task.retries + 1,
          );
          _emitUpdate();
          _fileLocks.remove(task.filePath);
          _activeDownloads--;
          _scheduleRetry(task.id);
          _processQueue();
          return;
        }
        final tempFile = File(tempPath);
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
        _handleError(
          taskId,
          _cleanErrorMessage(e),
          tempFilePath: task.filePath,
        );
      }
    } finally {
      _cancelTokens.remove(taskId);
      _speedMeters.remove(taskId);
      _lastProgressEmit.remove(taskId);
    }
  }

  /// 插件给的请求头 → 实际发给 CDN 的请求头。
  ///
  /// 剔除三类会坏事的头：
  /// * `host`：由 URL 决定，硬塞插件里的值会让 CDN 收到错误 Host；
  /// * `accept-encoding`：插件常写 `gzip, deflate, br`，而 Dart 的 HttpClient
  ///   只会解 gzip，拿到 br 会存成一堆乱码（播放器能解，下载不行）；
  /// * hop-by-hop 与 `range`：这些由我们控制，Range 要留给断点续传。
  static const _ignoredDownloadHeaders = <String>{
    'host',
    'accept-encoding',
    'content-encoding',
    'connection',
    'keep-alive',
    'content-length',
    'transfer-encoding',
    'range',
    'referer-length',
  };

  static Map<String, String> _downloadHeaders(Map<String, String>? source) {
    final headers = <String, String>{};
    (source ?? const <String, String>{}).forEach((key, value) {
      final name = key.trim();
      if (name.isEmpty || value.trim().isEmpty) return;
      if (_ignoredDownloadHeaders.contains(name.toLowerCase())) return;
      headers[name] = value;
    });
    return headers;
  }

  /// 4xx 里只有 408（请求超时）/ 429（限流）值得重试；
  /// 403 缺请求头、404 地址过期这类，重试多少次都一样。
  static bool _isRetryableDownloadError(DioException e) {
    final status = e.response?.statusCode ?? 0;
    if (status == 416) return true;
    if (status >= 400 && status < 500) return status == 408 || status == 429;
    return true;
  }

  String _describeDownloadError(DioException e, {String url = ''}) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
        return '连接服务器超时';
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return '下载超时：服务器长时间没有返回数据';
      case DioExceptionType.badCertificate:
        return 'HTTPS 证书校验失败';
      case DioExceptionType.connectionError:
        return '网络连接失败，请检查网络';
      case DioExceptionType.cancel:
        return '下载已取消';
      case DioExceptionType.badResponse:
        return _describeHttpStatus(e.response?.statusCode ?? 0);
      case DioExceptionType.unknown:
        break;
    }
    final message = (e.message ?? '').trim();
    if (message.isNotEmpty) return _oneLine(message);
    // 走到这里说明 Dio 连文案都没给（底层异常没有 message 时很常见）。
    // 只说一句「下载失败」等于没说 —— 补上目标主机和内部异常，用户和排查
    // 的人都能看出是「连不上」「被重定向到奇怪地址」还是「拿到了空响应」。
    final host = _hostOfUrl(url);
    final where = host.isEmpty ? '' : '（$host）';
    final inner = e.error;
    final innerText = inner == null
        ? ''
        : _oneLine('$inner').replaceFirst(RegExp(r'^\w*Exception:\s*'), '');
    if (innerText.isNotEmpty) return '下载失败$where：$innerText';
    return '下载失败$where：服务器没有返回任何数据';
  }

  /// 取 URL 的主机名，取不到就返回空串（只用于错误提示）。
  static String _hostOfUrl(String url) {
    if (url.isEmpty) return '';
    try {
      return Uri.tryParse(url)?.host ?? '';
    } catch (_) {
      return '';
    }
  }

  /// HTTP 状态码 → 用户能看懂的原因。
  String _describeHttpStatus(int code) {
    if (code == 403) {
      return '服务器拒绝访问（HTTP 403）：这条地址需要 Referer / User-Agent '
          '等请求头，或链接已经过期，重试一次试试';
    }
    if (code == 404 || code == 410) {
      return '文件不存在（HTTP $code）：链接可能已过期，重试会重新解析地址';
    }
    if (code == 416) return '断点续传位置无效（HTTP 416）';
    if (code == 429) return '请求过于频繁（HTTP 429），稍后再试';
    if (code >= 500) return '服务器错误（HTTP $code）';
    if (code > 0) return '下载失败（HTTP $code）';
    return '下载失败';
  }

  /// 异常 → 一行可读文案（去掉 `XxxException: ` 前缀、压成一行、限长）。
  static String _cleanErrorMessage(Object error) {
    var text = error.toString();
    text = text.replaceFirst(RegExp(r'^\w*Exception:\s*'), '');
    return _oneLine(text);
  }

  static String _oneLine(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.length <= 200) return flat;
    return '${flat.substring(0, 200)}…';
  }

  void _handleError(String taskId, String error, {String? tempFilePath}) {
    final idx = _indexOfTask(taskId);
    if (idx != -1) {
      _fileLocks.remove(_tasks[idx].filePath);
      _tasks[idx] = _tasks[idx].copyWith(
        status: DownloadStatus.error,
        error: error,
        speed: 0,
      );
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
    return _tasks.any(
      (t) => t.song.id == songId && t.status == DownloadStatus.completed,
    );
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
      if (header[0] == 0x4f &&
          header[1] == 0x67 &&
          header[2] == 0x67 &&
          header[3] == 0x53) {
        return 'ogg';
      }
      if (header[0] == 0x30 &&
          header[1] == 0x26 &&
          header[2] == 0xb2 &&
          header[3] == 0x75) {
        return 'wma';
      }
      if (header[0] == 0x52 &&
          header[1] == 0x49 &&
          header[2] == 0x46 &&
          header[3] == 0x46 &&
          header[8] == 0x57 &&
          header[9] == 0x41 &&
          header[10] == 0x56 &&
          header[11] == 0x45) {
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
      case 'mp3':
        return '.mp3';
      case 'flac':
        return '.flac';
      case 'm4a':
        return '.m4a';
      case 'wav':
        return '.wav';
      case 'ogg':
        return '.ogg';
      case 'wma':
        return '.wma';
      default:
        return '';
    }
  }

  void dispose() {
    _dio.close();
    _taskController.close();
  }
}
