#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <windowsx.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

// The Flutter view's own window procedure, which ViewProc hands on to.
WNDPROC g_view_proc = nullptr;

// The Flutter view fills the whole client area, so Windows asks it, not the
// window, what is under the pointer. Where the window has an answer of its
// own — the top resize edge, the maximize button — the view stands aside
// and Windows asks the window under it.
LRESULT CALLBACK ViewProc(HWND view, UINT message, WPARAM wparam,
                          LPARAM lparam) {
  if (message == WM_NCHITTEST &&
      SendMessage(GetParent(view), WM_NCHITTEST, wparam, lparam) !=
          HTCLIENT) {
    return HTTRANSPARENT;
  }
  return CallWindowProc(g_view_proc, view, message, wparam, lparam);
}

// How far into the window its top resize edge reaches, as tall as the frame
// Windows would have drawn there.
int FrameHeight(HWND hwnd) {
  UINT dpi = GetDpiForWindow(hwnd);
  return GetSystemMetricsForDpi(SM_CYFRAME, dpi) +
         GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  // The caption goes (see WM_NCCALCSIZE), measured again now that it has.
  SetWindowPos(GetHandle(), nullptr, 0, 0, 0, 0,
               SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                   SWP_NOACTIVATE);

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
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "sshbox/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        OnWindowCall(call, std::move(result));
      });
  HWND view = flutter_controller_->view()->GetNativeWindow();
  SetChildContent(view);
  g_view_proc = reinterpret_cast<WNDPROC>(SetWindowLongPtr(
      view, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(ViewProc)));

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
  window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::OnWindowCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  HWND hwnd = GetHandle();
  const std::string& method = call.method_name();
  if (method == "drag") {
    BeginMove();
  } else if (method == "minimize") {
    ShowWindow(hwnd, SW_MINIMIZE);
  } else if (method == "maximize") {
    ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
  } else if (method == "close") {
    PostMessage(hwnd, WM_CLOSE, 0, 0);
  } else if (method == "maximizeButton") {
    const auto* edges = std::get_if<std::vector<double>>(call.arguments());
    if (edges == nullptr || edges->size() != 4) {
      result->Error("bad-arguments", "left, top, right and bottom");
      return;
    }
    maximize_button_ = {static_cast<LONG>((*edges)[0]),
                        static_cast<LONG>((*edges)[1]),
                        static_cast<LONG>((*edges)[2]),
                        static_cast<LONG>((*edges)[3])};
  } else {
    result->NotImplemented();
    return;
  }
  result->Success();
}

void FlutterWindow::BeginMove() {
  // A click already let go leaves nothing to move, and the move below would
  // wait for the next press.
  int button = GetSystemMetrics(SM_SWAPBUTTON) ? VK_RBUTTON : VK_LBUTTON;
  if (!(GetAsyncKeyState(button) & 0x8000)) return;
  HWND hwnd = GetHandle();
  POINT at;
  GetCursorPos(&at);
  // Windows' own move, as a press on a title bar starts it: Aero snap, and a
  // maximized window let go of by dragging, come with it.
  ReleaseCapture();
  SendMessage(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, MAKELPARAM(at.x, at.y));
  // The move took the button's release, which Flutter would otherwise wait
  // for with the press held.
  if (!flutter_controller_) return;
  HWND view = flutter_controller_->view()->GetNativeWindow();
  GetCursorPos(&at);
  ScreenToClient(view, &at);
  PostMessage(view, WM_LBUTTONUP, 0, MAKELPARAM(at.x, at.y));
}

LRESULT FlutterWindow::HitTest(HWND hwnd, LPARAM lparam) {
  // The side and bottom edges are the frame Windows keeps.
  LRESULT hit = DefWindowProc(hwnd, WM_NCHITTEST, 0, lparam);
  switch (hit) {
    case HTLEFT:
    case HTRIGHT:
    case HTBOTTOM:
    case HTBOTTOMLEFT:
    case HTBOTTOMRIGHT:
    case HTTOPLEFT:
    case HTTOPRIGHT:
      return hit;
  }
  POINT at{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
  ScreenToClient(hwnd, &at);
  if (!IsZoomed(hwnd) && at.y >= 0 && at.y < FrameHeight(hwnd)) return HTTOP;
  // Windows 11 opens its snap layouts over what it is told is a maximize
  // button.
  if (PtInRect(&maximize_button_, at)) return HTMAXBUTTON;
  return HTCLIENT;
}

void FlutterWindow::SetMaximizeHover(bool hover) {
  if (hover == maximize_hover_ || !window_channel_) return;
  maximize_hover_ = hover;
  window_channel_->InvokeMethod(
      "maximizeHover", std::make_unique<flutter::EncodableValue>(hover));
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // No title bar: the app draws the tab strip there, and the window's
  // buttons at its right (title_bar.dart). The frame stays, for the resize
  // edges, the shadow and snapping.
  switch (message) {
    case WM_NCCALCSIZE: {
      if (!wparam) break;
      auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
      const LONG top = params->rgrc[0].top;
      DefWindowProc(hwnd, message, wparam, lparam);
      // Everything Windows took but the caption's and the top edge's room.
      // Maximized, the window runs past the screen by its frame on every
      // side, and that much stays off the top.
      params->rgrc[0].top = top + (IsZoomed(hwnd) ? FrameHeight(hwnd) : 0);
      return 0;
    }
    case WM_NCHITTEST:
      return HitTest(hwnd, lparam);
    case WM_NCMOUSEMOVE:
      SetMaximizeHover(wparam == HTMAXBUTTON);
      if (wparam == HTMAXBUTTON) {
        TRACKMOUSEEVENT track{sizeof(track), TME_LEAVE | TME_NONCLIENT, hwnd,
                              0};
        TrackMouseEvent(&track);
      }
      break;
    case WM_NCMOUSELEAVE:
      SetMaximizeHover(false);
      break;
    // Windows would draw a classic caption button of its own for these.
    case WM_NCLBUTTONDOWN:
    case WM_NCLBUTTONDBLCLK:
      if (wparam == HTMAXBUTTON) return 0;
      break;
    case WM_NCLBUTTONUP:
      if (wparam == HTMAXBUTTON) {
        /* mutation */;
        return 0;
      }
      break;
    case WM_SIZE:
      if (wparam != SIZE_MINIMIZED && window_channel_) {
        bool maximized = wparam == SIZE_MAXIMIZED;
        if (maximized != maximized_) {
          maximized_ = maximized;
          window_channel_->InvokeMethod(
              "maximized", std::make_unique<flutter::EncodableValue>(maximized));
        }
      }
      break;
  }

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
    case WM_SYSCOMMAND:
      // Alt, F10 or Alt+letter would put the keyboard in the window menu,
      // and a terminal wants those keys for its program. Alt+Space, the
      // window menu, still opens.
      if ((wparam & 0xFFF0) == SC_KEYMENU && lparam != ' ') return 0;
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
