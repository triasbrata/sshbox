#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <windowsx.h>

#include <algorithm>
#include <fstream>
#include <optional>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

// Declared in the engine's flutter_windows_internal.h, not in the public
// header, and exported by flutter_windows.dll all the same, as a dumpbin of
// Flutter 3.47.2's own showed. A window after the first is a second view on
// the first's engine, and these are how one is made and how the engine is
// found from the id the app sends.
extern "C" {
typedef struct {
  int width;
  int height;
} FlutterDesktopViewControllerProperties;

FlutterDesktopViewControllerRef FlutterDesktopEngineCreateViewController(
    FlutterDesktopEngineRef engine,
    const FlutterDesktopViewControllerProperties* properties);

FlutterDesktopEngineRef FlutterDesktopEngineForId(int64_t engine_id);
}

namespace {

// Posted to the first window to free a window after the first that has been
// destroyed, off the stack of its own message.
constexpr UINT kFreeWindow = WM_APP + 1;

// The windows, for the one that runs the app's channels: the first window
// owns the engine, and the others are made on it.
struct Windows {
  FlutterDesktopEngineRef engine = nullptr;
  FlutterWindow* first = nullptr;
  std::vector<FlutterWindow*> others;
  flutter::MethodChannel<flutter::EncodableValue>* window_channel = nullptr;
  flutter::MethodChannel<flutter::EncodableValue>* windows_channel = nullptr;
  // The app asked for several windows, so it is asked before one closes.
  bool multi = false;
  // The first window hidden after it was closed while others stay up, to be
  // shown again by the next window the app opens.
  bool first_hidden = false;
  int next_id = 1;
};

Windows g_windows;

// A number the app sent: Dart's int reaches here as 32 or 64 bits, and a
// double as a double.
std::optional<double> NumberOf(const flutter::EncodableValue* value) {
  if (value == nullptr) return std::nullopt;
  if (const auto* i = std::get_if<int32_t>(value)) return *i;
  if (const auto* l = std::get_if<int64_t>(value)) return static_cast<double>(*l);
  if (const auto* d = std::get_if<double>(value)) return *d;
  return std::nullopt;
}

const flutter::EncodableValue* Field(const flutter::EncodableValue* map,
                                     const char* key) {
  if (map == nullptr) return nullptr;
  const auto* entries = std::get_if<flutter::EncodableMap>(map);
  if (entries == nullptr) return nullptr;
  auto found = entries->find(flutter::EncodableValue(key));
  return found == entries->end() ? nullptr : &found->second;
}

// The frame the app sent for a window, if it is one: each number within
// ±100000 and a size of at least 200 by 150.
bool FrameOf(const flutter::EncodableValue* map, RECT* rect, bool* maximized) {
  double n[4];
  const char* keys[4] = {"x", "y", "width", "height"};
  for (int i = 0; i < 4; i++) {
    auto value = NumberOf(Field(map, keys[i]));
    if (!value || *value < -100000 || *value > 100000) return false;
    n[i] = *value;
  }
  if (n[2] < 200 || n[3] < 150) return false;
  rect->left = static_cast<LONG>(n[0]);
  rect->top = static_cast<LONG>(n[1]);
  rect->right = static_cast<LONG>(n[0] + n[2]);
  rect->bottom = static_cast<LONG>(n[1] + n[3]);
  const auto* flag = Field(map, "maximized");
  const auto* on = flag == nullptr ? nullptr : std::get_if<bool>(flag);
  *maximized = on != nullptr && *on;
  return true;
}

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

// Where the window is kept, in the app's own data folder — the one
// path_provider names for Dart — as one line: left top right bottom
// maximized. Minimized is never kept.
std::wstring PlacementPath() {
  wchar_t appdata[MAX_PATH];
  DWORD length = GetEnvironmentVariableW(L"APPDATA", appdata, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) return L"";
  std::wstring dir = std::wstring(appdata) + L"\\cloud.brata";
  CreateDirectoryW(dir.c_str(), nullptr);
  dir += L"\\Jeansh";
  CreateDirectoryW(dir.c_str(), nullptr);
  return dir + L"\\window.txt";
}

constexpr UINT_PTR kSaveTimer = 1;

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::FlutterWindow(FlutterDesktopEngineRef engine, int id)
    : project_(L"data"), engine_(engine), id_(id) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  // The caption goes (see WM_NCCALCSIZE), measured again now that it has.
  SetWindowPos(GetHandle(), nullptr, 0, 0, 0, 0,
               SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                   SWP_NOACTIVATE);
  RECT frame;
  if (engine_ != nullptr) {
    // A window after the first: a view of its own on the engine the first
    // window runs. Shown by whoever made it, once it is in place.
    frame = GetClientArea();
    FlutterDesktopViewControllerProperties properties{
        static_cast<int>(frame.right - frame.left),
        static_cast<int>(frame.bottom - frame.top)};
    controller_ = FlutterDesktopEngineCreateViewController(engine_, &properties);
    if (controller_ == nullptr) return false;
    view_id_ = FlutterDesktopViewControllerGetViewId(controller_);
    view_ = FlutterDesktopViewGetHWND(
        FlutterDesktopViewControllerGetView(controller_));
    SetChildContent(view_);
    if (g_view_proc == nullptr) {
      g_view_proc = reinterpret_cast<WNDPROC>(
          GetWindowLongPtr(view_, GWLP_WNDPROC));
    }
    SetWindowLongPtr(view_, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(ViewProc));
    return true;
  }

