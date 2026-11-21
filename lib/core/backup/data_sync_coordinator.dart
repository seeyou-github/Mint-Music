import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart' as dio;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../features/blacklist/application/blacklist_providers.dart';
import '../../features/player/application/play_progress_providers.dart';
import '../../features/radio/application/radio_providers.dart';
import '../../features/settings/application/settings_providers.dart';
import '../platform/app_paths.dart';
import 'delayed_sync.dart';
import 'extras_sync_service.dart';
import 'progress_sync_service.dart';
import 'sync_timeout.dart';
import 'webdav_service.dart';

/// 附加数据（黑名单 / 电台）与播放进度的同步编排。
///
/// 三份数据共用同一个 WebDAV 账号，但各自走独立的内容寻址快照：
/// * 歌单：原有 [PlaylistSyncService]，不在这里改；
/// * 附加数据：[ExtrasSyncService]；
/// * 播放进度：[ProgressSyncService]。
///
/// 触发来源：
/// * 手动同步 / 启动同步 / 歌单自动同步成功后 → [syncAfterPlaylist]（三段一起跑）；
/// * `settings.json` 任意写盘 → [scheduleExtras]（延迟 1 → 3 → 5 分钟）；
/// * 播放进度记录（切歌 / 暂停 / 停止 / 播完 / 退出）→ [progressChanged]，
///   自动推送最小间隔 10 分钟；
/// * 清空进度 → [progressCleared]（立即推送）；
/// * 退出应用 → [markExitSyncPending]（只写 temp 标记，不在关窗时打网络；
///   下次启动检测到标记后立即补一次同步）。
class DataSyncCoordinator {
  DataSyncCoordinator._();

  /// 进度自动推送最小间隔。
  ///
  /// 单次推送内部遇到网络抖动会先就地重试（见 `_progressRetryDelays`）；
  /// 重试用完才算这次失败，失败也按同样间隔等下一轮，不做跨轮的升级退避。
  static const Duration progressInterval = Duration(minutes: 10);

  static ProviderContainer? _container;

  /// 正在跑附加数据 / 进度同步的任务数：这期间设置写盘（同步自己会写同步
  /// 状态）不再反向触发调度。
  ///
  /// 用计数而不是布尔：手动同步、自动歌单同步、延迟 extras、进度推送、退出
  /// 同步可能同时进来（各自有独立超时），布尔标志会被先结束的那个提前清掉，
  /// 让第三个任务误以为没人跑。
  static int _busyCount = 0;

  static bool get _busy => _busyCount > 0;

  static void _enterBusy() => _busyCount++;

  static void _exitBusy() {
    if (_busyCount > 0) _busyCount--;
  }

  static final DelayedSync _extrasDelayed = DelayedSync(
    fileName: 'sync_extras.pending',
    run: _runScheduledExtras,
  );

  static DateTime? _lastProgressPush;
  static Timer? _progressTimer;
  static bool _progressRequested = false;
  static bool _progressForce = false;

  static void attach(ProviderContainer container) {
    _container = container;
    unawaited(_resumeIfPending(container));
  }

  /// 上次退出时还有一次附加数据同步没跑：启动后按 1 分钟补上。
  static Future<void> _resumeIfPending(ProviderContainer container) async {
    if (!_enabled(container)) return;
    await _extrasDelayed.resumeIfPending();
  }

  /// 总开关 + WebDAV 已配置时才自动同步。
  static bool _enabled(ProviderContainer container) {
    final config = container.read(webDavConfigProvider);
    return config.playlistSyncEnabled && config.isConfigured;
  }

  // ------------------------------------------------------------ 附加数据

  /// 设置写盘后调用（与 [AutoBackup.schedule] 一起挂在
  /// `AppPreferences.onWrite`）。
  static void scheduleExtras() {
    final container = _container;
    if (container == null) return;
    if (_busy) return;
    if (!_enabled(container)) return;
    _extrasDelayed.trigger();
  }

  /// 关闭「自动同步」时取消还在等待的附加数据同步。
  static void cancelScheduled() => _extrasDelayed.cancel();

  static Future<void> _runScheduledExtras() async {
    final container = _container;
    if (container == null) return;
    if (!_enabled(container)) return;
    // 正在跑别的同步：稍后按下一档延迟再来一次。
    if (_busy) {
      _extrasDelayed.trigger();
      return;
    }
    _enterBusy();
    try {
      final config = container.read(webDavConfigProvider);
      final op = SyncAttempt(1);
      final webdav = WebDavService(config, cancelToken: op.cancelToken);
      op.attachDiagnosis(() => webdav.diagnosis);
      final changed = await op.run(ExtrasSyncService.pullAndMerge(webdav));
      if (changed.changed) await _reloadExtras(container, changed);
    } catch (e) {
      debugPrint('[DataSync] 附加数据自动同步失败: $e');
    } finally {
      _exitBusy();
      _maybeScheduleProgress();
    }
  }

