import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/background_gradient.dart';

/// 背景光晕层：在渐变上叠若干团柔和的径向光斑。
///
/// 位置 / 半径 / 亮度由 [buildBackgroundGlows] 按「启动种子 + 颜色哈希」算：
/// 同一次启动内稳定，重启后换一批，所以每次打开界面看到的光晕都不一样。
/// 整层是 [IgnorePointer]，不会挡住页面里的点击。
///
/// [animated] 为 true（播放中且开启了「播放歌曲时动态光晕」）时，每团光晕
/// 按各自的随机相位 / 速度缓慢漂移，并叠加轻微的亮度与半径呼吸；暂停播放
/// 或关闭开关时停在当前位置，不会跳回初始布局。
class BackgroundGlowLayer extends StatefulWidget {
  const BackgroundGlowLayer({
    super.key,
    required this.colors,
    required this.count,
    required this.seed,
    this.animated = false,
  });

  /// 背景渐变的三段颜色（光晕取首色往白里提一点）。
  final List<Color> colors;

  /// 光晕数量（0 = 不画）。
  final int count;

  /// 启动种子（[backgroundGlowSeedProvider]）。
  final int seed;

  /// 是否让光晕缓慢移动 + 呼吸。
  final bool animated;

  @override
  State<BackgroundGlowLayer> createState() => _BackgroundGlowLayerState();
}

class _BackgroundGlowLayerState extends State<BackgroundGlowLayer>
    with SingleTickerProviderStateMixin {
  /// 一轮的时长：刻意放得很慢，光斑几乎察觉不到「在转」。
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  );

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant BackgroundGlowLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animated != widget.animated) _syncTicker();
  }

  void _syncTicker() {
    if (widget.animated) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 每团光晕的漂移 / 呼吸参数：由启动种子和下标生成，同一轮启动内稳定，
  /// 光晕之间互相不同步，看起来像各自随机飘。
  ///
  /// 速度取整数圈 / 轮：进度从 1 回到 0 时正弦值连续，循环不会「跳一下」。
  List<_GlowMotion> _motions(int count) {
    return List<_GlowMotion>.generate(count, (i) {
      final random = math.Random((widget.seed ^ 0x9E3779B9) + i * 0x45D9F3B);
      return _GlowMotion(
        phaseX: random.nextDouble() * 2 * math.pi,
        phaseY: random.nextDouble() * 2 * math.pi,
        speedX: (1 + random.nextInt(2)).toDouble(),
        speedY: (1 + random.nextInt(2)).toDouble(),
        dirX: random.nextBool() ? 1.0 : -1.0,
        dirY: random.nextBool() ? 1.0 : -1.0,
        phaseBreath: random.nextDouble() * 2 * math.pi,
        breathSpeed: (2 + random.nextInt(2)).toDouble(),
      );
    }, growable: false);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.count <= 0 || widget.colors.isEmpty) {
      return const SizedBox.shrink();
    }
    final glows = buildBackgroundGlows(
      colors: widget.colors,
      count: widget.count,
      seed: widget.seed,
    );
    if (glows.isEmpty) return const SizedBox.shrink();
    // 往白里提 22%：深色背景上是「亮一块」，浅色背景上是极淡的提亮，
    // 不会变成突兀的白斑。
    final glowColor = Color.lerp(widget.colors.first, Colors.white, 0.22)!;
    final motions = _motions(glows.length);
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
          return RepaintBoundary(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                final t = _controller.value;
                return Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    for (var i = 0; i < glows.length; i++)
                      _buildGlow(
                        glows[i],
                        motions[i],
                        t: t,
                        width: width,
                        height: height,
                        unit: unit,
                        glowColor: glowColor,
                      ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildGlow(
    BackgroundGlow glow,
    _GlowMotion motion, {
    required double t,
    required double width,
    required double height,
    required double unit,
    required Color glowColor,
  }) {
    // 用「当前相位 - 初始相位」做偏移：t = 0 时位移为 0，
    // 所以关闭动画或从未播放时，和原来的静态布局完全一致，不会跳一下。
    final dx =
        0.045 *
        (math.sin(2 * math.pi * t * motion.speedX + motion.phaseX) -
            math.sin(motion.phaseX)) *
        motion.dirX;
    final dy =
        0.040 *
        (math.cos(2 * math.pi * t * motion.speedY + motion.phaseY) -
            math.cos(motion.phaseY)) *
        motion.dirY;
    final breath =
        math.sin(2 * math.pi * t * motion.breathSpeed + motion.phaseBreath) -
        math.sin(motion.phaseBreath);
    final radius = glow.radius * unit * (1 + 0.06 * breath);
    final opacity = (glow.opacity * (1 + 0.18 * breath))
        .clamp(0.0, 0.35)
        .toDouble();
    return Positioned(
      left: (glow.x + dx) * width - radius,
      top: (glow.y + dy) * height - radius,
      width: radius * 2,
      height: radius * 2,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              glowColor.withValues(alpha: opacity),
              glowColor.withValues(alpha: 0),
            ],
          ),
        ),
      ),
    );
  }
}

/// 单团光晕的动画参数。
class _GlowMotion {
  const _GlowMotion({
    required this.phaseX,
    required this.phaseY,
    required this.speedX,
    required this.speedY,
    required this.dirX,
    required this.dirY,
    required this.phaseBreath,
    required this.breathSpeed,
  });

  final double phaseX;
  final double phaseY;

  /// 横向 / 纵向每轮走几圈（整数，保证循环连续）。
  final double speedX;
  final double speedY;

  /// 漂移方向。
  final double dirX;
  final double dirY;

  final double phaseBreath;
  final double breathSpeed;
}
