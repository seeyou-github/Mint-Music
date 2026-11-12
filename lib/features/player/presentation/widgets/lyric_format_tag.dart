import 'package:flutter/material.dart';

import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/theme_colors.dart';

/// 逐字歌词的格式标签（YRC / QRC / KRC / LRCX / TTML ...）。
///
/// 颜色一律取传入的主题色：原来有个 `dark: true` 分支写死白字，浅色主题下
/// 这个标签在浅底上几乎看不见，而且不跟随「外观设置 → 字体颜色」。
class LyricFormatTag extends StatelessWidget {
  const LyricFormatTag({super.key, required this.format, this.colors});

  final String format;
  final ThemeColors? colors;

  @override
  Widget build(BuildContext context) {
    final theme = colors;
    final foreground = theme?.textSecondary ?? Colors.grey;
    final background = theme?.surfaceVariant ?? Colors.transparent;
    final border = theme?.divider ?? Colors.grey;

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
