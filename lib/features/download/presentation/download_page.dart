import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../player/application/playback_controller.dart';
import '../application/download_providers.dart';
import '../domain/models/download_task.dart';

/// 下载管理页。
///
/// 不再按「进行中 / 已完成 / 失败」分类，所有任务按下载时间倒序放在同一个
/// 列表里；列表左侧显示歌曲封面，点击条目直接播放该歌曲；下载完成的条目
/// 右侧显示文件信息并提供「删除」按钮。
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

/// 单条下载任务：封面 + 曲名 / 歌手 + 状态 / 文件信息 + 操作按钮。
class _DownloadTaskItem extends ConsumerWidget {
  const _DownloadTaskItem({required this.task});

  final DownloadTask task;

  bool get _isCompleted => task.status == DownloadStatus.completed;

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
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 左侧：歌曲封面 + 曲名 / 歌手（点击条目直接播放）
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _playTask(context),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _buildCover(context, colors),
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
                            if (_isCompleted) ...[
                              const SizedBox(height: 4),
                              _buildFileInfo(context, colors),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              // 右侧：状态徽标 / 删除按钮
              if (_isCompleted)
                _buildDeleteButton(context, ref, colors)
              else
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

  /// 左侧封面（没有封面时显示默认封面）。
  Widget _buildCover(BuildContext context, ThemeColors colors) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        width: 46,
        height: 46,
        color: colors.surfaceVariant,
        child: MusicCoverImage(
          url: task.song.coverUrl,
          songId: task.song.id,
          mediaStoreId: task.song.mediaStoreId,
          fit: BoxFit.cover,
          errorWidget: Icon(
            Icons.music_note,
            size: 20,
            color: colors.textHint,
          ),
        ),
      ),
    );
  }

  /// 下载完成的歌曲：文件大小 / 长度 / 比特率 / 文件类型。
  Widget _buildFileInfo(BuildContext context, ThemeColors colors) {
    final size = task.totalSize > 0 ? task.totalSize : task.downloadedSize;
    final durationSec = task.song.duration;
    final bitrate = durationSec > 0 && size > 0
        ? (size * 8 / durationSec / 1000).round()
        : 0;
    final type = _fileType();

    return Wrap(
      spacing: 10,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _infoChip(context, colors, Icons.data_usage, _formatSize(size)),
        _infoChip(
          context,
          colors,
          Icons.schedule,
          _formatDuration(durationSec),
        ),
        if (bitrate > 0)
          _infoChip(context, colors, Icons.graphic_eq, '$bitrate kbps'),
        if (type.isNotEmpty)
          _infoChip(context, colors, Icons.insert_drive_file, type),
      ],
    );
  }

  Widget _infoChip(
    BuildContext context,
    ThemeColors colors,
    IconData icon,
    String text,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: colors.textHint),
        const SizedBox(width: 3),
        Text(
          text,
          style: TextStyle(fontSize: 11, color: colors.textHint),
        ),
      ],
    );
  }

  /// 下载完成的歌曲右侧的「删除」按钮。
  Widget _buildDeleteButton(
    BuildContext context,
    WidgetRef ref,
    ThemeColors colors,
  ) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      icon: Icon(Icons.delete_outline, size: 20, color: colors.error),
      tooltip: context.tr('删除'),
      onPressed: () => _confirmDelete(context, ref, colors),
    );
  }

  /// 删除确认：同时删除歌曲文件与该条下载记录。
  void _confirmDelete(BuildContext context, WidgetRef ref, ThemeColors colors) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(
          context.tr('删除下载文件'),
          style: TextStyle(color: colors.textPrimary),
        ),
        content: Text(
          context.tr('确定要删除《${task.song.title}》的下载文件吗？该条下载记录也会一并删除。'),
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
            onPressed: () async {
              Navigator.pop(ctx);
              await ref
                  .read(downloadRepositoryProvider)
                  .deleteTask(task.id, deleteFile: true);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(context.tr('已删除下载文件')),
                    backgroundColor: colors.surfaceVariant,
                  ),
                );
              }
            },
            child: Text(
              context.tr('删除'),
              style: TextStyle(color: colors.error),
            ),
          ),
        ],
      ),
    );
  }

  /// 点击列表项：直接播放该歌曲（文件不存在时提示错误）。
  Future<void> _playTask(BuildContext context) async {
    if (!_isCompleted) {
      _showMessage(context, context.tr('该歌曲尚未下载完成'));
      return;
    }
    try {
      final file = File(task.filePath);
      if (!await file.exists()) {
        _showMessage(context, context.tr('歌曲文件不存在，可能已被删除'));
        return;
      }
    } catch (_) {
      _showMessage(context, context.tr('歌曲文件不存在，可能已被删除'));
      return;
    }

    final song = task.song.copyWith(
      source: 'local',
      sourceUrl: task.filePath,
      filePath: task.filePath,
      clearSourceHeaders: true,
    );
    await ref
        .read(playbackControllerProvider.notifier)
        .setQueue([song], startIndex: 0);
  }

  void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.grey[800],
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 从文件路径推断文件类型（mp3 / flac ...）。
  String _fileType() {
    final path = task.filePath;
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return '';
    return path.substring(dot + 1).toLowerCase();
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

  String _formatDuration(int seconds) {
    if (seconds <= 0) return '--:--';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
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
