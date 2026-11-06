import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/player/domain/services/cover_color_extractor.dart';
import 'theme_provider.dart';

/// 整个主界面的背景色（纵向渐变的上、下两色）。
///
/// 始终返回两个颜色：不启用跟随封面时两色相同，等于用户在「外观设置 →
/// 背景颜色」里选的纯色，这样外层 `AnimatedContainer` 的类型始终是
/// `LinearGradient`，切歌 / 关开关时可以做平滑插值，不会出现一帧跳变。
class CoverBackground {
  final Color top;
  final Color bottom;

  const CoverBackground({required this.top, required this.bottom});

  const CoverBackground.solid(Color color) : top = color, bottom = color;
}

/// 主界面背景取色。
///
/// - 深色主题：完全照搬播放详情页 —— 只保留封面色相、亮度压到 0.17→0.08
///   的暗色纵向渐变（[coverDarkBackgroundColor] 与播放页同一个函数）。
/// - 浅色主题：把封面主色淡淡混进用户的浅色背景，保持浅底黑字，避免
///   文字与系统状态栏图标失去反差。
/// - 开关关闭 / 没有封面 / 取色失败：回退用户的纯色背景。
final coverBackgroundProvider = Provider<CoverBackground>((ref) {
  final colors = ref.watch(themeColorsProvider);
  final solid = colors.background;
  if (!ref.watch(mainBackgroundFollowCoverProvider)) {
    return CoverBackground.solid(solid);
  }
  final cover = ref.watch(currentCoverColorProvider).valueOrNull?.dominantColor;
  // 没有封面、或提取失败拿到的默认灰，都不改背景。
  if (cover == null || cover == CoverColorResult.defaultResult.dominantColor) {
    return CoverBackground.solid(solid);
  }
  if (ref.watch(isLightThemeActiveProvider)) {
    return CoverBackground(top: Color.lerp(solid, cover, 0.30)!, bottom: solid);
  }
  return CoverBackground(
    top: coverDarkBackgroundColor(cover, lightness: 0.17),
    bottom: coverDarkBackgroundColor(cover, lightness: 0.08),
  );
});
