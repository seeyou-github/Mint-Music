import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../../../player/domain/models/song.dart';

const _uuid = Uuid();

enum DownloadStatus {
  queued,
  downloading,
  paused,
  completed,
  error,
  cancelled,

  /// 下载完成但文件已被用户删除 / 移动（不是下载失败）。
  fileMissing,
}

class DownloadTask {
  final String id;
  final Song song;
  final String url;
  final String quality;
  final String filePath;
  final DownloadStatus status;
  final double progress;
  final int totalSize;
  final int downloadedSize;
  final double speed;
  final int? remainingTime;
  final int retries;
  final String? error;

  /// 封面缺失：封面获取 / 写入失败时标记。
  ///
  /// 歌曲本身仍然是下载成功状态，只是没有内嵌封面，下载列表里会给出提示。
  final bool coverMissing;

  final int priority;
  final int createdAt;

  const DownloadTask({
    required this.id,
    required this.song,
    required this.url,
    required this.quality,
    required this.filePath,
    this.status = DownloadStatus.queued,
    this.progress = 0,
    this.totalSize = 0,
    this.downloadedSize = 0,
    this.speed = 0,
    this.remainingTime,
    this.retries = 0,
    this.error,
    this.coverMissing = false,
    this.priority = 0,
    required this.createdAt,
  });

  DownloadTask copyWith({
    String? id,
    Song? song,
    String? url,
    String? quality,
    String? filePath,
    DownloadStatus? status,
    double? progress,
    int? totalSize,
    int? downloadedSize,
    double? speed,
    int? remainingTime,
    int? retries,
    String? error,
    bool? coverMissing,
    int? priority,
    int? createdAt,
  }) {
    return DownloadTask(
      id: id ?? this.id,
      song: song ?? this.song,
      url: url ?? this.url,
      quality: quality ?? this.quality,
      filePath: filePath ?? this.filePath,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      totalSize: totalSize ?? this.totalSize,
      downloadedSize: downloadedSize ?? this.downloadedSize,
      speed: speed ?? this.speed,
      remainingTime: remainingTime ?? this.remainingTime,
      retries: retries ?? this.retries,
      error: error ?? this.error,
      coverMissing: coverMissing ?? this.coverMissing,
      priority: priority ?? this.priority,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'song': song.toJson(),
    'url': url,
    'quality': quality,
    'filePath': filePath,
    'status': status.name,
    'progress': progress,
    'totalSize': totalSize,
    'downloadedSize': downloadedSize,
    'speed': speed,
    'remainingTime': remainingTime,
    'retries': retries,
    'error': error,
    'coverMissing': coverMissing,
    'priority': priority,
    'createdAt': createdAt,
  };

  /// 落库用的瘦身版（歌曲不带整段歌词 / 请求头，见 [Song.toPersistJson]）。
  Map<String, dynamic> toPersistJson() => {
    'id': id,
    'song': song.toPersistJson(),
    'url': url,
    'quality': quality,
    'filePath': filePath,
    'status': status.name,
    'progress': progress,
    'totalSize': totalSize,
    'downloadedSize': downloadedSize,
    'speed': speed,
    'remainingTime': remainingTime,
    'retries': retries,
    'error': error,
    'coverMissing': coverMissing,
    'priority': priority,
    'createdAt': createdAt,
  };

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    return DownloadTask(
      id: json['id'] ?? '',
      song: Song.fromJson(json['song']),
      url: json['url'] ?? '',
      quality: json['quality'] ?? '320k',
      filePath: json['filePath'] ?? '',
      status: DownloadStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => DownloadStatus.queued,
      ),
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      totalSize: json['totalSize'] ?? 0,
      downloadedSize: json['downloadedSize'] ?? 0,
      speed: (json['speed'] as num?)?.toDouble() ?? 0,
      remainingTime: json['remainingTime'],
      retries: json['retries'] ?? 0,
      error: json['error'],
      coverMissing: json['coverMissing'] == true,
      priority: json['priority'] ?? 0,
      createdAt: json['createdAt'] ?? DateTime.now().millisecondsSinceEpoch,
    );
  }

  static String generateId() => _uuid.v4();

  /// 只计算路径，不创建目录（用于同步迁移已存在的任务）。
  static String buildFilePathSync({
    required String downloadDir,
    required String title,
    required String artist,
    required String quality,
    String? extension,
  }) {
    final ext = _extensionFromQuality(quality, extension);
    // 下载文件名固定为：歌手名 - 歌曲名
    // 用平台分隔符拼接，避免 Windows 上出现「C:\.../歌曲.mp3」这种混合路径。
    final safeTitle = _sanitizeFilename('$artist - $title');
    return p.join(downloadDir, '$safeTitle.$ext');
  }

  static Future<String> buildFilePath({
    required String downloadDir,
    required String title,
    required String artist,
    required String quality,
    String? extension,
  }) async {
    final dir = Directory(downloadDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    return buildFilePathSync(
      downloadDir: downloadDir,
      title: title,
      artist: artist,
      quality: quality,
      extension: extension,
    );
  }

  static String _extensionFromQuality(String quality, String? original) {
    if (original != null && original.isNotEmpty) return original;
    switch (quality) {
      case 'flac':
      case 'flac24bit':
      case 'hires':
      case 'atmos':
      case 'master':
        return 'flac';
      case '128k':
      case '320k':
      default:
        return 'mp3';
    }
  }

  static String _sanitizeFilename(String name) {
    return name
        .replaceAll(RegExp(r'[/\\:*?"<>|]'), '')
        .replaceAll(RegExp(r'^\.+'), '')
        .replaceAll(RegExp(r'\.+$'), '')
        .trim();
  }
}
