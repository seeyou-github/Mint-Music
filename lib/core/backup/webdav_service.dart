import 'dart:convert';
import 'dart:io' show File, FileMode, RandomAccessFile, gzip;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart' as dio;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;
import 'package:webdav_client/webdav_client.dart' as webdav;

import '../platform/app_paths.dart';
import '../security/local_field_codec.dart';

/// 带可读原因的 WebDAV 异常。
class WebDavException implements Exception {
  const WebDavException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// 服务器不支持 `Range`（忽略分段请求、把整份文件发回来）时内部抛这个，
/// 用来把分段下载快速切回单线程，不会当成用户可见的错误。
class _RangeNotSupported implements Exception {
  const _RangeNotSupported();
}

/// 把网络 / WebDAV 异常转换成用户能看懂的原因。
String describeWebDavError(Object error) {
  if (error is WebDavException) return error.message;
  if (error is dio.DioException) {
    final uri = error.requestOptions.uri;
    switch (error.type) {
      case dio.DioExceptionType.connectionTimeout:
        return '连接超时：无法在 15 秒内连接 $uri，请检查网络或服务器地址';
      case dio.DioExceptionType.sendTimeout:
        return '发送超时：向 $uri 上传数据超时，请检查网络';
      case dio.DioExceptionType.receiveTimeout:
        return '接收超时：$uri 响应过慢，请稍后重试';
      case dio.DioExceptionType.transformTimeout:
        // dio 5.9 新增：解析响应数据（转换）超时，同样是「服务端太慢」。
        return '接收超时：$uri 响应数据解析超时，请稍后重试';
      case dio.DioExceptionType.badCertificate:
        return 'HTTPS 证书校验失败：$uri';
      case dio.DioExceptionType.connectionError:
        return '网络连接失败：无法访问 $uri\n${error.error ?? error.message ?? ''}'.trim();
      case dio.DioExceptionType.cancel:
        return '请求已取消';
      case dio.DioExceptionType.badResponse:
        final code = error.response?.statusCode;
        final message = error.response?.statusMessage;
        return '服务器返回错误：HTTP $code'
            '${message == null || message.isEmpty ? '' : ' $message'}';
      case dio.DioExceptionType.unknown:
        return '网络异常：${error.error ?? error.message ?? error}';
    }
  }
  return error.toString();
}

/// WebDAV 远端配置。
class WebDavConfig {
  const WebDavConfig({
    this.url = '',
    this.user = '',
    this.password = '',
    this.deviceName = '',
    this.playlistSyncEnabled = false,
  });

  /// WebDAV 服务器地址，例如 `https://dav.example.com/back`。
  final String url;

  final String user;
  final String password;

  /// 设备名称：备份压缩包保存到 `<url>/<设备名>/` 下。
  final String deviceName;

  /// 「自动同步」总开关（歌单自动同步 + 设置变更自动备份）。
  final bool playlistSyncEnabled;

  bool get isConfigured => url.trim().isNotEmpty;

  WebDavConfig copyWith({
    String? url,
    String? user,
    String? password,
    String? deviceName,
    bool? playlistSyncEnabled,
  }) {
    return WebDavConfig(
      url: url ?? this.url,
      user: user ?? this.user,
      password: password ?? this.password,
      deviceName: deviceName ?? this.deviceName,
      playlistSyncEnabled: playlistSyncEnabled ?? this.playlistSyncEnabled,
    );
  }

  /// 地址 / 账号 / 密码编码后写盘：设置文件以及打包进备份包的 settings.json
  /// 都只包含编码后的值，读回时由 [fromJson] 还原。
  Map<String, dynamic> toJson() => {
    'url': sealField(url),
    'user': sealField(user),
    'password': sealField(password),
    'deviceName': deviceName,
    'playlistSyncEnabled': playlistSyncEnabled,
  };

