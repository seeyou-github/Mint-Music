#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>

#include "resource.h"
#include "window_state.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// 窗口是否处于「自绘标题栏」模式（Dart 侧的 WindowChrome 会把 WS_CAPTION
// 去掉，把最顶上那条窗口栏交给 Flutter 画）。
//
// 下面几处（WM_NCCALCSIZE / WM_NCHITTEST / Flutter 视图的边缘让位）只在去掉
// WS_CAPTION 之后才改变默认行为，所以直接用样式位判断，不需要 Dart 再单独
// 通知原生一次；Dart 侧一旦把标题栏改回系统样式，这里也立刻退回默认处理。
bool HasCustomTitleBar(HWND window) {
  return (::GetWindowLongPtr(window, GWL_STYLE) & WS_CAPTION) == 0;
}

/// 自绘标题栏模式下窗口边缘的可缩放区域（逻辑像素）。
///
/// 客户区铺满整个窗口之后，系统原本那圈「缩放边框」没有了，只能由
/// [Win32Window::MessageHandler] 的 WM_NCHITTEST 自己给回来；顶部窄一点，
/// 免得吃掉自绘标题栏上那几个窗口按钮的点击。
constexpr int kResizeBorderDip = 6;
constexpr int kResizeBorderTopDip = 4;

/// Flutter 视图子窗口被改动前的消息过程，子类化之后要转发给它。
WNDPROC g_child_content_proc = nullptr;

/// 已经挂上钩子的子窗口（Flutter 若换了新的视图窗口就重新挂）。
HWND g_hooked_child = nullptr;

/// 判断某个屏幕坐标是否落在窗口边缘那一圈里。
bool IsOnResizeBorder(HWND parent, int x, int y) {
  RECT window_rect{};
  if (!::GetWindowRect(parent, &window_rect)) {
    return false;
  }
  const double scale = WindowState::GetScaleFactor(parent);
  const int border = Scale(kResizeBorderDip, scale);
  const int top = Scale(kResizeBorderTopDip, scale);
  return x < window_rect.left + border || x >= window_rect.right - border ||
         y < window_rect.top + top || y >= window_rect.bottom - border;
}

