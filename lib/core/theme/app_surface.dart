import 'package:flutter/material.dart';

import 'theme_colors.dart';

/// 卡片 / 按钮 / 设置块统一的「悬浮表面」装饰。
///
/// 主界面背景跟随封面取色后是一整片渐变，控件底色（[ThemeColors.surface]）
/// 已被刻意派生得只比背景亮一点点，因此这里不再靠色差分层，而是靠：
///   1. 一条极细的边框勾出边界（[floatingBorder]）；
///   2. 下方一层柔和阴影制造「浮起来」的立体感（[floatingShadows]）。
///
/// 想让悬浮更明显 / 更收敛，只改 [floatingShadows] 一处即可，所有卡片、
/// 按钮、设置块同时生效。深色主题下纯黑阴影在暗背景上不显眼，额外补了一道
/// 极淡的顶边高光来勾轮廓。
List<BoxShadow> floatingShadows(ThemeColors colors) {
  final isLight =
      ThemeData.estimateBrightnessForColor(colors.background) ==
      Brightness.light;
  return [
    BoxShadow(
      color: Colors.black.withValues(alpha: isLight ? 0.12 : 0.32),
      blurRadius: 10,
      spreadRadius: 0.5,
      offset: const Offset(0, 3),
    ),
    if (!isLight)
      const BoxShadow(
        color: Color(0x14FFFFFF),
        blurRadius: 1,
        offset: Offset(0, -1),
      ),
  ];
}

/// 按钮 / 标签这类小控件用的轻阴影：同样有浮起感，但不会让密集的
/// 分类栏、分页条看起来一团脏。
List<BoxShadow> floatingSubtleShadows(ThemeColors colors) {
  final isLight =
      ThemeData.estimateBrightnessForColor(colors.background) ==
      Brightness.light;
  return [
    BoxShadow(
      color: Colors.black.withValues(alpha: isLight ? 0.07 : 0.20),
      blurRadius: 4,
      offset: const Offset(0, 2),
    ),
  ];
}

/// 悬浮表面的细边框：用派生自背景的分隔线色，深色下略亮、浅色下略暗。
Border floatingBorder(ThemeColors colors) =>
    Border.all(color: colors.divider.withValues(alpha: 0.45), width: 0.5);

/// 卡片 / 按钮 / 设置块的统一 [BoxDecoration]。
///
/// [withShadow] 传 false 时只保留底色与细边框，用于「内部还要
/// `clipBehavior` 裁剪」的卡片 —— 阴影改由 [floatingCard] 画在外层。
/// [subtle] 给按钮 / 标签用更轻的阴影。
BoxDecoration floatingSurfaceDecoration(
  ThemeColors colors, {
  required double radius,
  Color? color,
  bool withShadow = true,
  bool subtle = false,
}) {
  return BoxDecoration(
    color: color ?? colors.surface,
    borderRadius: BorderRadius.circular(radius),
    border: floatingBorder(colors),
    boxShadow: withShadow
        ? (subtle ? floatingSubtleShadows(colors) : floatingShadows(colors))
        : null,
  );
}

/// 给「内部带 `clipBehavior` 裁剪」的卡片套一层不会被裁掉的阴影。
///
/// `Container(clipBehavior: Clip.antiAlias)` 会把 `BoxDecoration.boxShadow`
/// 连同内容一起裁到圆角矩形以内，阴影恰好画在卡片外侧，会被全部裁掉。
/// 所以卡片内的 decoration 用 `withShadow: false`，阴影由这里的外层
/// [DecoratedBox] 绘制（它先画阴影再画不透明的卡片，边缘正好露出来）。
Widget floatingCard({
  required ThemeColors colors,
  required double radius,
  required Widget child,
}) {
  final borderRadius = BorderRadius.circular(radius);
  return DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: borderRadius,
      boxShadow: floatingShadows(colors),
    ),
    // 边框画在内容之上：卡片的封面 / 文字区会铺满整个圆角矩形，若把边框
    // 放进背景 decoration，会被 child 整块盖住，只剩阴影看不出边界。
    child: DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        border: floatingBorder(colors),
      ),
      child: child,
    ),
  );
}
