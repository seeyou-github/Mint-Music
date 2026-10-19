import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';
import '../application/download_providers.dart';
import '../domain/models/download_task.dart';

/// 下载管理页。
///
/// 不再按「进行中 / 已完成 / 失败」分类，所有任务按下载时间倒序放在同一个
/// 列表里，用状态徽标区分；进行中可直接取消，已取消/失败可重试。
class DownloadPage extends ConsumerWidget {
  const DownloadPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(themeColorsProvider);
    final tasksAsync = ref.watch(downloadTasksProvider);

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildHeader(context, ref, colors, tasksAsync.valueOrNull ?? const []),
            Expanded(
              child: tasksAsync.when(
                data: (tasks) {
                  if (tasks.isEmpty) {
                    return _buildEmptyState(context, colors);
                  }
                  // 所有任务按下载时间倒序（最新的在最上面）。
                  final sorted = [...tasks]
                    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg,
                      0,
                      AppSpacing.lg,
                      AppSpacing.xxxl,
                    ),
                    itemCount: sorted.length,
                    addAutomaticKeepAlives: false,
                    addRepaintBoundaries: true,
                    itemBuilder: (context, index) =>
                        _DownloadTaskItem(task: sorted[index]),
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, __) => _buildEmptyState(context, colors),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    WidgetRef ref,
    ThemeColors colors,
    List<DownloadTask> tasks,
  ) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        ResponsiveLayout.horizontalPadding(context),
        AppSpacing.md,
        ResponsiveLayout.horizontalPadding(context),
        AppSpacing.md,
      ),
      child: Row(
        children: [
          if (context.canPop()) ...[
            IconButton(
              icon: Icon(Icons.arrow_back, color: colors.textPrimary),
              onPressed: () => context.pop(),
              visualDensity: VisualDensity.compact,
              tooltip: context.tr('返回'),
            ),
            const SizedBox(width: AppSpacing.xs),
          ],
          Expanded(
            child: Text(
              context.tr('下载管理'),
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: colors.textPrimary,
              ),
            ),
          ),
          _buildClearButton(context, ref, colors, tasks.isEmpty),
        ],
      ),
    );
  }

  Widget _buildClearButton(
    BuildContext context,
    WidgetRef ref,
    ThemeColors colors,
    bool disabled,
  ) {
    return Opacity(
      opacity: disabled ? 0.45 : 1,
      child: GestureDetector(
        onTap: disabled ? null : () => _confirmClear(context, ref, colors),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(AppRadius.full),
            border: Border.all(color: colors.divider),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.delete_sweep_outlined, size: 16, color: colors.textSecondary),
              const SizedBox(width: 4),
              Text(
                context.tr('清除下载列表'),
                style: TextStyle(fontSize: 12, color: colors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmClear(BuildContext context, WidgetRef ref, ThemeColors colors) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(
          context.tr('清除下载列表'),
          style: TextStyle(color: colors.textPrimary),
        ),
        content: Text(
          context.tr('确定要清除所有下载记录吗？已下载的文件不会被删除。'),
          style: TextStyle(color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              context.tr('取消'),
              style: TextStyle(color: colors.textHint),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(downloadRepositoryProvider).clearTasks('all');
            },
            child: Text(
              context.tr('清除'),
              style: TextStyle(color: colors.error),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, ThemeColors colors) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.download_outlined,
            size: 48,
            color: colors.textHint.withValues(alpha: 0.5),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            context.tr('暂无下载任务'),
            style: TextStyle(fontSize: 14, color: colors.textHint),
          ),
        ],
      ),
    );
  }
}

/// 单条下载任务：标题 + 状态徽标 + 进度 + 操作按钮。
class _DownloadTaskItem extends ConsumerWidget {
  const _DownloadTaskItem({required this.task});

