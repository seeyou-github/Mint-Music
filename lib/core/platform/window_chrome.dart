import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

// ── FFI 签名（native → dart） ─────────────────────────────────────────────
typedef _FindWindowWNative = IntPtr Function(Pointer<Utf16>, Pointer<Utf16>);
typedef _FindWindowWDart = int Function(Pointer<Utf16>, Pointer<Utf16>);
typedef _GetWindowThreadProcessIdNative =
    Uint32 Function(IntPtr, Pointer<Uint32>);
typedef _GetWindowThreadProcessIdDart = int Function(int, Pointer<Uint32>);
typedef _GetWindowLongPtrNative = IntPtr Function(IntPtr, Int32);
typedef _GetWindowLongPtrDart = int Function(int, int);
typedef _SetWindowLongPtrNative = IntPtr Function(IntPtr, Int32, IntPtr);
typedef _SetWindowLongPtrDart = int Function(int, int, int);
typedef _SetWindowPosNative =
    Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32);
typedef _SetWindowPosDart = int Function(int, int, int, int, int, int, int);
typedef _ShowWindowNative = Int32 Function(IntPtr, Int32);
typedef _ShowWindowDart = int Function(int, int);
typedef _PostMessageWNative = Int32 Function(IntPtr, Uint32, IntPtr, IntPtr);
typedef _PostMessageWDart = int Function(int, int, int, int);
typedef _SendMessageWNative = IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr);
typedef _SendMessageWDart = int Function(int, int, int, int);
typedef _IsZoomedNative = Int32 Function(IntPtr);
typedef _IsZoomedDart = int Function(int);
typedef _NoArgNative = Int32 Function();
typedef _NoArgDart = int Function();
typedef _DwmSetWindowAttributeNative =
    Int32 Function(IntPtr, Uint32, Pointer<Void>, Uint32);
typedef _DwmSetWindowAttributeDart = int Function(int, int, Pointer<Void>, int);

/// Windows 主窗口的「自绘标题栏」支撑。
///
/// 为什么不用系统标题栏：Windows 10（本机 19044）的 DWM 只认
/// `DWMWA_USE_IMMERSIVE_DARK_MODE`（深色标题栏固定是纯黑），
/// `DWMWA_CAPTION_COLOR` / `DWMWA_BORDER_COLOR` 是 Windows 11 才加的属性，
/// 在 Win10 上调用直接返回 `E_INVALIDARG`，所以**系统标题栏的颜色在 Win10 上
/// 改不了**。想让「最顶上的窗口栏」和设置里的「背景颜色」一致，只能把系统
/// 标题栏去掉，由 Flutter 自己画一条（PiliPlus 也是这个路子）。
///
/// 这里只做窗口层面的脏活，画界面的是 `lib/app/windows_title_bar.dart`：
///
/// - [enableCustomTitleBar]：去掉 `WS_CAPTION`，但**保留** `WS_THICKFRAME`
///   （边框可拖动缩放）、`WS_SYSMENU` / `WS_MINIMIZEBOX` / `WS_MAXIMIZEBOX`
///   （Alt+F4、任务栏右键菜单、Aero Snap 都照常），客户端区域顶到窗口最上边；
///   配合原生侧 `windows/runner/win32_window.cpp`：
///   - `WM_GETMINMAXINFO`：把最大化尺寸限制到显示器工作区，否则无标题栏窗口
///     最大化会铺满整块屏幕、盖住任务栏；
///   - `WM_NCCALCSIZE`：客户区铺满整个窗口，否则 `WS_THICKFRAME` 的缩放边框
///     会在标题栏上方留一条没人绘制的黑边；
///   - `WM_NCHITTEST` + Flutter 视图的边缘让位：把边角缩放区域还给系统；
///   - `WM_NCACTIVATE` / `WM_NCPAINT`：窗口失焦 / 重新获得焦点时，系统会按默认
///     样式把非客户区整块重画回来（四周冒出一圈老式 Windows 边框），必须拦掉；
/// - [startDrag] / [minimize] / [toggleMaximize] / [close]：给自绘按钮和
///   拖动区域用；
/// - [setDarkFrame]：深色背景时把窗口边框压暗，别在深色界面外面留一圈亮边；
/// - [disableTransitions]：关掉最大化 / 还原的 DWM 过渡动画。无边框窗口做这个
///   动画时缩放的是整块界面位图，中间帧比例对不上，看起来就是界面抖动。
///
/// 所有调用失败都静默忽略（拿不到句柄、找不到函数都只是「不生效」），
/// 保证不影响窗口本身。
class WindowChrome {
  WindowChrome._();

