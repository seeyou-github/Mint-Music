#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  // 启动耗时诊断：这几行日志用于区分「引擎/图形初始化慢」和「Dart 侧慢」。
  LogStartupEvent("FlutterWindow::OnCreate: begin");

  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  LogStartupEvent("FlutterWindow::OnCreate: creating FlutterViewController");
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  LogStartupEvent(
      "FlutterWindow::OnCreate: FlutterViewController created (engine + GPU)");
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  LogStartupEvent("FlutterWindow::OnCreate: registering plugins");
  RegisterPlugins(flutter_controller_->engine());
  LogStartupEvent("FlutterWindow::OnCreate: plugins registered");
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    LogStartupEvent("first frame rendered -> Show()");
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // 收到关闭请求时直接终止进程，跳过退出阶段的析构清理。
  //
  // 原因：flutter_inappwebview_windows 在析构 WebView2 时会触发 fail-fast
  // （异常码 STATUS_FAIL_FAST_EXCEPTION，常报 dcomp.dll），表现为关闭窗口时
  // 弹出「mintmusic.exe - 快速异常检测失败」。该问题即使完全不使用 WebView
  // 也会出现，因为插件在注册时就创建了管理器对象；上游至今未修复。
  // 见 https://github.com/pichillilorenzo/flutter_inappwebview/issues/2512
  //
  // 此处进程本就要退出，直接 TerminateProcess 反而能避免那次崩溃，且退出码
  // 为 0，不会在任务管理器/事件查看器里留下崩溃记录。
  if (message == WM_CLOSE) {
    ::TerminateProcess(::GetCurrentProcess(), 0);
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