  factory WebDavConfig.fromJson(Map<String, dynamic> json) {
    return WebDavConfig(
      url: unsealField('${json['url'] ?? ''}'),
      user: unsealField('${json['user'] ?? ''}'),
      password: unsealField('${json['password'] ?? ''}'),
      deviceName: '${json['deviceName'] ?? ''}',
      playlistSyncEnabled: json['playlistSyncEnabled'] == true,
    );
  }
}

/// 远端备份文件条目。
class RemoteBackupFile {
  const RemoteBackupFile({
    required this.name,
    required this.path,
    required this.size,
    required this.modified,
  });

  final String name;
  final String path;
  final int size;
  final DateTime? modified;
}

/// WebDAV 客户端封装：备份上传 / 下载 / 列表，歌单 JSON 的读写。
class WebDavService {
  WebDavService(this.config, {dio.CancelToken? cancelToken})
    : _cancelToken = cancelToken;

  final WebDavConfig config;

  /// 本次操作的取消令牌（见 `SyncAttempt`）。
  ///
  /// 超时后它会被 cancel，正在等待的请求立刻结束，服务器迟到的响应也不会
  /// 再被写盘 / 合并。为 null 时（后台推送、连接测试）不参与取消。
  final dio.CancelToken? _cancelToken;

  /// 本次操作是否已被取消（超时 / 主动取消）。
  ///
  /// 上层在把结果写盘之前先看一眼：取消后即使数据已经拿到，也当作失败丢弃。
  bool get isCancelled => _cancelToken?.isCancelled ?? false;

  webdav.Client? _client;

  webdav.Client _buildClient() {
    final existing = _client;
    if (existing != null) return existing;
    final client = webdav.newClient(
      config.url.trim(),
      user: config.user,
      password: config.password,
    );
    client.setConnectTimeout(15000);
    client.setReceiveTimeout(30000);
    _client = client;
    return client;
  }

  void _requireConfigured() {
    if (!config.isConfigured) {
      throw const WebDavException('未配置 WebDAV：请先在「设置 → 备份还原」中填写 WebDAV 地址');
    }
  }

  /// 读取远端文件的全部字节。
  ///
  /// 不调用 `client.read()`：它固定先发 OPTIONS 且要求返回 200，遇到
  /// 301/302 的服务器会直接抛错（`DioException [bad response]: null`）。
  /// 这里走和备份包同一条下载链路（[downloadToFile]）：小文件单线程、
  /// 大文件按段并发，都带重试 / 断点续传和更宽松的空闲超时（歌单同步用）。
  Future<Uint8List> _readBytes(String path) async {
    final dir = await AppPaths.tempDirectory();
    final temp = File(
      p.join(
        dir.path,
        'webdav_read_${DateTime.now().microsecondsSinceEpoch}.bin',
      ),
    );
    try {
      await downloadToFile(path, savePath: temp.path);
      if (isCancelled) throw const WebDavException('下载已取消');
      return await temp.readAsBytes();
    } finally {
      await _deleteQuietly(temp);
    }
  }

  /// 直接发 PUT 写入远端文件。
  ///
  /// 同样绕过 `client.write()` 的 OPTIONS 预检（部分服务器 OPTIONS 会 301）。
  /// 重定向手动处理，避免 PUT 被客户端改写成 GET。
  Future<void> _writeBytes(String path, Uint8List bytes) async {
    final client = _buildClient();
    var target = path;
    for (var redirects = 0; redirects <= 5; redirects++) {
      final response = await client.c.req<dynamic>(
        client,
        'PUT',
        target,
        data: bytes,
        cancelToken: _cancelToken,
        optionsHandler: (options) {
          options.followRedirects = false;
          options.validateStatus = (status) => status != null;
          options.responseType = dio.ResponseType.plain;
          // content-length 手动带上：部分服务器要求 PUT 必须带长度。
          final headers = options.headers ?? <String, dynamic>{};
          headers['content-length'] = bytes.length;
          options.headers = headers;
        },
      );
      final status = response.statusCode ?? 0;
      if (status >= 200 && status < 300) return;
      if (status >= 300 && status < 400) {
        final location = response.headers.value('location');
        if (location == null || location.isEmpty) {
          throw WebDavException(
            '服务器返回重定向（HTTP $status），但没有提供跳转地址',
            statusCode: status,
          );
        }
        final current = Uri.tryParse(target);
        target = current?.resolve(location).toString() ?? location;
        continue;
      }
      final message = response.statusMessage;
      throw WebDavException(
        '上传失败：HTTP $status'
        '${message == null || message.isEmpty ? '' : ' $message'}',
        statusCode: status,
      );
    }
    throw const WebDavException('上传失败：重定向次数过多');
  }

