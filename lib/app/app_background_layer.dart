import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/theme_provider.dart';
import '../features/player/application/playback_controller.dart';
import '../features/player/domain/models/song.dart';
import '../shared/widgets/background_dither_layer.dart';
import '../shared/widgets/background_glow_layer.dart';
import '../shared/widgets/music_cover_image.dart';

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
      final sigma = ref.watch(blurBackgroundSigmaProvider);
      final brightness = ref.watch(blurBackgroundBrightnessProvider);
      // 浅色主题下正文是深色，照片太暗就看不清字，额外盖一层白纱。
      final lighten = ref.watch(isLightThemeActiveProvider);

      // 没有图时退回渐变：主界面不能空着。
      final Widget fallback;
      if (path == null) {
        fallback = _GradientBackground(glowAnimated: glowAnimated);
      } else {
        fallback = _BlurBackground(
          baseColor: const Color(0xFF101012),
          image: Image.file(
            File(path),
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            cacheWidth: _kBlurDecodeWidth,
            gaplessPlayback: true,
            // 图片坏了就当没有：底下铺的纯色还在，不会白屏。
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
          sigma: sigma,
          brightness: brightness,
          lightenForLightTheme: lighten,
        );
      }

      // 「主界面跟随封面变色」在高斯模糊模式下：背景直接用当前歌曲封面糊化。
      if (ref.watch(coverBlurBackdropEnabledProvider)) {
        // 订阅身份而不是 currentSong：同一首歌换清晰度时封面地址会变，
        // 而 Song 的 == 只比 id，订阅 currentSong 收不到这次变化。
        ref.watch(currentSongIdentityProvider);
        final song = ref.read(playbackControllerProvider).currentSong;
        if (song != null) {
          return _CoverBlurBackground(
            song: song,
            sigma: sigma,
            brightness: brightness,
            lightenForLightTheme: lighten,
            // 封面还在下载 / 这首歌根本没封面时，就用它兜着。
            fallback: fallback,
          );
        }
      }
      return fallback;
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

/// 「当前歌曲封面糊化」背景。
///
/// 封面走 [MusicCoverImage] 那条链路（在线地址 / 本地缓存 / 音频内嵌封面都
/// 能取到）；还在加载或这首歌压根没有封面时，下面那层 [fallback] 直接透出来，
/// 不会先黑一下。
class _CoverBlurBackground extends StatelessWidget {
  const _CoverBlurBackground({
    required this.song,
    required this.sigma,
    required this.brightness,
    required this.lightenForLightTheme,
    required this.fallback,
  });

  final Song song;
  final double sigma;
  final double brightness;
  final bool lightenForLightTheme;

  /// 兜底背景（用户的模糊图 / 渐变），同时充当封面加载期间的垫底。
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final hasCoverSource =
        (song.coverUrl?.isNotEmpty ?? false) ||
        song.isLocal ||
        song.mediaStoreId != null;
    if (!hasCoverSource) return fallback;

    return Stack(
      fit: StackFit.expand,
      children: [
        fallback,
        _BlurBackground(
          // 底下已经有兜底背景了，不要再铺一层不透明底色。
          baseColor: null,
          image: MusicCoverImage(
            // 换歌换 key：上一首的字节不能带过来（切歌瞬间会闪一下旧封面）。
            key: ValueKey<String>('${song.id}|${song.coverUrl}'),
            url: song.coverUrl,
            songId: song.id,
            mediaStoreId: song.mediaStoreId,
            filePath: song.filePath,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            cacheWidth: _kCoverDecodeWidth,
            filterQuality: FilterQuality.low,
            // 取不到图时不留占位图标：让下面那层兜底背景透出来。
            errorWidget: const SizedBox.shrink(),
          ),
          sigma: sigma,
          brightness: brightness,
          lightenForLightTheme: lightenForLightTheme,
        ),
      ],
    );
  }
}

/// 解码宽度：模糊会把细节全抹平，按屏幕宽度解一张大图纯属浪费内存。
const int _kBlurDecodeWidth = 1080;

/// 封面本来就不大（常见 500~1000），糊化后再降一档，省一半内存。
const int _kCoverDecodeWidth = 720;

/// 高斯模糊背景：图片 → 模糊 → 叠亮度 → 噪点。
class _BlurBackground extends StatelessWidget {
  const _BlurBackground({
    required this.image,
    required this.sigma,
    required this.brightness,
    required this.lightenForLightTheme,
    required this.baseColor,
  });

  /// 要糊化的图（用户选的图片，或当前歌曲封面）。
  final Widget image;

  final double sigma;

  /// 1 = 原图；小于 1 压暗，大于 1 提亮。
  final double brightness;

  /// 浅色主题是否额外盖一层白纱（深色文字压在暗背景上会看不清）。
  final bool lightenForLightTheme;

  /// 图片下面铺的底色；为 null 表示「底下已有背景」，不铺（否则会盖住兜底背景）。
  final Color? baseColor;

  @override
  Widget build(BuildContext context) {
    final blurSigma = sigma.clamp(0.0, 60.0);
    // 模糊会让图片边缘向内发虚，稍微放大一点把发虚的边推到屏幕外。
    final scale = blurSigma <= 0.5 ? 1.0 : 1.0 + blurSigma / 120;

    final normalized = brightness.clamp(0.2, 1.4);
    final darken = normalized < 1 ? (1 - normalized) : 0.0;
    final whiten = normalized > 1 ? (normalized - 1) * 0.6 : 0.0;

    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 图片加载出来之前、或解码失败时的底色。
          if (baseColor != null) ColoredBox(color: baseColor!),
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
