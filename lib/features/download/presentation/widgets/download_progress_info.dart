import 'package:flutter/material.dart';

import '../../../../core/l10n/l10n.dart';

/// 下载中的进度信息行：左侧百分比，右侧「速度: xx/s  文件大小」。
///
/// 「速度:」这个标签的位置必须固定：网速数值和文件大小的位数一直在变，
/// 若把它们拼成一个字符串，标签就会跟着左右移动（看起来像在抖）。这里把
/// 两个数值各自放进固定宽度的盒子里，标签和列位置就被钉死了。
class DownloadProgressInfo extends StatelessWidget {
  const DownloadProgressInfo({
    super.key,
    required this.progress,
    required this.speedLabel,
    required this.sizeLabel,
    required this.color,
  });

  /// 0~1 的下载进度，左侧显示成百分比。
  final double progress;

  /// 已格式化好的速度文案（如 `1.2 MB/s`），空值用 `-`。
  final String speedLabel;

  /// 已格式化好的文件大小文案（如 `5.3 MB`）。
  final String sizeLabel;

  final Color color;

  /// 速度数值区的固定宽度（fontSize 11 的基准，随系统字号缩放）。
  /// 按最长文案「1023.9 KB/s」留够余量，避免被裁掉单位。
  static const double speedWidth = 66;

  /// 文件大小数值区的固定宽度。
  static const double sizeWidth = 52;

  /// 「速度:」标签，测试用它取位置。
  static const Key labelKey = Key('download-speed-label');

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final style = TextStyle(fontSize: 11, color: color);
    return Row(
      children: [
        Text('${(progress * 100).toStringAsFixed(0)}%', style: style),
        const Spacer(),
        Text('${context.tr('速度')}:', key: labelKey, style: style),
        SizedBox(width: 4 * textScale),
        // 网速：固定宽度，位数变化只发生在盒子内部。
        SizedBox(
          width: speedWidth * textScale,
          child: Text(
            speedLabel,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: style,
          ),
        ),
        SizedBox(width: 10 * textScale),
        // 文件大小：同样固定宽度，否则它一变宽也会把「速度:」推走。
        SizedBox(
          width: sizeWidth * textScale,
          child: Text(
            sizeLabel,
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: style,
          ),
        ),
      ],
    );
  }
}
