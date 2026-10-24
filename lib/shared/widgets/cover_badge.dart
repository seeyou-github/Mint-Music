import 'package:flutter/material.dart';

/// 封面右上角的黑色标签（来源 / 专辑 / 作者）。
class CoverBadge extends StatelessWidget {
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
  Widget build(BuildContext context) {
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
          fontSize: 11,
          height: 1.1,
          fontWeight: FontWeight.w500,
          color: color,
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
