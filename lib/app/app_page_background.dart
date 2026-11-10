import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/platform/window_chrome.dart';
import '../core/theme/theme_provider.dart';
import '../features/player/application/playback_controller.dart';
import '../shared/widgets/background_dither_layer.dart';
import '../shared/widgets/background_glow_layer.dart';
import 'windows_title_bar.dart';

/// 二级页面自己的一份「主界面背景」。
///
/// 主界面背景是 `MaterialApp.builder` 里那层全局渐变，各页面的 `Scaffold` 都是
/// 透明的（见 `073b779` / `c2776cb`）。对底部那几个分类页没问题，但**二级页面
/// 在滑动转场里必须自己是不透明的**：
///
/// - 滑入时它从右侧盖过来，自身透明就会在滑动过程中露出下面那一页的内容；
/// - 滑出时同理，看着像「底下那页提前出现了」，而不是被慢慢揭开。
///
/// 所以这里在页面内容下面铺一份和窗口那层**完全相同**的渐变：
///
/// - 颜色与方向一致；纵向渐变做横向平移，视觉上等于没动，所以跟着页面滑也不会
///   露出「背景在动」的破绽；
/// - 相位也对齐窗口：Windows 顶上有一条 32dp 的自绘标题栏（见 [WindowsTitleBar]），
///   页面区域是从它下面开始的，渐变要按「窗口顶部」起算才不会和底部页面错开
///   一小段颜色。
///
/// 用在这两处：
/// - `app_router.dart` 的 `_slideTransition`：所有「从右侧滑入」的二级页面，
///   背景跟着页面一起平移；
/// - 走系统默认转场（缩放 / 淡入）的几个页面，直接包在自己的根节点上：
///   专辑/作者详情（GoRoute 只写了 `builder`）、自定义歌单编辑页、电台编辑页。
///
/// 底部导航里的分类页仍然是透明的、直接透出全局那层。
class AppPageBackground extends ConsumerWidget {
  const AppPageBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gradient = ref.watch(backgroundGradientProvider);
    // 与窗口那层背景保持同一套动画开关：播放中且开启动态光晕时才移动。
    final glowAnimated =
        ref.watch(coverGlowAnimationEnabledProvider) &&
        ref.watch(
          playbackControllerProvider.select((state) => state.isPlaying),
        );
    // 页面区域相对窗口顶部下移了多少（只有 Windows 自绘标题栏时非 0）。
    final topInset = Platform.isWindows && WindowChrome.hasCustomTitleBar
        ? WindowsTitleBar.height
        : 0.0;
    // 渐变盒：向上伸出 topInset、向下铺到页面底部。页面本身从 topInset 开始、
    // 一直铺到窗口底部，所以这个盒子的高度**恰好等于窗口高度**，页面里看到的
    // 就是全局渐变从标题栏下沿到底部那一段 —— 相位天然对齐，不需要拿窗口高度
    // 算任何东西。
    //
    // 之前用 `Alignment(0, 2*topInset/H - 1)` 反推相位：窗口从最小化恢复 /
    // 刚创建时 MediaQuery 会先报一个很小的 H，相位算成接近 +1，整屏背景被压成
    // 底部一条（看起来「整体变浅」），尺寸恢复后 1 秒补间又摊开，就是那个
    // 「由浅变深」的闪动。
    //
    // 现在这里不读 MediaQuery、不读窗口尺寸：decoration 是常量，窗口尺寸怎么
    // 变都只是这个盒子的高度变（超出部分被 Stack 裁掉），不会重算、不会补间。
    return Stack(
      // 超出页面的部分（标题栏那一条）直接裁掉。
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: -topInset,
          bottom: 0,
          child: Stack(
            fit: StackFit.expand,
            children: [
              AnimatedContainer(
                // 与全局那层同一条曲线：改「背景渐变」时两边一起过渡，
                // 不会一快一慢。
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
              // 二级页背景也要有和主界面同一批光晕，否则滑入 / 滑出时
              // 会看到「光晕突然没了」。
              BackgroundGlowLayer(
                colors: gradient.colors,
                count: gradient.glowCount,
                seed: ref.watch(backgroundGlowSeedProvider),
                animated: glowAnimated,
              ),
              // 打散渐变 / 光晕在 8 位色深下的色带。
              const BackgroundDitherLayer(),
            ],
          ),
        ),
        Positioned.fill(child: child),
      ],
    );
  }
}
