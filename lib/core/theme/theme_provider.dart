import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'theme_colors.dart';

export 'theme_colors.dart';

/// 应用主题模式：浅色 / 深色 / 跟随系统。
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);

final themePrimaryColorProvider = StateProvider<String>((ref) => '#1DB954');

/// 深色模式「字体颜色」的默认值（暖调米黄色）。
const String defaultThemeFontColor = '#D9C8B1';

/// 浅色模式「字体颜色」「第二字体颜色」的默认值。
const String defaultLightFontColor = '#000000';
const String defaultLightSecondaryFontColor = '#111111';

/// 浅色 / 深色模式「背景颜色」的默认值（与 [ThemeColors] 的默认背景一致）。
const String defaultLightBackgroundColor = '#DCD7C9';
const String defaultDarkBackgroundColor = '#212128';

/// 深色模式「字体颜色」：主文字颜色（十六进制），为空表示使用主题默认色。
final darkThemeFontColorProvider = StateProvider<String>(
  (ref) => defaultThemeFontColor,
);

/// 浅色模式「字体颜色」：主文字颜色（十六进制），为空表示使用主题默认色。
final lightThemeFontColorProvider = StateProvider<String>(
  (ref) => defaultLightFontColor,
);

/// 深色模式「第二字体颜色」：次级文字颜色（十六进制），为空表示使用主题默认色。
final darkThemeSecondaryFontColorProvider = StateProvider<String>((ref) => '');

/// 浅色模式「第二字体颜色」：次级文字颜色（十六进制），为空表示使用主题默认色。
final lightThemeSecondaryFontColorProvider = StateProvider<String>(
  (ref) => defaultLightSecondaryFontColor,
);

/// 深色模式「背景颜色」：十六进制，为空表示使用主题默认背景。
final darkThemeBackgroundColorProvider = StateProvider<String>(
  (ref) => defaultDarkBackgroundColor,
);

/// 浅色模式「背景颜色」：十六进制，为空表示使用主题默认背景。
final lightThemeBackgroundColorProvider = StateProvider<String>(
  (ref) => defaultLightBackgroundColor,
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

final themeColorsProvider = Provider<ThemeColors>((ref) {
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
  final backgroundHex = ref.watch(
    isLight
        ? lightThemeBackgroundColorProvider
        : darkThemeBackgroundColorProvider,
  );
  final cache = isLight ? _cachedLightColors : _cachedDarkColors;
  final key = '$primaryHex|$fontHex|$secondaryHex|$backgroundHex';
  return cache.putIfAbsent(key, () {
    final primaryColor = _parseThemeColor(primaryHex);
    final base = isLight
        ? ThemeColors.lightWithPrimary(primaryColor)
        : ThemeColors.darkWithPrimary(primaryColor);
    return base
        .copyWithTextColors(
          textPrimary: _parseOptionalColor(fontHex),
          textSecondary: _parseOptionalColor(secondaryHex),
        )
        .copyWithBackground(_parseOptionalColor(backgroundHex));
  });
});
