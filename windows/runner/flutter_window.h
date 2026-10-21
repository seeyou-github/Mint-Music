#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Channel used to talk to the Dart side (taskbar thumbnail toolbar).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      method_channel_;

  // Channel used to control the native desktop lyric window.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      desktop_lyric_channel_;

  // Channel used to open folders / reveal files in the system file manager.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      file_manager_channel_;

  // Sends |method| to the Dart side.
  void SendToDart(const std::string& method);

  // Handles a desktop lyric method call coming from the Dart side.
  void HandleDesktopLyricCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Handles a file manager method call coming from the Dart side.
  void HandleFileManagerCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
