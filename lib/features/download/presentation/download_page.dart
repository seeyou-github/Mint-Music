import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/platform/file_manager_service.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';
import '../../../shared/widgets/song_list_item.dart';
import '../../player/application/playback_controller.dart';
import '../../settings/application/settings_providers.dart';
import '../application/download_providers.dart';
import '../data/download_repository.dart';
import '../domain/models/download_task.dart';
import 'widgets/download_progress_info.dart';

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
            _buildHeader(
              context,
              ref,
              colors,
              tasksAsync.valueOrNull ?? const [],
            ),
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
                        _DownloadTaskItem(task: sorted[index], index: index),
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
          _buildOpenFolderButton(context, ref, colors),
          const SizedBox(width: AppSpacing.xs),
          _buildClearButton(context, ref, colors, tasks.isEmpty),
        ],
      ),
    );
  }

  /// 「打开目录」按钮（Windows）/「显示路径」按钮（Android）。
  ///
  /// Windows 上直接用系统文件管理器打开下载目录；Android 没有这个能力，
  /// 改成把当前歌曲的下载路径显示出来。
  Widget _buildOpenFolderButton(
    BuildContext context,
    WidgetRef ref,
    ThemeColors colors,
  ) {
    final isAndroid = Platform.isAndroid;
    final label = isAndroid ? context.tr('显示路径') : context.tr('打开目录');
    return GestureDetector(
      onTap: () => _handleOpenFolder(context, ref, colors),
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
            Icon(
              isAndroid ? Icons.info_outline : Icons.folder_open_outlined,
              size: 16,
              color: colors.textSecondary,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  /// 打开下载目录；打不开（Android / 失败）就把路径显示出来。
  Future<void> _handleOpenFolder(
    BuildContext context,
    WidgetRef ref,
    ThemeColors colors,
  ) async {
    final dir = ref.read(downloadDirProvider);
    if (dir.trim().isNotEmpty) {
      final opened = await FileManagerService.openFolder(dir);
      if (opened) return;
    }
    if (!context.mounted) return;
    await _showDownloadPathDialog(context, ref, colors);
  }

  /// 把当前歌曲的下载路径显示出来。
  Future<void> _showDownloadPathDialog(
    BuildContext context,
    WidgetRef ref,
    ThemeColors colors,
  ) async {
    final dir = ref.read(downloadDirProvider);
    final song = ref.read(playbackControllerProvider).currentSong;
    final filePath = song?.filePath ?? '';
    final lines = <String>[
      if (filePath.isNotEmpty) ...[
        '${context.tr('当前歌曲')}：${song?.title ?? ''}',
        filePath,
        '',
      ],
      '${context.tr('下载目录')}：',
      dir.isEmpty ? context.tr('（未设置）') : dir,
    ];

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(
          context.tr('下载路径'),
          style: TextStyle(color: colors.textPrimary),
        ),
        content: SingleChildScrollView(
          child: SelectableText(
            lines.join('\n'),
            style: TextStyle(fontSize: 13, color: colors.textSecondary),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              context.tr('关闭'),
              style: TextStyle(color: colors.textHint),
            ),
          ),
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
              Icon(
                Icons.delete_sweep_outlined,
                size: 16,
                color: colors.textSecondary,
              ),
              const SizedBox(width: 4),
              Text(
                context.tr('清除'),
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

/// 单条下载任务。
///
/// 布局与「发现页 → 歌单详情」的歌曲列表一致：序号 + 封面 + 曲名 / 来源 / 歌手，
/// 右侧固定「删除」按钮。四种状态：
/// * 下载中：行下方显示进度条与下载信息（不再显示「下载中」徽标）；
/// * 已暂停（上次退出时还没下完）：右侧显示「继续」按钮；
/// * 失败 / 文件不存在：右侧显示「重试」按钮，其下方显示文字提示；
/// * 成功：右侧只显示文件大小（不再显示进度条与下载信息）。
class _DownloadTaskItem extends ConsumerStatefulWidget {
  const _DownloadTaskItem({required this.task, required this.index});

  final DownloadTask task;
  final int index;

  @override
  ConsumerState<_DownloadTaskItem> createState() => _DownloadTaskItemState();
}

class _DownloadTaskItemState extends ConsumerState<_DownloadTaskItem> {
  /// 下载完成的歌曲，文件是否已被移除（null = 尚未检查）。
  bool? _fileMissing;

  @override
  void initState() {
    super.initState();
    _checkFile();
  }

  @override
  void didUpdateWidget(covariant _DownloadTaskItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task.status != widget.task.status ||
        oldWidget.task.filePath != widget.task.filePath) {
      _checkFile();
    }
  }

  /// 检查下载完成的歌曲文件是否还在（可能被用户手动删除 / 移动）。
  Future<void> _checkFile() async {
    if (widget.task.status != DownloadStatus.completed) {
      if (_fileMissing != false && mounted) {
        setState(() => _fileMissing = false);
      }
      return;
    }
    var exists = false;
    try {
      exists = await File(widget.task.filePath).exists();
    } catch (_) {
      exists = false;
    }
    if (!mounted) return;
    setState(() => _fileMissing = !exists);
  }

  DownloadTask get task => widget.task;

  bool get _isCompleted => task.status == DownloadStatus.completed;

  /// 文件已被删除 / 移动（恢复任务时标记，或列表内检测到文件缺失）。
  bool get _isMissing =>
      task.status == DownloadStatus.fileMissing ||
      (_isCompleted && _fileMissing == true);

  bool get _isDownloading =>
      task.status == DownloadStatus.downloading ||
      task.status == DownloadStatus.queued;

  bool get _isFailed =>
      task.status == DownloadStatus.error ||
      task.status == DownloadStatus.cancelled;

  /// 上次退出时未下载完的任务：恢复后显示「继续」按钮。
  bool get _isPaused => task.status == DownloadStatus.paused;

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final repo = ref.read(downloadRepositoryProvider);

    return SongListItem(
      song: task.song,
      index: widget.index,
      showQuality: false,
      showDuration: false,
      showMenuButton: false,
      onTap: () => _handleTap(context),
      trailing: _buildTrailing(context, colors, repo),
      footer: _isDownloading ? _buildProgress(colors) : null,
    );
  }

  /// 右侧区域：成功时显示文件大小；失败 / 文件不存在时显示「重试」+ 提示文字。
  Widget _buildTrailing(
    BuildContext context,
    ThemeColors colors,
    DownloadRepository repo,
  ) {
    if (_isCompleted && !_isMissing) {
      // 下载成功：显示文件大小 + 删除按钮；封面缺失时额外给一个提示。
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.insert_drive_file_outlined,
            size: 13,
            color: colors.textHint,
          ),
          const SizedBox(width: 4),
          Text(
            _formatSize(
              task.totalSize > 0 ? task.totalSize : task.downloadedSize,
            ),
            style: TextStyle(fontSize: 12, color: colors.textHint),
          ),
          if (task.coverMissing) ...[
            const SizedBox(width: AppSpacing.sm),
            Tooltip(
              message: context.tr('封面获取失败，歌曲未写入内嵌封面'),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.image_not_supported_outlined,
                    size: 13,
                    color: colors.warning,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    context.tr('无封面'),
                    style: TextStyle(fontSize: 11, color: colors.warning),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(width: AppSpacing.xs),
          _buildDeleteButton(context, colors, repo),
        ],
      );
    }

    if (_isFailed || _isMissing || _isPaused) {
      // 失败 / 文件不存在 / 上次未下完：显示「继续（重试）」+「删除」，
      // 文字提示在按钮下方。
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildRetryButton(
                context,
                colors,
                label: _isPaused ? context.tr('继续') : context.tr('重试'),
                icon: _isPaused
                    ? Icons.play_arrow_rounded
                    : Icons.refresh_rounded,
                onPressed: _isPaused
                    ? () => repo.resumeTask(task.id)
                    : () => repo.retryTask(task.id),
              ),
              _buildDeleteButton(context, colors, repo),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            _isMissing
                ? context.tr('文件已删除')
                : _isPaused
                ? context.tr('已暂停')
                : (task.status == DownloadStatus.cancelled
                      ? context.tr('已取消')
                      : context.tr('失败')),
            style: TextStyle(
              fontSize: 11,
              color: _isPaused ? colors.textSecondary : colors.error,
            ),
          ),
        ],
      );
    }

    // 下载中：只显示删除按钮（进度信息在行下方）。
    return _buildDeleteButton(context, colors, repo);
  }

  /// 删除按钮：删除歌曲文件与该条下载记录。
  Widget _buildDeleteButton(
    BuildContext context,
    ThemeColors colors,
    DownloadRepository repo,
  ) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      icon: Icon(Icons.delete_outline, size: 19, color: colors.error),
      tooltip: context.tr('删除'),
      onPressed: () => _confirmDelete(context, colors, repo),
    );
  }

  /// 继续 / 重试按钮。
  Widget _buildRetryButton(
    BuildContext context,
    ThemeColors colors, {
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: colors.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(color: colors.primary.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: colors.primary),
            const SizedBox(width: 3),
            Text(label, style: TextStyle(fontSize: 12, color: colors.primary)),
          ],
        ),
      ),
    );
  }

  /// 下载中：进度条 + 进度 / 速度 / 大小信息。
  ///
  /// 右侧「速度:」标签的位置必须固定（见 [DownloadProgressInfo]），否则网速
  /// 位数一变，标签就会跟着左右移动。
  Widget _buildProgress(ThemeColors colors) {
    final totalSize = task.totalSize > 0 ? task.totalSize : task.downloadedSize;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: task.status == DownloadStatus.queued ? null : task.progress,
            backgroundColor: colors.disabled,
            valueColor: AlwaysStoppedAnimation<Color>(colors.primary),
            minHeight: 3,
          ),
        ),
        const SizedBox(height: 4),
        DownloadProgressInfo(
          progress: task.progress,
          speedLabel: _formatSpeed(task.speed),
          sizeLabel: _formatSize(totalSize),
          color: colors.textHint,
        ),
      ],
    );
  }

  /// 点击条目：下载完成的歌曲直接播放；文件被移除时提示「文件不存在」。
  Future<void> _handleTap(BuildContext context) async {
    if (!_isCompleted) {
      _showMessage(context, context.tr('该歌曲尚未下载完成'));
      return;
    }

    var exists = false;
    try {
      exists = await File(task.filePath).exists();
    } catch (_) {
      exists = false;
    }
    if (!exists) {
      if (mounted) setState(() => _fileMissing = true);
      _showMessage(context, context.tr('文件不存在'));
      return;
    }

    final song = task.song.copyWith(
      source: 'local',
      sourceUrl: task.filePath,
      filePath: task.filePath,
      clearSourceHeaders: true,
    );
    await ref.read(playbackControllerProvider.notifier).setQueue([
      song,
    ], startIndex: 0);
  }

  /// 删除确认：同时删除歌曲文件与该条下载记录。
  void _confirmDelete(
    BuildContext context,
    ThemeColors colors,
    DownloadRepository repo,
  ) {
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
              await repo.deleteTask(task.id, deleteFile: true);
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

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _formatSpeed(double bytesPerSec) {
    if (bytesPerSec <= 0) return '-';
    if (bytesPerSec < 1024) return '${bytesPerSec.toStringAsFixed(0)} B/s';
    final kb = bytesPerSec / 1024;
    // 四舍五入后可能到 1024.0，这时提前进位到 MB/s，避免出现
    // 「1024.0 KB/s」这种多一位、还会被数值区裁掉的文案。
    if (kb < 1023.95) return '${kb.toStringAsFixed(1)} KB/s';
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }
}
