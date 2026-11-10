import 'package:flutter/material.dart';

import 'theme_colors.dart';

/// 「当前选中」的标签 / 导航胶囊底色：与侧栏「发现」的激活态一致。
///
/// 主题色按 15% 叠在背景上 —— 深色底上看起来就是把主题色调暗一档，
/// 文字 / 图标统一用主题色本身，比整块实心主题色更收敛。
const double activeChipAlpha = 0.15;

Color activeChipColor(ThemeColors colors) =>
    colors.primary.withValues(alpha: activeChipAlpha);

/// 选中胶囊的同色细边：给原本带描边的胶囊（文件夹标签、设置分类）保留
/// 轮廓，否则只剩一块色块，边会糊在背景里。
Border activeChipBorder(ThemeColors colors) =>
    Border.all(color: colors.primary.withValues(alpha: 0.5));

/// 选中胶囊的完整装饰（底色 + 可选细边）。
BoxDecoration activeChipDecoration(
  ThemeColors colors, {
  required double radius,
  bool withBorder = false,
}) {
  return BoxDecoration(
    color: activeChipColor(colors),
    borderRadius: BorderRadius.circular(radius),
    border: withBorder ? activeChipBorder(colors) : null,
  );
}

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

/// 顶栏按钮 / 搜索框统一的「轻阴影表面」。
///
/// 只有底色 + 一层很轻的阴影，**不画描边**：发现页、收藏页、本地页的顶栏
/// 控件都用它，三页观感才一致（收藏页以前用的是 1px 描边，和发现页的
/// 纯色块对不上）。[circle] 为 true 时做成圆形（圆形图标按钮）。
BoxDecoration floatingButtonDecoration(
  ThemeColors colors, {
  double radius = 999,
  bool circle = false,
}) {
  return BoxDecoration(
    color: colors.surface,
    shape: circle ? BoxShape.circle : BoxShape.rectangle,
    borderRadius: circle ? null : BorderRadius.circular(radius),
    boxShadow: floatingSubtleShadows(colors),
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
