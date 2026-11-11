import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/backup/auto_backup.dart';
import '../../core/backup/playlist_sync_service.dart';
import '../../core/backup/sync_timeout.dart';
import '../../core/backup/webdav_service.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_surface.dart';
import '../../core/theme/theme_provider.dart';
import '../../features/library/application/playlist_providers.dart';
import '../../features/settings/application/settings_providers.dart';

enum _SyncPhase { idle, syncing, success }

/// 歌单同步按钮：同步中显示转圈，成功后显示勾选，可再次点击同步。
///
/// [alsoBackup] 为 true 时，歌单同步完成后还会把当前配置备份一份到 WebDAV
/// （「设置 → 备份还原 → 立即同步」用，逻辑 = 歌单同步 + 备份）。
class PlaylistSyncButton extends ConsumerStatefulWidget {
  const PlaylistSyncButton({
    super.key,
    this.alsoBackup = false,
    this.compact = false,
  });

  final bool alsoBackup;

  /// 只显示图标（与本地页顶部的「扫描」按钮同款 40×40 圆角方块）。
  final bool compact;

  @override
  ConsumerState<PlaylistSyncButton> createState() => _PlaylistSyncButtonState();
}

class _PlaylistSyncButtonState extends ConsumerState<PlaylistSyncButton> {
  _SyncPhase _phase = _SyncPhase.idle;
  Timer? _successTimer;

  /// 本次同步是第几次尝试（1 = 用户刚点的这次，2 起是「重新同步」）。
  /// 首次 1 分钟超时，重试 2 分钟超时。
  int _attempt = 0;

  /// 正在进行的这次同步（点「同步中」按钮时用它取消）。
  SyncAttempt? _current;

  /// 这次结束是用户主动点停的（不是超时 / 网络错误），不弹失败框。
  bool _stopped = false;

  @override
  void dispose() {
    _successTimer?.cancel();
    // 离开页面不主动取消：同步会在后台跑完（有超时兜底），
    // 回来时按钮恢复成空闲态即可。
    super.dispose();
  }

  /// 用户点击：空闲时开始同步，同步中再点一次就是「停止」。
  Future<void> _sync() async {
    if (_phase == _SyncPhase.syncing) {
      _stop();
      return;
    }
    _successTimer?.cancel();
    _attempt = 0;
    await _runSync();
  }

  /// 停止当前同步：取消底层 HTTP 请求，已改动到一半的本地歌单会被还原。
  void _stop() {
    final op = _current;
    if (op == null || _stopped) return;
    _stopped = true;
    op.cancel('已停止同步');
  }

  /// 真正执行一次同步（超时按 [_attempt] 决定：首次 1 分钟，重试 2 分钟）。
  Future<void> _runSync() async {
    _attempt += 1;
    _successTimer?.cancel();
    setState(() => _phase = _SyncPhase.syncing);

    final config = ref.read(webDavConfigProvider);
    final op = SyncAttempt(_attempt);
    _current = op;
    _stopped = false;
    try {
      if (!config.isConfigured) {
        throw const WebDavException('未配置 WebDAV：请先在「设置 → 备份还原」中填写 WebDAV 地址');
      }
      // 整次尝试（等本地歌单 + 拉取合并）共用一个超时，避免服务器
      // 「连上了但一直不回」时界面无限停在「同步中」。
      // 超时 / 手动停止都会取消底层 HTTP 请求（迟到的响应不会被合并）。
      await op.run(() async {
        // 确保本地歌单（含「我的收藏」）已就绪，再与远端合并。
        await ref.read(playlistsProvider.future);
        await PlaylistSyncService.pullAndMerge(
          WebDavService(config, cancelToken: op.cancelToken),
        );
        if (widget.alsoBackup) {
          // 歌单同步完再备份一份配置（与「备份到 WebDAV」同一套流程）。
          // 单独包一层：备份失败时用户要知道「歌单已经同步成功」。
          try {
            await AutoBackup.runNow();
          } catch (e) {
            throw WebDavException('歌单已同步，但备份配置失败：${describeWebDavError(e)}');
          }
        }
      }());
      // 旧的一次同步（已被新的点击取代）不再影响界面。
      if (!mounted || !identical(_current, op)) return;
      ref.invalidate(playlistsProvider);
      setState(() => _phase = _SyncPhase.success);
      _successTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _phase = _SyncPhase.idle);
      });
    } catch (e) {
      if (!mounted || !identical(_current, op)) return;
      setState(() => _phase = _SyncPhase.idle);
      if (_stopped) {
        _toastStopped();
        return;
      }
      await _showFailure(describeWebDavError(e));
    } finally {
      if (identical(_current, op)) _current = null;
    }
  }

  /// 提示「已停止同步」（比弹框轻，停止是用户自己的操作）。
  void _toastStopped() {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(context.tr('已停止同步')),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _showFailure(String reason) async {
    if (!mounted) return;
    final colors = ref.read(themeColorsProvider);
    final retry = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.dialogSurface,
        title: Text(
          widget.alsoBackup ? tr('同步失败') : tr('歌单同步失败'),
          style: TextStyle(color: colors.textPrimary),
        ),
        content: SingleChildScrollView(
          child: Text(
            tr('同步失败原因：\n$reason'),
            style: TextStyle(color: colors.textSecondary),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('取消'), style: TextStyle(color: colors.textHint)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('重新同步'), style: TextStyle(color: colors.primary)),
          ),
        ],
      ),
    );
    if (retry == true && mounted) await _runSync();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final syncing = _phase == _SyncPhase.syncing;
    final success = _phase == _SyncPhase.success;
    final foreground = success ? colors.success : colors.textSecondary;
    final tooltip = syncing
        ? context.tr('点击停止同步')
        : success
        ? context.tr('已同步')
        : widget.alsoBackup
        ? context.tr('同步歌单并备份配置')
        : context.tr('同步歌单');

    if (widget.compact) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _sync,
        child: Tooltip(
          message: tooltip,
          waitDuration: const Duration(milliseconds: 600),
          child: Container(
            width: 40,
            height: 40,
            decoration: success
                ? BoxDecoration(
                    color: colors.success.withValues(alpha: 0.08),
                    border: Border.all(color: colors.success),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  )
                : floatingButtonDecoration(colors, radius: AppRadius.md),
            child: Center(
              child: syncing
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.primary,
                      ),
                    )
                  : Icon(
                      success ? Icons.check_circle : Icons.sync,
                      size: 20,
                      color: foreground,
                    ),
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 同步中再点一次 = 停止（会取消底层请求，并把改到一半的本地歌单还原）。
      onTap: _sync,
      child: Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 600),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: 6,
          ),
          decoration: success
              ? BoxDecoration(
                  color: colors.success.withValues(alpha: 0.08),
                  border: Border.all(color: colors.success),
                  borderRadius: BorderRadius.circular(AppRadius.full),
                )
              // 常态与发现页 / 本地页顶栏按钮一致：底色 + 轻阴影，不画描边。
              : floatingButtonDecoration(colors),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (syncing)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.primary,
                  ),
                )
              else
                Icon(
                  success ? Icons.check_circle : Icons.sync,
                  size: 14,
                  color: foreground,
                ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                success
                    ? context.tr('已同步')
                    : syncing
                    ? context.tr('同步中')
                    : context.tr('同步'),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: foreground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
