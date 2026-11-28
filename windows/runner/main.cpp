#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include <csignal>
#include <cstdlib>
#include <exception>

#include "runner_log.h"
#include "utils.h"

namespace {
LONG WINAPI OnUnhandled(EXCEPTION_POINTERS* info) {
  runner_log::Write("unhandled exception %08lx at %p",
                    info->ExceptionRecord->ExceptionCode,
                    info->ExceptionRecord->ExceptionAddress);
  // Where: the module and the offset in it, for the caller and the frames
  // above it.
  void* frames[24];
  USHORT count = CaptureStackBackTrace(0, 24, frames, nullptr);
  void* at = info->ExceptionRecord->ExceptionAddress;
  for (USHORT i = 0; i <= count; i++) {
    void* address = i == 0 ? at : frames[i - 1];
    HMODULE module = nullptr;
    wchar_t name[MAX_PATH] = L"?";
    if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                               GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           reinterpret_cast<LPCWSTR>(address), &module)) {
      GetModuleFileNameW(module, name, MAX_PATH);
    }
    const wchar_t* base = wcsrchr(name, L'\\');
    runner_log::Write("  frame %u: %ls+0x%llx", i, base ? base + 1 : name,
                      static_cast<unsigned long long>(
                          reinterpret_cast<uintptr_t>(address) -
                          reinterpret_cast<uintptr_t>(module)));
  }
  return EXCEPTION_CONTINUE_SEARCH;
}
void OnInvalidParameter(const wchar_t*, const wchar_t*, const wchar_t*,
                        unsigned int, uintptr_t) {
  runner_log::Write("invalid parameter handler");
}
void OnAbort(int) { runner_log::Write("SIGABRT"); }
void OnTerminate() {
  runner_log::Write("std::terminate");
  std::abort();
}
void OnExit() { runner_log::Write("atexit: process exiting"); }
}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  runner_log::Write("---- start, pid %lu", GetCurrentProcessId());
  ::SetUnhandledExceptionFilter(OnUnhandled);
  _set_invalid_parameter_handler(OnInvalidParameter);
  std::signal(SIGABRT, OnAbort);
  std::set_terminate(OnTerminate);
  std::atexit(OnExit);

  // One Jeansh at a time, as on Android, macOS and Linux: started again, it
  // brings the window already up forward and leaves, since two copies would
  // each save their own tabs over the other's. The mutex goes with the
  // process.
  ::CreateMutexW(nullptr, FALSE, L"Local\\cloud.brata.terminal");
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND running = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Jeansh");
    if (running != nullptr) {
      ::ShowWindow(running, ::IsIconic(running) ? SW_RESTORE : SW_SHOW);
      ::SetForegroundWindow(running);
    }
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Jeansh", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  runner_log::Write("message loop ended, wParam %lld", (long long)msg.wParam);
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
