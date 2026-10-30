import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/l10n/l10n.dart';
import '../../local/application/local_providers.dart';
import '../../settings/application/settings_providers.dart';
import '../../plugin/application/plugin_providers.dart';
import '../data/download_repository.dart';
import '../domain/models/download_task.dart';

class DownloadNotification {
  final String message;
  final Color? backgroundColor;
  DownloadNotification({required this.message, this.backgroundColor});
}

final downloadNotificationProvider = StateProvider<DownloadNotification?>(
  (ref) => null,
);

final downloadRepositoryProvider = Provider<DownloadRepository>((ref) {
  final repo = DownloadRepository();

  // 当下载目录变化时，自动注册到本地音乐扫描器
  repo.onDirectoryChanged = (dir) {
    final localRepo = ref.read(localMusicRepositoryProvider);
    localRepo.addDirectory(dir);
  };

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
    final resolved = await musicSourceManager.getMusicUrlForDownload(
      task.song,
      quality: task.quality,
    );
    if (resolved == null) return null;
    return (url: resolved.url, source: resolved.source);
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
  repo.setQualityValidator((sourceId) {
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
    ref
        .read(downloadNotificationProvider.notifier)
        .state = DownloadNotification(
      message: tr('${task.song.title} 下载失败'),
      backgroundColor: backgroundColor ?? Colors.red,
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