  // 窗口样式位（winuser.h）。
  static const int _gwlStyle = -16;
  static const int _wsCaption = 0x00C00000;
  static const int _wsThickFrame = 0x00040000;
  static const int _wsSysMenu = 0x00080000;
  static const int _wsMinimizeBox = 0x00020000;
  static const int _wsMaximizeBox = 0x00010000;

  static const int _swpNoSize = 0x0001;
  static const int _swpNoMove = 0x0002;
  static const int _swpNoZOrder = 0x0004;
  static const int _swpNoActivate = 0x0010;
  static const int _swpFrameChanged = 0x0020;

  static const int _swMinimize = 6;
  static const int _swMaximize = 3;
  static const int _swRestore = 9;

  static const int _wmClose = 0x0010;
  static const int _wmNcLButtonDown = 0x00A1;
  static const int _htCaption = 2;

  /// DWM：深色窗口装饰（Win10 1809+）。去掉标题栏后它只影响边框 / 阴影的颜色。
  static const int _attrUseImmersiveDarkMode = 20;

  /// Flutter 默认 Windows runner 注册的窗口类名（见
  /// `windows/runner/win32_window.cpp`）。
  static const String _windowClassName = 'FLUTTER_RUNNER_WIN32_WINDOW';

  static bool _bound = false;
  static bool _failed = false;
  static bool _customTitleBarEnabled = false;
  static int _hwnd = 0;
  static bool? _lastDarkFrame;

  static _FindWindowWDart? _findWindow;
  static _GetWindowThreadProcessIdDart? _getWindowThreadProcessId;
  static _GetWindowLongPtrDart? _getWindowLong;
  static _SetWindowLongPtrDart? _setWindowLong;
  static _SetWindowPosDart? _setWindowPos;
  static _ShowWindowDart? _showWindow;
  static _PostMessageWDart? _postMessage;
  static _SendMessageWDart? _sendMessage;
  static _IsZoomedDart? _isZoomed;
  static _NoArgDart? _releaseCapture;
  static _DwmSetWindowAttributeDart? _setWindowAttribute;

  /// 当前平台是否支持（只有 Windows 走这套）。
  static bool get isSupported => Platform.isWindows;

  /// 系统标题栏是否已经成功去掉（成功后才该插入自绘标题栏）。
  ///
  /// 万一改样式失败（例如没拿到窗口句柄），界面就不插自绘栏，退回系统标题栏的
  /// 老样子，不会出现「两个标题栏」。
  static bool get hasCustomTitleBar => _customTitleBarEnabled;

