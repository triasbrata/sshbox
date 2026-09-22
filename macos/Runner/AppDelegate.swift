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
  @IBAction func openSettings(_ sender: Any?) {
    guard let flutter = mainFlutterWindow?.contentViewController as? FlutterViewController
    else { return }
    FlutterMethodChannel(name: "sshbox/menu", binaryMessenger: flutter.engine.binaryMessenger)
      .invokeMethod("openSettings", arguments: nil)
  }
}