  // ------------------------------------------------------------ 歌单同步之后

  /// 歌单同步（手动 / 启动 / 自动）完成后调用：接着同步附加数据与播放进度。
  ///
  /// 复用调用方的 [webdav]（共享超时与取消令牌），失败向上抛出，让界面
  /// 提示「歌单已同步，但附加数据同步失败」。
  static Future<void> syncAfterPlaylist(WebDavService webdav) async {
    final container = _container;
    _enterBusy();
    _extrasDelayed.cancel();
    _progressTimer?.cancel();
    _progressTimer = null;
    try {
      final extrasChanged = await ExtrasSyncService.pullAndMerge(webdav);
      if (extrasChanged.changed && container != null) {
        await _reloadExtras(container, extrasChanged);
      }
      if (container != null) {
        // 正在播放的进度可能还在延迟写队列里，先落盘再合并。
        await container.read(playProgressStoreProvider).flush();
      }
      final progressChanged = await ProgressSyncService.pullAndMerge(webdav);
      _lastProgressPush = DateTime.now();
      if (progressChanged && container != null) {
        // 合并期间可能又记录了新进度，统一落盘后再读回内存。
        await container.read(playProgressStoreProvider).flush();
        await container.read(playedProgressProvider.notifier).reload();
      }
    } finally {
      _exitBusy();
      _maybeScheduleProgress();
    }
  }

  /// 「自动歌单同步」成功后（已有自己的网络调用）再补一次附加数据同步。
  ///
  /// 自动同步没有现成的 [WebDavService]，这里单独建一个、单独计时；
  /// 失败只记日志，不影响歌单同步的状态提示。
  static Future<void> syncDataAfterAutoPlaylist() async {
    final container = _container;
    if (container == null) return;
    if (_busy) return;
    if (!_enabled(container)) return;
    final config = container.read(webDavConfigProvider);
    _enterBusy();
    _extrasDelayed.cancel();
    try {
      final op = SyncAttempt(1);
      final webdav = WebDavService(config, cancelToken: op.cancelToken);
      op.attachDiagnosis(() => webdav.diagnosis);
      await op.run(() async {
        final extrasChanged = await ExtrasSyncService.pullAndMerge(webdav);
        if (extrasChanged.changed) {
          await _reloadExtras(container, extrasChanged);
        }
        await container.read(playProgressStoreProvider).flush();
        final progressChanged = await ProgressSyncService.pullAndMerge(webdav);
        _lastProgressPush = DateTime.now();
        if (progressChanged) {
          await container.read(playProgressStoreProvider).flush();
          await container.read(playedProgressProvider.notifier).reload();
        }
      }());
    } catch (e) {
      debugPrint('[DataSync] 自动同步附加数据失败: $e');
    } finally {
      _exitBusy();
      _maybeScheduleProgress();
    }
  }

  // ------------------------------------------------------------ 播放进度

  /// 记录了一次播放进度（切歌 / 暂停 / 停止 / 播完）。
  ///
  /// 不是每次记录都推：10 分钟内只推一次，期间记录的数据攒着，到点一起传。
  static void progressChanged() {
    if (_container == null) return;
    _progressRequested = true;
    _maybeScheduleProgress();
  }

  /// 「最近播放」页清空进度后调用：立即推送（不受 10 分钟间隔限制）。
  static void progressCleared() {
    if (_container == null) return;
    _progressRequested = true;
    _progressForce = true;
    _progressTimer?.cancel();
    _progressTimer = null;
    _maybeScheduleProgress();
  }

  static void _maybeScheduleProgress() {
    final container = _container;
    if (container == null) return;
    if (!_progressRequested) return;
    if (_busy) return;
    if (_progressTimer != null) return;
    if (!_enabled(container)) {
      _progressRequested = false;
      _progressForce = false;
      return;
    }
    if (_progressForce) {
      _progressForce = false;
      _progressRequested = false;
      unawaited(_runProgress(container.read(webDavConfigProvider)));
      return;
    }
    final last = _lastProgressPush;
    final wait = last == null
        ? Duration.zero
        : progressInterval - DateTime.now().difference(last);
    if (wait <= Duration.zero) {
      _progressRequested = false;
      unawaited(_runProgress(container.read(webDavConfigProvider)));
      return;
    }
    _progressTimer = Timer(wait, () {
      _progressTimer = null;
      _maybeScheduleProgress();
    });
  }

