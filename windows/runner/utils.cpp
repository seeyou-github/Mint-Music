#include "utils.h"

#include <flutter_windows.h>
#include <io.h>
#include <stdio.h>
#include <windows.h>

#include <iostream>

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

namespace {

// Returns the process age in milliseconds, i.e. how long ago the process was
// created. This includes the time Windows spent loading DLLs and any antivirus
// pre-scan before `wWinMain` was reached.
unsigned long long ProcessAgeInMilliseconds() {
  FILETIME creation_time, exit_time, kernel_time, user_time;
  if (!::GetProcessTimes(::GetCurrentProcess(), &creation_time, &exit_time,
                         &kernel_time, &user_time)) {
    return 0;
  }

  FILETIME now_time;
  ::GetSystemTimeAsFileTime(&now_time);

  ULARGE_INTEGER created;
  created.LowPart = creation_time.dwLowDateTime;
  created.HighPart = creation_time.dwHighDateTime;

  ULARGE_INTEGER now;
  now.LowPart = now_time.dwLowDateTime;
  now.HighPart = now_time.dwHighDateTime;

  // FILETIME ticks are 100 ns, so the difference is divided by 10000 for ms.
  return (now.QuadPart - created.QuadPart) / 10000ULL;
}

}  // namespace

void LogStartupEvent(const char* stage) {
  wchar_t temp_path[MAX_PATH + 1];
  const DWORD length = ::GetTempPathW(MAX_PATH, temp_path);
  if (length == 0 || length > static_cast<DWORD>(MAX_PATH)) {
    return;
  }

  std::wstring log_path(temp_path);
  log_path += L"mintmusic_startup.log";

  SYSTEMTIME now;
  ::GetLocalTime(&now);

  FILE* file = nullptr;
  if (_wfopen_s(&file, log_path.c_str(), L"a") != 0 || file == nullptr) {
    return;
  }

  ::fprintf(file,
            "[runner] %04d-%02d-%02d %02d:%02d:%02d.%03d age=%llums %s\n",
            now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute,
            now.wSecond, now.wMilliseconds, ProcessAgeInMilliseconds(), stage);
  ::fclose(file);
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
