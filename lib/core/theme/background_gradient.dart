import 'package:flutter/material.dart';

/// 主界面背景渐变。
///
/// 用户在「外观设置 → 背景渐变」里选 1~3 个颜色，这里统一展开成**固定 3 段**
/// （不足时用插值补），这样切换背景时 `AnimatedContainer` 的两端渐变颜色数量
/// 一致、可以平滑插值，不会跳变。
class BackgroundGradient {
  /// 纵向渐变的 3 个颜色（从顶到底）。
  final List<Color> colors;

  /// 中间色：派生 `surface` / `divider` 等控件色用的基准。
  final Color mid;

  const BackgroundGradient({required this.colors, required this.mid});

  /// 纯色（三个色段相同），用于「只选了一个颜色」或兜底。
  factory BackgroundGradient.solid(Color color) =>
      BackgroundGradient(colors: [color, color, color], mid: color);
}

/// 把用户选的颜色（0~3 个）解析成 3 段渐变。
///
/// - 一个都没选：用 [fallback]（主题默认背景）；
/// - 1 个：三段同色，即纯色背景；
/// - 2 个：中间插一半，形成起 → 止的平滑过渡；
/// - 3 个：原样使用。
///
/// 超过 3 个只取前 3 个（设置界面本来就限制最多 3 个）。
BackgroundGradient resolveBackgroundGradient({
  required List<Color> picked,
  required Color fallback,
}) {
  final colors = picked.isEmpty
      ? <Color>[fallback]
      : picked.take(3).toList(growable: false);
  if (colors.length >= 3) {
    return BackgroundGradient(colors: colors, mid: colors[1]);
  }
  if (colors.length == 2) {
    final middle = Color.lerp(colors[0], colors[1], 0.5)!;
    return BackgroundGradient(
      colors: [colors[0], middle, colors[1]],
      mid: middle,
    );
  }
  return BackgroundGradient.solid(colors[0]);
}
