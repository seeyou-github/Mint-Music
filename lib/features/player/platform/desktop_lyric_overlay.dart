import 'dart:io';

import 'package:flutter/services.dart';

import '../../../features/player/domain/models/desktop_lyric_settings.dart';
import '../domain/models/lyric_line.dart';

/// Android / Windows 系统级悬浮歌词窗的通道封装。
///
/// Android 原生实现见
/// `android/app/src/main/kotlin/.../DesktopLyricOverlayHandler.kt`,
/// 其设计参考 lx-music-mobile 的 `LyricView.java`。
///
/// Windows 原生实现见 `windows/runner/desktop_lyric_window.cpp`：
/// 一个独立的顶层窗口（无边框、背景透明、可置顶），不依赖 Flutter 视图，
/// 因此应用最小化后依然显示在桌面上。
class DesktopLyricOverlay {
  DesktopLyricOverlay._();

  static final DesktopLyricOverlay instance = DesktopLyricOverlay._();

  static const MethodChannel _channel = MethodChannel(
    'com.mintmusic/desktop_lyric',
  );

  /// 悬浮窗只在 Android / Windows 上可用,其它平台回退到应用内悬浮层。
  bool get supported => Platform.isAndroid || Platform.isWindows;

  /// 是否为 Windows（原生实现是独立桌面窗口,行为与 Android 悬浮窗不同）。
  bool get isWindows => Platform.isWindows;

  /// 监听原生侧拖动结束后回传的位置(屏幕百分比)。
  void setPositionListener(void Function(double x, double y)? onChanged) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onPositionChanged' && onChanged != null) {
        final args = call.arguments;
        if (args is Map) {
          onChanged(
            (args['x'] as num?)?.toDouble() ?? 0,
            (args['y'] as num?)?.toDouble() ?? 0,
          );
        }
      }
      return null;
    });
  }

  Future<bool> checkPermission() async {
    if (!supported) return false;
    // Windows 的独立顶层窗口不需要额外授权。
    if (isWindows) return true;
    try {
      return await _channel.invokeMethod<bool>('checkPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 跳转到系统「在其他应用上层显示」授权页。
  Future<void> openPermissionSettings() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('openPermissionSettings');
    } on PlatformException {
      // 忽略:用户可在系统设置里手动授权。
    } on MissingPluginException {
      // 忽略
    }
  }

  Future<bool> isShowing() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('isShowing') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 创建并显示悬浮窗。未授权时返回 false。
  Future<bool> show() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('show') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> hide() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('hide');
    } on PlatformException {
      // 忽略
    } on MissingPluginException {
      // 忽略
    }
  }

  Future<void> updateConfig(
    DesktopLyricSettings settings, {
    String? fontFamily,
    String? fontPath,
  }) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('updateConfig', {
        'isLock': settings.isLock,
        'maxLineNum': settings.maxLineNum,
        'fontSize': settings.fontSize,
        'opacityPercent': settings.opacityPercent,
        'playedColor': settings.playedColor,
        'unplayColor': settings.unplayColor,
        'shadowColor': settings.shadowColor,
        'positionX': settings.positionX,
        'positionY': settings.positionY,
        // 应用字体（设置 - 外观设置 - 应用字体）
        if (fontFamily != null) 'fontFamily': fontFamily,
        if (fontPath != null) 'fontPath': fontPath,
      });
    } on PlatformException {
      // 忽略
    } on MissingPluginException {
      // 忽略
    }
  }

  Future<void> updateLyric({
    required List<LyricLine> lines,
    required int activeIndex,
    required bool showTranslation,
    required bool showRoman,
  }) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('updateLyric', {
        // 带上行起始时间:原生侧据此自行推进当前行,
        // 应用退到后台后也能保持实时(不依赖 Dart 的进度回调)。
        'lines': lines
            .map(
              (line) => {
                'time': line.startTimeMs,
                'text': line.plainText.trim(),
                'translation': line.translatedLyric?.trim(),
                'roman': line.romanLyric?.trim(),
              },
            )
            .toList(growable: false),
        'activeIndex': activeIndex,
        'showTranslation': showTranslation,
        'showRoman': showRoman,
      });
    } on PlatformException {
      // 忽略
    } on MissingPluginException {
      // 忽略
    }
  }

  /// 下发进度锚点:原生侧据此用单调时钟自行推进歌词行。
  ///
  /// 行号由原生侧自行计算并按到下一行的精确剩余时间调度,Dart 侧不再推送
  /// 行号(见 [desktopLyricSyncProvider] 里的说明)。
  Future<void> setPlayState({
    required int positionMs,
    required bool isPlaying,
  }) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('setPlayState', {
        'positionMs': positionMs,
        'isPlaying': isPlaying,
      });
    } on PlatformException {
      // 忽略
    } on MissingPluginException {
      // 忽略
    }
  }
}
