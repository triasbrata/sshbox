#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Help › Check for updates…
constexpr UINT kCheckForUpdates = 1001;

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  // A Help menu in the window's own menu bar, before the client area is
  // measured, since the bar takes its height from it. No mnemonic: Alt
  // belongs to the program in the terminal, and the menu to the mouse.
  HMENU help = CreatePopupMenu();
  AppendMenu(help, MF_STRING, kCheckForUpdates, L"Check for updates\u2026");
  HMENU bar = CreateMenu();
  AppendMenu(bar, MF_POPUP, reinterpret_cast<UINT_PTR>(help), L"Help");
  SetMenu(GetHandle(), bar);

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
  menu_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "sshbox/menu",
          &flutter::StandardMethodCodec::GetInstance());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

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
  menu_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
    case WM_COMMAND:
      if (LOWORD(wparam) == kCheckForUpdates && menu_channel_) {
        menu_channel_->InvokeMethod("checkForUpdates", nullptr);
        return 0;
      }
      break;
    case WM_SYSCOMMAND:
      // Alt, F10 or Alt+letter would put the keyboard in the menu bar, and a
      // terminal wants those keys for its program. Alt+Space, the window
      // menu, still opens.
      if ((wparam & 0xFFF0) == SC_KEYMENU && lparam != ' ') return 0;
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
