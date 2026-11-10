import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/theme_provider.dart';
import '../shared/widgets/background_dither_layer.dart';
import '../shared/widgets/background_glow_layer.dart';

/// 主界面背景层：按「背景颜色模式」画渐变（+ 光晕）或高斯模糊图。
///
/// 全局那层背景（`MaterialApp.builder`）和二级页面自己那份背景都用它，
/// 两边必须完全一致，否则页面滑入 / 滑出时会看出「背景在跳」。
class AppBackgroundLayer extends ConsumerWidget {
  const AppBackgroundLayer({super.key, required this.glowAnimated});

  /// 光晕是否跟着播放缓慢漂移（调用方已经按「开关 + 正在播放」算好）。
  final bool glowAnimated;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(backgroundModeProvider) == BackgroundMode.blur) {
      final path = ref.watch(blurBackgroundImagePathProvider).valueOrNull;
      // 没选图片 / 文件被删掉 / 还读不出来时退回渐变：主界面不能空着。
      if (path != null) {
        return _BlurBackground(
          path: path,
          sigma: ref.watch(blurBackgroundSigmaProvider),
          brightness: ref.watch(blurBackgroundBrightnessProvider),
          // 浅色主题下正文是深色，照片太暗就看不清字，额外盖一层白纱。
          lightenForLightTheme: ref.watch(isLightThemeActiveProvider),
        );
      }
    }
    return _GradientBackground(glowAnimated: glowAnimated);
  }
}

/// 背景渐变那套：渐变 + 光晕 + 抖动噪点（原来的全局背景就是这个）。
class _GradientBackground extends ConsumerWidget {
  const _GradientBackground({required this.glowAnimated});

  final bool glowAnimated;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gradient = ref.watch(backgroundGradientProvider);
    return Stack(
      fit: StackFit.expand,
      children: [
        // 1 秒过渡：换颜色 / 换主题时不会「啪」地跳一下。
        AnimatedContainer(
          duration: const Duration(seconds: 1),
          curve: Curves.easeInOut,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: gradient.begin,
              end: gradient.end,
              colors: gradient.colors,
            ),
          ),
        ),
        BackgroundGlowLayer(
          colors: gradient.colors,
          count: gradient.glowCount,
          seed: ref.watch(backgroundGlowSeedProvider),
          animated: glowAnimated,
        ),
        // 打散渐变 / 光晕在 8 位色深下的色带。
        const BackgroundDitherLayer(),
      ],
    );
  }
}

/// 高斯模糊背景：用户选的图片 → 模糊 → 叠亮度 → 噪点。
class _BlurBackground extends StatelessWidget {
  const _BlurBackground({
    required this.path,
    required this.sigma,
    required this.brightness,
    required this.lightenForLightTheme,
  });

  final String path;
  final double sigma;

  /// 1 = 原图；小于 1 压暗，大于 1 提亮。
  final double brightness;

  /// 浅色主题是否额外盖一层白纱（深色文字压在暗背景上会看不清）。
  final bool lightenForLightTheme;

  /// 解码宽度：模糊会把细节全抹平，按屏幕宽度解一张大图纯属浪费内存。
  static const int _decodeWidth = 1080;

  @override
  Widget build(BuildContext context) {
    final blurSigma = sigma.clamp(0.0, 60.0);
    // 模糊会让图片边缘向内发虚，稍微放大一点把发虚的边推到屏幕外。
    final scale = blurSigma <= 0.5 ? 1.0 : 1.0 + blurSigma / 120;

    final image = Image.file(
      File(path),
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      cacheWidth: _decodeWidth,
      gaplessPlayback: true,
      // 图片坏了就当没有：底下铺的纯色还在，不会白屏。
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );

    final normalized = brightness.clamp(0.2, 1.4);
    final darken = normalized < 1 ? (1 - normalized) : 0.0;
    final whiten = normalized > 1 ? (normalized - 1) * 0.6 : 0.0;

    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 图片加载出来之前、或解码失败时的底色。
          const ColoredBox(color: Color(0xFF101012)),
          if (blurSigma <= 0.5)
            Transform.scale(scale: scale, child: image)
          else
            ImageFiltered(
              imageFilter: ui.ImageFilter.blur(
                sigmaX: blurSigma,
                sigmaY: blurSigma,
              ),
              child: Transform.scale(scale: scale, child: image),
            ),
          // 浅色主题：正文是深色，先把图整体提亮，否则暗照片上根本看不清字。
          if (lightenForLightTheme)
            ColoredBox(color: Colors.white.withValues(alpha: 0.35)),
          if (darken > 0)
            ColoredBox(color: Colors.black.withValues(alpha: darken)),
          if (whiten > 0)
            ColoredBox(color: Colors.white.withValues(alpha: whiten)),
          // 与渐变背景一样做一层抖动，避免大面积纯色出现色带。
          const BackgroundDitherLayer(),
        ],
      ),
    );
  }
}
