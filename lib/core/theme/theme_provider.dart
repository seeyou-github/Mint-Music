import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'background_gradient.dart';
import 'background_derivation.dart';
import 'background_mode.dart';
import 'app_surface.dart';
import 'theme_colors.dart';

export 'background_mode.dart';
export 'theme_colors.dart';

/// 应用主题模式：浅色 / 深色 / 跟随系统。
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);

/// 「主题色」的默认值（暖金）。
///
/// 外观设置里内置颜色的**第一个**就是它，新装 / 没保存过主题色时用的也是
/// 它；改这里要同步设置存储（`SettingsService.getThemePrimaryColor`）的兜底值。
const String defaultThemePrimaryColor = '#DBB580';

final themePrimaryColorProvider = StateProvider<String>(
  (ref) => defaultThemePrimaryColor,
);

/// 深色模式「字体颜色」的默认值（低饱和的米灰黄）。
const String defaultThemeFontColor = '#C4BEA4';

/// 浅色模式「字体颜色」「第二字体颜色」的默认值。
const String defaultLightFontColor = '#000000';
const String defaultLightSecondaryFontColor = '#3A3933';

/// 深色模式「第二字体颜色」的默认值（中灰，比正文暗一档）。
const String defaultDarkSecondaryFontColor = '#9D9D9D';

/// 浅色 / 深色模式「背景颜色」的默认值（内置渐变的第一个色）。
const String defaultLightBackgroundColor = '#B6B6B6';
const String defaultDarkBackgroundColor = '#292934';

/// 默认「背景渐变」：就是外观设置里内置渐变的**第一个**
/// （深色「深空灰」#292934 → #1F1F27 → #15151A，
/// 浅色「中灰」#B6B6B6 → #A7A7A7 → #979797）。
///
/// 新装软件默认选中它；设置面板里第一个内置渐变的色值必须与这里保持一致。
/// 末尾的 `~5` 是「5 个背景光晕」标记（见 background_gradient.dart）。
const List<String> defaultLightBackgroundGradient = [
  defaultLightBackgroundColor,
  '#A7A7A7',
  '#979797',
  '~5',
];
const List<String> defaultDarkBackgroundGradient = [
  defaultDarkBackgroundColor,
  '#1F1F27',
  '#15151A',
  '~5',
];

/// 深色模式「字体颜色」：主文字颜色（十六进制），为空表示使用主题默认色。
final darkThemeFontColorProvider = StateProvider<String>(
  (ref) => defaultThemeFontColor,
);

/// 浅色模式「字体颜色」：主文字颜色（十六进制），为空表示使用主题默认色。
final lightThemeFontColorProvider = StateProvider<String>(
  (ref) => defaultLightFontColor,
);

/// 深色模式「第二字体颜色」：次级文字颜色（十六进制），为空表示使用主题默认色。
final darkThemeSecondaryFontColorProvider = StateProvider<String>(
  (ref) => defaultDarkSecondaryFontColor,
);

/// 浅色模式「第二字体颜色」：次级文字颜色（十六进制），为空表示使用主题默认色。
final lightThemeSecondaryFontColorProvider = StateProvider<String>(
  (ref) => defaultLightSecondaryFontColor,
);

/// 深色模式「背景渐变」：从顶到底最多 3 个十六进制颜色。
///
/// 1 个 = 纯色背景；2 个 = 起 → 止两段；3 个 = 三段。为空表示用主题默认背景。
/// 初始值就是内置渐变的第一个，见 [defaultDarkBackgroundGradient]。
final darkThemeBackgroundColorsProvider = StateProvider<List<String>>(
  (ref) => defaultDarkBackgroundGradient,
);

/// 浅色模式「背景渐变」：从顶到底最多 3 个十六进制颜色。
final lightThemeBackgroundColorsProvider = StateProvider<List<String>>(
  (ref) => defaultLightBackgroundGradient,
);

/// 系统当前的亮/暗偏好。
///
/// [ThemeMode.system] 下由它决定实际使用亮色还是暗色主题。初始值取自
/// [PlatformDispatcher]；运行期间由 `SystemBrightnessSync` 在
/// `didChangePlatformBrightness` 中更新（见 `system_brightness_sync.dart`），
/// 因此系统切换亮/暗时界面会实时跟随，无需重启。
final platformBrightnessProvider = StateProvider<Brightness>(
  (ref) => PlatformDispatcher.instance.platformBrightness,
);

