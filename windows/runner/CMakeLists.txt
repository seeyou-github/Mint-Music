cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# ── 版本资源：文件版本 = 编译时间（北京时间） ───────────────────────────────
#
# pubspec 里的 `2.0.0+1` 会让 exe 属性永远显示同一个版本号，用户没法据此判断
# 手上的 exe 是哪次编译出来的。这里在配置阶段生成一份头文件（固定按 UTC+8
# 计算，本地构建与 GitHub Actions 同一口径），Runner.rc 把它写进
# FILEVERSION / FileVersion，属性页就能看到 `2026.1110.0242` 这样的时间。
#
# 生成到构建目录，不改源码树；每次 `flutter build/run windows` 都会重新配置，
# 所以每次都刷新。
set(BUILD_STAMP_HEADER "${CMAKE_BINARY_DIR}/build_stamp.h")

# 1) 优先用 Dart 脚本（逻辑集中在 tool/win_build_stamp.dart，时区换算不会写两遍）。
#
#    **必须优先找 dart-sdk 里的 dart.exe**：`flutter/bin` 下还有一个没有扩展名
#    的 `dart`，它是给 Git Bash 用的 shell 脚本，`find_program(NAMES dart)`
#    在 Windows 上会先命中它，然后 execute_process 根本跑不起来（结果变量被
#    忽略、错误被吞掉），表现为「头文件没生成 → 版本退回 2.0.0+1」。
find_program(DART_EXECUTABLE NAMES dart dart.exe dart.bat
  HINTS
    "$ENV{FLUTTER_ROOT}/bin/cache/dart-sdk/bin"
    "${FLUTTER_ROOT}/bin/cache/dart-sdk/bin"
    "$ENV{FLUTTER_ROOT}/bin"
    "${FLUTTER_ROOT}/bin")
if(DART_EXECUTABLE)
  execute_process(
    COMMAND "${DART_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/../../tool/win_build_stamp.dart"
            "${BUILD_STAMP_HEADER}"
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../.."
    RESULT_VARIABLE _build_stamp_result
    ERROR_VARIABLE _build_stamp_error
    OUTPUT_QUIET)
  if(NOT _build_stamp_result EQUAL 0)
    message(WARNING
      "生成编译时间戳失败（dart=${DART_EXECUTABLE}）：${_build_stamp_error}")
  endif()
endif()

# 2) 没有可用的 dart 时用 PowerShell 兜底：Windows 一定有，跨日跨月交给
#    .NET 的 DateTime 处理，不用在 CMake 里算进位。
if(NOT EXISTS "${BUILD_STAMP_HEADER}")
  execute_process(
    COMMAND powershell -NoProfile -Command
      "$t=[datetime]::UtcNow.AddHours(8); \"$($t.ToString('yyyy.MMdd.HHmm'))|$($t.Year),$($t.Month),$($t.Day),$($t.Hour*100+$t.Minute)\""
    OUTPUT_VARIABLE _ps_stamp
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
    RESULT_VARIABLE _ps_stamp_result)
  if(_ps_stamp MATCHES "^([0-9]+\\.[0-9]+\\.[0-9]+)\\|([0-9]+,[0-9]+,[0-9]+,[0-9]+)$")
    file(WRITE "${BUILD_STAMP_HEADER}"
      "// 由 windows/runner/CMakeLists.txt 生成（PowerShell）。\n"
      "#define APP_BUILD_STAMP \"${CMAKE_MATCH_1}\"\n"
      "#define APP_FILE_VERSION ${CMAKE_MATCH_2}\n")
  endif()
endif()

# 3) 两条路都失败（极不可能）：退回 pubspec 的语义化版本，至少不让构建失败。
if(NOT EXISTS "${BUILD_STAMP_HEADER}")
  message(WARNING "无法生成编译时间戳，版本资源退回 pubspec 版本 ${FLUTTER_VERSION}")
  file(WRITE "${BUILD_STAMP_HEADER}"
    "// 由 windows/runner/CMakeLists.txt 兜底生成（未能获取编译时间）。\n"
    "#define APP_BUILD_STAMP \"${FLUTTER_VERSION}\"\n"
    "#define APP_FILE_VERSION ${FLUTTER_VERSION_MAJOR},${FLUTTER_VERSION_MINOR},${FLUTTER_VERSION_PATCH},${FLUTTER_VERSION_BUILD}\n")
endif()

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# 注意：CMake 目标名必须是 ASCII，所以这里用顶层 CMakeLists.txt 里的
# RUNNER_TARGET_NAME，产物的文件名再通过 OUTPUT_NAME 设成「薄荷音乐.exe」。
#
# Any new source files that you add to the application should be added here.
add_executable(${RUNNER_TARGET_NAME} WIN32
  "desktop_lyric_window.cpp"
  "flutter_window.cpp"
  "main.cpp"
  "thumbnail_toolbar.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "window_state.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# 产物文件名：任务管理器里的进程名 / 资源管理器里的文件名都显示「Music」。
set_target_properties(${RUNNER_TARGET_NAME} PROPERTIES OUTPUT_NAME "Music")

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${RUNNER_TARGET_NAME})

# 源码里带有中文注释 / 字符串，统一按 UTF-8 解析。
# 不加这个开关时 MSVC 会按系统 ANSI 代码页解析，触发 C4819 警告，
# 而本工程开启了 /WX（警告即错误），会导致编译失败。
target_compile_options(${RUNNER_TARGET_NAME} PRIVATE "/utf-8")

# Add preprocessor definitions for the build version.
target_compile_definitions(${RUNNER_TARGET_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${RUNNER_TARGET_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${RUNNER_TARGET_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${RUNNER_TARGET_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${RUNNER_TARGET_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${RUNNER_TARGET_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${RUNNER_TARGET_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${RUNNER_TARGET_NAME} PRIVATE "dwmapi.lib")
# 任务栏缩略图工具栏需要 COM（CoCreateInstance / ITaskbarList3）。
target_link_libraries(${RUNNER_TARGET_NAME} PRIVATE "ole32.lib")
# 缩略图工具栏的按钮图标使用 32 位图像列表（ImageList_*）。
target_link_libraries(${RUNNER_TARGET_NAME} PRIVATE "comctl32.lib")
# 窗口尺寸持久化用到注册表 API。
target_link_libraries(${RUNNER_TARGET_NAME} PRIVATE "advapi32.lib")
target_include_directories(${RUNNER_TARGET_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
# Runner.rc 里的 `#include "build_stamp.h"`（编译时间版本号）在构建目录里。
target_include_directories(${RUNNER_TARGET_NAME} PRIVATE "${CMAKE_BINARY_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${RUNNER_TARGET_NAME} flutter_assemble)
