import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart' as dio;
import 'package:webdav_client/webdav_client.dart' as webdav;

/// 带可读原因的 WebDAV 异常。
class WebDavException implements Exception {
  const WebDavException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
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
        return '网络连接失败：无法访问 $uri\n${error.error ?? error.message ?? ''}'
            .trim();
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

  /// 歌单实时同步开关。
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

  Map<String, dynamic> toJson() => {
    'url': url,
    'user': user,
    'password': password,
    'deviceName': deviceName,
    'playlistSyncEnabled': playlistSyncEnabled,
  };

  factory WebDavConfig.fromJson(Map<String, dynamic> json) {
    return WebDavConfig(
      url: '${json['url'] ?? ''}',
      user: '${json['user'] ?? ''}',
      password: '${json['password'] ?? ''}',
      deviceName: '${json['deviceName'] ?? ''}',
      playlistSyncEnabled: json['playlistSyncEnabled'] == true,
    );
  }
}

/// 远端备份文件条目。
class RemoteBackupFile {
  const RemoteBackupFile({required this.name, required this.path, required this.size, required this.modified});

  final String name;
  final String path;
  final int size;
  final DateTime? modified;
}

/// WebDAV 客户端封装：备份上传 / 下载 / 列表，歌单 JSON 的读写。
class WebDavService {
  WebDavService(this.config);

  final WebDavConfig config;

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
      throw const WebDavException(
        '未配置 WebDAV：请先在「设置 → 备份还原」中填写 WebDAV 地址',
      );
    }
  }

  /// 直接发 GET 读取远端文件。
  ///
  /// 不调用 `client.read()`：它固定先发 OPTIONS 且要求返回 200，遇到
  /// 301/302 的服务器会直接抛错（`DioException [bad response]: null`）。
  /// 这里让 Dio 跟随重定向，并手动兜底处理未自动跟随的 3xx。
  Future<Uint8List> _readBytes(String path) async {
    final client = _buildClient();
    var target = path;
    for (var redirects = 0; redirects <= 5; redirects++) {
      final response = await client.c.req<List<int>>(
        client,
        'GET',
        target,
        optionsHandler: (options) {
          options.responseType = dio.ResponseType.bytes;
          options.followRedirects = true;
          // 状态码由下面统一判断，避免 404 被 Dio 转成无信息的 badResponse。
          options.validateStatus = (status) => status != null;
        },
      );
      final status = response.statusCode ?? 0;
      if (status >= 200 && status < 300) {
        final data = response.data;
        if (data == null) return Uint8List(0);
        return data is Uint8List ? data : Uint8List.fromList(data);
      }
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
      if (status == 404) {
        throw WebDavException('远端文件不存在（HTTP 404）', statusCode: 404);
      }
      final message = response.statusMessage;
      throw WebDavException(
        'HTTP $status${message == null || message.isEmpty ? '' : ' $message'}',
        statusCode: status,
      );
    }
    throw const WebDavException('下载失败：重定向次数过多');
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
      await client.readDir(backupDir.isEmpty ? '/' : backupDir);
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
      await client.mkdir(path);
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
    final items = await client.readDir(dir);
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
    result.sort((a, b) => (b.modified ?? DateTime(0)).compareTo(a.modified ?? DateTime(0)));
    return result;
  }

  /// 下载远端备份文件。
  Future<Uint8List> downloadBackup(String path) async {
    _requireConfigured();
    return _readBytes(path);
  }

  /// 删除远端备份文件。
  Future<void> deleteBackup(String path) async {
    _requireConfigured();
    final client = _buildClient();
    await client.remove(path);
  }

  // ---------------------------------------------------------------- 歌单同步

  /// 歌单同步文件名（远端 `<远端根>/playlists.json`）。
  static const String playlistFileName = 'playlists.json';

  /// 读取远端歌单 JSON。
  ///
  /// 仅在远端文件确实不存在（404）时返回 null；网络 / 鉴权等错误一律
  /// 向上抛出，避免把「读取失败」误当成「远端没有歌单」而覆盖远端数据。
  Future<Map<String, dynamic>?> readRemotePlaylists() async {
    _requireConfigured();
    final target = playlistDir.isEmpty
        ? playlistFileName
        : '$playlistDir/$playlistFileName';
    var bytes = Uint8List(0);
    try {
      bytes = await _readBytes(target);
    } on WebDavException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
    if (bytes.isEmpty) return null;
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is Map) return decoded.map((k, v) => MapEntry('$k', v));
    throw const WebDavException('远端歌单文件格式错误：不是有效的 JSON 对象');
  }

  /// 写入远端歌单 JSON。
  Future<void> writeRemotePlaylists(Map<String, dynamic> data) async {
    _requireConfigured();
    await _ensureDir(playlistDir);
    final target = playlistDir.isEmpty
        ? playlistFileName
        : '$playlistDir/$playlistFileName';
    final text = jsonEncode({
      ...data,
      'deviceName': config.deviceName,
      'updatedAt': data['updatedAt'] ?? DateTime.now().millisecondsSinceEpoch,
    });
    await _writeBytes(target, Uint8List.fromList(utf8.encode(text)));
  }
}
