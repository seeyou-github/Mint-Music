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
    // 把「窗口 0→1 的渐变」压缩进页面区域：渐变起点落在窗口的
    // topInset/windowHeight 处（Alignment 的 y = 2f - 1）。
    final beginY = windowHeight > 0 ? (2 * topInset / windowHeight) - 1 : -1.0;
    return AnimatedContainer(
      // 与全局那层同一条曲线：改「背景渐变」时两边一起过渡，不会一快一慢。
      duration: const Duration(seconds: 1),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment(0, beginY),
          end: Alignment.bottomCenter,
          colors: gradient.colors,
        ),
      ),
      child: child,
    );
  }
}
