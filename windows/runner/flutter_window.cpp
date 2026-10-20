#include "flutter_window.h"

#include <optional>
#include <windows.h>

#include <shobjidl.h>

#include "flutter/generated_plugin_registrant.h"
#include "thumbnail_toolbar.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // 与 Dart 侧通信的通道：任务栏缩略图工具栏的按钮事件从这里下发，
  // 播放状态也从这里回传给原生侧（用于切换播放/暂停图标）。
  method_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "com.mintmusic/taskbar",
          &flutter::StandardMethodCodec::GetInstance());
  method_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "playbackState") {
          bool playing = false;
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments != nullptr) {
            const auto entry =
                arguments->find(flutter::EncodableValue(std::string("playing")));
            if (entry != arguments->end()) {
              if (const bool* value = std::get_if<bool>(&entry->second)) {
                playing = *value;
              }
            }
          }
          mintmusic::ThumbnailToolbar::SetPlaying(playing);
        }
        result->Success();
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
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

void FlutterWindow::SendToDart(const std::string& method) {
  if (!method_channel_) {
    return;
  }
  method_channel_->InvokeMethod(method, nullptr);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // 收到关闭请求时直接终止进程，跳过退出阶段的析构清理。
  //
  // 原因：flutter_inappwebview_windows 在析构 WebView2 时会触发 fail-fast
  // （异常码 STATUS_FAIL_FAST_EXCEPTION，常报 dcomp.dll），表现为关闭窗口时
  // 弹出「薄荷音乐.exe - 快速异常检测失败」。该问题即使完全不使用 WebView
  // 也会出现，因为插件在注册时就创建了管理器对象；上游至今未修复。
  // 见 https://github.com/pichillilorenzo/flutter_inappwebview/issues/2512
  //
  // 此处进程本就要退出，直接 TerminateProcess 反而能避免那次崩溃，且退出码
  // 为 0，不会在任务管理器/事件查看器里留下崩溃记录。
  if (message == WM_CLOSE) {
    // 退出前先把窗口尺寸落盘，下次启动按上次的尺寸恢复。
    SaveWindowSize();
    ::TerminateProcess(::GetCurrentProcess(), 0);
    return 0;
  }

  // 任务栏按钮创建完成后系统才会发送该消息，此时才可以给缩略图挂工具栏。
  static const UINT taskbar_button_created =
      ::RegisterWindowMessageW(L"TaskbarButtonCreated");
  if (taskbar_button_created != 0 && message == taskbar_button_created) {
    mintmusic::ThumbnailToolbar::Attach(hwnd);
    // 让 Dart 回报一次当前播放状态，保证播放 / 暂停按钮的图标正确。
    SendToDart("queryPlaybackState");
    return 0;
  }

  // 缩略图工具栏的按钮点击事件（只拦截我们自己的按钮 ID）。
  // 任务栏工具栏的点击通知码为 THBN_CLICKED，按钮 ID 在 wParam 低位。
  if (message == WM_COMMAND && HIWORD(wparam) == THBN_CLICKED) {
    switch (LOWORD(wparam)) {
      case mintmusic::kThumbnailButtonPrevious:
        SendToDart("previous");
        return 0;
      case mintmusic::kThumbnailButtonPlayPause:
        SendToDart("playPause");
        return 0;
      case mintmusic::kThumbnailButtonNext:
        SendToDart("next");
        return 0;
      default:
        break;
    }
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
