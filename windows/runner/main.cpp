#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  LogStartupEvent("wWinMain: entered main (DLLs loaded)");

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  // 启动耗时诊断结论：Flutter 3.47 起 Windows 默认启用 Impeller，而
  // Impeller 走 ANGLE(OpenGL ES) -> D3D11，没有 program 缓存，启动时必须在
  // 光栅线程上链接 70+ 个 shader program（≈146 次 D3DCompile），每次启动
  // 都要重来，实测把 FlutterViewController 的构造拖到 2~4 秒（本机 3.9 秒）。
  // 关掉 Impeller 退回 Skia 后，同样的机器上降到 0.1~0.3 秒。
  // 上游 issue：https://github.com/flutter/flutter/issues/191860
  // （等上游落地 ANGLE program 缓存 #193419 / 把 program 创建移到 IO 线程
  // #185723 之后，这段就可以删掉了。）
  // 注意：环境变量 FLUTTER_ENGINE_SWITCHES 在 release 构建里被编译掉，无效，
  // 只能在这里用 DartProject 的开关。
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"mintmusic", origin, size)) {
    LogStartupEvent("wWinMain: window.Create failed");
    return EXIT_FAILURE;
  }
  LogStartupEvent("wWinMain: window.Create returned (engine ready)");
  window.SetQuitOnClose(true);

  LogStartupEvent("wWinMain: message loop start (waiting for first frame)");
  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }
  LogStartupEvent("wWinMain: message loop end");

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