  /// 远端根路径（URL 里的路径部分，例如 `back`），仅用于界面展示。
  String get remoteRoot {
    final uri = Uri.tryParse(config.url.trim());
    final path = uri?.path ?? '';
    return path.replaceAll(RegExp(r'^/+|/+$'), '');
  }

  /// 备份压缩包所在目录（**相对** URL 基址）：`<设备名>`。
  ///
  /// URL 里已经带了远程路径（例如 `https://dav.example.com/back`），
  /// 这里的路径是相对基址的，所以最终落在 `back/<设备名>/`。
  String get backupDir => config.deviceName.trim();

  /// 歌单同步文件所在目录（相对 URL 基址，即 URL 里带的那个路径）。
  String get playlistDir => '';

  /// 远端备份文件名的前缀（用于列表过滤）。
  static const String backupNamePrefix = 'mintmusic-backup';

  // ---------------------------------------------------------------- 连接测试

  /// 测试连接是否可用。
  Future<String> testConnection() async {
    if (!config.isConfigured) return 'WebDAV 未配置';
    try {
      final client = _buildClient();
      await client.readDir(backupDir.isEmpty ? '/' : backupDir, _cancelToken);
      return '';
    } catch (e) {
      return '连接失败：$e';
    }
  }

  // ---------------------------------------------------------------- 备份

  /// 确保远端目录存在。
  Future<void> _ensureDir(String path) async {
    if (path.isEmpty) return;
    final client = _buildClient();
    try {
      await client.mkdir(path, _cancelToken);
    } catch (_) {
      // 目录已存在时服务端会报错，忽略即可。
    }
  }

  /// 上传备份压缩包。
  ///
  /// 保存位置：`<远端根>/<设备名>/<文件名>`。
  Future<void> uploadBackup(Uint8List bytes, String fileName) async {
    _requireConfigured();
    await _ensureDir(backupDir);
    final target = backupDir.isEmpty ? fileName : '$backupDir/$fileName';
    await _writeBytes(target, bytes);
  }

  /// 列出远端备份文件。
  Future<List<RemoteBackupFile>> listBackups() async {
    _requireConfigured();
    final client = _buildClient();
    final dir = backupDir.isEmpty ? '/' : backupDir;
    final items = await client.readDir(dir, _cancelToken);
    final result = <RemoteBackupFile>[];
    for (final item in items) {
      final dyn = item as dynamic;
      if (dyn.isDir == true) continue;
      final name = dyn.name?.toString() ?? '';
      if (name.isEmpty || name == '.' || name == '..') continue;
      if (!name.contains(backupNamePrefix)) continue;
      final path = dyn.path?.toString() ?? '$dir/$name';
      final size = dyn.size is int ? dyn.size as int : 0;
      final modified = dyn.mTime;
      DateTime? modifiedAt;
      if (modified is DateTime) {
        modifiedAt = modified;
      } else if (modified is int) {
        modifiedAt = DateTime.fromMillisecondsSinceEpoch(modified);
      }
      result.add(
        RemoteBackupFile(
          name: name,
          path: path,
          size: size,
          modified: modifiedAt,
        ),
      );
    }
    result.sort(
      (a, b) =>
          (b.modified ?? DateTime(0)).compareTo(a.modified ?? DateTime(0)),
    );
    return result;
  }

