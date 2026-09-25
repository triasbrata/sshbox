#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // What the app's window buttons and tab strip ask of the window.
  void OnWindowCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Moves the window with the mouse, from a press on the tab strip.
  void BeginMove();

  // What is under the pointer at |lparam|, a point on the screen.
  LRESULT HitTest(HWND hwnd, LPARAM lparam);

  // Tells the app the pointer is over its maximize button, or has left it.
  void SetMaximizeHover(bool hover);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // sshbox/window: the app asks the window to move, minimize, maximize and
  // close on it, and says where its maximize button is; the window says on
  // it when it is maximized or restored, and when the pointer is over that
  // button.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;

  // The app's maximize button, in the client area's physical pixels.
  RECT maximize_button_{};
  bool maximize_hover_ = false;
  bool maximized_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
