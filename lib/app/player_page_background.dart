import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/theme_provider.dart';
import 'app_background_layer.dart';

/// 播放详情页 / 歌词页的背景。
///
/// 底下那一层**就是主界面那一层**（[AppBackgroundLayer]）：同一套渐变、
/// 同一张模糊图、同一个「跟随封面」结果、同一个光晕种子，所以从主界面点进
/// 播放页时背景不会换一块，只有上面多一层压暗。
///
/// 压暗是必须的：播放类页面是整页沉浸式界面，文字固定白色，哪怕主界面用的是
/// 浅色渐变也得压到白字看得清。压多少按「背景模式 + 深浅主题」分档，尽量只压
/// 到刚够读的程度——压过头就又变成「两块背景」的割裂感。
class PlayerPageBackground extends ConsumerWidget {
  const PlayerPageBackground({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLight = ref.watch(isLightThemeActiveProvider);
    final isBlur = ref.watch(backgroundModeProvider) == BackgroundMode.blur;

    // 深色渐变背景本来就够暗（派生亮度 0.1 上下），几乎不用压；
    // 模糊背景是一张照片、亮度不可控，压得多一点；浅色主题一律压狠。
    final double dim;
    if (isBlur) {
      dim = isLight ? 0.68 : 0.42;
    } else {
      dim = isLight ? 0.64 : 0.12;
    }

    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 光晕不做漂移动画：主界面那层的动画是各自独立计时的，两页之间
          // 本来也对不上相位，这里跟着动只会让这一整页每帧重绘。
          const AppBackgroundLayer(glowAnimated: false),
          if (dim > 0) ColoredBox(color: Colors.black.withValues(alpha: dim)),
          // 下沿再压一层：托住播放控制 / 歌词，和背景的暗角呼应。
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0, 0.5, 1],
                colors: [
                  Colors.transparent,
                  Color(0x1A000000),
                  Color(0x59000000),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
