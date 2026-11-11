import 'package:flutter/material.dart';

import 'app_background_layer.dart';

/// 播放详情页 / 歌词页的背景。
///
/// 直接复用主界面那一层 [AppBackgroundLayer]：同一套渐变、同一张模糊图、
/// 同一个「跟随封面」结果、同一个光晕种子、同样的亮图压暗，**不再额外压暗**，
/// 从主界面点进播放页时背景完全一致。
class PlayerPageBackground extends StatelessWidget {
  const PlayerPageBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return const RepaintBoundary(child: AppBackgroundLayer());
  }
}