  /// 去掉系统标题栏，把「最顶上的窗口栏」交给 Flutter 自绘。
  ///
  /// 只在 Windows 上生效；重复调用是安全的（样式已经改过就直接返回）。
  static void enableCustomTitleBar() {
    if (!isSupported || _failed) return;
    _ensureBindings();
    final hwnd = _windowHandle();
    if (hwnd == 0) return;

    final getWindowLong = _getWindowLong;
    final setWindowLong = _setWindowLong;
    if (getWindowLong == null || setWindowLong == null) return;

    // 样式是 32 位值，先截断成无符号再算，避免 Dart 大整数带来的高位噪声。
    final style = getWindowLong(hwnd, _gwlStyle) & 0xFFFFFFFF;
    final newStyle =
        (style & ~_wsCaption) |
        _wsThickFrame |
        _wsSysMenu |
        _wsMinimizeBox |
        _wsMaximizeBox;
    if (newStyle == style) {
      // 已经是无标题栏形态（重复调用）。
      _customTitleBarEnabled = true;
      disableTransitions();
      return;
    }

    setWindowLong(hwnd, _gwlStyle, newStyle);
    // SWP_FRAMECHANGED 让系统按新样式重算非客户区，客户端区域随即顶到最上边。
    _setWindowPos?.call(
      hwnd,
      0,
      0,
      0,
      0,
      0,
      _swpNoMove |
          _swpNoSize |
          _swpNoZOrder |
          _swpNoActivate |
          _swpFrameChanged,
    );
    _customTitleBarEnabled = true;
    // 无边框窗口的最大化 / 还原动画会把整块客户区位图缩放平移，看起来像
    // 界面在抖，直接关掉（见 [disableTransitions]）。
    disableTransitions();
  }

  /// `DWMWA_TRANSITIONS_FORCEDISABLED`：关掉窗口过渡动画。
  static const int _attrTransitionsForceDisabled = 3;

  /// 关掉最大化 / 还原 / 最小化的 DWM 过渡动画。
  ///
  /// 有标题栏的窗口做最大化动画时，DWM 缩放的是「边框 + 标题栏 + 客户区
  /// 位图」，客户区占的比例小、内容也是旧的，所以看不出问题。
  ///
  /// 去掉 `WS_CAPTION` 之后客户区铺满整个窗口，DWM 缩放的就变成了**整块界面
  /// 位图**：它把「已经按最终尺寸 1827×1080 重排好的新内容」缩到旧窗口大小、
  /// 再平滑放大回去。中间那些帧里内容比例和窗口比例对不上，视觉上就是
  /// 界面控件先碎一下、左右错位、快速放大缩小，最后才「啪」地到位 —— 也就是
  /// 用户看到的「最大化 / 最小化过程中抖动」。
  ///
  /// 这里把过渡动画关掉：最大化 / 还原瞬间完成，不再有中间帧。
  /// 老系统（Win7 之前）不支持这个属性，调用失败只当作没生效。
  static void disableTransitions() {
    if (!isSupported || _failed) return;
    _ensureBindings();
    final hwnd = _windowHandle();
    if (hwnd == 0) return;
    final setWindowAttribute = _setWindowAttribute;
    if (setWindowAttribute == null) return;

    final buffer = calloc<Int32>();
    try {
      buffer.value = 1;
      setWindowAttribute(
        hwnd,
        _attrTransitionsForceDisabled,
        buffer.cast<Void>(),
        sizeOf<Int32>(),
      );
    } finally {
      calloc.free(buffer);
    }
  }

  /// 窗口边框 / 阴影跟随深浅色（[dark] 为 true 时用深色边框）。
  static void setDarkFrame(bool dark) {
    if (!isSupported || _failed) return;
    if (_lastDarkFrame == dark) return;
    _ensureBindings();
    final hwnd = _windowHandle();
    if (hwnd == 0) return;
    final setWindowAttribute = _setWindowAttribute;
    if (setWindowAttribute == null) return;

    final buffer = calloc<Int32>();
    try {
      buffer.value = dark ? 1 : 0;
      setWindowAttribute(
        hwnd,
        _attrUseImmersiveDarkMode,
        buffer.cast<Void>(),
        sizeOf<Int32>(),
      );
      _lastDarkFrame = dark;
    } finally {
      calloc.free(buffer);
    }
  }

