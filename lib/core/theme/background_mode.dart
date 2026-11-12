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

/// 设置目录里保存的所有背景图文件名（用户可以上传多张来回切换）。
///
/// 顺序就是设置页里图片的排列顺序；[blurBackgroundImageNameProvider] 是其中
/// 当前选中的那张。
final blurBackgroundImageNamesProvider = StateProvider<List<String>>(
  (ref) => const [],
);

/// 模糊程度（高斯 sigma）：0 = 不模糊，越大越糊。
final blurBackgroundSigmaProvider = StateProvider<double>((ref) => 40);

/// 背景图亮度（浅色主题）：1 = 原图，小于 1 压暗、大于 1 提亮。
///
/// 浅色主题正文是深色，背景图默认给足亮度（100%），否则整块背景发黑、
/// 深色字糊在上面；深色主题反过来，用 [darkBlurBrightnessProvider] 的 30%。
final lightBlurBrightnessProvider = StateProvider<double>((ref) => 1);

/// 背景图亮度（深色主题）：默认 30%，白字压在照片上才看得清。
final darkBlurBrightnessProvider = StateProvider<double>((ref) => 0.3);

/// 主界面背景饱和度（浅色主题）：1 = 原样，0 = 灰度，大于 1 更艳。
///
/// 浅色主题默认只留 10% 的彩度（接近灰白），底色才不会抢文字的对比度。
final lightBackgroundSaturationProvider = StateProvider<double>((ref) => 0.1);

/// 主界面背景饱和度（深色主题）：默认 20%。
final darkBackgroundSaturationProvider = StateProvider<double>((ref) => 0.2);

/// 饱和度用的颜色矩阵（[s] = 1 时是单位矩阵）。
///
/// 灰度权重用 Rec. 709 的 0.2126 / 0.7152 / 0.0722，与 `ColorFilter.matrix`
/// 的语义一致；矩阵乘在 RGB 上、不动 alpha。
List<double> blurSaturationMatrix(double s) {
  final v = s.clamp(0.0, 2.0);
  const lr = 0.2126;
  const lg = 0.7152;
  const lb = 0.0722;
  return [
    lr + (1 - lr) * v, lg - lg * v, lb - lb * v, 0, 0, //
    lr - lr * v, lg + (1 - lg) * v, lb - lb * v, 0, 0, //
    lr - lr * v, lg - lg * v, lb + (1 - lb) * v, 0, 0, //
    0, 0, 0, 1, 0, //
  ];
}

/// 把饱和度颜色矩阵作用到单个颜色上（权重与 [blurSaturationMatrix] 相同）。
///
/// 控件底色是从背景主色派生出来的（卡片、按钮、顶栏、菜单…），背景照片被
/// 调成灰度 / 更艳之后，这些颜色也得跟着变；按同一套矩阵算，两者色调才
/// 对得上，而不是背景灰了控件还是原来的艳丽色。
Color applyBlurSaturation(Color color, double saturation) {
  final s = saturation.clamp(0.0, 2.0);
  if (s == 1.0) return color;
  const lr = 0.2126;
  const lg = 0.7152;
  const lb = 0.0722;
  final r = color.r;
  final g = color.g;
  final b = color.b;
  double mix(double cr, double cg, double cb) =>
      (cr * r + cg * g + cb * b).clamp(0.0, 1.0);
  return Color.from(
    alpha: color.a,
    red: mix(lr + (1 - lr) * s, lg - lg * s, lb - lb * s),
    green: mix(lr - lr * s, lg + (1 - lg) * s, lb - lb * s),
    blue: mix(lr - lr * s, lg - lg * s, lb + (1 - lb) * s),
  );
}

/// 当前背景图自身的色彩浓度。
///
/// 0 = 黑白灰 / 暗到看不出颜色，1 = 颜色很足。由取色器解码背景图时顺手算出
/// （每像素色度的平均值），app 层写进这里；[effectiveBlurSaturation] 用它
/// 决定饱和度滑条生效多少。「跟随封面」时封面那层在图片加载出来、成为背景
/// 之前就自己算好浓度（见 `_CoverBackdrop`），不经过这里。取不到图时保持 1
/// （不衰减）。
final backgroundBlurColorfulnessProvider = StateProvider<double>((ref) => 1);

