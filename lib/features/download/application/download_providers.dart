import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import '../../../core/l10n/l10n.dart';
import '../../local/data/local_metadata_reader.dart';
import '../../player/domain/models/song.dart';
import '../../settings/application/settings_providers.dart';
import '../../plugin/application/plugin_providers.dart';
import '../data/download_repository.dart';
import '../domain/models/download_task.dart';

class DownloadNotification {
  final String message;
  final Color? backgroundColor;

  /// 显示时长：失败提示带原因，太短看不清。
  final Duration duration;

  DownloadNotification({
    required this.message,
    this.backgroundColor,
    this.duration = const Duration(seconds: 2),
  });
}

final downloadNotificationProvider = StateProvider<DownloadNotification?>(
  (ref) => null,
);

final downloadRepositoryProvider = Provider<DownloadRepository>((ref) {
  final repo = DownloadRepository();

  // 下载目录不会被自动加进本地页的扫描目录：扫描哪些目录完全由用户决定。

  // 异步初始化下载器（恢复任务 + 读取下载目录）。
  //
  // 首次点下载时这里可能还没执行完，此时 DownloadRepository.addTask 会
  // 自行从持久化设置里兜底读取目录，不会再用到硬编码的默认路径。
  unawaited(() async {
    try {
      final svc = await ref.read(settingsServiceProvider.future);
      await repo.init(
        downloadDir: await svc.getDownloadDir(),
        // 仅 WiFi 下载设置项已移除，固定为任意网络。
        wifiOnly: false,
        maxConcurrent: 3,
      );
    } catch (e) {
      // 设置初始化失败 / 超时也要初始化，让 addTask 使用持久化目录兜底。
      debugPrint('[DownloadProviders] 下载器初始化失败，使用持久化配置: $e');
      try {
        await repo.init(wifiOnly: false, maxConcurrent: 3);
      } catch (e2) {
        debugPrint('[DownloadProviders] 下载器兜底初始化失败: $e2');
      }
    }
  }());

  // 设置 URL 获取器
  final musicSourceManager = ref.read(musicSourceManagerProvider);
  repo.setUrlFetcher((task) async {
    // 平台歌曲没有地址接口：由插件解析，失败再换其它已安装的插件，
    // 实际使用的音源会写进下载任务里（下载列表里显示出来源）。
    //
    // 插件报错原因收下来：以前解析失败只会得到一句「无法获取播放链接」，
    // 用户不知道是没版权、插件没登录还是格式不支持。
    String? failure;
    final resolved = await musicSourceManager.getMusicUrlForDownload(
      task.song,
      quality: task.quality,
      onResolveError: (message) {
        if (message.trim().isNotEmpty) failure = message.trim();
      },
    );
    if (resolved == null) {
      return DownloadUrlResult(
        url: '',
        error: failure == null
            ? tr('无法获取播放链接：没有可用的音源能解析这首歌')
            : tr('无法获取播放链接：$failure'),
      );
    }
    return DownloadUrlResult(
      url: resolved.url,
      source: resolved.source,
      // 请求头必须一起交给下载器：B 站 / 网易的 CDN 会校验 Referer，
      // 缺了就是「能播放、下载 403」。
      headers: resolved.headers,
    );
  });

  // 设置标签写入选项获取器（对齐 CeruMusic tagWriteOptions）
  repo.setTagWriteOptionsFetcher(() {
    return TagWriteOptions(
      basicInfo: ref.read(tagWriteBasicInfoProvider),
      cover: ref.read(tagWriteCoverProvider),
      lyrics: ref.read(tagWriteLyricsProvider),
      downloadLyrics: ref.read(tagWriteDownloadLyricsProvider),
      lyricFormat: ref.read(tagWriteLyricFormatProvider),
    );
  });

  // 设置歌词获取器（下载时若歌词为空则实时获取）
  repo.setLyricFetcher((song) async {
    try {
      return await musicSourceManager.getLyric(song);
    } catch (e) {
      return null;
    }
  });

  // 设置逐字歌词获取器（下载时获取逐字歌词）
  repo.setLyricResultFetcher((song) async {
    try {
      return await musicSourceManager.getLyricResult(song);
    } catch (e) {
      return null;
    }
  });

  // 设置封面获取器（下载时获取高清封面URL）
  repo.setCoverFetcher((song) async {
    try {
      return await musicSourceManager.getPic(song);
    } catch (e) {
      return null;
    }
  });

  // 设置音质验证器：只允许插件**为自己声明过**的下载音质，避免下载任务
  // 拿到一个插件根本给不了的档位（表现为「下载完发现是 128k」）。
  //
  // 按整首歌取「实际出面解析地址的那个源」的音质声明：数据源歌曲的
  // `song.source` 是数据源插件（不提供下载），下载音质要看配置的播放源，
  // 否则下载菜单里能选的档位到这里会被误判成「不受支持」。
  repo.setQualityValidator((song) {
    final sourceId =
        musicSourceManager.effectivePlaybackSourceForSong(song) ??
        song.source ??
        '';
    return musicSourceManager.getDownloadQualitiesForSourceId(sourceId);
  });

  // 下载通知回调
  repo.onTaskStarted = (task, {backgroundColor}) {
    ref.read(downloadNotificationProvider.notifier).state =
        DownloadNotification(message: tr('开始下载 ${task.song.title}'));
  };
  repo.onTaskCompleted = (task, {backgroundColor}) {
    ref.read(downloadNotificationProvider.notifier).state =
        DownloadNotification(message: tr('${task.song.title} 下载完成'));
  };
  repo.onTaskError = (task, error, {backgroundColor}) {
    final detail = error.trim();
    ref
        .read(downloadNotificationProvider.notifier)
        .state = DownloadNotification(
      // 带上具体原因：失败提示只说「下载失败」等于没说。
      message: detail.isEmpty
          ? tr('${task.song.title} 下载失败')
          : tr('${task.song.title} 下载失败：$detail'),
      backgroundColor: backgroundColor ?? Colors.red,
      duration: const Duration(seconds: 5),
    );
  };

  // 监听设置变化（初始化完成前不主动覆盖，避免把尚未加载完的默认值写进 repo）
  ref.listen(downloadDirProvider, (prev, next) {
    repo.updateSettings(downloadDir: next);
  });
  ref.listen(wifiOnlyDownloadProvider, (prev, next) {
    repo.updateSettings(wifiOnly: next);
  });

  ref.onDispose(() => repo.dispose());
  return repo;
});