  // Still hidden: it shows at the first frame, already in place.
  RestorePlacement();

  frame = GetClientArea();

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
  windows_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "sshbox/windows",
          &flutter::StandardMethodCodec::GetInstance());
  windows_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        OnWindowsCall(call, std::move(result));
      });
  g_windows.first = this;
  g_windows.window_channel = window_channel_.get();
  g_windows.windows_channel = windows_channel_.get();
  view_ = flutter_controller_->view()->GetNativeWindow();
  SetChildContent(view_);
  g_view_proc = reinterpret_cast<WNDPROC>(SetWindowLongPtr(
      view_, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(ViewProc)));

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
  if (engine_ != nullptr) {
    // A window after the first: its view goes, and the engine stays.
    if (controller_ != nullptr) {
      FlutterDesktopViewControllerDestroy(controller_);
      controller_ = nullptr;
      auto& others = g_windows.others;
      others.erase(std::remove(others.begin(), others.end(), this),
                   others.end());
      NotifyWindows("closed", flutter::EncodableValue(id_));
      if (g_windows.first != nullptr && g_windows.first->GetHandle()) {
        PostMessage(g_windows.first->GetHandle(), kFreeWindow, 0,
                    reinterpret_cast<LPARAM>(this));
      }
    }
    Win32Window::OnDestroy();
    return;
  }

  g_windows.first = nullptr;
  g_windows.window_channel = nullptr;
  g_windows.windows_channel = nullptr;
  window_channel_ = nullptr;
  windows_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::RestorePlacement() {
  std::ifstream file(PlacementPath());
  long v[5];
  for (long& value : v) {
    // Each within ±100000: a file cut short, written by hand or out of
    // range leaves the window where it would have been.
    if (!(file >> value) || value < -100000 || value > 100000) return;
  }
  ApplyPlacement({v[0], v[1], v[2], v[3]}, v[4] != 0);
}

