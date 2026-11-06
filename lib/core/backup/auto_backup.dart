import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/application/settings_providers.dart';
import 'backup_service.dart';
import 'sync_timeout.dart';
import 'webdav_service.dart';

/// 配置变更后的自动备份（「自动同步」开关控制）。
///
/// 触发源是 `settings.json` 的每一次写盘（[AppPreferences.onWrite]），因此
/// 插件安装 / 卸载 / 启停 / 排序、热榜增删改、电台增删改、扫描目录增删改、
/// 字体安装，以及任何设置项变更都会走到这里，不需要在每个业务入口各挂一次。
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

  /// 连续修改设置（拖动滑块、连续增删）合并成一次上传。
  static const Duration debounce = Duration(seconds: 10);

  /// 两次自动备份之间至少间隔这么久。
  ///
  /// 主题色 / 歌词偏移这类操作会连着写很多次 settings.json，只靠防抖仍然
  /// 可能在长时间调整中反复上传整个备份包；这里再压一道，最多一分钟一次。
  static const Duration minInterval = Duration(minutes: 1);

  static ProviderContainer? _container;
  static Timer? _debounceTimer;

  /// 上次自动备份成功的时间（用于 [minInterval] 节流）。
  static DateTime? _lastRunAt;

  /// 正在上传 / 上一轮还没结束时是否需要补跑一次。
  static bool _running = false;
  static bool _pending = false;

  /// 启动时注入容器（读 WebDAV 配置需要它）。
  static void attach(ProviderContainer container) {
    _container = container;
  }

  /// `settings.json` 写盘后调用；开关没开 / 没配 WebDAV / 还没注入容器时忽略。
  static void schedule() {
    final container = _container;
    if (container == null) return;
    if (!_isEnabled(container)) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () {
      _debounceTimer = null;
      unawaited(run());
    });
  }

  static bool _isEnabled(ProviderContainer container) {
    final config = container.read(webDavConfigProvider);
    return config.playlistSyncEnabled && config.isConfigured;
  }

  /// 立即执行一次自动备份（防抖到点后走这里）。失败只记日志，不打断用户。
  static Future<void> run() async {
    final container = _container;
    if (container == null) return;
    if (!_isEnabled(container)) return;
    if (_running) {
      // 上一轮还在上传：等它结束再补一次，保证最后一次改动一定会被上传。
      _pending = true;
      return;
    }
    // 刚备份过：等够间隔再补一次，期间的新改动会重新排这个等待。
    final last = _lastRunAt;
    if (last != null) {
      final elapsed = DateTime.now().difference(last);
      if (elapsed < minInterval) {
        _debounceTimer?.cancel();
        _debounceTimer = Timer(minInterval - elapsed, () {
          _debounceTimer = null;
          unawaited(run());
        });
        return;
      }
    }
    _running = true;
    try {
      await _upload(container.read(webDavConfigProvider));
      _lastRunAt = DateTime.now();
    } catch (e) {
      debugPrint('[AutoBackup] 自动备份失败: $e');
    } finally {
      _running = false;
      if (_pending) {
        _pending = false;
        unawaited(run());
      }
    }
  }

  /// 「立即同步」按钮用：跳过防抖，失败时把异常抛给调用方显示原因。
  ///
  /// 不受「自动同步」开关限制（用户是主动点按钮）。
  static Future<void> runNow() async {
    final container = _container;
    if (container == null) return;
    final config = container.read(webDavConfigProvider);
    if (!config.isConfigured) {
      throw const WebDavException('未配置 WebDAV：请先在「设置 → 备份还原」中填写 WebDAV 地址');
    }
    await _upload(config);
    // 手动同步也算一次备份：避免刚点完按钮，设置一变又立刻自动上传一份。
    _lastRunAt = DateTime.now();
  }

  static Future<void> _upload(WebDavConfig config) async {
    final bytes = await BackupService.createBackup();
    final op = SyncAttempt(1);
    await op.run(
      WebDavService(
        config,
        cancelToken: op.cancelToken,
      ).uploadBackup(bytes, remoteFileName),
    );
  }
}