final downloadTasksProvider = StreamProvider<List<DownloadTask>>((ref) {
  final repo = ref.watch(downloadRepositoryProvider);
  return repo.taskStream;
});

/// 下载目录里扫描到的一个本地音频文件。
class DownloadDirSong {
  const DownloadDirSong({
    required this.song,
    required this.size,
    required this.modifiedAt,
  });

  final Song song;

  /// 文件大小（字节），列表右侧显示。
  final int size;

  /// 文件修改时间，用来把最新下载的文件排在前面。
  final int modifiedAt;
}

/// 下载目录里现存的本地音频文件。
///
/// autoDispose：每次进入下载页都会重新扫描（离开页面即销毁），这样用户
/// 在应用外往下载目录里放 / 删了文件，下次进来能直接反映出来。
/// 历史下载任务只存在内存里，重启后列表是空的，这些扫描结果就是「已下载
/// 的歌曲」的来源。
final downloadDirSongsProvider =
    FutureProvider.autoDispose<List<DownloadDirSong>>((ref) async {
      final dir = ref.watch(downloadDirProvider).trim();
      if (dir.isEmpty) return const [];
      final directory = Directory(dir);
      if (!await directory.exists()) return const [];

      final filePaths = <String>[];
      try {
        await for (final entity in directory.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File && LocalMetadataReader.isAudioFile(entity.path)) {
            filePaths.add(entity.path);
          }
        }
      } catch (e) {
        debugPrint('[Download] 扫描下载目录失败: $e');
        return const [];
      }

      final songs = <DownloadDirSong>[];
      for (final filePath in filePaths) {
        try {
          final stat = await File(filePath).stat();
          final metadata = await LocalMetadataReader.read(filePath);
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
          final embeddedLyric = metadata.lyrics?.trim() ?? '';

          songs.add(
            DownloadDirSong(
              song: Song(
                id: _localSongId(filePath),
                title: title,
                artist: artist,
                album: album,
                duration: metadata.durationSeconds ?? 0,
                source: 'local',
                filePath: filePath,
                sourceUrl: filePath,
                hasCover: metadata.artwork != null,
                coverKey: _localCoverKey(filePath),
                year: metadata.year,
                genre: metadata.genre,
                comment: metadata.comment,
                hasLyric: embeddedLyric.isNotEmpty,
              ),
              size: stat.size,
              modifiedAt: stat.modified.millisecondsSinceEpoch,
            ),
          );
        } catch (e) {
          debugPrint('[Download] 读取下载文件失败: $filePath - $e');
        }
      }

      // 新下载的文件排前面。
      songs.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
      return songs;
    });

/// 本地歌曲 id / 封面缓存 key 的生成方式与本地音乐扫描保持一致，
/// 这样同一首歌在本地页与下载页显示同样的封面、共享播放记录。
String _localSongId(String filePath) {
  final normalized = filePath.replaceAll('\\', '/');
  return md5.convert(utf8.encode(normalized)).toString().substring(0, 16);
}

String _localCoverKey(String filePath) {
  final normalized = filePath.replaceAll('\\', '/');
  return md5
      .convert(utf8.encode('cover_$normalized'))
      .toString()
      .substring(0, 16);
}

final downloadSearchQueryProvider = StateProvider<String>((ref) => '');

final filteredDownloadTasksProvider = Provider<List<DownloadTask>>((ref) {
  final query = ref.watch(downloadSearchQueryProvider);
  final tasksAsync = ref.watch(downloadTasksProvider);
  return tasksAsync.when(
    data: (tasks) {
      if (query.isEmpty) return tasks;
      return tasks
          .where(
            (t) =>
                t.song.title.toLowerCase().contains(query.toLowerCase()) ||
                t.song.artist.toLowerCase().contains(query.toLowerCase()),
          )
          .toList();
    },
    loading: () => [],
    error: (_, __) => [],
  );
});

final downloadStatsProvider =
    Provider<({int total, int downloading, int completed, int failed})>((ref) {
      final tasksAsync = ref.watch(downloadTasksProvider);
      return tasksAsync.when(
        data: (tasks) {
          final downloading = tasks
              .where(
                (t) =>
                    t.status == DownloadStatus.downloading ||
                    t.status == DownloadStatus.queued,
              )
              .length;
          final completed = tasks
              .where((t) => t.status == DownloadStatus.completed)
              .length;
          final failed = tasks
              .where(
                (t) =>
                    t.status == DownloadStatus.error ||
                    t.status == DownloadStatus.cancelled ||
                    t.status == DownloadStatus.fileMissing,
              )
              .length;
          return (
            total: tasks.length,
            downloading: downloading,
            completed: completed,
            failed: failed,
          );
        },
        loading: () => (total: 0, downloading: 0, completed: 0, failed: 0),
        error: (_, __) => (total: 0, downloading: 0, completed: 0, failed: 0),
      );
    });
