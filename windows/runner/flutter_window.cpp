#include "flutter_window.h"

#include <optional>
#include <windows.h>

#include <shellapi.h>
#include <shobjidl.h>

#include "flutter/generated_plugin_registrant.h"
#include "desktop_lyric_window.h"
#include "thumbnail_toolbar.h"

namespace {

// 从 EncodableMap 中按键取值的辅助函数。
const flutter::EncodableValue* MapValue(const flutter::EncodableMap* map,
                                        const char* key) {
  if (map == nullptr) {
    return nullptr;
  }
  const auto it = map->find(flutter::EncodableValue(std::string(key)));
  if (it == map->end()) {
    return nullptr;
  }
  return &it->second;
}

bool GetBool(const flutter::EncodableMap* map, const char* key, bool fallback) {
  const auto* value = MapValue(map, key);
  if (value == nullptr) {
    return fallback;
  }
  if (const bool* result = std::get_if<bool>(value)) {
    return *result;
  }
  return fallback;
}

int GetInt(const flutter::EncodableMap* map, const char* key, int fallback) {
  const auto* value = MapValue(map, key);
  if (value == nullptr) {
    return fallback;
  }
  if (const int32_t* result = std::get_if<int32_t>(value)) {
    return *result;
  }
  if (const int64_t* result = std::get_if<int64_t>(value)) {
    return static_cast<int>(*result);
  }
  if (const double* result = std::get_if<double>(value)) {
    return static_cast<int>(*result);
  }
  return fallback;
}

double GetDouble(const flutter::EncodableMap* map,
                 const char* key,
                 double fallback) {
  const auto* value = MapValue(map, key);
  if (value == nullptr) {
    return fallback;
  }
  if (const double* result = std::get_if<double>(value)) {
    return *result;
  }
  if (const int32_t* result = std::get_if<int32_t>(value)) {
    return static_cast<double>(*result);
  }
  if (const int64_t* result = std::get_if<int64_t>(value)) {
    return static_cast<double>(*result);
  }
  return fallback;
}

std::string GetStringUtf8(const flutter::EncodableMap* map, const char* key) {
  const auto* value = MapValue(map, key);
  if (value == nullptr) {
    return std::string();
  }
  if (const std::string* result = std::get_if<std::string>(value)) {
    return *result;
  }
  return std::string();
}

// UTF-8 字符串转 UTF-16（GDI 绘制中文需要 UTF-16）。
std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) {
    return std::wstring();
  }
  const int length =
      ::MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
  if (length <= 1) {
    return std::wstring();
  }
  std::wstring wide(static_cast<size_t>(length), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, &wide[0], length);
  wide.resize(static_cast<size_t>(length - 1));
  return wide;
}

}  // namespace

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

  // 桌面歌词：Dart 侧通过该通道控制独立的桌面歌词窗口。
  desktop_lyric_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.mintmusic/desktop_lyric",
          &flutter::StandardMethodCodec::GetInstance());
  desktop_lyric_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        HandleDesktopLyricCall(call, std::move(result));
      });

  // 文件管理器：Dart 侧请求用系统文件管理器打开目录 / 定位文件。
  file_manager_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.mintmusic/file_manager",
          &flutter::StandardMethodCodec::GetInstance());
  file_manager_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        HandleFileManagerCall(call, std::move(result));
      });

  // 桌面歌词窗口被拖动后，把新位置回传给 Dart 侧持久化。
  mintmusic::DesktopLyricWindow::Instance().SetPositionCallback(
      [this](double x, double y) {
        if (!desktop_lyric_channel_) {
          return;
        }
        flutter::EncodableMap arguments;
        arguments[flutter::EncodableValue(std::string("x"))] =
            flutter::EncodableValue(x);
        arguments[flutter::EncodableValue(std::string("y"))] =
            flutter::EncodableValue(y);
        desktop_lyric_channel_->InvokeMethod(
            "onPositionChanged",
            std::make_unique<flutter::EncodableValue>(arguments));
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

// 用系统文件管理器打开目录 / 定位文件。
//
// * openFolder：直接打开该目录；
// * revealFile：打开文件所在目录并选中该文件（explorer /select）。
void FlutterWindow::HandleFileManagerCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
  const std::string path = GetStringUtf8(arguments, "path");
  if (path.empty()) {
    result->Error("path is required");
    return;
  }
  const std::wstring wide_path = Utf8ToWide(path);
  if (wide_path.empty()) {
    result->Error("invalid path");
    return;
  }

  if (call.method_name() == "openFolder") {
    // 直接把目录交给 ShellExecute（资源管理器会用「打开文件夹」的方式打开它）。
    //
    // 注意：不能把整条命令（`explorer.exe "C:\dir"`）当成 lpFile 传进来 ——
    // 带引号的命令行不是合法路径，ShellExecute 会直接失败（返回值 <= 32），
    // 表现就是「点了没反应 / 提示无法打开所在文件夹」。
    const HINSTANCE ret = ::ShellExecuteW(nullptr, L"open", wide_path.c_str(),
                                          nullptr, nullptr, SW_SHOWNORMAL);
    result->Success(static_cast<int64_t>(reinterpret_cast<intptr_t>(ret)) > 32);
    return;
  }

  if (call.method_name() == "revealFile") {
    // 打开所在目录并选中该文件：程序放 lpFile，`/select,"file"` 放 lpParameters，
    // explorer 才会正确解析参数（同样不能拼成一条命令塞进 lpFile）。
    const std::wstring parameters = L"/select,\"" + wide_path + L"\"";
    const HINSTANCE ret =
        ::ShellExecuteW(nullptr, L"open", L"explorer.exe", parameters.c_str(),
                        nullptr, SW_SHOWNORMAL);
    result->Success(static_cast<int64_t>(reinterpret_cast<intptr_t>(ret)) > 32);
    return;
  }

  result->NotImplemented();
}

void FlutterWindow::HandleDesktopLyricCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  auto& window = mintmusic::DesktopLyricWindow::Instance();
  const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());

  if (call.method_name() == "show") {
    window.Show();
    result->Success(window.IsShowing());
    return;
  }
  if (call.method_name() == "hide") {
    window.Hide();
    result->Success();
    return;
  }
  if (call.method_name() == "isShowing") {
    result->Success(window.IsShowing());
    return;
  }
  if (call.method_name() == "checkPermission") {
    // Windows 的顶层窗口不需要额外授权。
    result->Success(true);
    return;
  }
  if (call.method_name() == "openPermissionSettings") {
    // Windows 无需跳转系统授权页。
    result->Success();
    return;
  }
  if (call.method_name() == "updateConfig") {
    // 应用字体：字体族名 + 字体文件路径（原生侧注册后按族名取用）。
    const std::wstring font_family = Utf8ToWide(GetStringUtf8(arguments, "fontFamily"));
    const std::wstring font_path = Utf8ToWide(GetStringUtf8(arguments, "fontPath"));
    window.UpdateConfig(
        static_cast<int>(GetDouble(arguments, "fontSize", 42)),
        static_cast<unsigned int>(
            GetInt(arguments, "playedColor", static_cast<int>(0xFFFFFFFF))),
        static_cast<unsigned int>(
            GetInt(arguments, "unplayColor", static_cast<int>(0xFFFFFFFF))),
        static_cast<unsigned int>(
            GetInt(arguments, "shadowColor", static_cast<int>(0xFF000000))),
        GetDouble(arguments, "positionX", 50),
        GetDouble(arguments, "positionY", 85), font_family, font_path,
        GetInt(arguments, "fontWeight", 500));
    result->Success();
    return;
  }
  if (call.method_name() == "updateLyric") {
    std::vector<mintmusic::DesktopLyricLine> lines;
    const auto* lines_value = MapValue(arguments, "lines");
    if (lines_value != nullptr) {
      const auto* list = std::get_if<flutter::EncodableList>(lines_value);
      if (list != nullptr) {
        for (const auto& item : *list) {
          const auto* line_map = std::get_if<flutter::EncodableMap>(&item);
          if (line_map == nullptr) {
            continue;
          }
          mintmusic::DesktopLyricLine line;
          line.time_ms = GetInt(line_map, "time", 0);
          line.end_time_ms = GetInt(line_map, "endTime", 0);
          line.text = Utf8ToWide(GetStringUtf8(line_map, "text"));
          line.translation = Utf8ToWide(GetStringUtf8(line_map, "translation"));
          line.roman = Utf8ToWide(GetStringUtf8(line_map, "roman"));
          lines.push_back(line);
        }
      }
    }
    window.UpdateLyric(lines, GetInt(arguments, "activeIndex", 0),
                       GetBool(arguments, "showTranslation", false),
                       GetBool(arguments, "showRoman", false));
    result->Success();
    return;
  }
  if (call.method_name() == "setPlayState") {
    window.SetPlayState(static_cast<long long>(GetInt(arguments, "positionMs", 0)),
                        GetBool(arguments, "isPlaying", false));
    result->Success();
    return;
  }
  result->NotImplemented();
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
