#include "window_state.h"

#include <flutter_windows.h>

#include <string>

#include <stdlib.h>
#include <windows.h>

namespace {

// 窗口尺寸保存在注册表里，随应用一起清理，不需要额外的文件 IO。
constexpr wchar_t kRegistryKey[] = L"Software\\com.kingmc.mintmusic";
constexpr wchar_t kWindowSizeValue[] = L"WindowSize";

// 合理的窗口尺寸范围，避免把异常值（例如被拖到屏幕外）写进去。
constexpr unsigned int kMinWidth = 640;
constexpr unsigned int kMinHeight = 480;
constexpr unsigned int kMaxWidth = 10000;
constexpr unsigned int kMaxHeight = 10000;

constexpr unsigned int kDefaultWidth = 1280;
constexpr unsigned int kDefaultHeight = 720;

}  // namespace

double WindowState::GetScaleFactor(HWND window) {
  // GetDpiForWindow 需要 Win10 1607 以上的 SDK 声明，这里用始终可用的
  // GetDeviceCaps(LOGPIXELSX)：在 Per-Monitor DPI 感知下它返回的就是
  // 窗口所在显示器的 DPI。
  UINT dpi = 96;
  HDC dc = ::GetDC(window);
  if (dc != nullptr) {
    const int device_dpi = ::GetDeviceCaps(dc, LOGPIXELSX);
    if (device_dpi > 0) {
      dpi = static_cast<UINT>(device_dpi);
    }
    ::ReleaseDC(window, dc);
  }
  if (dpi == 0) {
    dpi = 96;
  }
  return dpi / 96.0;
}

Win32Window::Size WindowState::GetSavedSize() {
  Win32Window::Size default_size(kDefaultWidth, kDefaultHeight);

  HKEY key = nullptr;
  if (::RegOpenKeyExW(HKEY_CURRENT_USER, kRegistryKey, 0, KEY_READ, &key) !=
      ERROR_SUCCESS) {
    return default_size;
  }

  wchar_t buffer[64] = {0};
  DWORD buffer_size = sizeof(buffer);
  DWORD value_type = 0;
  const LONG result =
      ::RegQueryValueExW(key, kWindowSizeValue, nullptr, &value_type,
                          reinterpret_cast<LPBYTE>(buffer), &buffer_size);
  ::RegCloseKey(key);

  if (result != ERROR_SUCCESS || value_type != REG_SZ) {
    return default_size;
  }

  const std::wstring value(buffer);
  const size_t separator = value.find(L'x');
  if (separator == std::wstring::npos) {
    return default_size;
  }

  const int width = ::_wtoi(value.substr(0, separator).c_str());
  const int height = ::_wtoi(value.substr(separator + 1).c_str());
  if (width < static_cast<int>(kMinWidth) ||
      height < static_cast<int>(kMinHeight) ||
      width > static_cast<int>(kMaxWidth) ||
      height > static_cast<int>(kMaxHeight)) {
    return default_size;
  }

  return Win32Window::Size(static_cast<unsigned int>(width),
                           static_cast<unsigned int>(height));
}

void WindowState::SaveSize(const Win32Window::Size& size) {
  if (size.width < kMinWidth || size.height < kMinHeight ||
      size.width > kMaxWidth || size.height > kMaxHeight) {
    return;
  }

  const std::wstring value =
      std::to_wstring(size.width) + L"x" + std::to_wstring(size.height);

  HKEY key = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, kRegistryKey, 0, nullptr,
                        REG_OPTION_NON_VOLATILE, KEY_WRITE, nullptr, &key,
                        nullptr) != ERROR_SUCCESS) {
    return;
  }
  ::RegSetValueExW(key, kWindowSizeValue, 0, REG_SZ,
                   reinterpret_cast<const BYTE*>(value.c_str()),
                   static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
  ::RegCloseKey(key);
}

Win32Window::Point WindowState::GetCenteredOrigin(
    const Win32Window::Size& size) {
  RECT work_area{};
  if (!::SystemParametersInfoW(SPI_GETWORKAREA, 0, &work_area, 0)) {
    return Win32Window::Point(10, 10);
  }

  // 工作区是物理像素，窗口位置最终也会按 DPI 缩放，这里先换算回逻辑像素。
  HMONITOR monitor = ::MonitorFromPoint(
      POINT{work_area.left, work_area.top}, MONITOR_DEFAULTTOPRIMARY);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  if (dpi == 0) {
    dpi = 96;
  }
  const double scale = dpi / 96.0;

  const int work_width =
      static_cast<int>((work_area.right - work_area.left) / scale);
  const int work_height =
      static_cast<int>((work_area.bottom - work_area.top) / scale);
  const int work_left = static_cast<int>(work_area.left / scale);
  const int work_top = static_cast<int>(work_area.top / scale);

  int x = work_left + (work_width - static_cast<int>(size.width)) / 2;
  int y = work_top + (work_height - static_cast<int>(size.height)) / 2;
  if (x < 0) {
    x = 0;
  }
  if (y < 0) {
    y = 0;
  }

  return Win32Window::Point(static_cast<unsigned int>(x),
                            static_cast<unsigned int>(y));
}
