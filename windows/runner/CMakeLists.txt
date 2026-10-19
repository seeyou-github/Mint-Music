cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# 注意：CMake 目标名必须是 ASCII，所以这里用顶层 CMakeLists.txt 里的
# RUNNER_TARGET_NAME，产物的文件名再通过 OUTPUT_NAME 设成「薄荷音乐.exe」。
#
# Any new source files that you add to the application should be added here.
add_executable(${RUNNER_TARGET_NAME} WIN32
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

# 产物文件名：任务管理器里的进程名 / 资源管理器里的文件名都显示「薄荷音乐」。
set_target_properties(${RUNNER_TARGET_NAME} PROPERTIES OUTPUT_NAME "薄荷音乐")

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

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${RUNNER_TARGET_NAME} flutter_assemble)