/// 图片本身色彩很低时，饱和度调整按这个比例打折。
///
/// 纯黑白 / 灰度图是 0（调了也没颜色可调），暗到发黑的图色度也很低；
/// 从 [startAt] 到 [fullAt] 平滑升到 1，正常颜色的图不受影响。
double saturationStrengthForColorfulness(
  double colorfulness, {
  double startAt = 0.04,
  double fullAt = 0.18,
}) {
  final t = ((colorfulness - startAt) / (fullAt - startAt)).clamp(0.0, 1.0);
  // smoothstep：低浓度区间过渡柔和，不会在某个数值上力度突变。
  return t * t * (3 - 2 * t);
}

/// 滑条上的 [saturation] 按图片自身色彩浓度打折后的实际值。
///
/// 黑白 / 暗图上硬拉饱和度只会把压缩噪点、色斑放大，所以这类图几乎不生效；
/// 颜色正常的图原样生效。
double effectiveBlurSaturation(double saturation, double colorfulness) {
  final strength = saturationStrengthForColorfulness(colorfulness);
  final s = saturation.clamp(0.0, 2.0);
  return (1 + (s - 1) * strength).clamp(0.0, 2.0);
}

/// 「亮图自动压暗」强度（0 = 关闭，1 = 100%，2 = 200%）。
///
/// 用户的「亮度」是固定值，白底封面和暗色封面套同一档亮度时，前者会亮得
/// 看不清白字、后者又太黑。这里再按图片自身的平均亮度补一层黑色：图片越亮
/// 压得越多，暗图几乎不压。100% 对特别亮的图仍可能不够，允许拉到 200%。
final blurBackgroundAutoDarkenProvider = StateProvider<double>((ref) => 1.8);

/// 按图片平均亮度算自动压暗的黑色不透明度。
///
/// 亮度不超过 [threshold] 不压；从 [threshold] 到 1 线性增加，纯白图最多压
/// `maxAlpha * strength`（[strength] 取 0~2，200% 时接近全黑，但用 [limit]
/// 兜底保留一点纹理）。图片的「平均亮度」由取色结果（取色算法跳过极暗 /
/// 极亮像素后的平均色）的 luminance 提供。
double blurAutoDarkenAlpha({
  required double luminance,
  required double strength,
  double threshold = 0.3,
  double maxAlpha = 0.65,
  double limit = 0.9,
}) {
  if (strength <= 0) return 0;
  final l = luminance.clamp(0.0, 1.0);
  if (l <= threshold) return 0;
  final t = ((l - threshold) / (1 - threshold)).clamp(0.0, 1.0);
  return (t * maxAlpha * strength.clamp(0.0, 2.0)).clamp(0.0, limit);
}

/// 背景图的绝对路径：没设置、文件被删掉或读不出来时返回 null，
/// 由调用方退回渐变背景。
final blurBackgroundImagePathProvider = FutureProvider<String?>((ref) async {
  final name = ref.watch(blurBackgroundImageNameProvider).trim();
  if (name.isEmpty) return null;
  try {
    final dir = await AppPaths.blurBackgroundDirectory();
    final file = File(p.join(dir.path, name));
    if (await _isUsableImage(file)) return file.path;
    // 旧版图片直接放在设置目录里；还原旧备份后还没被启动迁移搬到子目录时，
    // 按旧路径取，避免背景暂时退回渐变。
    final legacy = File(
      p.join((await AppPaths.settingsDirectory()).path, name),
    );
    if (await _isUsableImage(legacy)) return legacy.path;
    return null;
  } catch (_) {
    return null;
  }
});

Future<bool> _isUsableImage(File file) async {
  try {
    if (!await file.exists()) return false;
    return await file.length() > 0;
  } catch (_) {
    return false;
  }
}

/// 高斯模糊背景图的「基调色」：压暗后的照片主色。
///
/// core 层不依赖取色器（那是 features 层），所以由 app 层算好后写进来。
/// 控件底色（侧栏、卡片、按钮、搜索框…）据此派生：
///   - 不跟照片同色调的话，中性灰的控件压在彩色照片上像「贴上去的」；
///   - 直接拿照片原色又太亮，白字看不清，所以取的是压暗过的基色，
///     再由 [ThemeColors.copyWithBackground] 往上提一档亮度。
final backgroundBlurTintProvider = StateProvider<Color?>((ref) => null);
