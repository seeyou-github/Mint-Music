import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'theme_colors.dart';

export 'theme_colors.dart';

/// 应用主题模式：浅色 / 深色 / 跟随系统。
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);

final themePrimaryColorProvider = StateProvider<String>((ref) => '#1DB954');

/// 「字体颜色」：主文字颜色（十六进制），为空表示使用主题默认色。
final themeFontColorProvider = StateProvider<String>((ref) => '');

/// 「第二字体颜色」：次级文字颜色（十六进制），为空表示使用主题默认色。
final themeSecondaryFontColorProvider = StateProvider<String>((ref) => '');

/// 系统当前的亮/暗偏好。
///
/// [ThemeMode.system] 下由它决定实际使用亮色还是暗色主题。初始值取自
/// [PlatformDispatcher]；运行期间由 App 的 `WidgetsBindingObserver` 在
/// `didChangePlatformBrightness` 中更新（见 `app.dart`），因此系统切换
/// 亮/暗时界面会实时跟随，无需重启。
final platformBrightnessProvider = StateProvider<Brightness>(
  (ref) => PlatformDispatcher.instance.platformBrightness,
);

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

final _cachedLightColors = <String, ThemeColors>{};
final _cachedDarkColors = <String, ThemeColors>{};

final themeColorsProvider = Provider<ThemeColors>((ref) {
  final themeMode = ref.watch(themeModeProvider);
  final primaryHex = ref.watch(themePrimaryColorProvider);
  final fontHex = ref.watch(themeFontColorProvider);
  final secondaryHex = ref.watch(themeSecondaryFontColorProvider);
  final platformBrightness = ref.watch(platformBrightnessProvider);
  final isLight = isThemeModeLight(themeMode, platformBrightness);
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