/// 当前实际生效的是否为浅色外观（「跟随系统」时按系统亮度展开）。
///
/// [themeColorsProvider] 以及外观设置用它决定当前编辑的是浅色还是深色那一套
/// 字体颜色 / 背景颜色。
final isLightThemeActiveProvider = Provider<bool>((ref) {
  return isThemeModeLight(
    ref.watch(themeModeProvider),
    ref.watch(platformBrightnessProvider),
  );
});

/// 主题模式 -> 持久化值。
String themeModeToPref(ThemeMode mode) => switch (mode) {
  ThemeMode.light => 'light',
  ThemeMode.dark => 'dark',
  ThemeMode.system => 'system',
};

/// 持久化值 -> 主题模式。未知值回落为跟随系统，保证旧版本数据可用。
ThemeMode themeModeFromPref(String? value) => switch (value) {
  'dark' => ThemeMode.dark,
  'light' => ThemeMode.light,
  _ => ThemeMode.system,
};

/// 把主题模式解析成「是否亮色」：[ThemeMode.system] 按系统偏好展开。
bool isThemeModeLight(ThemeMode mode, Brightness platformBrightness) =>
    switch (mode) {
      ThemeMode.light => true,
      ThemeMode.dark => false,
      ThemeMode.system => platformBrightness == Brightness.light,
    };

Color _parseThemeColor(String hex) {
  try {
    final code = hex.replaceFirst('#', '');
    return Color(int.parse('FF$code', radix: 16));
  } catch (_) {
    // 配置里是非法色值时回落到默认主题色（暖金）。
    return const Color(0xFFDBB580);
  }
}

/// 解析用户设置里的文字颜色；为空或非法时返回 null（表示不改动默认色）。
Color? _parseOptionalColor(String hex) {
  if (hex.trim().isEmpty) return null;
  try {
    final code = hex.replaceFirst('#', '').trim();
    if (code.length != 6 && code.length != 8) return null;
    return Color(int.parse('FF$code', radix: 16));
  } catch (_) {
    return null;
  }
}

/// 封面来源 / 类型标签的文字颜色。
///
/// 统一跟随「外观设置 → 深色模式 → 字体颜色」；标签边框仍用各自来源色，
/// 不受这里影响。字体颜色被清空时回落到深色主题的默认文字色。
final coverBadgeTextColorProvider = Provider<Color>((ref) {
  return _parseOptionalColor(ref.watch(darkThemeFontColorProvider)) ??
      ThemeColors.dark.textPrimary;
});

final _cachedLightColors = <String, ThemeColors>{};
final _cachedDarkColors = <String, ThemeColors>{};

/// 用户在「外观设置」里选的颜色派生出的基础主题色。
///
/// 只是中间层，不含背景：背景由 [backgroundGradientProvider] 单独提供。
/// 实际给界面用的是下面的 [themeColorsProvider]，它会用背景渐变的中间色
/// 再派生一套控件色。分开是为了避免两者互相依赖。
final baseThemeColorsProvider = Provider<ThemeColors>((ref) {
  final isLight = ref.watch(isLightThemeActiveProvider);
  final primaryHex = ref.watch(themePrimaryColorProvider);
  final fontHex = ref.watch(
    isLight ? lightThemeFontColorProvider : darkThemeFontColorProvider,
  );
  final secondaryHex = ref.watch(
    isLight
        ? lightThemeSecondaryFontColorProvider
        : darkThemeSecondaryFontColorProvider,
  );
  final cache = isLight ? _cachedLightColors : _cachedDarkColors;
  final key = '$primaryHex|$fontHex|$secondaryHex';
  return cache.putIfAbsent(key, () {
    final primaryColor = _parseThemeColor(primaryHex);
    final base = isLight
        ? ThemeColors.lightWithPrimary(primaryColor)
        : ThemeColors.darkWithPrimary(primaryColor);
    return base.copyWithTextColors(
      textPrimary: _parseOptionalColor(fontHex),
      textSecondary: _parseOptionalColor(secondaryHex),
    );
  });
});

