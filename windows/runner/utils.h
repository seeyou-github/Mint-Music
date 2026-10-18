#ifndef RUNNER_UTILS_H_
#define RUNNER_UTILS_H_

#include <string>
#include <vector>

// Creates a console for the process, and redirects stdout and stderr to
// it for both the runner and the Flutter library.
void CreateAndAttachConsole();

// Appends a startup timing line to `%TEMP%\mintmusic_startup.log`.
//
// Used to diagnose the "window takes a long time to appear on Windows" issue:
// the Flutter runner keeps the window hidden until the first frame is
// rendered, so any stall before that looks like the app never starts. Each
// line records the wall clock, the process age (ms since the process was
// created, which exposes DLL loading / antivirus pre-scan time) and the stage.
// The Dart side writes to the same file, so both halves can be compared.
//
// Never throws; a failure to write is ignored.
void LogStartupEvent(const char* stage);

// Takes a null-terminated wchar_t* encoded in UTF-16 and returns a std::string
// encoded in UTF-8. Returns an empty std::string on failure.
std::string Utf8FromUtf16(const wchar_t* utf16_string);

// Gets the command line arguments passed in as a std::vector<std::string>,
// encoded in UTF-8. Returns an empty std::vector<std::string> on failure.
std::vector<std::string> GetCommandLineArguments();

#endif  // RUNNER_UTILS_H_
