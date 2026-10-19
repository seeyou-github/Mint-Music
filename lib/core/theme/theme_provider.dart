import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'theme_colors.dart';

export 'theme_colors.dart';

/// 应用主题模式：浅色 / 深色 / 跟随系统。
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);

final themePrimaryColorProvider = StateProvider<String>((ref) => '#1DB954');

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

final _cachedLightColors = <String, ThemeColors>{};
final _cachedDarkColors = <String, ThemeColors>{};

final themeColorsProvider = Provider<ThemeColors>((ref) {
  final themeMode = ref.watch(themeModeProvider);
  final primaryHex = ref.watch(themePrimaryColorProvider);
  final platformBrightness = ref.watch(platformBrightnessProvider);
  final isLight = isThemeModeLight(themeMode, platformBrightness);
  final cache = isLight ? _cachedLightColors : _cachedDarkColors;
  return cache.putIfAbsent(primaryHex, () {
    final primaryColor = _parseThemeColor(primaryHex);
    return isLight
        ? ThemeColors.lightWithPrimary(primaryColor)
        : ThemeColors.darkWithPrimary(primaryColor);
  });
});
