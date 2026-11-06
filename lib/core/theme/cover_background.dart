import 'package:flutter/material.dart';

import '../../features/player/domain/services/cover_color_extractor.dart';

/// 整个主界面的背景色（纵向渐变的上、下两色 + 控件色基准）。
///
/// 始终返回两个颜色：不启用跟随封面时两色相同，等于用户在「外观设置 →
/// 背景颜色」里选的纯色，这样外层 `AnimatedContainer` 的类型始终是
/// `LinearGradient`，切歌 / 关开关时可以做平滑插值，不会出现一帧跳变。
///
/// 这里只放数据类与纯函数，不引用任何 Riverpod provider —— provider 统一放在
/// `theme_provider.dart`（`coverBackgroundProvider` / `themeColorsProvider`），
/// 避免两个库互相 import。
class CoverBackground {
  final Color top;
  final Color bottom;

  /// 派生控件色（surface / surfaceVariant / divider / 迷你播放器）用的基准纯色。
  /// 取渐变的中段色，卡片与侧栏才会和背景同一色调。
  final Color control;

  /// 是否真的在跟随封面；false 时主题直接返回用户设置派生的基础色。
  final bool active;

  const CoverBackground({
    required this.top,
    required this.bottom,
    required this.control,
    required this.active,
  });

  const CoverBackground.solid(Color color)
    : top = color,
      bottom = color,
      control = color,
      active = false;
}

/// 把「用户背景色 + 当前封面主色 + 明暗 + 开关」解析成主界面配色。
///
/// - 深色主题：完全照搬播放详情页 —— 只保留封面色相、亮度压到 0.17→0.08
///   的暗色纵向渐变（[coverDarkBackgroundColor] 与播放页同一个函数）。
/// - 浅色主题：把封面主色淡淡混进用户的浅色背景，保持浅底黑字，避免
///   文字与系统状态栏图标失去反差。
/// - 开关关闭 / 没有封面 / 取色失败：回退用户的纯色背景。
CoverBackground resolveCoverBackground({
  required Color solid,
  required Color? cover,
  required bool isLight,
  required bool enabled,
}) {
  if (!enabled ||
      cover == null ||
      cover == CoverColorResult.defaultResult.dominantColor) {
    return CoverBackground.solid(solid);
  }
  if (isLight) {
    final tinted = Color.lerp(solid, cover, 0.30)!;
    return CoverBackground(
      top: tinted,
      bottom: solid,
      control: tinted,
      active: true,
    );
  }
  return CoverBackground(
    top: coverDarkBackgroundColor(cover, lightness: 0.17),
    bottom: coverDarkBackgroundColor(cover, lightness: 0.08),
    control: coverDarkBackgroundColor(cover, lightness: 0.12),
    active: true,
  );
}