/// 「主界面跟随封面变色」开关（仅深色主题生效）。
///
/// 打开后主界面背景由「当前歌曲封面主色」派生，算法与播放详情页背景
/// 完全相同（见 [deriveBackgroundGradient]）；浅色主题下忽略这个开关。
final coverBackgroundEnabledProvider = StateProvider<bool>((ref) => false);

/// 高斯模糊模式下，背景是否改成「当前播放歌曲的封面糊化」。
///
/// 条件：背景颜色模式 = 高斯模糊 + 「主界面跟随封面变色」打开。与渐变模式
/// 同一口径，这个开关在浅色主题下不生效（浅色背景得够亮，封面色压不住）。
///
/// 关掉开关 / 没在播放时返回 false，背景回到用户自己选的那张模糊图。
final coverBlurBackdropEnabledProvider = Provider<bool>((ref) {
  return ref.watch(backgroundModeProvider) == BackgroundMode.blur &&
      ref.watch(coverBackgroundEnabledProvider) &&
      !ref.watch(isLightThemeActiveProvider);
});

/// 「歌曲列表不显示封面」开关（默认关闭）。
///
/// 打开后各处的歌曲列表不再构建封面控件，也就不会触发封面网络请求；
/// 本地音乐页的本地歌曲列表、播放详情页以及播放栏 / 侧栏不受影响。
final songListHideCoverProvider = StateProvider<bool>((ref) => false);

/// 当前封面主色。
///
/// core 层不该直接依赖播放器的取色器（那是 features 层），所以由 app 层在
/// `currentCoverColorProvider` 出结果时把颜色写进来，这里只负责存。
final coverAccentColorProvider = StateProvider<Color?>((ref) => null);

/// 当前封面自身的色彩浓度（0 = 黑白灰 / 暗到看不出颜色，1 = 颜色很足）。
///
/// 与 [coverAccentColorProvider] 一起由 app 层从取色结果同步过来。控件底色
/// 从封面主色派生（见 [backgroundGradientProvider]），饱和度滑条按这个浓度
/// 打折 —— 黑白 / 暗封面上硬拉饱和度只会把噪点、色斑放大。背景图片那层
/// 不读这里，它在图片成为背景之前就按字节自己算好了。
final coverAccentColorfulnessProvider = StateProvider<double>((ref) => 1);

/// 背景光晕的启动种子。
///
/// 每次启动应用换一个随机值，光晕的位置 / 半径因此「每次启动都不同」；
/// 同一次启动内保持不变，不会每帧乱跳（见 [buildBackgroundGlows]）。
final backgroundGlowSeedProvider = Provider<int>(
  (ref) => math.Random().nextInt(1 << 30),
);

