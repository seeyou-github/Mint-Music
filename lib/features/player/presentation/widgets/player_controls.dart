import 'package:flutter/material.dart';
import '../../domain/models/play_mode.dart';
import '../../../settings/application/settings_providers.dart';

/// 根据音质标识和时长（秒）估算文件大小
String _estimateSize(String qualityId, int durationSec) {
  if (durationSec <= 0) return '';
  final kbps = <String, int>{
    '128k': 128,
    '192k': 192,
    '320k': 320,
    'flac': 1000,
    'flac24bit': 2000,
    'hires': 3000,
    'atmos': 500,
    'master': 3000,
  };
  final bitrate = kbps[qualityId] ?? 320;
  final sizeBytes = bitrate * 1000 ~/ 8 * durationSec;
  if (sizeBytes < 1024 * 1024) {
    return '${(sizeBytes / 1024).toStringAsFixed(1)}KB';
  }
  return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(2)}MB';
}

class PlayerProgressBar extends StatefulWidget {
  /// 非紧凑模式下进度条（与时间标签）的水平留白。
  ///
  /// 竖屏播放页的操作按钮行要与进度条左右对齐，统一引用这个值。
  static const double horizontalPadding = 32;

  final double progress;
  final Duration position;
  final Duration duration;
  final ValueChanged<double> onSeek;

  /// 拖动过程中的歌词预览（null 表示结束预览）。
  final ValueChanged<double?>? onSeekPreview;
  final String currentQuality;
  final List<String> availableQualities;
  final ValueChanged<String>? onQualityTap;

  /// 紧凑模式：用于手机横屏等高度受限的场景，压缩内边距。
  final bool compact;

  const PlayerProgressBar({
    super.key,
    required this.progress,
    required this.position,
    required this.duration,
    required this.onSeek,
    this.onSeekPreview,
    this.currentQuality = '320k',
    this.availableQualities = const [],
    this.onQualityTap,
    this.compact = false,
  });

  @override
  State<PlayerProgressBar> createState() => _PlayerProgressBarState();
}

class _PlayerProgressBarState extends State<PlayerProgressBar> {
  bool _isDragging = false;
  double _dragProgress = 0.0;

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  double get _displayProgress => _isDragging ? _dragProgress : widget.progress;

  double _getProgress(Offset globalPosition) {
    final box = context.findRenderObject() as RenderBox;
    final local = box.globalToLocal(globalPosition);
    return (local.dx / box.size.width).clamp(0.0, 1.0);
  }

