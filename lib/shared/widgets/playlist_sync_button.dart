import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/backup/playlist_sync_service.dart';
import '../../core/backup/webdav_service.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/theme_provider.dart';
import '../../features/library/application/playlist_providers.dart';
import '../../features/settings/application/settings_providers.dart';

enum _SyncPhase { idle, syncing, success }

/// 歌单同步按钮：同步中显示转圈，成功后显示勾选，可再次点击同步。
class PlaylistSyncButton extends ConsumerStatefulWidget {
  const PlaylistSyncButton({super.key});

  @override
  ConsumerState<PlaylistSyncButton> createState() => _PlaylistSyncButtonState();
}

class _PlaylistSyncButtonState extends ConsumerState<PlaylistSyncButton> {
  _SyncPhase _phase = _SyncPhase.idle;
  Timer? _successTimer;

  @override
  void dispose() {
    _successTimer?.cancel();
    super.dispose();
  }

  Future<void> _sync() async {
    if (_phase == _SyncPhase.syncing) return;
    _successTimer?.cancel();
    setState(() => _phase = _SyncPhase.syncing);

    final config = ref.read(webDavConfigProvider);
    try {
      if (!config.isConfigured) {
        throw const WebDavException('未配置 WebDAV：请先在「设置 → 备份还原」中填写 WebDAV 地址');
      }
      // 确保本地歌单（含「我的收藏」）已就绪，再与远端合并。
      await ref.read(playlistsProvider.future);
      await PlaylistSyncService.pullAndMerge(WebDavService(config));
      if (!mounted) return;
      ref.invalidate(playlistsProvider);
      setState(() => _phase = _SyncPhase.success);
      _successTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _phase = _SyncPhase.idle);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _phase = _SyncPhase.idle);
      await _showFailure(describeWebDavError(e));
    }
  }

  Future<void> _showFailure(String reason) async {
    if (!mounted) return;
    final colors = ref.read(themeColorsProvider);
    final retry = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(tr('歌单同步失败'), style: TextStyle(color: colors.textPrimary)),
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
    if (retry == true && mounted) await _sync();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final syncing = _phase == _SyncPhase.syncing;
    final success = _phase == _SyncPhase.success;
    final foreground = success ? colors.success : colors.textSecondary;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: syncing ? null : _sync,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 6,
        ),
        decoration: BoxDecoration(
          color: success
              ? colors.success.withValues(alpha: 0.08)
              : Colors.transparent,
          border: Border.all(color: success ? colors.success : colors.divider),
          borderRadius: BorderRadius.circular(AppRadius.full),
        ),
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
    );
  }
}