/// Flutter 视图子窗口的消息过程（替代原来的，其它消息原样转发）。
///
/// 自绘标题栏模式下客户区铺满了整个窗口，鼠标落在窗口任何位置都会被这个
/// 子窗口接住，父窗口的 WM_NCHITTEST 永远轮不到，缩放边框也就没了。这里在
/// 靠近窗口边缘时返回 HTTRANSPARENT —— 系统会带着同一个点去问下面的父窗口，
/// 由父窗口回一个 HTLEFT / HTTOP 之类的缩放命中，缩放因此仍然是系统原生行为
/// （跟手、有系统提示、不阻塞 Dart）。
LRESULT CALLBACK ChildContentProc(HWND hwnd,
                                  UINT const message,
                                  WPARAM const wparam,
                                  LPARAM const lparam) {
  if (message == WM_NCHITTEST) {
    const HWND parent = ::GetParent(hwnd);
    if (parent != nullptr && HasCustomTitleBar(parent) &&
        !::IsZoomed(parent) && !::IsIconic(parent)) {
      const int x = static_cast<short>(LOWORD(lparam));
      const int y = static_cast<short>(HIWORD(lparam));
      if (IsOnResizeBorder(parent, x, y)) {
        return HTTRANSPARENT;
      }
    }
  }
  if (g_child_content_proc == nullptr) {
    return ::DefWindowProc(hwnd, message, wparam, lparam);
  }
  return ::CallWindowProc(g_child_content_proc, hwnd, message, wparam, lparam);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

// Applies the application icon to the window.
//
// The taskbar button icon, the caption icon on the left of the title bar and
// the process icon shown in the task manager are all taken from the window
// icon, so it has to be set explicitly with the icon resource shipped in
// `resources/app_icon.ico`.
void ApplyWindowIcon(HWND window) {
  const HINSTANCE instance = ::GetModuleHandle(nullptr);
  if (instance == nullptr) {
    return;
  }

  HICON big_icon = static_cast<HICON>(::LoadImageW(
      instance, MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON, 0, 0,
      LR_DEFAULTSIZE));
  if (big_icon != nullptr) {
    ::SendMessage(window, WM_SETICON, ICON_BIG,
                  reinterpret_cast<LPARAM>(big_icon));
  }

  HICON small_icon = static_cast<HICON>(::LoadImageW(
      instance, MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      ::GetSystemMetrics(SM_CXSMICON), ::GetSystemMetrics(SM_CYSMICON), 0));
  if (small_icon != nullptr) {
    ::SendMessage(window, WM_SETICON, ICON_SMALL,
                  reinterpret_cast<LPARAM>(small_icon));
  }
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);
  ApplyWindowIcon(window);

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_GETMINMAXINFO: {
      // 自绘标题栏窗口（去掉 WS_CAPTION、保留 WS_THICKFRAME）最大化时，系统
      // 会把窗口矩形铺满整块显示器（实测 1920×1080 屏上是 (-8,-8)-(1928,1088)），
      // 连带把任务栏那一条也盖进窗口里。而下面 WM_NCCALCSIZE 又把客户区对齐
      // 到工作区，多出来的那条就变成「没人绘制的非客户区」——窗口类没设背景
      // 画刷，DWM 直接呈现成纯黑，和深色任务栏一个颜色，看上去像任务栏还在，
      // 实际已经点不动了（任务栏在右侧时尤其明显，左边也会露出黑边）。
      //
      // 把最大化的尺寸 / 位置直接限制到显示器工作区，窗口矩形就不会越过
      // 任务栏；任务栏在上下左右哪个方向都适用，多显示器按窗口所在屏计算。
      MINMAXINFO* min_max_info = reinterpret_cast<MINMAXINFO*>(lparam);
      MONITORINFO monitor_info{};
      monitor_info.cbSize = sizeof(monitor_info);
      if (::GetMonitorInfo(
              ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
              &monitor_info)) {
        min_max_info->ptMaxSize.x =
            monitor_info.rcWork.right - monitor_info.rcWork.left;
        min_max_info->ptMaxSize.y =
            monitor_info.rcWork.bottom - monitor_info.rcWork.top;
        // ptMaxPosition 是相对本显示器左上角的偏移，副屏上同样成立。
        min_max_info->ptMaxPosition.x =
            monitor_info.rcWork.left - monitor_info.rcMonitor.left;
        min_max_info->ptMaxPosition.y =
            monitor_info.rcWork.top - monitor_info.rcMonitor.top;
      }
      return 0;
    }

    case WM_NCCALCSIZE: {
      // 自绘标题栏模式下不要任何非客户区：留着的话 WS_THICKFRAME 的缩放边框
      // 会占掉窗口顶部几个像素，而那一条既没有人绘制（窗口类没设背景画刷，
      // Flutter 的视图只覆盖客户区），看起来就是标题栏上方的一条黑线。
      // 返回 0 表示「客户区 = 整个窗口」。
      if (wparam != TRUE || !HasCustomTitleBar(hwnd)) {
        break;
      }
      auto params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
      // 最大化时窗口矩形已经由 WM_GETMINMAXINFO 限制到工作区，但系统在这里
      // 给的建议矩形仍会向外扩一圈边框（约 8px），要裁到工作区才不会让内容
      // 被屏幕边缘切掉。
      //
      // 关键是**求交集，而不是直接赋成工作区**：最大化 / 还原的过渡帧里窗口
      // 矩形还在动画中间、比工作区小，直接赋值会把客户区瞬间拉到最终尺寸，
      // Flutter 视图跟着放大又缩小，看起来就是「窗口抖动、快速增大减小」。
      // 求交集时过渡帧原样不动，只有真正超出工作区的帧才被裁。
      //
      // 最小化时（IsIconic）客户区会被系统缩成一百多像素，这时更不能动它。
      if (::IsZoomed(hwnd) && !::IsIconic(hwnd)) {
        MONITORINFO monitor_info{};
        monitor_info.cbSize = sizeof(monitor_info);
        if (::GetMonitorInfo(::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                             &monitor_info)) {
          RECT clipped{};
          if (::IntersectRect(&clipped, &params->rgrc[0],
                              &monitor_info.rcWork)) {
            params->rgrc[0] = clipped;
          }
        }
      }
      return 0;
    }

    case WM_NCHITTEST: {
      // 非客户区收掉之后，边角缩放就落在客户区里了，这里再把缩放区域还给
      // 系统，否则窗口不能靠拖边框改变大小（拖动标题栏、Aero Snap 不受影响，
      // 那是 Dart 侧发 WM_NCLBUTTONDOWN + HTCAPTION 走的系统流程）。
      // 这个分支能被调用，是因为 Flutter 视图子窗口在边缘返回了
      // HTTRANSPARENT（见 ChildContentProc），系统才来问父窗口。
      if (!HasCustomTitleBar(hwnd) || ::IsZoomed(hwnd) || ::IsIconic(hwnd)) {
        break;
      }
      RECT window_rect{};
      if (!::GetWindowRect(hwnd, &window_rect)) {
        break;
      }
      const int x = static_cast<short>(LOWORD(lparam));
      const int y = static_cast<short>(HIWORD(lparam));
      const double scale = WindowState::GetScaleFactor(hwnd);
      // 与 ChildContentProc 用的是同一组宽度，两边必须一致：子窗口只在
      // 这一圈里让位，父窗口也只在这一圈里给缩放命中。
      const int side = Scale(kResizeBorderDip, scale);
      const int top = Scale(kResizeBorderTopDip, scale);

      const bool on_left = x < window_rect.left + side;
      const bool on_right = x >= window_rect.right - side;
      const bool on_top = y < window_rect.top + top;
      const bool on_bottom = y >= window_rect.bottom - side;

      if (on_top && on_left) {
        return HTTOPLEFT;
      }
      if (on_top && on_right) {
        return HTTOPRIGHT;
      }
      if (on_bottom && on_left) {
        return HTBOTTOMLEFT;
      }
      if (on_bottom && on_right) {
        return HTBOTTOMRIGHT;
      }
      if (on_left) {
        return HTLEFT;
      }
      if (on_right) {
        return HTRIGHT;
      }
      if (on_top) {
        return HTTOP;
      }
      if (on_bottom) {
        return HTBOTTOM;
      }
      break;
    }

    case WM_NCACTIVATE: {
      // 自绘标题栏模式下必须拦下来：窗口的激活状态一变（失焦 / 重新获得焦点，
      // 或点了自绘标题栏触发 WM_NCLBUTTONDOWN），DefWindowProc 就会按系统默认
      // 样式把非客户区整块重画回来 —— 表现为窗口四周突然冒出一圈老式 Windows
      // 边框，连系统标题栏一起。
      //
      // 只拦 WM_NCPAINT 不够（实测它走的是另一条重绘路径），必须在这里直接
      // 返回，不让 DefWindowProc 有机会去画。
      if (HasCustomTitleBar(hwnd)) {
        return TRUE;
      }
      break;
    }

    case WM_NCPAINT: {
      // 自绘标题栏模式下没有非客户区，画什么都没有意义；交回 DefWindowProc
      // 反而会按默认样式把边框画出来。
      if (HasCustomTitleBar(hwnd)) {
        return 0;
      }
      break;
    }

    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      // 最小化时客户区会被系统缩成一百多像素（实测 197×33）。这时绝不能把
      // Flutter 视图也跟着 MoveWindow 过去：视图会被压成一条，最小化动画里
      // 看到的就是「内容被快速压扁」，恢复时又猛地放大，来回一次就是抖动。
      // 视图保持原尺寸，等真正恢复（SIZE_RESTORED / SIZE_MAXIMIZED）再按新的
      // 客户区调整。
      if (wparam == SIZE_MINIMIZED) {
        return 0;
      }
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      // 只记录普通状态下的窗口尺寸：最大化（最大化按钮 / 双击标题栏）
      // 不记录，下次启动仍恢复成用户调整过的尺寸。
      // 自定义最大化是 SetWindowPos 实现的，系统按 SIZE_RESTORED 上报，
      // 要用 custom_maximized_ 把它排除掉。
      if (wparam == SIZE_RESTORED && !custom_maximized_) {
        RECT window_rect{};
        if (::GetWindowRect(hwnd, &window_rect)) {
          const double scale = WindowState::GetScaleFactor(hwnd);
          const int width = static_cast<int>(
              (window_rect.right - window_rect.left) / scale);
          const int height = static_cast<int>(
              (window_rect.bottom - window_rect.top) / scale);
          if (width > 0 && height > 0) {
            last_normal_size_ = Size(static_cast<unsigned int>(width),
                                     static_cast<unsigned int>(height));
            has_normal_size_ = true;
          }
        }
      }
      return 0;
    }

    case WM_EXITSIZEMOVE: {
      // 拖动 / 缩放结束时再落盘一次，避免拖动过程中频繁写注册表。
      SaveWindowSize();
      return 0;
    }

    case WM_APP + 101: {
      // 给 Dart 侧查「现在是不是最大化」：自定义最大化时 IsZoomed 是 false。
      return (custom_maximized_ || ::IsZoomed(hwnd)) ? 1 : 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  // 给 Flutter 的视图挂一层消息钩子：靠近窗口边缘时让它「透明」，把缩放
  // 命中让给父窗口（见 ChildContentProc 的说明）。原来的过程留在
  // g_child_content_proc 里照常转发；同一个窗口只挂一次，万一 Flutter 之后
  // 换了新的视图窗口，下次进来会重新挂。
  if (g_hooked_child != content) {
    const WNDPROC previous = reinterpret_cast<WNDPROC>(::SetWindowLongPtr(
        content, GWLP_WNDPROC,
        reinterpret_cast<LONG_PTR>(ChildContentProc)));
    if (previous != nullptr) {
      g_child_content_proc = previous;
      g_hooked_child = content;
    }
  }

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

void Win32Window::SaveWindowSize() {
  if (!has_normal_size_) {
    return;
  }
  WindowState::SaveSize(last_normal_size_);
}

bool Win32Window::HandleMaximizeSysCommand(UINT command) {
  const HWND hwnd = window_handle_;
  if (hwnd == nullptr || !HasCustomTitleBar(hwnd)) {
    return false;
  }
  if (command != SC_MAXIMIZE && command != SC_RESTORE) {
    return false;
  }
  ToggleCustomMaximize(command == SC_MAXIMIZE);
  return true;
}

void Win32Window::ToggleCustomMaximize(bool maximize) {
  const HWND hwnd = window_handle_;
  if (hwnd == nullptr) {
    return;
  }

  // 最小化状态下先让系统还原（这一步没有过渡动画），并保持最大化外观：
  // 系统给的是「最小化前的矩形」，我们只负责把它纠正成工作区。
  if (::IsIconic(hwnd)) {
    ::ShowWindow(hwnd, SW_RESTORE);
    if (custom_maximized_) {
      MONITORINFO monitor_info{};
      monitor_info.cbSize = sizeof(monitor_info);
      if (::GetMonitorInfo(::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                           &monitor_info)) {
        const RECT& work = monitor_info.rcWork;
        ::SetWindowPos(hwnd, nullptr, work.left, work.top,
                       work.right - work.left, work.bottom - work.top,
                       SWP_NOZORDER | SWP_NOACTIVATE);
      }
    }
    return;
  }

  // 由系统自己最大化的窗口（例如把窗口拖到屏幕顶部触发 Aero Snap）：
  // 还原交回系统处理，我们只清状态。
  if (!maximize && ::IsZoomed(hwnd)) {
    ::ShowWindow(hwnd, SW_RESTORE);
    custom_maximized_ = false;
    return;
  }

  if (maximize) {
    if (custom_maximized_ || ::IsZoomed(hwnd)) {
      return;  // 已经是最大化，不重复处理
    }
    MONITORINFO monitor_info{};
    monitor_info.cbSize = sizeof(monitor_info);
    if (!::GetMonitorInfo(::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                          &monitor_info)) {
      return;
    }
    // 记住当前位置，还原时用。
    ::GetWindowRect(hwnd, &custom_normal_rect_);
    custom_maximized_ = true;
    const RECT& work = monitor_info.rcWork;
    ::SetWindowPos(hwnd, nullptr, work.left, work.top, work.right - work.left,
                   work.bottom - work.top, SWP_NOZORDER | SWP_NOACTIVATE);
    return;
  }

  if (!custom_maximized_) {
    return;
  }
  // 还原到进入最大化之前的矩形（位置 + 大小）。用 SetWindowPos 直接到位，
  // 不走 ShowWindow(SW_RESTORE)，同样避免过渡动画。
  const RECT rect = custom_normal_rect_;
  custom_maximized_ = false;
  ::SetWindowPos(hwnd, nullptr, rect.left, rect.top, rect.right - rect.left,
                 rect.bottom - rect.top, SWP_NOZORDER | SWP_NOACTIVATE);
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
