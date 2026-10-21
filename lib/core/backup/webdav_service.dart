import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

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
      url: config.url.trim(),
      user: config.user,
      password: config.password,
    );
    client.setConnectTimeout(15000);
    client.setReceiveTimeout(30000);
    _client = client;
    return client;
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
    if (!config.isConfigured) throw Exception('WebDAV 未配置');
    final client = _buildClient();
    await _ensureDir(backupDir);
    final target = backupDir.isEmpty ? fileName : '$backupDir/$fileName';
    await client.write(target, bytes);
  }

  /// 列出远端备份文件。
  Future<List<RemoteBackupFile>> listBackups() async {
    if (!config.isConfigured) throw Exception('WebDAV 未配置');
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
      final size = (dyn.size ?? 0) is int ? dyn.size as int : 0;
      final modified = dyn.lastModified ?? dyn.modified;
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
    final client = _buildClient();
    final bytes = await client.read(path);
    if (bytes is Uint8List) return bytes;
    return Uint8List.fromList(bytes as List<int>);
  }

  // ---------------------------------------------------------------- 歌单同步

  /// 歌单同步文件名（远端 `<远端根>/playlists.json`）。
  static const String playlistFileName = 'playlists.json';

  /// 读取远端歌单 JSON（不存在时返回 null）。
  Future<Map<String, dynamic>?> readRemotePlaylists() async {
    if (!config.isConfigured) return null;
    final client = _buildClient();
    final target = playlistDir.isEmpty
        ? playlistFileName
        : '$playlistDir/$playlistFileName';
    try {
      final bytes = await client.read(target);
      final text = utf8.decode(bytes is Uint8List ? bytes : Uint8List.fromList(bytes as List<int>));
      final decoded = jsonDecode(text);
      if (decoded is Map) return decoded.map((k, v) => MapEntry('$k', v));
      return null;
    } catch (e) {
      debugPrint('[WebDavService] 读取远端歌单失败: $e');
      return null;
    }
  }

  /// 写入远端歌单 JSON。
  Future<void> writeRemotePlaylists(Map<String, dynamic> data) async {
    if (!config.isConfigured) throw Exception('WebDAV 未配置');
    final client = _buildClient();
    await _ensureDir(playlistDir);
    final target = playlistDir.isEmpty
        ? playlistFileName
        : '$playlistDir/$playlistFileName';
    final text = jsonEncode(data);
    await client.write(target, utf8.encode(text));
  }
}
