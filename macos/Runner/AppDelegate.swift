import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// The app menu's Settings… (⌘,), wired in MainMenu.xib. A click lands
  /// here and is handed to Dart, which opens the page. The key itself is
  /// taken in Dart before the menu is asked, so it reaches here only when
  /// nothing in the window has focus.
  @IBAction func openSettings(_ sender: Any?) { menu("openSettings") }

  /// The app menu's Check for Updates…, under About: Dart runs the check
  /// Settings runs, and answers.
  @IBAction func checkForUpdates(_ sender: Any?) { menu("checkForUpdates") }

  /// View › Zoom In, Zoom Out and Actual Size (⌘+, ⌘− and ⌘0): the UI text
  /// size's steps. Dart takes the keys first, so a click is what lands here.
  @IBAction func zoomIn(_ sender: Any?) { menu("zoomIn") }
  @IBAction func zoomOut(_ sender: Any?) { menu("zoomOut") }
  @IBAction func zoomReset(_ sender: Any?) { menu("zoomReset") }

  private func menu(_ method: String) {
    guard let flutter = mainFlutterWindow?.contentViewController as? FlutterViewController
    else { return }
    FlutterMethodChannel(name: "sshbox/menu", binaryMessenger: flutter.engine.binaryMessenger)
      .invokeMethod(method, arguments: nil)
  }
}