  /// 进度推送失败后就地重试的间隔（次数 = 长度）。
  ///
  /// 连接超时（Dio 的 15s）这类错误多半是网络抽风，隔几秒再试通常就好了。
  /// 以前一次失败就等到 10 分钟后的下一轮，用户中途关掉软件进度就丢了。
  static const List<Duration> _progressRetryDelays = <Duration>[
    Duration(seconds: 3),
    Duration(seconds: 9),
  ];

  /// 这类错误值得重试吗。
  ///
  /// 只认「连不上 / 连到一半断了 / 收包超时」；认证失败、404、冲突这些重试
  /// 多少次都一样，直接等下一轮。
  static bool _isTransientNetworkError(Object error) {
    if (error is SocketException) return true;
    if (error is dio.DioException) {
      switch (error.type) {
        case dio.DioExceptionType.connectionTimeout:
        case dio.DioExceptionType.sendTimeout:
        case dio.DioExceptionType.receiveTimeout:
        case dio.DioExceptionType.connectionError:
          return true;
        case dio.DioExceptionType.unknown:
          return error.error is SocketException;
        case dio.DioExceptionType.badResponse:
        case dio.DioExceptionType.badCertificate:
        case dio.DioExceptionType.cancel:
        case dio.DioExceptionType.transformTimeout:
          return false;
      }
    }
    return false;
  }

  static Future<void> _runProgress(WebDavConfig config) async {
    final container = _container;
    if (container == null) return;
    _enterBusy();
    try {
      await container.read(playProgressStoreProvider).flush();
      for (var attempt = 0; ; attempt++) {
        final op = SyncAttempt(1);
        final webdav = WebDavService(config, cancelToken: op.cancelToken);
        try {
          final changed = await op.run(
            ProgressSyncService.pullAndMerge(webdav),
          );
          if (changed) {
            await container.read(playProgressStoreProvider).flush();
            await container.read(playedProgressProvider.notifier).reload();
          }
          break;
        } catch (e) {
          // 重试用完，或这次错得不值得重试（认证 / 404 等）：交给外层记录。
          if (attempt >= _progressRetryDelays.length ||
              !_isTransientNetworkError(e)) {
            rethrow;
          }
          final delay = _progressRetryDelays[attempt];
          await Future<void>.delayed(delay);
          // 等的时候用户关掉了自动同步：别再打了。
          if (!_enabled(container)) return;
        }
      }
    } catch (e) {
      debugPrint('[DataSync] 播放进度自动同步失败: $e');
    } finally {
      // 成功或最终失败都从这一刻起重新计 10 分钟：失败也不立刻重排，
      // 免得网络不通时反复打服务器。
      _lastProgressPush = DateTime.now();
      _exitBusy();
      _maybeScheduleProgress();
    }
  }

  // ------------------------------------------------------------ 退出

  static const String _exitPendingName = 'sync_exit.pending';

  /// 退出应用前调用：只在 `temp` 写一个待同步标记，不发起任何网络请求。
  ///
  /// 关窗时等待 WebDAV 往返会让窗口迟迟不消失；这里把「退出同步」推迟到
  /// 下次启动。注意标记**不代表要立刻同步**——它是每次正常退出都会写的，
  /// 启动同步统一走 1 分钟延迟（见 `App._scheduleStartupSync`）；
  /// 成功后用 [clearExitSyncPending] 清掉。
  static Future<void> markExitSyncPending() async {
    final container = _container;
    if (container == null || !_enabled(container)) return;
    await _writeExitMarker();
  }

  /// 补同步成功后清掉退出标记（失败时保留，下次启动再试）。
  static Future<void> clearExitSyncPending() async {
    try {
      final file = await _exitMarkerFile();
      if (file != null && await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('[DataSync] 清除退出同步标记失败: $e');
    }
  }

  static Future<File?> _exitMarkerFile() async {
    try {
      final dir = await AppPaths.tempDirectory();
      return File(p.join(dir.path, _exitPendingName));
    } catch (e) {
      debugPrint('[DataSync] 取临时目录失败: $e');
      return null;
    }
  }

  static Future<void> _writeExitMarker() async {
    try {
      final file = await _exitMarkerFile();
      if (file == null) return;
      await file.writeAsString(DateTime.now().toIso8601String(), flush: true);
    } catch (e) {
      debugPrint('[DataSync] 写入退出同步标记失败: $e');
    }
  }

  // ------------------------------------------------------------ 内部

  static Future<void> _reloadExtras(
    ProviderContainer container,
    ExtrasSyncResult result,
  ) async {
    if (result.blacklist) {
      try {
        await container.read(blacklistProvider.notifier).reload();
      } catch (e) {
        debugPrint('[DataSync] 重读黑名单失败: $e');
      }
    }
    if (result.radio) {
      try {
        await container.read(radioProvider.notifier).reload();
      } catch (e) {
        debugPrint('[DataSync] 重读电台失败: $e');
      }
    }
  }
}
