import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/l10n/l10n.dart';
import '../../../../core/theme/theme_provider.dart';
import '../../domain/models/play_mode.dart';
import '../../domain/models/song.dart';
import '../../../local/application/local_providers.dart';
import '../../../settings/application/settings_providers.dart';

/// 根据音质标识和时长（秒）估算文件大小
String _estimateSize(String qualityId, int durationSec) {
  if (durationSec <= 0) return '';
  final kbps = <String, int>{
    '64k': 64,
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

/// 播放页的音质短名称：有损只显示档位码率，无损只显示编码格式，
/// 其余档位沿用全局名称（如「高清臻音」「超清母带」）。
String _playerQualityName(String qualityId) {
  switch (qualityId) {
    case '128k':
      return '128K';
    case '320k':
      return '320K';
    case 'flac':
      return 'Flac';
    default:
      return getQualityDisplayName(qualityId);
  }
}

class PlayerProgressBar extends ConsumerStatefulWidget {
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

  /// 当前歌曲：本地歌曲按文件实时读取真实码率，并禁止切换音质。
  final Song? currentSong;

  /// 需要登录才能使用的档位：菜单里照常列出但置灰，点击给出「去填凭据」提示。
  final Set<String> gatedQualities;
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
    this.currentSong,
    this.gatedQualities = const {},
    this.onQualityTap,
    this.compact = false,
  });

  @override
  ConsumerState<PlayerProgressBar> createState() => _PlayerProgressBarState();
}

class _PlayerProgressBarState extends ConsumerState<PlayerProgressBar> {
  bool _isDragging = false;
  double _dragProgress = 0.0;

  /// 进度条本体（不含左右留白）的盒子：点击 / 拖动按它计算比例。
  final GlobalKey _barKey = GlobalKey();

