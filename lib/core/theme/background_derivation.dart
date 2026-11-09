/// 背景色派生：把「一个基色」变成整块界面能用的渐变。
///
/// 播放详情页、歌词页、设置里的「背景渐变」共用这一套算法，保证同一种
/// 基色在哪里出现都是同一个观感：
///   - 只保留基色的**色相**，饱和度夹进一个很窄的区间（鲜艳封面不会在
///     界面上留下亮黄 / 亮蓝的刺眼色块）；
///   - 接近无彩色（S < 0.08）直接按纯灰处理，避免出现奇怪的偏色；
///   - 亮度压进固定区间：深色主题往下压（0.17 → 0.08），浅色主题往上提
///     （0.94 → 0.86），白色 / 黑色封面都不会派生出「反主题」的背景。
library;

import 'package:flutter/material.dart';

/// 亮度可调的幅度（滑条推到两端时的偏移量）。
const double _kDarkBrightnessRange = 0.10;
const double _kLightBrightnessRange = 0.06;

/// 派生后亮度的允许区间（「保护 = 0」时才夹紧，保护拉满会直接用原色）。
const double _kDarkMinLightness = 0.02;
const double _kDarkMaxLightness = 0.40;
const double _kLightMinLightness = 0.55;
const double _kLightMaxLightness = 0.99;

/// 深色主题：亮度往这个区间压 —— `0.03 + 原亮度 * 0.13`。
///
/// 颜色越亮，被压掉的绝对亮度越多（0.9 → 约 0.15），越暗压得越少（0.2 → 约
/// 0.06）；纯黑封面也不会被抬亮。
const double _kDarkLightnessFloor = 0.03;
const double _kDarkLightnessScale = 0.13;

/// 浅色主题：往白提亮的比例（越暗提得越多，越亮动得越少）。
const double _kLightLightnessLift = 0.5;

/// 饱和度衰减系数：饱和度降幅 = 原饱和度² × 这个系数 —— 越鲜艳降得越多。
const double _kSaturationDrop = 0.85;

/// 派生后饱和度的上限：深色背景容得下更多色彩，浅色背景压得更狠。
const double _kDarkMaxSaturation = 0.30;
const double _kLightMaxSaturation = 0.22;

/// 上下落差的基准幅度（spread = 1 时的半差）。
const double _kDarkSpread = 0.045;
const double _kLightSpread = 0.04;

/// 饱和度低于这个值就当作无彩色（灰），避免灰白封面色出现偏红 / 偏绿。
const double _kGraySaturationThreshold = 0.08;

/// 把 [color] 处理成「可用作背景」的深色：保留色相，饱和度夹紧，
/// 亮度固定为 [lightness]。
///
/// 播放页通知卡片底色、封面投影用它（这些地方要的是固定的暗色，不跟随
/// 封面自身的明暗）。
Color coverDarkBackgroundColor(Color color, {required double lightness}) {
  final hsl = HSLColor.fromColor(color);
  final saturation = hsl.saturation < _kGraySaturationThreshold
      ? 0.0
      : hsl.saturation.clamp(0.12, _kDarkMaxSaturation);
  return hsl.withSaturation(saturation).withLightness(lightness).toColor();
}

/// 由「基色」派生背景渐变的 3 段颜色（从顶到底）。
///
/// 与封面取色、设置里的「背景渐变」共用：
/// - [isLight]：浅色主题走「提亮」版本，深色主题走「压暗」版本；
/// - [brightness]：整体亮度偏移，-1 ~ 1（0 = 默认）；
/// - [spread]：渐变落差倍率，0 = 纯色，1 = 默认，最大 10 = 落差 ×10；
///   编辑器里的「渐变幅度」滑条就是 0%~1000%。
/// - [protect]：0 = 完全按背景规则压暗 / 降饱和，1 = 用原色本身。
///   设置里的编辑器（手选颜色、图片取色）都用 1，即不做任何处理；
///   只有「跟随封面」这类自动取色用 0。
/// - [saturationScale]：饱和度倍率（编辑器里的「饱和度」滑条），
///   1 = 保持原样，0 = 灰，2 = 加倍。
///
/// 压暗 / 降饱和的幅度都和颜色自身挂钩：越亮压得越多、越鲜艳降得越多，
/// 所以浅色封面不会留下发白的背景，鲜艳封面也不会留下刺眼色块。
List<Color> deriveBackgroundGradient(
  Color base, {
  required bool isLight,
  double brightness = 0,
  double spread = 1,
  double protect = 0,
  double saturationScale = 1,
}) {
  final hsl = HSLColor.fromColor(base);
  final baseLightness = hsl.lightness;
  final baseSaturation = hsl.saturation;

  // 亮度：深色主题往暗处压、浅色主题往白处提，幅度都与原亮度相关。
  final dampedLightness = isLight
      ? baseLightness + (1 - baseLightness) * _kLightLightnessLift
      : _kDarkLightnessFloor + baseLightness * _kDarkLightnessScale;
  // 饱和度：降幅 = 原饱和度² × 系数，越鲜艳降得越多。
  final dampedSaturation =
      (baseSaturation - baseSaturation * baseSaturation * _kSaturationDrop)
          .clamp(0.0, isLight ? _kLightMaxSaturation : _kDarkMaxSaturation);

  // 保护原色：0 用处理过的值，1 用原色。
  final protectRatio = protect.clamp(0.0, 1.0);
  final dampedClamped = dampedLightness.clamp(
    isLight ? _kLightMinLightness : _kDarkMinLightness,
    isLight ? _kLightMaxLightness : _kDarkMaxLightness,
  );
  final lightness =
      dampedClamped + (baseLightness - dampedClamped) * protectRatio;
  final saturation =
      (dampedSaturation + (baseSaturation - dampedSaturation) * protectRatio) *
      saturationScale.clamp(0.0, 2.0);

  final delta =
      (isLight ? _kLightSpread : _kDarkSpread) * spread.clamp(0.0, 10.0);
  final offset =
      brightness.clamp(-1.0, 1.0) *
      (isLight ? _kLightBrightnessRange : _kDarkBrightnessRange);

  Color at(double value) => hsl
      .withSaturation(saturation.clamp(0.0, 1.0))
      .withLightness(value.clamp(0.0, 1.0))
      .toColor();

  return [
    at(lightness + delta + offset),
    at(lightness + offset),
    at(lightness - delta + offset),
  ];
}
