import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';

/// Windows 上把系统标题栏（最顶上的窗口栏）涂成应用当前的主题背景色。
///
/// 用 DWM 的 `DwmSetWindowAttribute`：
///
/// | 属性 | 值 | 作用 | 支持的系统 |
/// |---|---|---|---|
/// | `DWMWA_USE_IMMERSIVE_DARK_MODE` | 20 | 让标题栏 / 按钮变深色或浅色 | Win10 19041+ |
/// | `DWMWA_BORDER_COLOR` | 34 | 窗口边框颜色 | Win11 22000+ |
/// | `DWMWA_CAPTION_COLOR` | 35 | 标题栏底色 | Win11 22000+ |
/// | `DWMWA_TEXT_COLOR` | 36 | 标题文字颜色 | Win11 22621+ |
///
/// **Windows 10 拿不到自定义颜色**：本机（Win10 LTSC 21H2 / 19044）实测
/// 20 返回 `S_OK`，34 / 35 / 36 都返回 `0x80070057`（参数无效）——这几个
/// 属性是 Windows 11 才加的，10 上只能选择「深色 / 浅色」两套系统配色
/// （深色标题栏是 `#202020`，和应用默认背景 `#212128` 肉眼几乎无差）。
/// 想要在 Win10 上做到和设置里完全同色，只能去掉系统标题栏、自己在 Flutter
/// 里画一条（含最小化 / 最大化 / 关闭与拖动），那是另一件事。
///
/// 所有调用失败都静默忽略，保证在任何系统上都不影响窗口本身。
class WindowTitleBar {
  WindowTitleBar._();

  // DWM 窗口属性编号（dwmapi.h）。
  static const int _attrUseImmersiveDarkMode = 20;
  static const int _attrBorderColor = 34;
  static const int _attrCaptionColor = 35;
  static const int _attrTextColor = 36;

  /// Flutter 默认 Windows runner 注册的窗口类名（见
  /// `windows/runner/win32_window.cpp`）。
  static const String _windowClassName = 'FLUTTER_RUNNER_WIN32_WINDOW';

  static bool _bound = false;
  static bool _failed = false;

  static int _hwnd = 0;
  static Color? _lastApplied;

  static int Function(int, int, Pointer<Void>, int)? _setWindowAttribute;
  static int Function(Pointer<Utf16>, Pointer<Utf16>)? _findWindow;
  static int Function(int, Pointer<Uint32>)? _getWindowThreadProcessId;

  /// 让标题栏跟随 [background]（一般直接传 `themeColors.background`）。
  ///
  /// 颜色没变化时直接返回；窗口还没创建出来时会保持 [_lastApplied] 为空，
  /// 下一次（主题变化或重建）再试。
  static void apply(Color background) {
    if (!Platform.isWindows || _failed) return;
    if (_lastApplied == background) return;

    _ensureBindings();
    if (!_bound) return;

    try {
      final hwnd = _windowHandle();
      if (hwnd == 0) return;

      final isDark = background.computeLuminance() < 0.5;
      final colorRef = _colorRef(background);
      // 一次性传 4 个属性；旧系统上不认识的编号会返回错误码，忽略即可。
      _setDword(hwnd, _attrUseImmersiveDarkMode, isDark ? 1 : 0);
      _setDword(hwnd, _attrCaptionColor, colorRef);
      _setDword(hwnd, _attrBorderColor, colorRef);
      // 标题文字：深色背景配白字，浅色背景配黑字（COLORREF）。
      _setDword(hwnd, _attrTextColor, isDark ? 0x00FFFFFF : 0x000000);
      _lastApplied = background;
    } catch (e) {
      debugPrint('[WindowTitleBar] 设置标题栏颜色失败: $e');
    }
  }

  static void _ensureBindings() {
    if (_bound || _failed) return;
    try {
      final dwmapi = DynamicLibrary.open('dwmapi.dll');
      _setWindowAttribute = dwmapi.lookupFunction<
        Int32 Function(IntPtr, Uint32, Pointer<Void>, Uint32),
        int Function(int, int, Pointer<Void>, int)
      >('DwmSetWindowAttribute');

      final user32 = DynamicLibrary.open('user32.dll');
      _findWindow = user32.lookupFunction<
        IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
        int Function(Pointer<Utf16>, Pointer<Utf16>)
      >('FindWindowW');
      _getWindowThreadProcessId = user32.lookupFunction<
        Uint32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)
      >('GetWindowThreadProcessId');

      _bound = true;
    } catch (e) {
      _failed = true;
      debugPrint('[WindowTitleBar] 加载 dwmapi / user32 失败: $e');
    }
  }

  /// 找到主窗口句柄（按窗口类名 + 进程 id 双重确认，避免误改其它 Flutter 程序）。
  static int _windowHandle() {
    if (_hwnd != 0) return _hwnd;
    final findWindow = _findWindow;
    final getWindowThreadProcessId = _getWindowThreadProcessId;
    if (findWindow == null || getWindowThreadProcessId == null) return 0;

    final className = _windowClassName.toNativeUtf16();
    try {
      final hwnd = findWindow(className, nullptr);
      if (hwnd == 0) return 0;
      final owner = calloc<Uint32>();
      try {
        getWindowThreadProcessId(hwnd, owner);
        if (owner.value != pid) return 0;
      } finally {
        calloc.free(owner);
      }
      _hwnd = hwnd;
      return hwnd;
    } finally {
      calloc.free(className);
    }
  }

  /// Flutter 的 `Color`（0xAARRGGBB）→ Win32 的 `COLORREF`（0x00BBGGRR）。
  static int _colorRef(Color color) {
    final r = (color.r * 255).round().clamp(0, 255);
    final g = (color.g * 255).round().clamp(0, 255);
    final b = (color.b * 255).round().clamp(0, 255);
    return (b << 16) | (g << 8) | r;
  }

  static void _setDword(int hwnd, int attribute, int value) {
    final setWindowAttribute = _setWindowAttribute;
    if (setWindowAttribute == null) return;
    final buffer = calloc<Uint32>();
    try {
      buffer.value = value;
      setWindowAttribute(hwnd, attribute, buffer.cast<Void>(), sizeOf<Uint32>());
    } finally {
      calloc.free(buffer);
    }
  }
}
