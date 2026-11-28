#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter_windows.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
//
// The first window owns the engine, through the client wrapper's view
// controller. The windows after it, which the app opens over
// sshbox/windows, each host a view of their own on that same engine, made
// through the engine's C API.
class FlutterWindow : public Win32Window {
 public:
  // Creates the first FlutterWindow, hosting a Flutter view running
  // |project|.
  explicit FlutterWindow(const flutter::DartProject& project);

  // Creates a window after the first, hosting a new view on |engine|, which
  // the app knows as window |id|.
  FlutterWindow(FlutterDesktopEngineRef engine, int id);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // What the app's window buttons and tab strip ask of the window. A window
  // after the first is asked on the first's channel, and says which it is.
  void OnWindowCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleWindowCall(
      const std::string& method, const flutter::EncodableValue* arguments,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // What the app asks of its windows: open one, close one, raise one.
  void OnWindowsCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Tells the app something about this window.
  void Notify(const char* method, bool value);
  void NotifyWindows(const char* method, flutter::EncodableValue value);
  void NotifyMoved();

  // Takes the view of a window after the first off the engine.
  void ReleaseView();

  // A window the app closes waits out of sight for the next it opens.
  void Park();
  void Unpark(int id);

  // Moves the window with the mouse, from a press on the tab strip.
  void BeginMove();

  // What is under the pointer at |lparam|, a point on the screen.
  LRESULT HitTest(HWND hwnd, LPARAM lparam);

  // Tells the app the pointer is over its maximize button, or has left it.
  void SetMaximizeHover(bool hover);

  // The window where it was last time, at the size it was; and kept as it
  // changes. See flutter_window.cpp.
  void RestorePlacement();
  void ApplyPlacement(RECT rect, bool maximized);
  void SavePlacement();

  // The project to run, for the first window.
  flutter::DartProject project_;

  // The Flutter instance hosted by the first window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // A window after the first: the engine it shares, and its own view.
  FlutterDesktopEngineRef engine_ = nullptr;
  FlutterDesktopViewControllerRef controller_ = nullptr;

  // The app's name for this window, 0 for the first, and Flutter's for its
  // view.
  int id_ = 0;
  int64_t view_id_ = 0;
  HWND view_ = nullptr;

  // The app has said this window may go: its close is not asked of the app.
  bool force_close_ = false;
  // The view of a window after the first was released by `close`, and the
  // window's destruction has yet to tell the app.
  bool released_ = false;

  // sshbox/window: the app asks the window to move, minimize, maximize and
  // close on it, and says where its maximize button is; the window says on
  // it when it is maximized or restored, and when the pointer is over that
  // button. The first window's.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;

  // sshbox/windows, the first window's too.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      windows_channel_;

  // The app's maximize button, in the client area's physical pixels.
  RECT maximize_button_{};
  bool maximize_hover_ = false;
  bool maximized_ = false;

  // The window's rectangle while neither maximized nor minimized, a snapped
  // one included, in physical pixels on the screen.
  RECT normal_{};
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
