import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 背景渐变方向。
///
/// 8 个固定方向覆盖上下 / 左右 / 四个对角，再加一个 [random]：它不写死某一个
/// 角度，而是按渐变的颜色算哈希挑一个方向 —— 同一个渐变每次启动方向都一样
/// （不会每帧闪），但不同渐变之间方向各不相同，不会所有背景都朝同一个方向。
enum GradientDirection {
  topToBottom('上下'),
  bottomToTop('下上'),
  leftToRight('左右'),
  rightToLeft('右左'),
  diagonalDownRight('左上到右下'),
  diagonalDownLeft('右上到左下'),
  diagonalUpRight('左下到右上'),
  diagonalUpLeft('右下到左上'),
  random('随机');

  const GradientDirection(this.label);

  /// 设置界面里显示的名字。
  final String label;

  /// 渐变起点（[random] 请走 [BackgroundGradient.begin]，会先解析成固定方向）。
  Alignment get begin => switch (this) {
    GradientDirection.bottomToTop => Alignment.bottomCenter,
    GradientDirection.leftToRight => Alignment.centerLeft,
    GradientDirection.rightToLeft => Alignment.centerRight,
    GradientDirection.diagonalDownRight => Alignment.topLeft,
    GradientDirection.diagonalDownLeft => Alignment.topRight,
    GradientDirection.diagonalUpRight => Alignment.bottomLeft,
    GradientDirection.diagonalUpLeft => Alignment.bottomRight,
    GradientDirection.topToBottom ||
    GradientDirection.random => Alignment.topCenter,
  };

  /// 渐变终点。
  Alignment get end => switch (this) {
    GradientDirection.topToBottom => Alignment.bottomCenter,
    GradientDirection.bottomToTop => Alignment.topCenter,
    GradientDirection.leftToRight => Alignment.centerRight,
    GradientDirection.rightToLeft => Alignment.centerLeft,
    GradientDirection.diagonalDownRight => Alignment.bottomRight,
    GradientDirection.diagonalDownLeft => Alignment.bottomLeft,
    GradientDirection.diagonalUpRight => Alignment.topRight,
    GradientDirection.diagonalUpLeft => Alignment.topLeft,
    GradientDirection.random => Alignment.bottomCenter,
  };
}

/// 固定方向列表（不含 [GradientDirection.random]），随机时从这里面挑。
const List<GradientDirection> _fixedDirections = [
  GradientDirection.topToBottom,
  GradientDirection.bottomToTop,
  GradientDirection.leftToRight,
  GradientDirection.rightToLeft,
  GradientDirection.diagonalDownRight,
  GradientDirection.diagonalDownLeft,
  GradientDirection.diagonalUpRight,
  GradientDirection.diagonalUpLeft,
];

/// 按颜色算一个稳定的哈希来挑方向：同一组颜色永远得到同一个方向。
GradientDirection randomDirectionFor(List<Color> colors) {
  var seed = 0;
  for (final color in colors) {
    seed = (seed * 31 + color.toARGB32()) & 0x7fffffff;
  }
  return _fixedDirections[seed % _fixedDirections.length];
}

/// 方向的持久化标记：写进颜色列表末尾，如 `@3`。
String gradientDirectionToken(GradientDirection direction) =>
    '@${direction.index}';

/// 从颜色列表里取出方向标记（没有或非法时回落到「上下」）。
GradientDirection gradientDirectionFromTokens(List<String> tokens) {
  for (final token in tokens) {
    if (!token.startsWith('@')) continue;
    final index = int.tryParse(token.substring(1));
    if (index != null &&
        index >= 0 &&
        index < GradientDirection.values.length) {
      return GradientDirection.values[index];
    }
  }
  return GradientDirection.topToBottom;
}

/// 去掉方向 / 光晕标记后的颜色列表。
List<String> gradientColorTokens(List<String> tokens) => tokens
    .where((token) => !token.startsWith('@') && !token.startsWith('~'))
    .toList(growable: false);

/// 光晕数量的持久化标记：`~3` 表示 3 个光晕。
String gradientGlowToken(int count) => '~$count';