/// 主界面背景渐变（用户在外观设置里选的颜色 → 固定 3 段）。
///
/// 只看设置里的颜色，不订阅 [themeColorsProvider]，不会成环。
final backgroundGradientProvider = Provider<BackgroundGradient>((ref) {
  final isLight = ref.watch(isLightThemeActiveProvider);
  // 高斯模糊模式：背景是照片，控件底色（侧栏 / 卡片 / 按钮 / 搜索框…）
  // 要跟着照片的色调走，否则中性灰压在彩色照片上像「贴上去的」。这里回一条
  // 「照片主色派生出来的暗色渐变」，[themeColorsProvider] 拿它的中间色去
  // 派生 surface（比背景亮一档），界面就是「颜色轻微变化 + 略亮一点」。
  if (ref.watch(backgroundModeProvider) == BackgroundMode.blur) {
    // 用「当前歌曲封面糊化」当背景时，控件底色得跟着这首歌的封面色走，
    // 否则照片是新的、卡片还是上一张图的色调。当前歌没封面（取不到主色）时
    // 背景退回用户选的模糊图，底色也跟着那张图走。
    final coverTint = ref.watch(coverBlurBackdropEnabledProvider)
        ? ref.watch(coverAccentColorProvider)
        : null;
    final tint = coverTint ?? ref.watch(backgroundBlurTintProvider);
    if (tint != null) {
      // 饱和度滑条也作用在控件底色上：背景照片调灰 / 调艳之后，从它主色
      // 派生的卡片、按钮、顶栏、菜单要一起变，否则背景和控件两个色调。
      // 浓度与背景图那层取同一份（封面按封面、用户图按用户图）。
      final saturation = effectiveBlurSaturation(
        ref.watch(backgroundSaturationProvider),
        coverTint != null
            ? ref.watch(coverAccentColorfulnessProvider)
            : ref.watch(backgroundBlurColorfulnessProvider),
      );
      final colors = deriveBackgroundGradient(
        applyBlurSaturation(tint, saturation),
        isLight: isLight,
      );
      return BackgroundGradient(colors: colors, mid: colors[1], glowCount: 0);
    }
    // 还没取到色（图刚选 / 正在算）时继续走下面的用户渐变，界面不会闪。
  }
  // 「跟随封面变色」只在深色主题生效：拿到封面主色就直接走派生算法，
  // 和播放详情页 / 歌词页背景是同一个函数，两处观感一致。
  if (!isLight && ref.watch(coverBackgroundEnabledProvider)) {
    final accent = ref.watch(coverAccentColorProvider);
    if (accent != null) {
      // 饱和度设置对封面派生的渐变同样生效；黑白 / 暗封面按浓度打折，
      // 与模糊模式下封面糊化背景的口径一致。
      final saturation = effectiveBlurSaturation(
        ref.watch(backgroundSaturationProvider),
        ref.watch(coverAccentColorfulnessProvider),
      );
      final colors = deriveBackgroundGradient(
        applyBlurSaturation(accent, saturation),
        isLight: false,
      );
      // 跟随封面时固定叠 3 个光晕（位置 / 半径每次启动随机），
      // 让主界面不至于是一整片平铺的渐变。
      return BackgroundGradient(colors: colors, mid: colors[1], glowCount: 3);
    }
  }
  final tokens = ref.watch(
    isLight
        ? lightThemeBackgroundColorsProvider
        : darkThemeBackgroundColorsProvider,
  );
  final picked = <Color>[];
  // 列表末尾可能带 `@n` 方向标记 / `~n` 光晕标记，解析颜色时跳过它们。
  for (final hex in gradientColorTokens(tokens)) {
    final parsed = _parseOptionalColor(hex);
    if (parsed != null) picked.add(parsed);
  }
  final gradient = resolveBackgroundGradient(
    picked: picked,
    fallback: isLight
        ? ThemeColors.light.background
        : ThemeColors.dark.background,
    direction: gradientDirectionFromTokens(tokens),
    glowCount: gradientGlowCountFromTokens(tokens),
  );
  // 内置 / 用户自建的渐变色也按饱和度设置调整：纯色没有噪点顾虑，直接用
  // 滑条值（不打折），控件底色同样从调整后的中间色派生。
  final saturation = ref
      .watch(backgroundSaturationProvider)
      .clamp(0.0, 2.0)
      .toDouble();
  if (saturation == 1.0) return gradient;
  final colors = [
    for (final color in gradient.colors) applyBlurSaturation(color, saturation),
  ];
  return BackgroundGradient(
    colors: colors,
    mid: colors[1],
    direction: gradient.direction,
    glowCount: gradient.glowCount,
  );
});

/// 主界面是否正在用「照片 / 封面糊化」当背景。
///
/// 只有这时控件才需要切成半透明玻璃层：背景渐变模式、或者模糊模式但没选图
/// 也没封面（实际退回渐变）时，控件仍用原来的不透明派生色。
final blurGlassEnabledProvider = Provider<bool>((ref) {
  if (ref.watch(backgroundModeProvider) != BackgroundMode.blur) return false;
  // 用户选的模糊图：取到主色就说明这张照片正在铺在屏幕上。
  if (ref.watch(backgroundBlurTintProvider) != null) return true;
  // 「跟随封面」开着时，背景换成当前歌曲封面糊化。
  return ref.watch(coverBlurBackdropEnabledProvider) &&
      ref.watch(coverAccentColorProvider) != null;
});

