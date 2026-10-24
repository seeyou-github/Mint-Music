import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme_provider.dart';

/// 封面右上角的黑色标签（来源 / 专辑 / 作者）。
///
/// 文字颜色统一跟随外观设置里的深色模式字体颜色，边框用 [color] 区分来源。
class CoverBadge extends ConsumerWidget {
  const CoverBadge({
    super.key,
    required this.label,
    this.color = Colors.white,
    this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textColor = ref.watch(coverBadgeTextColorProvider);
    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.85)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          height: 1.1,
          fontWeight: FontWeight.w500,
          color: textColor,
        ),
      ),
    );
    if (onTap == null) return badge;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onTap, child: badge),
    );
  }
}

/// 封面角落的数量 / 播放量标签（黑底、可选小图标）。
///
/// 与 [CoverBadge] 共用同一套文字规则：颜色跟随外观设置里的深色模式字体
/// 颜色，只改变文字，背景与圆角保持原样。
class CoverCountBadge extends ConsumerWidget {
  const CoverCountBadge({
    super.key,
    required this.label,
    this.icon,
    this.fontSize = 11,
    this.padding = const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    this.radius = 6,
    this.background = Colors.black,
  });

  final String label;
  final IconData? icon;

  /// 文字（以及图标）大小。
  final double fontSize;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color background;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textColor = ref.watch(coverBadgeTextColorProvider);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: fontSize, color: textColor),
            const SizedBox(width: 2),
          ],
          Text(
            label,
            style: TextStyle(fontSize: fontSize, height: 1.1, color: textColor),
          ),
        ],
      ),
    );
  }
}