/// 从颜色列表里取出光晕数量（没有标记 = 0，即不画光晕）。
int gradientGlowCountFromTokens(List<String> tokens) {
  for (final token in tokens) {
    if (!token.startsWith('~')) continue;
    final count = int.tryParse(token.substring(1));
    if (count != null) return count.clamp(0, 12);
  }
  return 0;
}

/// 一个背景光晕：位置 / 半径都用相对值，绘制时按容器尺寸换算。
class BackgroundGlow {
  const BackgroundGlow({
    required this.x,
    required this.y,
    required this.radius,
    required this.opacity,
  });

  /// 圆心横向位置（0~1，相对宽度）。
  final double x;

  /// 圆心纵向位置（0~1，相对高度）。
  final double y;

  /// 半径（相对容器短边）。
  final double radius;

  /// 中心不透明度（越靠边越透明）。
  final double opacity;
}

/// 生成一组光晕：位置、半径、亮度都随机。
///
/// 随机种子 = 启动种子 ^ 渐变颜色的哈希：
/// - 同一次启动、同一条渐变 → 布局稳定，不会每帧乱跳；
/// - 换一条渐变 / 重启应用 → 位置和范围都换一批（就是「每次启动都不同」）。
List<BackgroundGlow> buildBackgroundGlows({
  required List<Color> colors,
  required int count,
  required int seed,
}) {
  if (count <= 0 || colors.isEmpty) return const [];
  var colorSeed = 0;
  for (final color in colors) {
    colorSeed = (colorSeed * 31 + color.toARGB32()) & 0x7fffffff;
  }
  final random = math.Random(seed ^ colorSeed);
  return List<BackgroundGlow>.generate(count, (_) {
    return BackgroundGlow(
      x: random.nextDouble(),
      y: random.nextDouble(),
      // 半径 0.26~0.68 倍短边：小光点和大面积晕染混在一起才自然。
      radius: 0.26 + random.nextDouble() * 0.42,
      opacity: 0.07 + random.nextDouble() * 0.11,
    );
  }, growable: false);
}

/// 主界面背景渐变。
///
/// 用户在「外观设置 → 背景渐变」里选 1~3 个颜色，这里统一展开成**固定 3 段**
/// （不足时用插值补），这样切换背景时 `AnimatedContainer` 的两端渐变颜色数量
/// 一致、可以平滑插值，不会跳变。
class BackgroundGradient {
  /// 渐变方向的 3 个颜色（按 [begin] → [end] 排列）。
  final List<Color> colors;

  /// 中间色：派生 `surface` / `divider` 等控件色用的基准。
  final Color mid;

  /// 渐变方向（可能是 [GradientDirection.random]）。
  final GradientDirection direction;

  /// 叠加几个光晕（0 = 不画）。
  final int glowCount;

  const BackgroundGradient({
    required this.colors,
    required this.mid,
    this.direction = GradientDirection.topToBottom,
    this.glowCount = 0,
  });

  /// 纯色（三个色段相同），用于「只选了一个颜色」或兜底。
  factory BackgroundGradient.solid(
    Color color, {
    GradientDirection direction = GradientDirection.topToBottom,
    int glowCount = 0,
  }) => BackgroundGradient(
    colors: [color, color, color],
    mid: color,
    direction: direction,
    glowCount: glowCount,
  );

  /// 实际渲染用的方向：`random` 按颜色哈希解析成一个固定方向。
  GradientDirection get resolvedDirection =>
      direction == GradientDirection.random
      ? randomDirectionFor(colors)
      : direction;

  Alignment get begin => resolvedDirection.begin;

  Alignment get end => resolvedDirection.end;
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
  GradientDirection direction = GradientDirection.topToBottom,
  int glowCount = 0,
}) {
  final colors = picked.isEmpty
      ? <Color>[fallback]
      : picked.take(3).toList(growable: false);
  if (colors.length >= 3) {
    return BackgroundGradient(
      colors: colors,
      mid: colors[1],
      direction: direction,
      glowCount: glowCount,
    );
  }
  if (colors.length == 2) {
    final middle = Color.lerp(colors[0], colors[1], 0.5)!;
    return BackgroundGradient(
      colors: [colors[0], middle, colors[1]],
      mid: middle,
      direction: direction,
      glowCount: glowCount,
    );
  }
  return BackgroundGradient.solid(
    colors[0],
    direction: direction,
    glowCount: glowCount,
  );
}
