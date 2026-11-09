import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'background_gradient.dart';
import 'background_derivation.dart';
import 'theme_colors.dart';

export 'theme_colors.dart';

/// 应用主题模式：浅色 / 深色 / 跟随系统。
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);

final themePrimaryColorProvider = StateProvider<String>((ref) => '#1DB954');

/// 深色模式「字体颜色」的默认值（暖调黄）。
const String defaultThemeFontColor = '#DACB77';

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
    return const Color(0xFF1DB954);
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
final coverBackgroundEnabledProvider = StateProvider<bool>((ref) => true);

/// 当前封面主色。
///
/// core 层不该直接依赖播放器的取色器（那是 features 层），所以由 app 层在
/// `currentCoverColorProvider` 出结果时把颜色写进来，这里只负责存。
final coverAccentColorProvider = StateProvider<Color?>((ref) => null);

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
  // 「跟随封面变色」只在深色主题生效：拿到封面主色就直接走派生算法，
  // 和播放详情页 / 歌词页背景是同一个函数，两处观感一致。
  if (!isLight && ref.watch(coverBackgroundEnabledProvider)) {
    final accent = ref.watch(coverAccentColorProvider);
    if (accent != null) {
      final colors = deriveBackgroundGradient(accent, isLight: false);
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
  return resolveBackgroundGradient(
    picked: picked,
    fallback: isLight
        ? ThemeColors.light.background
        : ThemeColors.dark.background,
    direction: gradientDirectionFromTokens(tokens),
    glowCount: gradientGlowCountFromTokens(tokens),
  );
});

/// 详情页顶栏（悬浮面板）的底色。
///
/// 取背景渐变**顶部**的颜色（也就是顶栏身后那一块的实际颜色）走一遍
/// [ThemeColors.copyWithBackground]，再取它的 `surface`：与卡片用的是同一套
/// 「只比背景亮一点点」的派生幅度，所以不管深浅主题、不管用户配了什么渐变，
/// 面板总比身后的背景略亮一档，配合细边框 + 阴影就是「浮在页面上」的效果。
final detailHeaderSurfaceProvider = Provider<Color>((ref) {
  final base = ref.watch(baseThemeColorsProvider);
  final gradient = ref.watch(backgroundGradientProvider);
  return base.copyWithBackground(gradient.colors.first).surface;
});

/// 界面实际使用的主题色。
///
/// 用背景渐变的中间色走一遍 `copyWithBackground`：`surface` /
/// `surfaceVariant` / `divider` / `miniPlayerBackground` 跟着背景同一色调
/// 派生（侧栏、卡片、搜索框、底栏等所有控件），文字颜色保持用户设置不变，
/// 因此浅色主题仍是黑字、深色主题仍是浅字，对比度不会失控。
final themeColorsProvider = Provider<ThemeColors>((ref) {
  final base = ref.watch(baseThemeColorsProvider);
  return base.copyWithBackground(ref.watch(backgroundGradientProvider).mid);
});