  /// 时长 / 进度文案：不足一小时 `mm:ss`，超过一小时 `h:mm:ss`。
  ///
  /// 以前只取 `inMinutes.remainder(60)`，播客、现场、纯音乐这类超过一小时的
  /// 曲目会把小时吞掉（1:34:16 显示成 34:16），进度条看起来像「播了一半」。
  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) return '$hours:$minutes:$seconds';
    return '$minutes:$seconds';
  }

  double get _displayProgress => _isDragging ? _dragProgress : widget.progress;

  double _getProgress(Offset globalPosition) {
    // 用进度条本体而不是整个 PlayerProgressBar 的盒子：后者包含左右
    // horizontalPadding，按整宽换算会让两端都偏移一截（中间恰好接近）。
    final box = _barKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return 0.0;
    final local = box.globalToLocal(globalPosition);
    return (local.dx / box.size.width).clamp(0.0, 1.0);
  }

  void _showQualityPicker() {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    // 弹出菜单用实心的 dialogSurface，并跟随主题文字色（原来写死深色底 + 白字，
    // 浅色主题下和整体观感不一致）。
    final colors = ref.read(themeColorsProvider);
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        overlay.size.width / 2 - 60,
        overlay.size.height - 320,
        overlay.size.width / 2 + 60,
        overlay.size.height - 180,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: colors.dialogSurface,
      elevation: 8,
      items: widget.availableQualities.map((q) {
        final gated = widget.gatedQualities.contains(q);
        final displayName = _playerQualityName(q);
        final subtitle = gated
            ? tr('需登录')
            : _estimateSize(q, widget.duration.inSeconds);
        final active = q == widget.currentQuality;
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
                      color: gated
                          ? colors.textSecondary.withValues(alpha: 0.6)
                          : (active ? colors.textPrimary : colors.textSecondary),
                      fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 10,
                        color: gated
                            ? colors.warning.withValues(alpha: 0.9)
                            : colors.textSecondary.withValues(alpha: 0.8),
                      ),
                    ),
                ],
              ),
              if (active)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(Icons.check, size: 14, color: colors.textPrimary),
                ),
            ],
          ),
        );
      }).toList(),
    ).then((selected) {
      if (selected == null || selected == widget.currentQuality) return;
      // 需要登录的档位：不静默忽略，明确告诉用户为什么不能用、去哪里解决。
      if (widget.gatedQualities.contains(selected)) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              tr(
                '「${_playerQualityName(selected)}」需要先在插件管理 → 该插件 → 凭据 里填写登录信息',
              ),
            ),
            duration: const Duration(seconds: 3),
          ),
        );
        return;
      }
      widget.onQualityTap?.call(selected);
    });
  }

  @override
  Widget build(BuildContext context) {
    final compact = widget.compact;
    // 进度条配色与侧栏播放器一致：轨道用分隔线色，已播放部分 / 滑块用主题色。
    final colors = ref.watch(themeColorsProvider);
    // 本地文件只有一个「音源」，读真实码率显示，切换音质没有意义。
    final song = widget.currentSong;
    final isLocal = song?.source == 'local';
    final filePath = isLocal ? song?.filePath : null;
    final localLabel = (filePath != null && filePath.isNotEmpty)
        ? ref.watch(localQualityLabelProvider(filePath)).valueOrNull
        : null;
    final qualityLabel = localLabel ?? _playerQualityName(widget.currentQuality);
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
              key: _barKey,
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
                            // 未播放部分：主题色 10% 底，和侧栏进度条同一口径。
                            color: colors.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                      SizedBox(
                        height: barHeight,
                        child: Container(
                          width: progressWidth,
                          decoration: BoxDecoration(
                            color: colors.primary,
                            borderRadius: BorderRadius.circular(3),
                            boxShadow: [
                              BoxShadow(
                                color: colors.primary.withValues(alpha: 0.35),
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
                            decoration: BoxDecoration(
                              color: colors.primary,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: colors.primary.withValues(alpha: 0.4),
                                  blurRadius: 4,
                                ),
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
                    color: colors.textSecondary,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 1,
                  ),
                ),
                const Spacer(),
                if (widget.availableQualities.isNotEmpty)
                  GestureDetector(
                    // 本地歌曲：音质只是展示，点不开切换菜单。
                    onTap: isLocal ? null : _showQualityPicker,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: colors.textPrimary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        qualityLabel,
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.textSecondary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                const Spacer(),
                // 时长还没拿到（切歌加载窗口）时不显示，避免露出「00:00」
                // 或上一首残留的时长；maintainSize 保留占位，音质标签不位移。
                Visibility(
                  visible: widget.duration > Duration.zero,
                  maintainState: true,
                  maintainAnimation: true,
                  maintainSize: true,
                  child: Text(
                    _formatDuration(widget.duration),
                    style: TextStyle(
                      fontSize: compact ? 11 : 12,
                      color: colors.textSecondary,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 1,
                    ),
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

  /// 电台模式：「播放列表」「上一首」「循环模式」不可用（电台自己控制队列）。
  final bool radioMode;

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
    this.radioMode = false,
  });

  @override
  Widget build(BuildContext context) {
    final compact = this.compact;
    final modeButton = _ControlButton(
      icon: _playModeIcon,
      size: compact ? 20 : 20,
      boxSize: compact ? 40 : 48,
      onPressed: radioMode ? null : onCycleMode,
    );
    final previousButton = _ControlButton(
      icon: Icons.skip_previous,
      size: compact ? 24 : 24,
      boxSize: compact ? 40 : 48,
      onPressed: radioMode ? null : onPrevious,
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
      onPressed: radioMode ? null : onQueue,
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

class _ControlButton extends ConsumerWidget {
  final IconData icon;
  final double size;
  final double boxSize;

  /// 为 null 表示不可用（电台模式）：按钮变淡、点击无响应。
  final VoidCallback? onPressed;

  const _ControlButton({
    required this.icon,
    required this.size,
    required this.onPressed,
    this.boxSize = 48,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 上一首 / 下一首等控件跟随主题文字色：浅色主题下白色图标几乎看不见。
    final colors = ref.watch(themeColorsProvider);
    return SizedBox(
      width: boxSize,
      height: boxSize,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: size),
        color: colors.textPrimary.withValues(
          alpha: onPressed == null ? 0.28 : 0.85,
        ),
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          hoverColor: colors.textPrimary.withValues(alpha: 0.08),
        ),
      ),
    );
  }
}

class _PlayPauseButton extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final diameter = compact ? 54.0 : 64.0;
    final colors = ref.watch(themeColorsProvider);
    // 圆底始终保留（深色主题那圈淡底的观感），浅色主题换成深灰实心圆：
    // 浅色下主题色 15% 压在浅背景上几乎看不见，改用深灰；图标直接用当前
    // 背景色，看起来像从背景里镂出来的，不再是一块近黑圆贴白三角。
    final isLight = ref.watch(isLightThemeActiveProvider);
    final background = isLight
        ? Color.alphaBlend(
            colors.textPrimary.withValues(alpha: 0.65),
            colors.background,
          )
        : colors.primary.withValues(alpha: 0.15);
    final iconColor = isLight ? colors.background : colors.primary;
    return GestureDetector(
      // 遵循 CeruMusic/Sollin-Music：加载期间禁用按钮，避免连点
      onTap: isLoading ? null : onPressed,
      // 原来是 AnimatedContainer(200ms)：宽高与装饰都不会变，动画纯属浪费
      // 一个隐式动画控制器，直接用 Container。
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          color: background,
          shape: BoxShape.circle,
          // 浅色主题的底是深色实心圆，黑影压到 12% 只留一点立体感。
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isLight ? 0.12 : 0.3),
              blurRadius: isLight ? 12 : 16,
              offset: Offset(0, isLight ? 2 : 4),
            ),
          ],
        ),
        child: isLoading
            ? Center(
                child: SizedBox(
                  width: compact ? 20 : 24,
                  height: compact ? 20 : 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: iconColor,
                  ),
                ),
              )
            : Icon(
                isPlaying ? Icons.pause : Icons.play_arrow,
                size: compact ? 26 : 32,
                color: iconColor,
              ),
      ),
    );
  }
}