  /// 下载备份时的「空闲超时」：连续这么久没收到任何字节才算卡住。
  ///
  /// dio 的 `receiveTimeout` 语义是「响应头 / 每两个数据块之间的最长间隔」，
  /// 客户端级原来给的 30 秒对备份包来说太短：备份里连插件目录一起打包，几十 MB
  /// 很常见，服务器只要在开头憋住半分钟，界面就会报
  /// 「接收超时：… 响应过慢」。音频下载模块（`DownloadRepository`）用的是
  /// 10 分钟，这里同样放宽；整次下载的总耗时由上层 `SyncAttempt` 兜底。
  static const Duration downloadIdleTimeout = Duration(minutes: 2);

  /// 单次下载最多尝试几次（含首次）：失败后断点续传重试。
  static const int downloadMaxAttempts = 3;

  /// 多线程分段下载的并发数。
  ///
  /// WebDAV 走的是标准 HTTP，支持 `Range` 的服务器（TeraCloud / Nextcloud /
  /// 坚果云等）可以按段并发拉取：单连接被限速时，多开几条连接能明显提速。
  /// 服务器不接受 Range 或并发被拒时，[downloadToFile] 会自动退回单线程，
  /// 不会因此失败。
  static const int downloadParallelism = 4;

  /// 单个分片的最大字节数，同时也是「要不要分段」的门槛：
  /// 文件超过这个大小就走多线程，每片最多这么多字节。
  static const int _maxSegmentBytes = 100 * 1024;

  /// 把远端文件流式下载到 [savePath]，失败自动重试并从断点续传。
  ///
  /// 不整包塞进内存再判断成败：直接落盘的好处是失败时已经收到的字节还在，
  /// 下一次带 `Range` 接着下，不用把几十 MB 从头再来一遍。
  ///
  /// 大小已知且超过 [_maxSegmentBytes] 时先走 [downloadParallelism] 路分段
  /// 并发（每片最多 [_maxSegmentBytes]，分片数多于线程数时排队依次下）；
  /// 服务器不支持 `Range`、并发被限流或某段重试仍失败时，自动回退到单线程。
  Future<void> downloadToFile(
    String path, {
    required String savePath,
    int? expectedSize,
    void Function(int received, int total)? onProgress,
  }) async {
    _requireConfigured();
    final total = expectedSize ?? 0;
    if (total > _maxSegmentBytes && downloadParallelism > 1) {
      final done = await _downloadParallel(
        path,
        savePath: savePath,
        total: total,
        onProgress: onProgress,
      );
      if (done) return;
      // 分段被取消（超时）时不能装作成功，也不能再开单线程重下。
      if (isCancelled) throw const WebDavException('下载已取消');
    }
    await _downloadSingle(
      path,
      savePath: savePath,
      expectedSize: expectedSize,
      onProgress: onProgress,
    );
  }

  /// 单线程下载（带整文件断点续传与重试）。
  Future<void> _downloadSingle(
    String path, {
    required String savePath,
    int? expectedSize,
    void Function(int received, int total)? onProgress,
  }) async {
    final client = _buildClient();
    final file = File(savePath);
    Object? lastError;
    for (var attempt = 1; attempt <= downloadMaxAttempts; attempt++) {
      try {
        // 只有重试时才续传：首次下载的临时文件名是新的，不会误用上次的残片。
        var start = 0;
        if (attempt > 1 && await file.exists()) {
          start = await file.length();
        }
        if (expectedSize != null && expectedSize > 0 && start >= expectedSize) {
          return;
        }
        await _downloadOnce(
          client,
          path,
          file,
          start,
          expectedSize,
          onProgress,
        );
        return;
      } catch (e) {
        lastError = e;
        // 超时 / 用户取消：请求已经被 cancel 掉了，继续重试没有意义。
        if (isCancelled) rethrow;
        if (!_isRetryableDownloadError(e)) {
          await _deleteQuietly(file);
          rethrow;
        }
        if (attempt < downloadMaxAttempts) {
          await Future<void>.delayed(Duration(milliseconds: 800 * attempt));
        }
      }
    }
    await _deleteQuietly(file);
    if (lastError is WebDavException) throw lastError;
    throw WebDavException('下载失败：${lastError ?? '未知错误'}');
  }

