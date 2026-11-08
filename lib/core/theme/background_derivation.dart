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

/// 深色主题下的默认亮度：上 / 中 / 下。
const double _kDarkTopLightness = 0.17;
const double _kDarkMidLightness = 0.125;
const double _kDarkBottomLightness = 0.08;

/// 浅色主题下的默认亮度：上 / 中 / 下。
const double _kLightTopLightness = 0.94;
const double _kLightMidLightness = 0.90;
const double _kLightBottomLightness = 0.86;

/// 亮度可调的幅度（滑条推到两端时的偏移量）。
const double _kDarkBrightnessRange = 0.10;
const double _kLightBrightnessRange = 0.06;

/// 亮度硬夹紧区间，任何滑条组合都不会越界。
const double _kDarkMinLightness = 0.03;
const double _kDarkMaxLightness = 0.30;
const double _kLightMinLightness = 0.78;
const double _kLightMaxLightness = 0.98;

/// 饱和度区间：深色背景容得下更多色彩，浅色背景必须压得更狠才不会脏。
const double _kDarkMinSaturation = 0.12;
const double _kDarkMaxSaturation = 0.32;
const double _kLightMinSaturation = 0.06;
const double _kLightMaxSaturation = 0.18;

/// 饱和度低于这个值就当作无彩色（灰），避免灰白封面色出现偏红 / 偏绿。
const double _kGraySaturationThreshold = 0.08;

/// 把 [color] 处理成「可用作背景」的颜色：保留色相，饱和度夹紧，
/// 亮度固定为 [lightness]。
///
/// 播放页 / 歌词页的封面暗色、通知卡片底色、封面投影都用它。
Color coverDarkBackgroundColor(Color color, {required double lightness}) {
  final hsl = HSLColor.fromColor(color);
  final saturation = hsl.saturation < _kGraySaturationThreshold
      ? 0.0
      : hsl.saturation.clamp(_kDarkMinSaturation, _kDarkMaxSaturation);
  return hsl.withSaturation(saturation).withLightness(lightness).toColor();
}

/// 由「基色」派生背景渐变的 3 段颜色（从顶到底）。
///
/// - [isLight]：浅色主题走「提亮」版本，深色主题走「压暗」版本；
/// - [brightness]：整体亮度偏移，-1 ~ 1（0 = 默认）；
/// - [spread]：上下落差倍率，0 = 纯色，1 = 默认，2 = 落差翻倍。
///
/// 播放详情页取首尾两段（即默认的 0.17 / 0.08），与改动前的硬编码完全一致。
List<Color> deriveBackgroundGradient(
  Color base, {
  required bool isLight,
  double brightness = 0,
  double spread = 1,
}) {
  final hsl = HSLColor.fromColor(base);
  final baseSaturation = hsl.saturation < _kGraySaturationThreshold
      ? 0.0
      : hsl.saturation.clamp(
          isLight ? _kLightMinSaturation : _kDarkMinSaturation,
          isLight ? _kLightMaxSaturation : _kDarkMaxSaturation,
        );

  final topDefault = isLight ? _kLightTopLightness : _kDarkTopLightness;
  final midDefault = isLight ? _kLightMidLightness : _kDarkMidLightness;
  final bottomDefault = isLight
      ? _kLightBottomLightness
      : _kDarkBottomLightness;

  final offset =
      brightness.clamp(-1.0, 1.0) *
      (isLight ? _kLightBrightnessRange : _kDarkBrightnessRange);
  // spread 作用在「默认落差」上：0 收成纯色，1 保持原样，2 翻倍。
  final ratio = spread.clamp(0.0, 2.0);
  final top = midDefault + (topDefault - midDefault) * ratio;
  final bottom = midDefault - (midDefault - bottomDefault) * ratio;

  final minL = isLight ? _kLightMinLightness : _kDarkMinLightness;
  final maxL = isLight ? _kLightMaxLightness : _kDarkMaxLightness;

  Color at(double lightness) => hsl
      .withSaturation(baseSaturation)
      .withLightness(lightness.clamp(minL, maxL))
      .toColor();

  return [at(top + offset), at(midDefault + offset), at(bottom + offset)];
}
