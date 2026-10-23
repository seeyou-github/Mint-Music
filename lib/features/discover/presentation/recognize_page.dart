import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../shared/services/app_image_cache.dart';
import '../../player/application/playback_controller.dart';
import '../application/recognize_provider.dart';
import '../application/search_providers.dart';
import '../domain/models/recognize_result.dart';

class RecognizePage extends ConsumerStatefulWidget {
  const RecognizePage({super.key});

  @override
  ConsumerState<RecognizePage> createState() => _RecognizePageState();
}

class _RecognizePageState extends ConsumerState<RecognizePage> {
  Timer? _timer;
  bool _wasPlayingBefore = false;
  bool _starting = false;

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(ref.read(recognizeProvider.notifier).cancelRecording());
    _resumePlaybackIfNeeded(force: true);
    super.dispose();
  }

  /// 对标 CeruMusic start(): 暂停当前播放 → 开始录音
  Future<void> _handleStart() async {
    if (_starting) return;
    _starting = true;
    // 对标 CeruMusic: if (audioStore.Audio.isPlay) { wasPlaying = true; await audioStore.stop(); }
    final playbackState = ref.read(playbackControllerProvider);
    if (playbackState.isPlaying) {
      _wasPlayingBefore = true;
      ref.read(playbackControllerProvider.notifier).pause();
    } else {
      _wasPlayingBefore = false;
    }
    ref.read(recognizeProvider.notifier).setWasPlaying(_wasPlayingBefore);

    final notifier = ref.read(recognizeProvider.notifier);
    try {
      final granted = await notifier.requestPermission();
      if (!granted || !mounted) {
        _resumePlaybackIfNeeded();
        return;
      }
      await notifier.startRecording();
    } finally {
      _starting = false;
    }
  }

  /// 对标 CeruMusic stopRecording(): 停止录音
  void _handleStop() {
    ref.read(recognizeProvider.notifier).stopAndRecognize();
  }

  void _handleCancel() {
    ref.read(recognizeProvider.notifier).cancelRecording();
    _resumePlaybackIfNeeded();
  }

  /// 对标 CeruMusic: if (wasPlaying.value) { setTimeout(() => audioStore.start(), 500); }
  void _resumePlaybackIfNeeded({bool force = false}) {
    if (_wasPlayingBefore) {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (force || mounted) {
          ref.read(playbackControllerProvider.notifier).play();
        }
      });
      _wasPlayingBefore = false;
    }
  }

  /// 对标 CeruMusic onFilePicked(): 上传文件识别
  Future<void> _handleFileUpload() async {
    if (_starting) return;
    _starting = true;
    final playbackState = ref.read(playbackControllerProvider);
    _wasPlayingBefore = playbackState.isPlaying;
    if (_wasPlayingBefore) {
      ref.read(playbackControllerProvider.notifier).pause();
    }
    ref.read(recognizeProvider.notifier).setWasPlaying(_wasPlayingBefore);
    try {
      await ref.read(recognizeProvider.notifier).recognizeFromFile();
      if (mounted &&
          ref.read(recognizeProvider).status == RecognizeStatus.idle) {
        _resumePlaybackIfNeeded();
      }
    } finally {
      _starting = false;
    }
  }

  /// 对标 CeruMusic handlePlayResult(): 播放识别结果并跳转到识别片段
  void _handlePlayResult(RecognizeResult result) {
    final controller = ref.read(playbackControllerProvider.notifier);
    controller.prependAndPlay(result.toSong());
    // 对标 CeruMusic: if (song.startTime && song.startTime > 0) { audioStore.setCurrentTime(seconds); }
    if (result.startTime > 0) {
      final seconds = result.startTime / 1000;
      Future.delayed(const Duration(milliseconds: 500), () {
        controller.seek(Duration(milliseconds: (seconds * 1000).round()));
      });
    }
  }

  /// 对标 CeruMusic handleSearchResult(): 搜索识别结果
  void _handleSearchResult(RecognizeResult song) {
    if (song.name.isNotEmpty) {
      ref.read(pendingSearchQueryProvider.notifier).state = song.name;
      context.push('/search');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final state = ref.watch(recognizeProvider);

    // 监听状态变化，识别完成时恢复播放
    ref.listen<RecognizeState>(recognizeProvider, (prev, next) {
      if ((next.status == RecognizeStatus.success ||
              next.status == RecognizeStatus.failed) &&
          _wasPlayingBefore) {
        _resumePlaybackIfNeeded();
      }
    });

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(context, colors),
            Expanded(child: _buildContent(state, colors)),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ThemeColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => context.pop(),
            child: Icon(Icons.arrow_back, size: 24, color: colors.textPrimary),
          ),
          const SizedBox(width: AppSpacing.md),
          Text(
            context.tr('听歌识曲'),
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: colors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(RecognizeState state, ThemeColors colors) {
    if (state.status == RecognizeStatus.success && state.results.isNotEmpty) {
      return _buildResults(state.results, colors);
    }

    // 识别提示（失败时显示错误信息）+ 操作按钮：
    // 识别按钮居中，上传文件按钮在识别按钮下方。
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl,
          vertical: AppSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildStatusArea(state, colors),
            const SizedBox(height: AppSpacing.xl),
            _buildActionButtons(state, colors),
          ],
        ),
      ),
    );
  }

  /// 识别状态提示：失败时显示错误信息，录音中显示进度，其余状态显示一句话。
  Widget _buildStatusArea(RecognizeState state, ThemeColors colors) {
    final isRecording = state.status == RecognizeStatus.recording;

    if (state.status == RecognizeStatus.failed) {
      final message = state.errorMessage ?? tr('未能识别到歌曲');
      return Text(
        message,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 15, color: colors.error),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildStatusText(state, colors),
        if (isRecording) ...[
          const SizedBox(height: AppSpacing.lg),
          _buildProgressBar(state, colors),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '${state.elapsedSeconds}s / 15s',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w300,
              color: colors.textHint,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildStatusText(RecognizeState state, ThemeColors colors) {
    String text;
    Color color;

    switch (state.status) {
      case RecognizeStatus.idle:
        // 空闲状态不显示提示文案（下方已经有「识别 / 上传文件」按钮）。
        return const SizedBox.shrink();
      case RecognizeStatus.initializing:
        text = context.tr('正在初始化...');
        color = colors.textSecondary;
      case RecognizeStatus.recording:
        text = context.tr('正在识别中...');
        color = colors.primary;
      case RecognizeStatus.processing:
        text = context.tr('正在处理音频...');
        color = colors.textSecondary;
      case RecognizeStatus.uploading:
        text = context.tr('正在上传识别...');
        color = colors.textSecondary;
      case RecognizeStatus.success:
        text = context.tr('识别成功');
        color = colors.success;
      case RecognizeStatus.failed:
        text = state.errorMessage ?? context.tr('未能识别到歌曲');
        color = colors.error;
    }

    return Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: 15, color: color, fontWeight: FontWeight.w500),
    );
  }

  Widget _buildProgressBar(RecognizeState state, ThemeColors colors) {
    final progress = (state.elapsedSeconds / 15.0).clamp(0.0, 1.0);
    return SizedBox(
      width: 200,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LinearProgressIndicator(
          value: progress,
          backgroundColor: colors.divider,
          valueColor: AlwaysStoppedAnimation<Color>(colors.primary),
          minHeight: 4,
        ),
      ),
    );
  }

  Widget _buildResults(List<RecognizeResult> results, ThemeColors colors) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      children: [
        const SizedBox(height: AppSpacing.md),
        for (final song in results) _buildResultItem(song, colors),
        const SizedBox(height: AppSpacing.lg),
        Center(
          child: GestureDetector(
            onTap: () => ref.read(recognizeProvider.notifier).backToInitial(),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.xxl,
                vertical: AppSpacing.sm,
              ),
              decoration: BoxDecoration(
                border: Border.all(color: colors.divider),
                borderRadius: BorderRadius.circular(AppRadius.full),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.refresh, size: 16, color: colors.textSecondary),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    context.tr('继续识别'),
                    style: TextStyle(fontSize: 14, color: colors.textSecondary),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xxl),
      ],
    );
  }

  Widget _buildResultItem(RecognizeResult song, ThemeColors colors) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: SizedBox(
              width: 60,
              height: 60,
              child: song.img.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: song.img,
                      cacheManager: AppImageCache.manager,
                      fit: BoxFit.cover,
                      placeholder: (_, _) => _buildPlaceholderCover(colors),
                      errorWidget: (_, _, _) => _buildPlaceholderCover(colors),
                    )
                  : _buildPlaceholderCover(colors),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  song.name,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  song.singer,
                  style: TextStyle(fontSize: 13, color: colors.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (song.startTime > 0) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: colors.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      context.tr(
                        '识别片段: ${_formatTime(song.startTime ~/ 1000)}',
                      ),
                      style: TextStyle(fontSize: 11, color: colors.primary),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          _buildResultActions(song, colors),
        ],
      ),
    );
  }

  Widget _buildPlaceholderCover(ThemeColors colors) {
    return Container(
      color: colors.surfaceVariant,
      child: Icon(Icons.music_note, size: 24, color: colors.textHint),
    );
  }

  Widget _buildResultActions(RecognizeResult song, ThemeColors colors) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildIconButton(
          Icons.play_circle_fill_rounded,
          colors.primary,
          () => _handlePlayResult(song),
        ),
        const SizedBox(width: AppSpacing.sm),
        _buildIconButton(
          Icons.search_rounded,
          colors.textSecondary,
          () => _handleSearchResult(song),
        ),
      ],
    );
  }

  Widget _buildIconButton(IconData icon, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Icon(icon, size: 18, color: color),
      ),
    );
  }

  /// 操作按钮：识别按钮（居中）+ 上传文件按钮（在其下方）。
  ///
  /// 识别失败时同样展示这两个按钮（不再单独显示「重试」按钮）。
  Widget _buildActionButtons(RecognizeState state, ThemeColors colors) {
    final isIdle = state.status == RecognizeStatus.idle;
    final isRecording = state.status == RecognizeStatus.recording;
    final isFailed = state.status == RecognizeStatus.failed;
    final isBusy =
        state.status == RecognizeStatus.initializing ||
        state.status == RecognizeStatus.processing ||
        state.status == RecognizeStatus.uploading;
    // 空闲 / 识别失败时都可以上传文件；录音中该按钮变为「取消」。
    final canUpload = isIdle || isFailed;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 主按钮：开始 / 停止识别（居中）
        GestureDetector(
          onTap: isBusy ? null : (isRecording ? _handleStop : _handleStart),
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isBusy
                  ? colors.disabled
                  : isRecording
                  ? Colors.red
                  : colors.primary,
              boxShadow: [
                BoxShadow(
                  color: (isRecording ? Colors.red : colors.primary).withValues(
                    alpha: 0.3,
                  ),
                  blurRadius: 12,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: isBusy
                ? const Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    ),
                  )
                : Icon(
                    isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                    size: 32,
                    color: colors.textOnPrimary,
                  ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        // 辅助按钮：上传文件（在识别按钮下方）
        GestureDetector(
          onTap: canUpload
              ? _handleFileUpload
              : (isRecording ? _handleCancel : null),
          child: Opacity(
            opacity: canUpload ? 1.0 : 0.6,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm + 2,
              ),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(AppRadius.full),
                border: Border.all(color: colors.divider),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    canUpload ? Icons.file_upload_outlined : Icons.close,
                    size: 16,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    context.tr(canUpload ? '上传文件' : '取消'),
                    style: TextStyle(fontSize: 13, color: colors.textSecondary),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _formatTime(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}