  /// 多线程分段下载：每段各写一个临时文件，全部到齐后按顺序拼成 [savePath]。
  ///
  /// 返回 false 表示这条路走不通（服务器忽略 Range、并发被拒、某段重试耗尽），
  /// 调用方回退单线程；返回 true 表示文件已经完整落盘。
  Future<bool> _downloadParallel(
    String path, {
    required String savePath,
    required int total,
    void Function(int received, int total)? onProgress,
  }) async {
    // 每片最多 _maxSegmentBytes：文件越大片越多，由 [downloadParallelism] 个
    // worker 排队依次取，同一时刻最多开这么多条连接。
    final segmentCount = (total + _maxSegmentBytes - 1) ~/ _maxSegmentBytes;
    final file = File(savePath);
    // 每片已经下到多少字节：重试续传和进度都靠它，不去翻文件（文件是预分配的，
    // 分不清哪段是真数据、哪段还是空洞）。
    final segmentDone = List<int>.filled(segmentCount, 0);
    var aborted = false;

    var received = 0;
    var lastReportMs = 0;
    void report(int delta) {
      // 续传 / 重试时同几个字节可能被重复计入，钳一下上限，别让进度条超过 100%。
      received = math.min(total, received + delta);
      final now = DateTime.now().millisecondsSinceEpoch;
      // 分片回调很密：150ms 推一次进度就够，别把 UI 线程刷满。
      if (now - lastReportMs < 150 && received < total) return;
      lastReportMs = now;
      onProgress?.call(received, total);
    }

    try {
      final client = _buildClient();
      // 先花一个 1 字节的请求确认服务器真的支持 Range：不支持的话几条连接会
      // 各自把整份文件下回来（既慢又费流量），必须在开工前就分辨出来。
      if (!await _supportsRange(client, path)) return false;

      // 先把目标文件截到最终大小，每个分片直接写自己的偏移位置。
      // 分片一多，「每片一个临时文件再拼接」会多出几百个文件 + 一次全量拷贝。
      final truncate = await file.open(mode: FileMode.write);
      try {
        await truncate.truncate(total);
      } finally {
        await truncate.close();
      }

      var next = 0;
      Future<void> worker() async {
        // 每个 worker 一个句柄，片与片之间复用；写到哪儿由自己 setPosition 定。
        final handle = await file.open(mode: FileMode.append);
        try {
          while (!aborted) {
            final index = next++;
            if (index >= segmentCount) return;
            final start = index * _maxSegmentBytes;
            final end = math.min(total, start + _maxSegmentBytes) - 1;
            await _downloadSegment(
              client,
              path,
              handle,
              segmentDone,
              index,
              start,
              end,
              report,
              () => aborted,
            );
          }
        } finally {
          await handle.close();
        }
      }

      await Future.wait(
        [for (var i = 0; i < math.min(downloadParallelism, segmentCount); i++) worker()],
        // 某一片判定「服务器不支持 Range」时立刻收手，不等其它片跑完。
        eagerError: true,
      );
      onProgress?.call(total, total);
      return true;
    } on _RangeNotSupported {
      // 先把还在跑的 worker 喊停，避免它们继续往这个文件里写（下面单线程会
      // 重新截断整个文件，同时写就会写坏）。
      aborted = true;
      return false;
    } catch (e) {
      aborted = true;
      if (isCancelled) rethrow;
      debugPrint('[WebDav] 分段下载失败，回退单线程: $e');
      return false;
    }
  }

  /// 问服务器一句「支持 `Range` 吗」：只请求第 1 个字节，看它回不回 206。
  ///
  /// 有的 WebDAV 实现（部分只读网关、对象存储的静态映射）会忽略 `Range` 直接
  /// 回 200 + 整份文件；那种情况下分段下载毫无意义，必须先分辨出来。
  Future<bool> _supportsRange(webdav.Client client, String path) async {
    try {
      final response = await client.c.req<dynamic>(
        client,
        'GET',
        path,
        cancelToken: _cancelToken,
        optionsHandler: (options) {
          options.responseType = dio.ResponseType.stream;
          options.followRedirects = true;
          options.validateStatus = (status) => status != null;
          options.receiveTimeout = downloadIdleTimeout;
          options.headers = {...?options.headers, 'range': 'bytes=0-0'};
        },
      );
      final supported = response.statusCode == 206;
      // 这 1 个字节不写盘，直接丢掉释放连接。
      _closeStreamBody(response.data);
      return supported;
    } catch (e) {
      // 探测失败（网络 / 鉴权）不在这里下结论，交给单线程那条路去报错。
      debugPrint('[WebDav] Range 探测失败: $e');
      return false;
    }
  }

