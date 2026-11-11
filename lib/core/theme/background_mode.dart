import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../platform/app_paths.dart';

/// 主界面背景的呈现方式（设置 → 外观设置 → 背景颜色模式）。
enum BackgroundMode {
  /// 用户选的 1~3 段颜色渐变：可以叠光晕，也可以跟随当前歌曲封面变色。
  gradient('gradient'),

  /// 用户自己选的图片，高斯模糊后铺满主界面。
  blur('blur');

  const BackgroundMode(this.id);

  /// 持久化用的值。
  final String id;

  /// 从设置里读回来。未知值按默认的「高斯模糊」处理。
  static BackgroundMode fromId(String? raw) => switch (raw) {
    'gradient' => BackgroundMode.gradient,
    'blur' => BackgroundMode.blur,
    _ => BackgroundMode.blur,
  };
}

/// 背景颜色模式：背景渐变 / 高斯模糊（默认）。
final backgroundModeProvider = StateProvider<BackgroundMode>(
  (ref) => BackgroundMode.blur,
);

/// 高斯模糊背景图的**文件名**（图片存在 `config/setting` 下）。
///
/// 只存文件名、不存绝对路径：备份还原到别的设备（或换安装目录）后路径会变，
/// 文件名不变，重新拼一下就能用。
final blurBackgroundImageNameProvider = StateProvider<String>((ref) => '');

/// 模糊程度（高斯 sigma）：0 = 不模糊，越大越糊。
final blurBackgroundSigmaProvider = StateProvider<double>((ref) => 30);

/// 背景图亮度：1 = 原图，小于 1 压暗、大于 1 提亮。
final blurBackgroundBrightnessProvider = StateProvider<double>((ref) => 0.85);

/// 「亮图自动压暗」强度（0 = 关闭，1 = 最强）。
///
/// 用户的「亮度」是固定值，白底封面和暗色封面套同一档亮度时，前者会亮得
/// 看不清白字、后者又太黑。这里再按图片自身的平均亮度补一层黑色：图片越亮
/// 压得越多，暗图几乎不压。
final blurBackgroundAutoDarkenProvider = StateProvider<double>((ref) => 0.7);

/// 按图片平均亮度算自动压暗的黑色不透明度。
///
/// 亮度不超过 [threshold] 不压；从 [threshold] 到 1 线性增加，纯白图最多压
/// `maxAlpha * strength`。图片的「平均亮度」由取色结果（取色算法跳过极暗 /
/// 极亮像素后的平均色）的 luminance 提供。
double blurAutoDarkenAlpha({
  required double luminance,
  required double strength,
  double threshold = 0.3,
  double maxAlpha = 0.5,
}) {
  if (strength <= 0) return 0;
  final l = luminance.clamp(0.0, 1.0);
  if (l <= threshold) return 0;
  final t = ((l - threshold) / (1 - threshold)).clamp(0.0, 1.0);
  return t * maxAlpha * strength.clamp(0.0, 1.0);
}

/// 背景图的绝对路径：没设置、文件被删掉或读不出来时返回 null，
/// 由调用方退回渐变背景。
final blurBackgroundImagePathProvider = FutureProvider<String?>((ref) async {
  final name = ref.watch(blurBackgroundImageNameProvider).trim();
  if (name.isEmpty) return null;
  try {
    final dir = await AppPaths.settingsDirectory();
    final file = File(p.join(dir.path, name));
    if (!await file.exists()) return null;
    if (await file.length() == 0) return null;
    return file.path;
  } catch (_) {
    return null;
  }
});

/// 高斯模糊背景图的「基调色」：压暗后的照片主色。
///
/// core 层不依赖取色器（那是 features 层），所以由 app 层算好后写进来。
/// 控件底色（侧栏、卡片、按钮、搜索框…）据此派生：
///   - 不跟照片同色调的话，中性灰的控件压在彩色照片上像「贴上去的」；
///   - 直接拿照片原色又太亮，白字看不清，所以取的是压暗过的基色，
///     再由 [ThemeColors.copyWithBackground] 往上提一档亮度。
final backgroundBlurTintProvider = StateProvider<Color?>((ref) => null);
