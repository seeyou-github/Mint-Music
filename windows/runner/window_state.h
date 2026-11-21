#ifndef RUNNER_WINDOW_STATE_H_
#define RUNNER_WINDOW_STATE_H_

#include <windows.h>

#include "win32_window.h"

// 窗口尺寸 / 位置的持久化（仅 Windows 平台）。
//
// 需求：
// * 启动时窗口在当前显示器的工作区中居中显示；
// * 窗口大小沿用「上次调整后的大小」；
// * 最大化（点击最大化按钮 / 双击标题栏）时不要记录，恢复时仍使用
//   最大化之前的普通窗口尺寸。
class WindowState {
 public:
  // 读取上次保存的窗口尺寸；没有记录（或记录非法）时返回默认尺寸。
  static Win32Window::Size GetSavedSize();

  // 保存窗口尺寸（超出合理范围的值会被忽略）。
  static void SaveSize(const Win32Window::Size& size);

  // 计算窗口在主显示器工作区中居中的位置（逻辑像素）。
  static Win32Window::Point GetCenteredOrigin(const Win32Window::Size& size);

  // The scaling factor of the display the window is on (96 DPI = 1.0).
  static double GetScaleFactor(HWND window);
};

#endif  // RUNNER_WINDOW_STATE_H_
