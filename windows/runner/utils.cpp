#include "utils.h"

#include <flutter_windows.h>
#include <io.h>
#include <stdio.h>
#include <windows.h>

#include <iostream>
#include <string>

void CreateAndAttachConsole() {
  if (::AllocConsole()) {
    FILE *unused;
    if (freopen_s(&unused, "CONOUT$", "w", stdout)) {
      _dup2(_fileno(stdout), 1);
    }
    if (freopen_s(&unused, "CONOUT$", "w", stderr)) {
      _dup2(_fileno(stdout), 2);
    }
    std::ios::sync_with_stdio();
    FlutterDesktopResyncOutputStreams();
  }
}

std::vector<std::string> GetCommandLineArguments() {
  // Convert the UTF-16 command line arguments to UTF-8 for the Engine to use.
  int argc;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return std::vector<std::string>();
  }

  std::vector<std::string> command_line_arguments;

  // Skip the first argument as it's the binary name.
  for (int i = 1; i < argc; i++) {
    command_line_arguments.push_back(Utf8FromUtf16(argv[i]));
  }

  ::LocalFree(argv);

  return command_line_arguments;
}

void PrepareWebView2UserDataFolder() {
  // 已经显式指定过就尊重外部设置。
  wchar_t existing[MAX_PATH] = {0};
  const DWORD length = ::GetEnvironmentVariableW(L"WEBVIEW2_USER_DATA_FOLDER",
                                                existing, MAX_PATH);
  if (length > 0 && length < MAX_PATH) {
    return;
  }

  wchar_t exe_path[MAX_PATH] = {0};
  const DWORD exe_length = ::GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
  if (exe_length == 0 || exe_length >= MAX_PATH) {
    return;
  }

  // 去掉文件名，得到 exe 所在目录。
  std::wstring dir(exe_path, exe_length);
  const size_t separator = dir.find_last_of(L"\\/");
  if (separator == std::wstring::npos) {
    return;
  }
  dir = dir.substr(0, separator);

  const std::wstring udf = dir + L"\\AppData\\temp\\webview2";

  // 逐级创建目录（CreateDirectoryW 只会创建最后一级）。
  const size_t first = udf.find(L"\\");
  if (first == std::wstring::npos) {
    return;
  }
  size_t position = first;
  while (position != std::wstring::npos) {
    position = udf.find(L'\\', position + 1);
    const std::wstring part =
        position == std::wstring::npos ? udf : udf.substr(0, position);
    ::CreateDirectoryW(part.c_str(), nullptr);
  }

  ::SetEnvironmentVariableW(L"WEBVIEW2_USER_DATA_FOLDER", udf.c_str());
}

std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr) {
    return std::string();
  }
  unsigned int target_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      -1, nullptr, 0, nullptr, nullptr)
    -1; // remove the trailing null character
  int input_length = (int)wcslen(utf16_string);
  std::string utf8_string;
  if (target_length == 0 || target_length > utf8_string.max_size()) {
    return utf8_string;
  }
  utf8_string.resize(target_length);
  int converted_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, utf8_string.data(), target_length, nullptr, nullptr);
  if (converted_length == 0) {
    return std::string();
  }
  return utf8_string;
}