  /// 开始拖动窗口（在自绘标题栏上按下时调用）。
  ///
  /// 走系统的「非客户区拖动」流程，Aero Snap（拖到屏幕边缘吸附 / 顶边上滑）
  /// 和拖动已最大化窗口时的「先还原再拖」都由系统处理，不用自己算。
  /// 注意：`SendMessage` 会一直阻塞到这次拖动结束，期间由系统消息循环接管，
  /// 与 window_manager 的 `startDragging()` 行为一致。
  static void startDrag() {
    if (!isSupported || _failed) return;
    final hwnd = _windowHandle();
    if (hwnd == 0) return;
    _releaseCapture?.call();
    _sendMessage?.call(hwnd, _wmNcLButtonDown, _htCaption, 0);
  }

  static void minimize() {
    if (!isSupported || _failed) return;
    final hwnd = _windowHandle();
    if (hwnd == 0) return;
    _showWindow?.call(hwnd, _swMinimize);
  }

  /// 最大化 / 还原 切换。
  static void toggleMaximize() {
    if (!isSupported || _failed) return;
    final hwnd = _windowHandle();
    if (hwnd == 0) return;
    _showWindow?.call(hwnd, isMaximized ? _swRestore : _swMaximize);
  }

  /// 窗口当前是否最大化（用来切换自绘按钮的图标）。
  static bool get isMaximized {
    if (!isSupported || _failed) return false;
    final hwnd = _windowHandle();
    if (hwnd == 0) return false;
    final isZoomed = _isZoomed;
    if (isZoomed == null) return false;
    return isZoomed(hwnd) != 0;
  }

  static void close() {
    if (!isSupported || _failed) return;
    final hwnd = _windowHandle();
    if (hwnd == 0) return;
    // PostMessage 而不是 SendMessage：让关闭流程（含窗口状态保存）正常走完，
    // 也不会在 Dart 侧阻塞。
    _postMessage?.call(hwnd, _wmClose, 0, 0);
  }

  static void _ensureBindings() {
    if (_bound || _failed) return;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      _findWindow = user32.lookupFunction<_FindWindowWNative, _FindWindowWDart>(
        'FindWindowW',
      );
      _getWindowThreadProcessId = user32
          .lookupFunction<
            _GetWindowThreadProcessIdNative,
            _GetWindowThreadProcessIdDart
          >('GetWindowThreadProcessId');
      _getWindowLong = user32
          .lookupFunction<_GetWindowLongPtrNative, _GetWindowLongPtrDart>(
            'GetWindowLongPtrW',
          );
      _setWindowLong = user32
          .lookupFunction<_SetWindowLongPtrNative, _SetWindowLongPtrDart>(
            'SetWindowLongPtrW',
          );
      _setWindowPos = user32
          .lookupFunction<_SetWindowPosNative, _SetWindowPosDart>(
            'SetWindowPos',
          );
      _showWindow = user32.lookupFunction<_ShowWindowNative, _ShowWindowDart>(
        'ShowWindow',
      );
      _postMessage = user32
          .lookupFunction<_PostMessageWNative, _PostMessageWDart>(
            'PostMessageW',
          );
      _sendMessage = user32
          .lookupFunction<_SendMessageWNative, _SendMessageWDart>(
            'SendMessageW',
          );
      _isZoomed = user32.lookupFunction<_IsZoomedNative, _IsZoomedDart>(
        'IsZoomed',
      );
      _releaseCapture = user32.lookupFunction<_NoArgNative, _NoArgDart>(
        'ReleaseCapture',
      );
      _bound = true;
    } catch (e) {
      _failed = true;
      debugPrint('[WindowChrome] 加载 user32 失败: $e');
      return;
    }

    // dwmapi 只是锦上添花（边框配色），加载失败不影响自绘标题栏。
    try {
      final dwmapi = DynamicLibrary.open('dwmapi.dll');
      _setWindowAttribute = dwmapi
          .lookupFunction<
            _DwmSetWindowAttributeNative,
            _DwmSetWindowAttributeDart
          >('DwmSetWindowAttribute');
    } catch (e) {
      debugPrint('[WindowChrome] 加载 dwmapi 失败（边框配色不可用）: $e');
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
}
