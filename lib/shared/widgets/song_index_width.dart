import 'package:flutter/widgets.dart';

/// 歌曲列表「序号列」宽度：按列表里最大的序号自适应。
///
/// 以前各处把序号列写死成 40 / 44 / 48，26 首歌也白占那么多横向空间，
/// 序号被挤到离屏幕左边很远的位置。这里按「最大序号的位数」量一次：
///
/// * 1~9 首 → 1 位数宽度
/// * 10~99 首 → 2 位数宽度
/// * 1000 首以上 → 4 位数宽度
///
/// 用数字里最宽的 `8` 反复拼接来量，并按系统字号缩放，保证大字号下不折行。
double songIndexWidth(
  BuildContext context, {
  required int maxIndex,
  double fontSize = 13,
  FontWeight fontWeight = FontWeight.w500,
}) {
  final digits = (maxIndex < 1 ? 1 : maxIndex).toString().length;
  final painter = TextPainter(
    text: TextSpan(
      text: '8' * digits,
      style: TextStyle(fontSize: fontSize, fontWeight: fontWeight),
    ),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  // ceil 防止亚像素宽度把最后一位裁掉。
  return painter.width.ceilToDouble();
}
