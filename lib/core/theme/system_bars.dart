import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 系统状态栏 / 导航栏的样式。
///
/// ## 为什么状态栏会比界面「更深一层」
///
/// 应用是沉浸式的：Flutter 画布铺满整屏，状态栏区域露出的是页面自己的背景
/// （发现页是 `colors.background`，歌单详情页是封面渐变的顶部）。
///
/// 但从 Android 10（API 29）起，`Window` 有一个默认开启的「对比度保护」
/// （`setStatusBarContrastEnforced`）：**当状态栏颜色是透明时，系统会自己
/// 盖一层半透明黑（scrim）**，以保证白色图标看得清。于是同一个背景色在
/// 状态栏里会暗一截，看起来像多了一层灰。
///
/// Android 15（API 35）更是把 `setStatusBarColor` 变成了空操作，状态栏固定
/// 透明 —— 也就是说系统一定会自己画那层 scrim，应用完全管不到，除非显式把
/// 对比度保护关掉（[SystemUiOverlayStyle.systemStatusBarContrastEnforced]）。
///
/// 这里统一关掉它，并把状态栏颜色显式设为透明：
/// * API 29+：不再叠加 scrim，状态栏和页面背景同色同亮度；
/// * API 29 以下：状态栏从主题里的默认黑色改成透明，同样与页面同色。
///
/// 图标明暗仍按当前外观切换（深色外观用浅色图标），因此关掉 scrim 也不会
/// 出现「白图标看不见」的情况。
class SystemBars {
  const SystemBars._();

  /// 当前外观下应该使用的系统栏样式。
  ///
  /// [light] 表示当前是浅色外观（浅背景 + 深色文字）。
  static SystemUiOverlayStyle overlayStyle({required bool light}) {
    return SystemUiOverlayStyle(
      // 完全透明：状态栏区域直接露出页面背景。
      statusBarColor: Colors.transparent,
      // 关键：关掉系统给透明状态栏叠的半透明黑遮罩。
      systemStatusBarContrastEnforced: false,
      // Android：状态栏图标明暗。浅色外观用深色图标。
      statusBarIconBrightness: light ? Brightness.dark : Brightness.light,
      // iOS：状态栏文字明暗（Android 忽略）。
      statusBarBrightness: light ? Brightness.light : Brightness.dark,
    );
  }

  /// 立即应用一次（首帧之前用，避免启动瞬间还是系统默认的黑色状态栏）。
  static void apply({required bool light}) {
    SystemChrome.setSystemUIOverlayStyle(overlayStyle(light: light));
  }
}