// Puts the window at |rect|, in physical pixels, brought wholly onto a
// monitor it can be moved from, and says whether it shows maximized.
void FlutterWindow::ApplyPlacement(RECT rect, bool maximized) {
  LONG width = rect.right - rect.left, height = rect.bottom - rect.top;
  if (width < 200 || height < 150) return;
  // The monitor its top strip, the part that moves it, is on; when that is
  // on none — a laptop undocked, a screen unplugged — the main one, centred.
  // Either way it comes back no bigger than that monitor's work area and
  // wholly on it, so a window sized for a bigger screen keeps its buttons in
  // reach.
  RECT strip = {rect.left, rect.top, rect.right, rect.top + 40};
  HMONITOR monitor = MonitorFromRect(&strip, MONITOR_DEFAULTTONULL);
  bool seen = monitor != nullptr;
  if (!seen) monitor = MonitorFromPoint({0, 0}, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO info{sizeof(info)};
  GetMonitorInfo(monitor, &info);
  const RECT& work = info.rcWork;
  width = std::min(width, work.right - work.left);
  height = std::min(height, work.bottom - work.top);
  if (seen) {
    rect.left = std::clamp(rect.left, work.left, work.right - width);
    rect.top = std::clamp(rect.top, work.top, work.bottom - height);
  } else {
    rect.left = work.left + (work.right - work.left - width) / 2;
    rect.top = work.top + (work.bottom - work.top - height) / 2;
  }
  rect.right = rect.left + width;
  rect.bottom = rect.top + height;
  // Twice: a move onto a monitor of another DPI scales the window to suit
  // it (WM_DPICHANGED), and the second, at that DPI already, puts it back
  // at the size it was.
  for (int i = 0; i < 2; i++) {
    SetWindowPos(GetHandle(), nullptr, rect.left, rect.top, width, height,
                 SWP_NOZORDER | SWP_NOACTIVATE);
  }
  normal_ = rect;
  if (maximized) show_command_ = SW_SHOWMAXIMIZED;
}

void FlutterWindow::SavePlacement() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr || IsRectEmpty(&normal_)) return;
  // Minimized, IsZoomed says no: whether it goes back to maximized is the
  // placement's to say.
  bool maximized = IsZoomed(hwnd);
  if (IsIconic(hwnd)) {
    WINDOWPLACEMENT placement{sizeof(placement)};
    maximized = GetWindowPlacement(hwnd, &placement) &&
                (placement.flags & WPF_RESTORETOMAXIMIZED);
  }
  std::ofstream(PlacementPath())
      << normal_.left << ' ' << normal_.top << ' ' << normal_.right << ' '
      << normal_.bottom << ' ' << (maximized ? 1 : 0) << '\n';
}

void FlutterWindow::OnWindowCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // A window after the first says which it is, in a map beside what it asks.
  const flutter::EncodableValue* arguments = call.arguments();
  FlutterWindow* target = this;
  if (const auto* view = Field(arguments, "view")) {
    target = nullptr;
    if (auto id = NumberOf(view)) {
      for (FlutterWindow* other : g_windows.others) {
        if (other->view_id_ == static_cast<int64_t>(*id)) target = other;
      }
    }
    if (target == nullptr) {
      result->Success();
      return;
    }
    arguments = Field(arguments, "arguments");
  }
  target->HandleWindowCall(call.method_name(), arguments, std::move(result));
}

void FlutterWindow::HandleWindowCall(
    const std::string& method, const flutter::EncodableValue* arguments,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  HWND hwnd = GetHandle();
  if (method == "drag") {
    BeginMove();
  } else if (method == "minimize") {
    ShowWindow(hwnd, SW_MINIMIZE);
  } else if (method == "maximize") {
    ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
  } else if (method == "close") {
    PostMessage(hwnd, WM_CLOSE, 0, 0);
  } else if (method == "maximizeButton") {
    const auto* edges =
        arguments == nullptr
            ? nullptr
            : std::get_if<std::vector<double>>(arguments);
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
  if (view_ == nullptr) return;
  HWND view = view_;
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
  if (hover == maximize_hover_ || g_windows.window_channel == nullptr) return;
  maximize_hover_ = hover;
  Notify("maximizeHover", hover);
}

// Tells the app a state of this window: as a plain boolean for the first
// window, and with the view it is for beside it for another.
void FlutterWindow::Notify(const char* method, bool value) {
  if (g_windows.window_channel == nullptr) return;
  flutter::EncodableValue said(value);
  if (id_ != 0) {
    said = flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("view"), flutter::EncodableValue(view_id_)},
        {flutter::EncodableValue("value"), flutter::EncodableValue(value)}});
  }
  g_windows.window_channel->InvokeMethod(
      method, std::make_unique<flutter::EncodableValue>(std::move(said)));
}

