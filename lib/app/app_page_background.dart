import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/platform/window_chrome.dart';
import '../core/theme/theme_provider.dart';
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
    // 页面区域相对窗口顶部下移了多少（只有 Windows 自绘标题栏时非 0）。
    final topInset = Platform.isWindows && WindowChrome.hasCustomTitleBar
        ? WindowsTitleBar.height
        : 0.0;
    final windowHeight = MediaQuery.sizeOf(context).height;
    // 渐变的盒子按「整个窗口」的高度铺，再上移 topInset：页面里看到的就是
    // 全局渐变从 topInset 到窗口底部那一段，相位天然对齐。
    //
    // 之前是拿 MediaQuery 高度反推 `Alignment(0, 2*topInset/H - 1)`，把渐变
    // 压缩进页面区域。问题在于窗口从最小化恢复 / 刚创建时，MediaQuery 会先
    // 报一个很小的尺寸（几十 px），算出来的相位接近 +1，整个窗口背景被压成
    // 底部一条、看起来「整体变浅」；尺寸恢复后 1 秒的 AnimatedContainer 又把
    // 它补间回来，视觉上就是「窗口一出现，背景由浅变深」。
    //
    // 现在相位是常量，窗口尺寸只影响这个盒子的高度（被 Stack 裁掉），
    // 尺寸抖动不会再改变 decoration，也就不会触发那段补间。
    final boxHeight = windowHeight < 200 ? 200.0 : windowHeight;
    return Stack(
      // 超出页面的部分（顶栏那一条）直接裁掉。
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: -topInset,
          height: boxHeight,
          child: AnimatedContainer(
            // 与全局那层同一条曲线：改「背景渐变」时两边一起过渡，不会一快一慢。
            duration: const Duration(seconds: 1),
            curve: Curves.easeInOut,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: gradient.colors,
              ),
            ),
          ),
        ),
        Positioned.fill(child: child),
      ],
    );
  }
}
