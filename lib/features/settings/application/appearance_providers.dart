import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/theme_provider.dart';
import '../../player/domain/services/cover_color_extractor.dart';

/// 高斯模糊背景图的取色结果：控件底色用的主色 + 图片自身的色彩浓度。
class BlurBackgroundTint {
  const BlurBackgroundTint({required this.color, required this.colorfulness});

  /// 平均主色；图片几乎是纯黑 / 纯白 / 灰度时取不到可用的主色，为 null
  /// （控件退回中性主题色，但 [colorfulness] 仍是 0，饱和度滑条照样减弱）。
  final Color? color;

  /// 图片自身的色彩浓度：0 = 黑白灰 / 暗到看不出颜色，1 = 颜色很足。
  final double colorfulness;
}

/// 高斯模糊背景图的主色，用来派生控件底色（侧栏 / 卡片 / 按钮 / 搜索框…）。
///
/// 只解一张 96px 的小图取平均色就够：控件底色要的是整张照片的色调，不需要
/// 细节。照片取不到色、或者没有图片时返回 null，控件退回中性主题色。
///
/// 这里只给「原始主色」，压暗 / 提亮由 [deriveBackgroundGradient] 按深浅
/// 主题分别处理，浅色主题才不会拿到一个发黑的底色。
final blurBackgroundTintProvider = FutureProvider<BlurBackgroundTint?>((
  ref,
) async {
  final path = await ref.watch(blurBackgroundImagePathProvider.future);
  if (path == null) return null;
  try {
    final result = await CoverColorExtractor.extract(
      ResizeImage(FileImage(File(path)), width: 96, allowUpscaling: false),
    );
    final dominant = result.dominantColor;
    // 提取失败时拿到的是那条默认灰：当作「没取到色」，别把界面拉成纯灰。
    // 纯黑白 / 灰度图也会走到这里（所有像素都被跳过），但色彩浓度仍是 0。
    final usable = dominant != CoverColorResult.defaultResult.dominantColor;
    return BlurBackgroundTint(
      color: usable ? dominant : null,
      colorfulness: result.colorfulness,
    );
  } catch (_) {
    return null;
  }
});