void FlutterWindow::NotifyWindows(const char* method,
                                  flutter::EncodableValue value) {
  if (!g_windows.multi || g_windows.windows_channel == nullptr) return;
  g_windows.windows_channel->InvokeMethod(
      method, std::make_unique<flutter::EncodableValue>(std::move(value)));
}

// Tells the app where the window is, once it has held still.
void FlutterWindow::NotifyMoved() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr || IsRectEmpty(&normal_)) return;
  NotifyWindows(
      "moved",
      flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("id"), flutter::EncodableValue(id_)},
          {flutter::EncodableValue("x"),
           flutter::EncodableValue(static_cast<double>(normal_.left))},
          {flutter::EncodableValue("y"),
           flutter::EncodableValue(static_cast<double>(normal_.top))},
          {flutter::EncodableValue("width"),
           flutter::EncodableValue(
               static_cast<double>(normal_.right - normal_.left))},
          {flutter::EncodableValue("height"),
           flutter::EncodableValue(
               static_cast<double>(normal_.bottom - normal_.top))},
          {flutter::EncodableValue("maximized"),
           flutter::EncodableValue(IsZoomed(hwnd) != 0)}}));
}

// What the app asks of its windows. Only the first window's channel hears
// it: the others are made and closed from here.
void FlutterWindow::OnWindowsCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  const flutter::EncodableValue* arguments = call.arguments();

  if (method == "supported") {
    // The engine is found by the id the app sends.
    if (auto id = NumberOf(arguments)) {
      g_windows.engine = FlutterDesktopEngineForId(static_cast<int64_t>(*id));
    }
    g_windows.multi = g_windows.engine != nullptr;
    result->Success(flutter::EncodableValue(g_windows.multi));
  } else if (method == "open" && g_windows.multi) {
    RECT rect;
    bool maximized = false;
    bool framed = FrameOf(arguments, &rect, &maximized);
    if (g_windows.first_hidden) {
      // The first window comes back before a new one is made.
      g_windows.first_hidden = false;
      HWND hwnd = GetHandle();
      SetWindowTextW(hwnd, L"Jeansh");
      if (framed) ApplyPlacement(rect, maximized);
      ShowWindow(hwnd, maximized ? SW_SHOWMAXIMIZED : SW_SHOW);
      SetForegroundWindow(hwnd);
      NotifyWindows("opened", flutter::EncodableValue(flutter::EncodableMap{
                                  {flutter::EncodableValue("id"),
                                   flutter::EncodableValue(0)},
                                  {flutter::EncodableValue("viewId"),
                                   flutter::EncodableValue(0)}}));
      result->Success(flutter::EncodableValue(0));
      return;
    }
    int id = g_windows.next_id++;
    auto* window = new FlutterWindow(g_windows.engine, id);
    // Each a little lower and to the right of the last, as a window manager
    // would place them; a saved frame replaces that.
    unsigned int step = 40 * static_cast<unsigned int>(id % 8);
    if (!window->Create(L"Jeansh", Point(10 + step, 10 + step),
                        Size(1280, 720))) {
      delete window;
      result->Error("no-window", "The window could not be made");
      return;
    }
    if (framed) window->ApplyPlacement(rect, maximized);
    window->Show();
    g_windows.others.push_back(window);
    NotifyWindows("opened", flutter::EncodableValue(flutter::EncodableMap{
                                {flutter::EncodableValue("id"),
                                 flutter::EncodableValue(id)},
                                {flutter::EncodableValue("viewId"),
                                 flutter::EncodableValue(window->view_id_)}}));
    result->Success(flutter::EncodableValue(id));
  } else if (method == "close" && arguments != nullptr &&
             NumberOf(arguments).has_value()) {
    int id = static_cast<int>(*NumberOf(arguments));
    FlutterWindow* target = nullptr;
    for (FlutterWindow* other : g_windows.others) {
      if (other->id_ == id) target = other;
    }
    if (id == 0) {
      if (g_windows.others.empty()) {
        // The last window: the app quits, and keeps where it was.
        force_close_ = true;
        PostMessage(GetHandle(), WM_CLOSE, 0, 0);
      } else {
        // Hidden, not destroyed: its view is the engine's first, which has
        // to stay. A title of its own, so a second Jeansh started now finds
        // a window that is up.
        KillTimer(GetHandle(), kSaveTimer);
        SavePlacement();
        SetWindowTextW(GetHandle(), L"Jeansh (hidden)");
        ShowWindow(GetHandle(), SW_HIDE);
        g_windows.first_hidden = true;
      }
    } else if (target != nullptr) {
      if (g_windows.first_hidden && g_windows.others.size() == 1) {
        // The last window left is this one: the app quits.
        PostQuitMessage(0);
      } else {
        target->force_close_ = true;
        PostMessage(target->GetHandle(), WM_CLOSE, 0, 0);
      }
    }
    result->Success();
  } else if (method == "activate" && arguments != nullptr &&
             NumberOf(arguments).has_value()) {
    int id = static_cast<int>(*NumberOf(arguments));
    HWND hwnd = id == 0 ? GetHandle() : nullptr;
    for (FlutterWindow* other : g_windows.others) {
      if (other->id_ == id) hwnd = other->GetHandle();
    }
    if (hwnd != nullptr) {
      if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
      SetForegroundWindow(hwnd);
    }
    result->Success();
  } else {
    result->NotImplemented();
  }
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
        ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
        return 0;
      }
      break;
    // Kept as it changes rather than at close: an update restarts the app
    // with exit(), which closes nothing. Half a second after the last
    // change, so a drag writes once. A minimized window keeps what it had.
    case WM_WINDOWPOSCHANGED:
      if (IsWindowVisible(hwnd) && !IsIconic(hwnd)) {
        if (!IsZoomed(hwnd)) GetWindowRect(hwnd, &normal_);
        SetTimer(hwnd, kSaveTimer, 500, nullptr);
      }
      break;
    case WM_TIMER:
      if (wparam == kSaveTimer) {
        KillTimer(hwnd, kSaveTimer);
        if (engine_ == nullptr) SavePlacement();
        NotifyMoved();
        return 0;
      }
      break;
    case WM_CLOSE:
      // The app decides whether the window goes, and says so with `close`.
      if (g_windows.multi && !force_close_) {
        NotifyWindows("closeRequested", flutter::EncodableValue(id_));
        return 0;
      }
      KillTimer(hwnd, kSaveTimer);
      if (engine_ == nullptr) SavePlacement();
      break;
    case WM_ACTIVATE:
      if (LOWORD(wparam) != WA_INACTIVE) {
        NotifyWindows("focused", flutter::EncodableValue(id_));
      }
      break;
    case kFreeWindow:
      if (id_ == 0 && lparam != 0) {
        delete reinterpret_cast<FlutterWindow*>(lparam);
        return 0;
      }
      break;
    case WM_SIZE:
      if (wparam != SIZE_MINIMIZED && g_windows.window_channel != nullptr) {
        bool maximized = wparam == SIZE_MAXIMIZED;
        if (maximized != maximized_) {
          maximized_ = maximized;
          Notify("maximized", maximized);
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
  } else if (controller_ != nullptr) {
    LRESULT handled = 0;
    if (FlutterDesktopViewControllerHandleTopLevelWindowProc(
            controller_, hwnd, message, wparam, lparam, &handled)) {
      return handled;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
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