  /// 下载一片 `[start, end]`（闭区间），直接写进 [handle] 对应的偏移位置。
  ///
  /// [segmentDone] 记录每片已下字节：片内重试时从断点续传，进度也按它补报，
  /// 已经落盘的字节不会重复计。失败按片重试，重试耗尽才整体回退单线程。
  Future<void> _downloadSegment(
    webdav.Client client,
    String path,
    RandomAccessFile handle,
    List<int> segmentDone,
    int index,
    int start,
    int end,
    void Function(int delta) onBytes,
    bool Function() isAborted,
  ) async {
    Object? lastError;
    for (var attempt = 1; attempt <= downloadMaxAttempts; attempt++) {
      try {
        if (isAborted()) throw const _RangeNotSupported();
        final offset = start + segmentDone[index];
        if (offset > end) return;

        final response = await client.c.req<dynamic>(
          client,
          'GET',
          path,
          cancelToken: _cancelToken,
          optionsHandler: (options) {
            options.responseType = dio.ResponseType.stream;
            options.followRedirects = true;
            options.validateStatus = (status) => status != null;
            options.receiveTimeout = downloadIdleTimeout;
            options.headers = {
              ...?options.headers,
              'range': 'bytes=$offset-$end',
            };
          },
        );
        final status = response.statusCode ?? 0;
        if (status == 200) {
          // 服务器忽略了 Range，把整份文件发了回来：分片拼不起来，放弃。
          _closeStreamBody(response.data);
          throw const _RangeNotSupported();
        }
        if (status != 206) {
          _closeStreamBody(response.data);
          if (status == 404) {
            throw WebDavException('远端文件不存在（HTTP 404）', statusCode: 404);
          }
          final message = response.statusMessage;
          throw WebDavException(
            'HTTP $status${message == null || message.isEmpty ? '' : ' $message'}',
            statusCode: status,
          );
        }

        final body = response.data;
        if (body is! dio.ResponseBody) {
          throw const WebDavException('下载失败：服务器没有返回数据流');
        }
        await handle.setPosition(offset);
        var written = offset;
        await for (final chunk in body.stream) {
          if (isAborted()) throw const _RangeNotSupported();
          await handle.writeFrom(chunk);
          written += chunk.length;
          segmentDone[index] = written - start;
          onBytes(chunk.length);
        }
        await handle.flush();
        // 片内字节数对不上（服务端提前掐断）：按失败处理，交给重试补。
        if (written != end + 1) {
          throw WebDavException('分段不完整：$written/${end + 1}');
        }
        return;
      } on _RangeNotSupported {
        rethrow;
      } catch (e) {
        lastError = e;
        if (isCancelled) rethrow;
        if (!_isRetryableDownloadError(e)) rethrow;
        if (attempt < downloadMaxAttempts) {
          await Future<void>.delayed(Duration(milliseconds: 600 * attempt));
        }
      }
    }
    if (lastError is WebDavException) throw lastError;
    throw WebDavException('分段下载失败：${lastError ?? '未知错误'}');
  }

