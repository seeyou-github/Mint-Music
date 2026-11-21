import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/platform/window_chrome.dart';
import '../core/utils/responsive_layout.dart';
import 'app_background_layer.dart';
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
/// - 盒子与全局那层**完全同坐标**：页面区域只占窗口的一部分（宽屏下左边是
///   侧栏，Windows 顶上还有一条 32dp 的自绘标题栏），所以盒子向左伸出侧栏
///   宽度、向上伸出标题栏高度，再被页面裁掉。光晕位置、模糊图 `cover` 裁切、
///   噪点图案都按窗口尺寸算，和主界面逐像素一致，不再是「小一号的另一块背景」。
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
    // 页面区域相对窗口左上角平移了多少：Windows 自绘标题栏占高度，宽屏下
    // 左侧还有侧栏（侧栏只在「平板横屏」显示，此时必然是展开态，宽度固定）。
    final topInset = Platform.isWindows && WindowChrome.hasCustomTitleBar
        ? WindowsTitleBar.height
        : 0.0;
    final leftInset = ResponsiveLayout.shouldShowSidebar(context)
        ? ResponsiveLayout.sidebarWidth
        : 0.0;
    // 渐变盒：向左伸出侧栏宽度、向上伸出标题栏高度、右下铺到页面边缘。页面
    // 本身从窗口的 (leftInset, topInset) 开始、一直铺到窗口右下角，所以这个
    // 盒子**恰好等于窗口大小且与窗口左上角对齐**，页面里看到的就是全局背景
    // 对应的那一段 —— 相位、光晕、模糊图裁切天然一致，不需要拿窗口尺寸算
    // 任何东西。
    //
    // 之前只补了纵向标题栏：宽屏下盒子比窗口窄一个侧栏宽度，光晕按局部宽度
    // 排布、模糊图按局部框裁切，二级页背景和主界面在细节上对不上（尤其高斯
    // 模糊模式）。横向补偿后两边画的是同一块背景。
    //
    // 不读 MediaQuery、不读窗口尺寸：decoration 是常量，窗口尺寸怎么变都只是
    // 这个盒子的高度 / 宽度变（超出部分被 Stack 裁掉），不会重算、不会补间。
    return Stack(
      // 超出页面的部分（标题栏、侧栏那两块）直接裁掉。
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned(
          left: -leftInset,
          right: 0,
          top: -topInset,
          bottom: 0,
          // 和全局那层是同一个组件：渐变 / 光晕 / 高斯模糊图都跟着「背景颜色
          // 模式」走，二级页滑入滑出不会看出背景不一样。
          child: const AppBackgroundLayer(),
        ),
        Positioned.fill(child: child),
      ],
    );
  }
}
