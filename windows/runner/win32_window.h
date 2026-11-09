#ifndef RUNNER_WIN32_WINDOW_H_
#define RUNNER_WIN32_WINDOW_H_

#include <windows.h>

#include <functional>
#include <memory>
#include <string>

// A class abstraction for a high DPI-aware Win32 Window. Intended to be
// inherited from by classes that wish to specialize with custom
// rendering and input handling
class Win32Window {
 public:
  struct Point {
    unsigned int x;
    unsigned int y;
    Point(unsigned int x, unsigned int y) : x(x), y(y) {}
  };

  struct Size {
    unsigned int width;
    unsigned int height;
    Size(unsigned int width, unsigned int height)
        : width(width), height(height) {}
  };

  Win32Window();
  virtual ~Win32Window();

  // Creates a win32 window with |title| that is positioned and sized using
  // |origin| and |size|. New windows are created on the default monitor. Window
  // sizes are specified to the OS in physical pixels, hence to ensure a
  // consistent size this function will scale the inputted width and height as
  // as appropriate for the default monitor. The window is invisible until
  // |Show| is called. Returns true if the window was created successfully.
  bool Create(const std::wstring& title, const Point& origin, const Size& size);

  // Show the current window. Returns true if the window was successfully shown.
  bool Show();

  // Release OS resources associated with window.
  void Destroy();

  // Inserts |content| into the window tree.
  void SetChildContent(HWND content);

  // Returns the backing Window handle to enable clients to set icon and other
  // window properties. Returns nullptr if the window has been destroyed.
  HWND GetHandle();

  /// 自绘标题栏窗口的「最大化 / 还原」命令处理。
  ///
  /// 必须由 [FlutterWindow] 在把消息交给 Flutter 引擎**之前**调用：引擎
  /// `HandleTopLevelWindowProc` 一旦返回处理结果，消息就不会再走到
  /// `Win32Window::MessageHandler`，放在后面等于没拦到。
  /// 返回 true 表示这条 WM_SYSCOMMAND 已经处理完，调用方应直接返回 0。
  bool HandleMaximizeSysCommand(UINT command);

  // If true, closing this window will quit the application.
  void SetQuitOnClose(bool quit_on_close);

  // Return a RECT representing the bounds of the current client area.
  RECT GetClientArea();

  // Persists the current window size so the next launch can restore it.
  //
  // Only the "normal" (non maximized) size is recorded: clicking the maximize
  // button or double clicking the title bar must not overwrite the size that
  // was adjusted by the user.
  void SaveWindowSize();

 protected:
  // Processes and route salient window messages for mouse handling,
  // size change and DPI. Delegates handling of these to member overloads that
  // inheriting classes can handle.
  virtual LRESULT MessageHandler(HWND window,
                                 UINT const message,
                                 WPARAM const wparam,
                                 LPARAM const lparam) noexcept;

  // Called when CreateAndShow is called, allowing subclass window-related
  // setup. Subclasses should return false if setup fails.
  virtual bool OnCreate();

  // Called when Destroy is called.
  virtual void OnDestroy();

 private:
  friend class WindowClassRegistrar;

  // OS callback called by message pump. Handles the WM_NCCREATE message which
  // is passed when the non-client area is being created and enables automatic
  // non-client DPI scaling so that the non-client area automatically
  // responds to changes in DPI. All other messages are handled by
  // MessageHandler.
  static LRESULT CALLBACK WndProc(HWND const window,
                                  UINT const message,
                                  WPARAM const wparam,
                                  LPARAM const lparam) noexcept;

  // Retrieves a class instance pointer for |window|
  static Win32Window* GetThisFromHandle(HWND const window) noexcept;

  // Update the window frame's theme to match the system theme.
  static void UpdateTheme(HWND const window);

  bool quit_on_close_ = false;

  // window handle for top level window.
  HWND window_handle_ = nullptr;

  // window handle for hosted content.
  HWND child_content_ = nullptr;

  // The last known size of the window in its "normal" (not maximized) state.
  Size last_normal_size_{0, 0};
  bool has_normal_size_ = false;

  // ── 自绘标题栏窗口自己的最大化状态 ─────────────────────────────────────
  //
  // 不用系统的 ShowWindow(SW_MAXIMIZE)：Win10 上无边框窗口的最大化会播一段
  // DWM 过渡动画，动画缩放的是「已经按新尺寸重排好的内容」的旧帧，看起来就是
  // 窗口先变回原尺寸再放大（DWMWA_TRANSITIONS_FORCEDISABLED 从 Win8 起已不
  // 生效，拦不住）。改成直接 SetWindowPos 到工作区，一步到位、没有中间帧。
  //
  // 代价：窗口不再处于系统的「最大化」状态（IsZoomed 为 false），所以状态自己
  // 记，并通过 WM_APP+101 暴露给 Dart 侧查。
  bool custom_maximized_ = false;

  // 进入自定义最大化之前的窗口矩形，还原时原样恢复。
  RECT custom_normal_rect_{0, 0, 0, 0};

  // 最大化 / 还原（无动画）。
  void ToggleCustomMaximize(bool maximize);
};

#endif  // RUNNER_WIN32_WINDOW_H_
