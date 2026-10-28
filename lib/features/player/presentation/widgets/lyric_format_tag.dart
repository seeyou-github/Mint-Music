import 'package:flutter/material.dart';

import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/theme_colors.dart';

/// 逐字歌词的格式标签（YRC / QRC / KRC / LRCX / TTML ...）。
///
/// [dark] 用于深色封面背景（全屏播放页歌词区），否则使用传入的主题颜色。
class LyricFormatTag extends StatelessWidget {
  const LyricFormatTag({
    super.key,
    required this.format,
    this.colors,
    this.dark = false,
  });

  final String format;
  final ThemeColors? colors;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final theme = colors;
    final foreground = dark
        ? Colors.white.withValues(alpha: 0.8)
        : theme?.textSecondary ?? Colors.grey;
    final background = dark
        ? Colors.white.withValues(alpha: 0.12)
        : theme?.surfaceVariant ?? Colors.transparent;
    final border = dark
        ? Colors.white.withValues(alpha: 0.22)
        : theme?.divider ?? Colors.grey;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.full),
        border: Border.all(color: border, width: 0.5),
      ),
      child: Text(
        format,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
          color: foreground,
        ),
      ),
    );
  }
}
