import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/background_gradient.dart';

/// 背景光晕层：在渐变上叠若干团柔和的径向光斑。
///
/// 位置 / 半径 / 亮度由 [buildBackgroundGlows] 按「启动种子 + 颜色哈希」算：
/// 同一次启动内稳定，重启后换一批，所以每次打开界面看到的光晕都不一样。
/// 整层是 [IgnorePointer]，不会挡住页面里的点击。
class BackgroundGlowLayer extends StatelessWidget {
  const BackgroundGlowLayer({
    super.key,
    required this.colors,
    required this.count,
    required this.seed,
  });

  /// 背景渐变的三段颜色（光晕取首色往白里提一点）。
  final List<Color> colors;

  /// 光晕数量（0 = 不画）。
  final int count;

  /// 启动种子（[backgroundGlowSeedProvider]）。
  final int seed;

  @override
  Widget build(BuildContext context) {
    if (count <= 0 || colors.isEmpty) return const SizedBox.shrink();
    final glows = buildBackgroundGlows(
      colors: colors,
      count: count,
      seed: seed,
    );
    if (glows.isEmpty) return const SizedBox.shrink();
    // 往白里提 22%：深色背景上是「亮一块」，浅色背景上是极淡的提亮，
    // 不会变成突兀的白斑。
    final glowColor = Color.lerp(colors.first, Colors.white, 0.22)!;
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final height = constraints.maxHeight;
          if (!width.isFinite || !height.isFinite) {
            return const SizedBox.shrink();
          }
          // 半径按短边算：窄窗口 / 长条窗口也不会画出被拉扁的椭圆光斑。
          final unit = math.min(width, height);
          return Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              for (final glow in glows)
                Positioned(
                  left: glow.x * width - glow.radius * unit,
                  top: glow.y * height - glow.radius * unit,
                  width: glow.radius * unit * 2,
                  height: glow.radius * unit * 2,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          glowColor.withValues(alpha: glow.opacity),
                          glowColor.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