  /// 发一次 GET，把响应体按块写进 [file]。
  ///
  /// [start] > 0 时带上 `Range` 续传：服务器回 206 就追加写；回 200 说明它
  /// 不支持断点续传 / 忽略了 Range，只能把文件截断从头写。
  Future<void> _downloadOnce(
    webdav.Client client,
    String path,
    File file,
    int start,
    int? expectedSize,
    void Function(int received, int total)? onProgress,
  ) async {
    var target = path;
    for (var redirects = 0; redirects <= 5; redirects++) {
      final response = await client.c.req<dynamic>(
        client,
        'GET',
        target,
        cancelToken: _cancelToken,
        optionsHandler: (options) {
          options.responseType = dio.ResponseType.stream;
          options.followRedirects = true;
          // 状态码由下面统一判断，避免 404 被 Dio 转成无信息的 badResponse。
          options.validateStatus = (status) => status != null;
          // 只把「长时间一个字节都没有」当失败，整体耗时交给上层超时。
          options.receiveTimeout = downloadIdleTimeout;
          if (start > 0) {
            options.headers = {...?options.headers, 'range': 'bytes=$start-'};
          }
        },
      );
      final status = response.statusCode ?? 0;

      if (status >= 300 && status < 400) {
        final location = response.headers.value('location');
        _closeStreamBody(response.data);
        if (location == null || location.isEmpty) {
          throw WebDavException(
            '服务器返回重定向（HTTP $status），但没有提供跳转地址',
            statusCode: status,
          );
        }
        final current = Uri.tryParse(target);
        target = current?.resolve(location).toString() ?? location;
        continue;
      }

      if (status != 200 && status != 206) {
        _closeStreamBody(response.data);
        if (status == 404) {
          throw WebDavException('远端文件不存在（HTTP 404）', statusCode: 404);
        }
        final message = response.statusMessage;
        throw WebDavException(
          'HTTP $status${message == null || message.isEmpty ? '' : ' $message'}',
          statusCode: status,
        );
      }

      final body = response.data;
      if (body is! dio.ResponseBody) {
        throw const WebDavException('下载失败：服务器没有返回数据流');
      }
      final resume = status == 206 && start > 0;
      final receivedBase = resume ? start : 0;
      final contentLength =
          int.tryParse(response.headers.value('content-length') ?? '') ?? 0;
      final total =
          expectedSize ??
          (contentLength > 0 ? contentLength + receivedBase : 0);

      final sink = file.openWrite(
        mode: resume ? FileMode.writeOnlyAppend : FileMode.write,
      );
      var received = receivedBase;
      try {
        await for (final chunk in body.stream) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      return;
    }
    throw const WebDavException('下载失败：重定向次数过多');
  }

  void _closeStreamBody(Object? data) {
    if (data is dio.ResponseBody) {
      // `ResponseBody.close()` 是 dio 的内部成员，这里直接取消订阅，
      // 效果一样：连接立刻释放，不会因为没读完响应体把 socket 一直挂着。
      data.stream.listen(null, onError: (Object _) {}).cancel();
    }
  }

  /// 这个错误还值不值得重试。
  ///
  /// 4xx（404 / 403 / 400…）说明是这条路径或权限本身有问题，再试也一样；
  /// 超时、连接中断、5xx、408、429 都值得带 `Range` 再试一次。
  bool _isRetryableDownloadError(Object error) {
    if (error is WebDavException) {
      final code = error.statusCode;
      if (code == null) return true;
      return code >= 500 || code == 408 || code == 429;
    }
    return true;
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 删不掉就留给系统清理，不影响本次结果。
    }
  }

  /// 下载远端备份文件。
  ///
  /// 先流式落到临时文件再读进内存：整包 `ResponseType.bytes` 时 dio 会在
  /// 两个数据块之间套 30 秒的 receiveTimeout（见 [downloadIdleTimeout]），
  /// 大备份包几乎必然报「接收超时」，而且失败只能从头再来。
  Future<Uint8List> downloadBackup(
    String path, {
    int? expectedSize,
    void Function(int received, int total)? onProgress,
  }) async {
    _requireConfigured();
    final dir = await AppPaths.tempDirectory();
    final temp = File(
      p.join(
        dir.path,
        'webdav_restore_${DateTime.now().microsecondsSinceEpoch}.zip',
      ),
    );
    try {
      await downloadToFile(
        path,
        savePath: temp.path,
        expectedSize: expectedSize,
        onProgress: onProgress,
      );
      // 超时 / 主动取消后即使字节已经收完也不采用，避免半截包被当成成功。
      if (isCancelled) throw const WebDavException('下载已取消');
      return await temp.readAsBytes();
    } finally {
      await _deleteQuietly(temp);
    }
  }