/// 详情页顶栏（悬浮面板）的底色。
///
/// 取背景渐变**顶部**的颜色（也就是顶栏身后那一块的实际颜色）走一遍
/// [ThemeColors.copyWithBackground]，再取它的 `surface`：与卡片用的是同一套
/// 「只比背景亮一点点」的派生幅度，所以不管深浅主题、不管用户配了什么渐变，
/// 面板总比身后的背景略亮一档，配合细边框 + 阴影就是「浮在页面上」的效果。
///
/// 高斯模糊模式下改用 [blurGlassSurface]，和卡片、按钮是同一种半透明质感。
final detailHeaderSurfaceProvider = Provider<Color>((ref) {
  final base = ref.watch(baseThemeColorsProvider);
  final gradient = ref.watch(backgroundGradientProvider);
  final backdrop = gradient.colors.first;
  if (ref.watch(blurGlassEnabledProvider)) {
    return blurGlassSurface(
      backdrop,
      isLight: ref.watch(isLightThemeActiveProvider),
      step: 0.06,
    );
  }
  return base.copyWithBackground(backdrop).surface;
});

/// 歌单 / 榜单 / 作者 / 专辑详情页顶栏实际铺的那层半透明底色。
///
/// 顶栏贴着页面顶部，身后就是背景渐变的最上段：这里直接用那个颜色、只留
/// 很低的不透明度。渐变模式下和身后的背景几乎完全一致，模糊模式下也只是一
/// 层很淡的同色调薄纱 —— 上下连成一片，不会再出现「顶部贴了一条明显更亮的
/// 色块」的分界。
///
/// 不再沿用 [detailHeaderSurfaceProvider] 的 surface / 玻璃色：那一档是给
/// 卡片、按钮用的，比背景亮得更多，铺满整条顶栏时色差很明显。
final detailPageHeaderSurfaceProvider = Provider<Color>((ref) {
  final backdrop = ref.watch(backgroundGradientProvider).colors.first;
  final isLight = ref.watch(isLightThemeActiveProvider);
  // 只留一点点：模糊模式下照片的明暗会在顶栏与列表之间形成细微层次，
  // 但远看仍是同一片背景。
  return backdrop.withValues(alpha: isLight ? 0.20 : 0.24);
});

/// 底部迷你播放栏的底色。
///
/// 高斯模糊模式下控件统一是半透明玻璃，但迷你播放栏只有 56 高、歌名是
/// 13 号字，照片的纹理和明暗直接透上来会让文字发糊（Android 上尤其明显）。
/// 这里把同一档玻璃色提回接近实心：色调仍跟着背景走，只是不再透纹理。
/// 渐变模式下 [ThemeColors.surface] 本来就不透明，原样返回。
final miniPlayerSurfaceProvider = Provider<Color>((ref) {
  final surface = ref.watch(themeColorsProvider).surface;
  if (!ref.watch(blurGlassEnabledProvider)) return surface;
  return surface.withValues(alpha: 0.92);
});

/// 界面实际使用的主题色。
///
/// 用背景渐变的中间色走一遍 `copyWithBackground`：`surface` /
/// `surfaceVariant` / `divider` / `miniPlayerBackground` 跟着背景同一色调
/// 派生（侧栏、卡片、搜索框、底栏等所有控件），文字颜色保持用户设置不变，
/// 因此浅色主题仍是黑字、深色主题仍是浅字，对比度不会失控。
///
/// 高斯模糊模式下这里的「背景渐变」是照片主色派生的那条（见
/// [backgroundGradientProvider]），控件色调跟着照片走；并且会再换成半透明
/// 玻璃层，让照片的纹理透出来，而不是用一块实心色把照片盖住。弹框 / 底部
/// 弹层 / 弹出菜单 / SnackBar 例外，它们用 `dialogSurface` 保持实心。
final themeColorsProvider = Provider<ThemeColors>((ref) {
  final base = ref.watch(baseThemeColorsProvider);
  final mid = ref.watch(backgroundGradientProvider).mid;
  final derived = base.copyWithBackground(mid);
  if (!ref.watch(blurGlassEnabledProvider)) return derived;
  final isLight = ref.watch(isLightThemeActiveProvider);
  return derived.copyWithSurface(
    surface: blurGlassSurface(mid, isLight: isLight),
    surfaceVariant: blurGlassSurface(mid, isLight: isLight, step: 0.10),
  );
});
