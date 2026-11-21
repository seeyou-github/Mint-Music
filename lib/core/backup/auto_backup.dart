import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/application/settings_providers.dart';
import 'backup_service.dart';
import 'delayed_sync.dart';
import 'playlist_sync_status.dart';
import 'sync_timeout.dart';
import 'webdav_service.dart';

/// 配置变更后的自动备份（「自动同步」开关控制）。
///
/// 触发源是 `settings.json` 的每一次写盘（[AppPreferences.onWrite]），因此
/// 插件安装 / 卸载 / 启停 / 排序、热榜增删改、电台增删改、扫描目录增删改、
/// 字体安装，以及任何设置项变更都会走到这里，不需要在每个业务入口各挂一次。
///
/// 不立即上传：交给 [DelayedSync] 按 1 → 3 → 5 分钟逐次延后，连续调设置
/// 不会把整包配置反复传上去。等待标志写在 `AppData\temp`，应用中途退出后
/// 下次启动按第一次的 1 分钟补跑。
///
/// 行为与「备份到 WebDAV」按钮一致：生成同一个备份压缩包并上传，区别只有
/// 文件名固定（见 [remoteFileName]）——自动同步如果也用时间戳命名，改一次
/// 设置就多一个远端文件，很快就会堆满。
class AutoBackup {
  AutoBackup._();

  /// 自动备份的远端文件名。
  ///
  /// 带 `mintmusic-backup` 前缀，所以也会出现在「从 WebDAV 还原」的列表里；
  /// 固定文件名保证每次覆盖，远端始终只有一份最新状态。
  static const String remoteFileName = 'auto-mintmusic-backup.zip';

  /// 连续修改设置（拖动滑块、连续增删）不立即上传：按 1 → 3 → 5 分钟
  /// 逐次延后，连续调设置不会把整包配置反复传上去。
  static final DelayedSync _delayed = DelayedSync(
    fileName: 'sync_settings.pending',
    run: _runScheduled,
  );

  static ProviderContainer? _container;

  /// 正在生成 / 上传备份：这期间设置写盘不再重新排队。
  static bool _running = false;

  /// 启动时注入容器（读 WebDAV 配置需要它）。
  static void attach(ProviderContainer container) {
    _container = container;
    // 上次退出时还有一次延迟备份没跑完：启动后按第一次的延迟补上。
    unawaited(_resumeIfPending(container));
  }

  static Future<void> _resumeIfPending(ProviderContainer container) async {
    if (!_isEnabled(container)) return;
    await _delayed.resumeIfPending();
  }

  /// `settings.json` 写盘后调用；开关没开 / 没配 WebDAV / 还没注入容器时忽略。
  static void schedule() {
    final container = _container;
    if (container == null) return;
    if (!_isEnabled(container)) return;
    // 备份过程本身也可能顺手写设置（导出前落盘），不能因此再排一轮。
    if (_running) return;
    _delayed.trigger();
  }

  static bool _isEnabled(ProviderContainer container) {
    final config = container.read(webDavConfigProvider);
    return config.playlistSyncEnabled && config.isConfigured;
  }

  /// 关闭「自动同步」时调用：作废还在等待的延迟备份并清掉临时标志。
  ///
  /// 不清的话，关开关后退出、以后重新打开时会按旧标志补跑一次。
  static void cancelScheduled() => _delayed.cancel();

  static Future<void> _runScheduled() async {
    final container = _container;
    if (container == null) return;
    // 等待期间开关可能被关掉了。
    if (!_isEnabled(container)) return;
    await run();
  }

  /// 执行一次自动备份（延迟到点后走这里）。失败只记日志，不打断用户。
  static Future<void> run() async {
    final container = _container;
    if (container == null) return;
    if (!_isEnabled(container)) return;
    if (_running) return;
    _running = true;
    // 设置变更触发的自动备份在窗口底部给出提示：生成备份包 + 上传可能
    // 要几秒，静默执行会让用户以为设置没生效 / 不知道正在写远端。
    final status = container.read(playlistSyncStatusProvider.notifier);
    status.start(kind: PlaylistSyncKind.backup);
    try {
      await _upload(container.read(webDavConfigProvider));
      status.succeed(kind: PlaylistSyncKind.backup);
    } catch (e) {
      debugPrint('[AutoBackup] 自动备份失败: $e');
      status.fail(describeWebDavError(e), kind: PlaylistSyncKind.backup);
    } finally {
      _running = false;
    }
  }

  /// 「立即同步」按钮用：跳过延迟，失败时把异常抛给调用方显示原因。
  ///
  /// 不受「自动同步」开关限制（用户是主动点按钮）。
  static Future<void> runNow() async {
    final container = _container;
    if (container == null) return;
    final config = container.read(webDavConfigProvider);
    if (!config.isConfigured) {
      throw const WebDavException('未配置 WebDAV：请先在「设置 → 备份还原」中填写 WebDAV 地址');
    }
    // 手动备份期间设置写盘不重新排队（备份自己想写设置也一样）。
    _running = true;
    try {
      await _upload(config);
      // 刚完整备份过：还在等的那次自动备份没必要再跑。
      _delayed.cancel();
    } finally {
      _running = false;
    }
  }

  static Future<void> _upload(WebDavConfig config) async {
    final bytes = await BackupService.createBackup();
    final op = SyncAttempt(1);
    final webdav = WebDavService(config, cancelToken: op.cancelToken);
    op.attachDiagnosis(() => webdav.diagnosis);
    await op.run(webdav.uploadBackup(bytes, remoteFileName));
  }
}
