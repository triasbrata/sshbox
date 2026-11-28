#ifndef RUNNER_RUNNER_LOG_H_
#define RUNNER_RUNNER_LOG_H_

#include <windows.h>

#include <cstdarg>
#include <cstdio>
#include <string>

// A log the runner writes itself, to %APPDATA%\cloud.brata\Jeansh\runner.log,
// one line at a time and flushed through to the disk, so a process that ends
// without a word leaves how far it got. It says what the native side did to
// each window, and how the process ended: a quit, an exit, an abort or an
// exception. Never anything a user typed or saw.
namespace runner_log {

inline std::wstring Path() {
  wchar_t appdata[MAX_PATH];
  DWORD length = GetEnvironmentVariableW(L"APPDATA", appdata, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) return L"";
  std::wstring dir = std::wstring(appdata) + L"\\cloud.brata";
  CreateDirectoryW(dir.c_str(), nullptr);
  dir += L"\\Jeansh";
  CreateDirectoryW(dir.c_str(), nullptr);
  return dir + L"\\runner.log";
}

inline void Write(const char* format, ...) {
  static const std::wstring path = Path();
  if (path.empty()) return;
  char text[512];
  va_list args;
  va_start(args, format);
  int n = vsnprintf(text, sizeof(text) - 2, format, args);
  va_end(args);
  if (n < 0) return;
  if (n > static_cast<int>(sizeof(text)) - 3) n = sizeof(text) - 3;
  SYSTEMTIME t;
  GetLocalTime(&t);
  char line[640];
  int m = snprintf(line, sizeof(line), "%02d:%02d:%02d.%03d [%lu] %.*s\r\n",
                   t.wHour, t.wMinute, t.wSecond, t.wMilliseconds,
                   GetCurrentThreadId(), n, text);
  if (m <= 0) return;
  HANDLE file = CreateFileW(path.c_str(), FILE_APPEND_DATA,
                            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                            OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  DWORD written = 0;
  WriteFile(file, line, static_cast<DWORD>(m), &written, nullptr);
  FlushFileBuffers(file);
  CloseHandle(file);
}

}  // namespace runner_log

#endif  // RUNNER_RUNNER_LOG_H_