  /// 删除远端备份文件。
  Future<void> deleteBackup(String path) async {
    _requireConfigured();
    final client = _buildClient();
    await client.remove(path, _cancelToken);
  }

  // ---------------------------------------------------------------- 歌单同步

  /// 歌单同步文件名（远端 `<远端根>/playlists.json.gz`）。
  static const String playlistFileName = 'playlists.json';

  /// 压缩后的歌单文件名。
  ///
  /// 上千首收藏序列化后 2MB 上下，gzip 能压到 14%（约 300KB），手机流量上传
  /// 差别很明显。老版本只会读写未压缩的 [playlistFileName]，所以远端还留着
  /// 那份文件时，写入会同时更新它（见 [writeRemotePlaylists]）。
  static const String playlistCompressedName = 'playlists.json.gz';

  String _playlistPath(String name) =>
      playlistDir.isEmpty ? name : '$playlistDir/$name';

  /// 读取远端歌单 JSON。
  ///
  /// 优先读压缩版；没有（404）时回退到老版本的未压缩文件。
  /// 仅在远端确实不存在时返回 null；网络 / 鉴权等错误一律向上抛出，
  /// 避免把「读取失败」误当成「远端没有歌单」而覆盖远端数据。
  Future<Map<String, dynamic>?> readRemotePlaylists() async {
    _requireConfigured();
    var bytes = Uint8List(0);
    try {
      bytes = await _readBytes(_playlistPath(playlistCompressedName));
      // 万一服务器上那个 `.gz` 实际是没压缩的旧文件，解压失败就按原文解析。
      bytes = _gunzipOrRaw(bytes);
    } on WebDavException catch (e) {
      if (e.statusCode != 404) rethrow;
      try {
        bytes = await _readBytes(_playlistPath(playlistFileName));
      } on WebDavException catch (e2) {
        if (e2.statusCode == 404) return null;
        rethrow;
      }
    }
    if (bytes.isEmpty) return null;
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is Map) return decoded.map((k, v) => MapEntry('$k', v));
    throw const WebDavException('远端歌单文件格式错误：不是有效的 JSON 对象');
  }

  /// 写入远端歌单 JSON（压缩）。
  Future<void> writeRemotePlaylists(Map<String, dynamic> data) async {
    _requireConfigured();
    await _ensureDir(playlistDir);
    final text = jsonEncode({
      ...data,
      'deviceName': config.deviceName,
      'updatedAt': data['updatedAt'] ?? DateTime.now().millisecondsSinceEpoch,
    });
    final bytes = Uint8List.fromList(utf8.encode(text));
    await _writeBytes(
      _playlistPath(playlistCompressedName),
      Uint8List.fromList(gzip.encode(bytes)),
    );
    // 远端还留着一份未压缩文件 → 说明有老版本客户端在同步，一并更新它，
    // 否则老端读不到新数据，会把整份旧歌单再推回来。
    if (await _remoteFileExists(playlistFileName)) {
      await _writeBytes(_playlistPath(playlistFileName), bytes);
    }
  }

  Uint8List _gunzipOrRaw(Uint8List bytes) {
    if (bytes.isEmpty) return bytes;
    try {
      return Uint8List.fromList(gzip.decode(bytes));
    } catch (_) {
      return bytes;
    }
  }

  /// 远端目录里是否有这个文件（一次 PROPFIND）。
  Future<bool> _remoteFileExists(String name) async {
    try {
      final client = _buildClient();
      final dir = playlistDir.isEmpty ? '/' : playlistDir;
      final items = await client.readDir(dir, _cancelToken);
      for (final item in items) {
        final dyn = item as dynamic;
        if (dyn.isDir == true) continue;
        if ('${dyn.name}' == name) return true;
      }
    } catch (_) {
      // 查不到就当作没有：少写一份兼容文件不影响新版本自己同步。
    }
    return false;
  }
}
