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

/// 窗口背景画刷：启动空窗期 / 最大化过渡时父窗口露出的区域用它填充。
///
/// 以前 `hbrBackground = 0`，系统用默认白色，窗口四周或空窗时会闪白。
/// PiliPlus 用 `g_startup_background_brush` + `WM_ERASEBKGND` 解决，
/// 这里同样在 `WM_ERASEBKGND` 里用它填满客户区。
static HBRUSH g_startup_background_brush = nullptr;

HBRUSH EnsureStartupBackgroundBrush() {
  if (g_startup_background_brush != nullptr) {
    return g_startup_background_brush;
  }
  DWORD light_mode = 1;
  DWORD light_mode_size = sizeof(light_mode);
  const bool dark =
      ::RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                    kGetPreferredBrightnessRegValue, RRF_RT_REG_DWORD, nullptr,
                    &light_mode, &light_mode_size) == ERROR_SUCCESS &&
      light_mode == 0;
  // 与默认背景渐变的边缘色一致，那一圈边框不会显得突兀。
  const COLORREF color =
      dark ? RGB(41, 41, 52)       // #292934
           : RGB(182, 182, 182);  // #B6B6B6
  g_startup_background_brush = ::CreateSolidBrush(color);
  return g_startup_background_brush;
}

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// 本项目的窗口栏始终由 Flutter 自绘（WindowsTitleBar）。
//
// 注意：**保留 WS_CAPTION**（创建时就是 WS_OVERLAPPEDWINDOW），同时让
// WM_NCCALCSIZE 返回「客户区 = 整个窗口」，再配合
// DwmExtendFrameIntoClientArea 去掉系统边框。这样 DWM 仍把窗口当
// 「有边框窗口」做最大化 / 最小化动画，不会出现无边框窗口那种
// 「先移到左上角、回弹、再放大」的中间帧；又不会留下非客户区边框
// （window_manager 的 is_frameless_ 分支就是这么做的）。
// 所以这里不能用样式位判断，本项目恒为自绘模式。
bool HasCustomTitleBar(HWND /*window*/) {
  return true;
}

/// 最大化时把客户区向外扩一圈，抵消系统给最大化窗口加的 8px 边框，
/// 让内容正好铺满工作区（照搬 window_manager 的 adjustNCCALCSIZE）。
void AdjustNcCalcSize(NCCALCSIZE_PARAMS* params) {
  LONG left = 8;
  LONG top = 8;
  // 用 rgrc[0] 找显示器，而不是 MonitorFromWindow：窗口从最小化恢复时
  // 可能还没落到正确的显示器上（window_manager issue #489）。
  HMONITOR monitor = ::MonitorFromRect(&params->rgrc[0],
                                       MONITOR_DEFAULTTONEAREST);
  if (monitor != nullptr) {
    MONITORINFO info{};
    info.cbSize = sizeof(info);
    if (::GetMonitorInfo(monitor, &info)) {
      left = params->rgrc[0].left - info.rcWork.left;
      top = params->rgrc[0].top - info.rcWork.top;
    }
  }
  params->rgrc[0].left -= left;
  params->rgrc[0].top -= top;
  params->rgrc[0].right += left;
  params->rgrc[0].bottom += top;
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
    window_class.hbrBackground = EnsureStartupBackgroundBrush();
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
  const bool shown = ShowWindow(window_handle_, SW_SHOWNORMAL);
  // 窗口可见之后再触发一次 FRAMECHANGED：SetChildContent 里那次发生在窗口
  // 显示之前，系统可能已经按默认样式画过一遍非客户区。这里重算一次，保证
  // 首帧显示时就没有系统边框。
  MARGINS margins = {0, 0, 0, 0};
  ::DwmExtendFrameIntoClientArea(window_handle_, &margins);
  ::SetWindowPos(window_handle_, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                     SWP_FRAMECHANGED);
  return shown;
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
    case WM_NCCALCSIZE: {
      // 照搬 window_manager 的 is_frameless_ 分支：客户区 = 整个窗口，
      // 不留非客户区。之前照抄的 TitleBarStyle.hidden 分支会在左/右/下
      // 留 8px 非客户区给系统缩放命中；这圈没有任何一方负责绘制时就是
      // 一圈白边（WM_NCPAINT 被拦掉，DWM 也不会替应用画），要等最大化
      // 把客户区扩到工作区、环宽变 0 才消失。
      //
      // 本项目已经在客户区里自己还了缩放命中（ChildContentProc 的
      // HTTRANSPARENT + 父窗口 WM_NCHITTEST），不需要这圈非客户区。
      if (wparam != TRUE || !HasCustomTitleBar(hwnd)) {
        break;
      }
      if (::IsZoomed(hwnd) && !::IsIconic(hwnd)) {
        // 最大化时把边界扩到工作区，内容才不会被屏幕边缘切掉。
        AdjustNcCalcSize(reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam));
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

    case WM_ERASEBKGND: {
      // 客户区铺满整窗之后，父窗口背景就是应用底色：启动空窗期、最大化 /
      // 还原过渡时露出的部分都用这个画刷填，避免闪白（PiliPlus 同款做法）。
      HBRUSH brush = EnsureStartupBackgroundBrush();
      RECT rect{};
      if (brush == nullptr || !::GetClientRect(hwnd, &rect)) {
        break;
      }
      ::FillRect(reinterpret_cast<HDC>(wparam), &rect, brush);
      return 1;
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
      if (wparam == SIZE_RESTORED) {
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

  // 保留 WS_CAPTION 的前提下去掉系统边框：DwmExtendFrameIntoClientArea
  // 配合上面的 WM_NCCALCSIZE（客户区 = 整个窗口）把边框收掉，再触发
  // SWP_FRAMECHANGED 让系统按新规则重算客户区。对应 window_manager 的
  // setAsFrameless()，也是 PiliPlus 的做法。
  MARGINS margins = {0, 0, 0, 0};
  ::DwmExtendFrameIntoClientArea(window_handle_, &margins);
  ::SetWindowPos(window_handle_, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                     SWP_FRAMECHANGED);

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