  final DownloadTask task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(themeColorsProvider);
    final repo = ref.read(downloadRepositoryProvider);
    final status = _statusStyle(context, task.status, colors);
    final showProgress = task.status == DownloadStatus.downloading ||
        task.status == DownloadStatus.queued;

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: colors.divider.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: status.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(status.icon, size: 20, color: status.color),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      task.song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: colors.textHint),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              _StatusBadge(label: status.label, color: status.color),
            ],
          ),
          if (showProgress) ...[
            const SizedBox(height: AppSpacing.sm),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: task.status == DownloadStatus.queued ? null : task.progress,
                backgroundColor: colors.disabled,
                valueColor: AlwaysStoppedAnimation<Color>(colors.primary),
                minHeight: 4,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${(task.progress * 100).toStringAsFixed(0)}%  ${_formatSpeed(task.speed)}',
                  style: TextStyle(fontSize: 11, color: colors.textHint),
                ),
                Text(
                  '${_formatSize(task.downloadedSize)}/${_formatSize(task.totalSize)}  ${_formatRemaining(context, task.remainingTime)}',
                  style: TextStyle(fontSize: 11, color: colors.textHint),
                ),
              ],
            ),
          ],
          if (task.error != null &&
              task.status == DownloadStatus.error) ...[
            const SizedBox(height: 4),
            Text(
              task.error!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: colors.error),
            ),
          ],
          if (_hasActions(task.status)) ...[
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (task.status == DownloadStatus.paused)
                  _actionButton(
                    context,
                    colors,
                    icon: Icons.play_arrow_rounded,
                    label: '继续',
                    color: colors.primary,
                    onTap: () => repo.resumeTask(task.id),
                  ),
                if (task.status == DownloadStatus.error ||
                    task.status == DownloadStatus.cancelled)
                  _actionButton(
                    context,
                    colors,
                    icon: Icons.refresh_rounded,
                    label: '重试',
                    color: colors.primary,
                    onTap: () => repo.retryTask(task.id),
                  ),
                if (task.status == DownloadStatus.downloading ||
                    task.status == DownloadStatus.queued ||
                    task.status == DownloadStatus.paused) ...[
                  if (task.status == DownloadStatus.paused)
                    const SizedBox(width: AppSpacing.sm),
                  _actionButton(
                    context,
                    colors,
                    icon: Icons.close_rounded,
                    label: '取消',
                    color: colors.textSecondary,
                    onTap: () => repo.cancelTask(task.id),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  bool _hasActions(DownloadStatus status) {
    switch (status) {
      case DownloadStatus.downloading:
      case DownloadStatus.queued:
      case DownloadStatus.paused:
      case DownloadStatus.error:
      case DownloadStatus.cancelled:
        return true;
      case DownloadStatus.completed:
        return false;
    }
  }

  Widget _actionButton(
    BuildContext context,
    ThemeColors colors, {
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              context.tr(label),
              style: TextStyle(fontSize: 12, color: color),
            ),
          ],
        ),
      ),
    );
  }

  _StatusStyle _statusStyle(
    BuildContext context,
    DownloadStatus status,
    ThemeColors colors,
  ) {
    switch (status) {
      case DownloadStatus.downloading:
        return _StatusStyle(
          label: context.tr('进行中'),
          icon: Icons.downloading,
          color: colors.primary,
        );
      case DownloadStatus.queued:
        return _StatusStyle(
          label: context.tr('等待中'),
          icon: Icons.schedule,
          color: colors.primary,
        );
      case DownloadStatus.paused:
        return _StatusStyle(
          label: context.tr('已暂停'),
          icon: Icons.pause_circle_outline,
          color: colors.textSecondary,
        );
      case DownloadStatus.completed:
        return _StatusStyle(
          label: context.tr('已完成'),
          icon: Icons.check_circle,
          color: const Color(0xFF34A853),
        );
      case DownloadStatus.error:
        return _StatusStyle(
          label: context.tr('失败'),
          icon: Icons.error_outline,
          color: colors.error,
        );
      case DownloadStatus.cancelled:
        return _StatusStyle(
          label: context.tr('已取消'),
          icon: Icons.cancel_outlined,
          color: colors.textHint,
        );
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _formatSpeed(double bytesPerSec) {
    if (bytesPerSec <= 0) return '';
    if (bytesPerSec < 1024) return '${bytesPerSec.toStringAsFixed(0)} B/s';
    if (bytesPerSec < 1024 * 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  String _formatRemaining(BuildContext context, int? seconds) {
    if (seconds == null || seconds <= 0) return '';
    final mins = seconds ~/ 60;
    final secs = seconds % 60;
    if (mins > 0) return context.tr('剩余 $mins分$secs秒');
    return context.tr('剩余 $secs秒');
  }
}

class _StatusStyle {
  const _StatusStyle({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: color,
        ),
      ),
    );
  }
}