  void _showQualityPicker() {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        overlay.size.width / 2 - 60,
        overlay.size.height - 320,
        overlay.size.width / 2 + 60,
        overlay.size.height - 180,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: const Color(0xFF282828),
      elevation: 8,
      items: widget.availableQualities.map((q) {
        final displayName = getQualityDisplayName(q);
        final sizeStr = _estimateSize(q, widget.duration.inSeconds);
        return PopupMenuItem<String>(
          value: q,
          height: 40,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName,
                    style: TextStyle(
                      fontSize: 13,
                      color: q == widget.currentQuality
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.7),
                      fontWeight: q == widget.currentQuality
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                  if (sizeStr.isNotEmpty)
                    Text(
                      sizeStr,
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                    ),
                ],
              ),
              if (q == widget.currentQuality)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(Icons.check, size: 14, color: Colors.white),
                ),
            ],
          ),
        );
      }).toList(),
    ).then((selected) {
      if (selected != null && selected != widget.currentQuality) {
        widget.onQualityTap?.call(selected);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final compact = widget.compact;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : PlayerProgressBar.horizontalPadding,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTapDown: (d) {
              final p = _getProgress(d.globalPosition);
              widget.onSeek(p);
            },
            onPanStart: (d) {
              setState(() {
                _isDragging = true;
                _dragProgress = _getProgress(d.globalPosition);
              });
              widget.onSeekPreview?.call(_dragProgress);
            },
            onPanUpdate: (d) {
              setState(() {
                _dragProgress = _getProgress(d.globalPosition);
              });
              widget.onSeekPreview?.call(_dragProgress);
            },
            onPanEnd: (_) {
              widget.onSeek(_dragProgress);
              widget.onSeekPreview?.call(null);
              setState(() {
                _isDragging = false;
              });
            },
            onPanCancel: () {
              widget.onSeekPreview?.call(null);
              setState(() {
                _isDragging = false;
              });
            },
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: EdgeInsets.symmetric(vertical: compact ? 4 : 12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final barWidth = constraints.maxWidth;
                  final progressWidth = barWidth * _displayProgress;
                  final barHeight = compact ? 4.0 : 6.0;
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      SizedBox(
                        height: barHeight,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                      SizedBox(
                        height: barHeight,
                        child: Container(
                          width: progressWidth,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(3),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.white.withValues(alpha: 0.3),
                                blurRadius: 10,
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (_isDragging)
                        Positioned(
                          left: progressWidth - 6,
                          top: -3,
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(color: Colors.white24, blurRadius: 4),
                              ],
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Row(
              children: [
                Text(
                  _formatDuration(
                    _isDragging
                        ? Duration(
                            milliseconds:
                                (widget.duration.inMilliseconds * _dragProgress)
                                    .round(),
                          )
                        : widget.position,
                  ),
                  style: TextStyle(
                    fontSize: compact ? 11 : 12,
                    color: Colors.white.withValues(alpha: 0.6),
                    fontWeight: FontWeight.w500,
                    letterSpacing: 1,
                  ),
                ),
                const Spacer(),
                if (widget.availableQualities.isNotEmpty)
                  GestureDetector(
                    onTap: _showQualityPicker,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        getQualityDisplayName(widget.currentQuality),
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.white.withValues(alpha: 0.8),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                const Spacer(),
                Text(
                  _formatDuration(widget.duration),
                  style: TextStyle(
                    fontSize: compact ? 11 : 12,
                    color: Colors.white.withValues(alpha: 0.6),
                    fontWeight: FontWeight.w500,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class PlaybackControlRow extends StatelessWidget {
  final bool isPlaying;
  final bool isLoading;
  final PlayMode playMode;
  final VoidCallback onPlayPause;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onCycleMode;
  final VoidCallback onQueue;

  /// 紧凑模式：用于手机横屏等高度受限的场景，缩小按钮与内边距。
  final bool compact;

  const PlaybackControlRow({
    super.key,
    required this.isPlaying,
    required this.isLoading,
    required this.playMode,
    required this.onPlayPause,
    required this.onPrevious,
    required this.onNext,
    required this.onCycleMode,
    required this.onQueue,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final compact = this.compact;
    final modeButton = _ControlButton(
      icon: _playModeIcon,
      size: compact ? 20 : 20,
      boxSize: compact ? 40 : 48,
      onPressed: onCycleMode,
    );
    final previousButton = _ControlButton(
      icon: Icons.skip_previous,
      size: compact ? 24 : 24,
      boxSize: compact ? 40 : 48,
      onPressed: onPrevious,
    );
    final playButton = _PlayPauseButton(
      isPlaying: isPlaying,
      isLoading: isLoading,
      compact: compact,
      onPressed: onPlayPause,
    );
    final nextButton = _ControlButton(
      icon: Icons.skip_next,
      size: compact ? 24 : 24,
      boxSize: compact ? 40 : 48,
      onPressed: onNext,
    );
    final queueButton = _ControlButton(
      icon: Icons.queue_music,
      size: compact ? 22 : 22,
      boxSize: compact ? 40 : 48,
      onPressed: onQueue,
    );

    if (compact) {
      // 紧凑模式：固定小间距居中排列，不再均分整行（手机横屏空间有限）。
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            modeButton,
            const SizedBox(width: 10),
            previousButton,
            const SizedBox(width: 6),
            playButton,
            const SizedBox(width: 6),
            nextButton,
            const SizedBox(width: 10),
            queueButton,
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          modeButton,
          previousButton,
          playButton,
          nextButton,
          queueButton,
        ],
      ),
    );
  }

  IconData get _playModeIcon {
    switch (playMode) {
      case PlayMode.singleLoop:
        return Icons.repeat_one;
      case PlayMode.shuffle:
        return Icons.shuffle;
      case PlayMode.listLoop:
        return Icons.repeat;
    }
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final double boxSize;
  final VoidCallback onPressed;

  const _ControlButton({
    required this.icon,
    required this.size,
    required this.onPressed,
    this.boxSize = 48,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: boxSize,
      height: boxSize,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: size),
        color: Colors.white.withValues(alpha: 0.7),
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          hoverColor: Colors.white.withValues(alpha: 0.1),
        ),
      ),
    );
  }
}

class _PlayPauseButton extends StatelessWidget {
  final bool isPlaying;
  final bool isLoading;
  final bool compact;
  final VoidCallback onPressed;

  const _PlayPauseButton({
    required this.isPlaying,
    required this.isLoading,
    required this.onPressed,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final diameter = compact ? 54.0 : 64.0;
    return GestureDetector(
      // 遵循 CeruMusic/Sollin-Music：加载期间禁用按钮，避免连点
      onTap: isLoading ? null : onPressed,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: isLoading
            ? Center(
                child: SizedBox(
                  width: compact ? 20 : 24,
                  height: compact ? 20 : 24,
                  child: const CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: Colors.black,
                  ),
                ),
              )
            : Icon(
                isPlaying ? Icons.pause : Icons.play_arrow,
                size: compact ? 26 : 32,
                color: Colors.black,
              ),
      ),
    );
  }
}
