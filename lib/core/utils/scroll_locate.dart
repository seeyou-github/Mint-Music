import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 把 [controller] 定位到列表中第 [index] 项。
///
/// 一次性解决两个问题：
///
/// 1. **卡顿**：直接 `animateTo` 跨越几千像素时，动画的每一帧都会让列表构建
///    并布局途经的条目（歌曲行还带封面加载），长列表上明显掉帧。这里先
///    `jumpTo` 到距目标一个可视高度处，再用短动画滑完最后一屏，需要构建的
///    条目数量从「整段距离」降到「一屏」。
/// 2. **累积偏移**：目标位置由 `index * itemExtent` 推出，一旦 itemExtent 与
///    真实行高有误差，误差会随 index 线性放大（第 85 项、每行差 8px 就是
///    680px，目标会整个滚出可视区）。调用方通过 `itemExtent` /
///    `prototypeItem` 保证行高真实值，落点再用 [alignment] 放到可视区中部
///    偏上，避免贴顶被头部或悬浮层遮挡。
Future<void> scrollToItemIndex(
  ScrollController controller, {
  required int index,
  required double itemExtent,
  double alignment = 0.25,
  Duration duration = const Duration(milliseconds: 260),
}) async {
  if (!controller.hasClients || itemExtent <= 0 || index < 0) return;

  final position = controller.position;
  final viewport = position.viewportDimension;
  final minExtent = position.minScrollExtent;
  final maxExtent = position.maxScrollExtent;

  final itemTop = index * itemExtent;
  final slack = math.max(0.0, viewport - itemExtent);
  final target = (itemTop - slack * alignment).clamp(minExtent, maxExtent);
  if (duration == Duration.zero) {
    controller.jumpTo(target);
    return;
  }
  final delta = target - position.pixels;

  // 距离超过 1.5 屏就先瞬移到目标附近，只把最后一屏留给动画。
  if (delta.abs() > viewport * 1.5) {
    final preJump = (target - (delta > 0 ? viewport : -viewport)).clamp(
      minExtent,
      maxExtent,
    );
    controller.jumpTo(preJump);
  }

  await controller.animateTo(
    target,
    duration: duration,
    curve: Curves.easeOutCubic,
  );
}
