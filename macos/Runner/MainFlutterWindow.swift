import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

class MainFlutterWindow: NSWindow {
  /// Kept for as long as the window: it answers the tab strip's channel.
  private var titleBar: TitleBar?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    titleBar = TitleBar(window: self, controller: flutterViewController)

    // The same channel and method Android's MainActivity answers, so the Dart
    // side has one path: the copy is taken here and only its path crosses.
    // Nothing else on this channel is asked for on a Mac — `saveAs`,
    // `copyImage`, `open` and `shared` are Android's, and guarded there.
    let share = FlutterMethodChannel(
      name: "sshbox/share",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    share.setMethodCallHandler { call, result in
      guard call.method == "clipboardImage" else {
        result(FlutterMethodNotImplemented)
        return
      }
      // No limit rather than none allowed, for an argument that is not a
      // number: the Dart side always sends one, and failing open here beats
      // refusing every picture as too big.
      ClipboardImage.take(
        limit: (call.arguments as? NSNumber)?.intValue ?? Int.max,
        result: result)
    }

    super.awakeFromNib()
  }
}

/// The window's title bar, which the Flutter view runs up under so the tab
/// strip is drawn into it, as Chrome and VS Code draw theirs: one row, the
/// window's buttons at the left of the tabs. The buttons stay AppKit's, and
/// the title stays set, so Mission Control and the Window menu still read
/// Jeansh; it is only not drawn.
///
/// Nothing in the Flutter view moves the window by itself — FlutterView is
/// opaque, and a mouse-down on an opaque view never moves its window — so the
/// strip's empty space asks for it here, through `drag`. Not
/// isMovableByWindowBackground, which would move the window for a drag
/// anywhere in it, a selection in a terminal included.
final class TitleBar {
  private let window: NSWindow
  private weak var controller: FlutterViewController?
  private let channel: FlutterMethodChannel

  /// What the Dart side is told while full screen hides the buttons.
  private static let hidden: [String: Double] = ["inset": 0, "height": 0]

  /// The last measure taken outside full screen, sent again on the way out
  /// of it, before the buttons are back to be measured. AppKit's usual
  /// numbers until then, for a window that opens in full screen.
  private var measured: [String: Double] = ["inset": 78, "height": 28]

  init(window: NSWindow, controller: FlutterViewController) {
    self.window = window
    self.controller = controller
    channel = FlutterMethodChannel(
      name: "sshbox/window", binaryMessenger: controller.engine.binaryMessenger)

    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.styleMask.insert(.fullSizeContentView)

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      switch call.method {
      case "titleBar":
        result(self.window.styleMask.contains(.fullScreen) ? Self.hidden : self.measure())
      case "drag":
        self.drag()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // Full screen hides the buttons with the title bar and gives their room
    // back: once it is there, and before it leaves, so on neither way does a
    // button stand over a tab.
    let center = NotificationCenter.default
    _ = center.addObserver(
      forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main
    ) { [weak self] _ in
      self?.channel.invokeMethod("titleBar", arguments: Self.hidden)
    }
    _ = center.addObserver(
      forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      self.channel.invokeMethod("titleBar", arguments: self.measured)
    }
  }

  /// Where the tabs may start, and how tall the band is that a page other
  /// than the tabs keeps clear of. The tabs start past the zoom button by as
  /// much again as the close button stands off the window's edge, so the
  /// three buttons have the same margin either side.
  private func measure() -> [String: Double] {
    window.layoutIfNeeded()
    guard
      let close = window.standardWindowButton(.closeButton),
      let zoom = window.standardWindowButton(.zoomButton)
    else { return Self.hidden }
    measured = [
      "inset": Double(zoom.frame.maxX + close.frame.minX),
      "height": Double(window.frame.height - window.contentLayoutRect.height),
    ]
    return measured
  }

  /// A press on the strip's empty space: the window follows the mouse, as it
  /// does from a title bar, or for the second press of a double-click it does
  /// what System Settings says a double-click on a title bar does.
  private func drag() {
    // The press the strip heard is AppKit's current event only while the
    // button is still held. A click already over has nothing to drag, and
    // starting a drag for one could leave the window following the mouse.
    guard
      let event = window.currentEvent,
      event.type == .leftMouseDown || event.type == .leftMouseDragged,
      NSEvent.pressedMouseButtons & 1 != 0
    else { return }
    if event.type == .leftMouseDown && event.clickCount == 2 {
      doubleClick()
    } else {
      window.performDrag(with: event)
    }
    releaseInFlutter()
  }

  /// Zoom, minimise or nothing, as Desktop & Dock's "Double-click a window's
  /// title bar to" is set: zoom when it was never set, as macOS does, and for
  /// Fill, which has no public call of its own.
  private func doubleClick() {
    switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
    case "Minimize": window.miniaturize(nil)
    case "None": break
    default: window.zoom(nil)
    }
  }

  /// The mouse-up for a press that moved or minimised the window can go to
  /// the window server rather than the view, and Flutter, never hearing it,
  /// would take the button for still held and the next click on a tab for a
  /// drag. So it is told the press is over; should the real mouse-up arrive
  /// after all, Flutter reads it as the mouse moving.
  private func releaseInFlutter() {
    guard
      let controller,
      let up = NSEvent.mouseEvent(
        with: .leftMouseUp, location: window.mouseLocationOutsideOfEventStream,
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
        clickCount: 1, pressure: 0)
    else { return }
    controller.mouseUp(with: up)
  }
}

/// The picture on the Mac's clipboard, copied into a file of the app's own:
/// a path and a name, the shape Android hands back, or nothing at all when
/// the clipboard holds no picture — then the paste goes on to be text.
///
/// A terminal is a byte stream, so a picture can only reach the host as a
/// file the upload puts there; that is why the bytes stop here and only the
/// path is answered.
enum ClipboardImage {
  /// One image at a time, as Android keeps one: the directory is emptied
  /// before each copy, so a paste leaves no pile of pictures behind.
  private static var directory: URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("clipboard", isDirectory: true)
  }

  /// What a picture that cannot be taken says. There is no app to name on a
  /// Mac — the pasteboard does not say who wrote it — so it says what to do.
  private static let refused =
    "The picture on the clipboard could not be read. Try copying it again, "
    + "or open it from the files drawer."

  static func take(limit: Int, result: @escaping FlutterResult) {
    let board = NSPasteboard.general

    // A picture copied in Finder arrives as a file URL, and is taken as it
    // is, name and all. Everything else — a screenshot, a copy from a
    // browser — arrives as bytes, and macOS offers the same picture under
    // several types: PNG first, being lossless and small; then JPEG, which
    // is a photo's own bytes; TIFF last, which macOS synthesises for almost
    // anything and which is far the largest.
    if let url = fileURL(board) {
      copy(from: url, limit: limit, result: result)
      return
    }
    let types: [NSPasteboard.PasteboardType] = [
      .png, NSPasteboard.PasteboardType("public.jpeg"), .tiff,
    ]
    guard let type = types.first(where: { board.availableType(from: [$0]) != nil }) else {
      result(nil)
      return
    }
    // It said it had one: a type that then hands over nothing is an error,
    // never silence, which reads as a feature that does nothing.
    guard let data = board.data(forType: type) else {
      result(FlutterError(code: "unreadable", message: refused, details: nil))
      return
    }
    if data.count > limit {
      result(FlutterError(code: "too_big", message: tooBig(limit), details: nil))
      return
    }
    let name = stamped(extension: self.extension(of: type))
    guard let file = write(data, as: name) else {
      result(FlutterError(code: "unreadable", message: refused, details: nil))
      return
    }
    result(["path": file.path, "name": name])
  }

  /// The clipboard's file URL, when it is a picture this app can send: a
  /// folder, a PDF or a video copied in Finder is not, and the paste goes on
  /// to be text as it would with nothing on the clipboard.
  private static func fileURL(_ board: NSPasteboard) -> URL? {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    guard
      let urls = board.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
      let url = urls.first,
      let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
      type.conforms(to: .image)
    else { return nil }
    return url
  }

  /// A picture already on disk: weighed before it is copied, so a huge one
  /// is refused without being read at all, and keeping the name it has.
  private static func copy(from url: URL, limit: Int, result: @escaping FlutterResult) {
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    if size > limit {
      result(FlutterError(code: "too_big", message: tooBig(limit), details: nil))
      return
    }
    guard let data = try? Data(contentsOf: url) else {
      result(FlutterError(code: "unreadable", message: refused, details: nil))
      return
    }
    let name = url.lastPathComponent
    guard let file = write(data, as: name) else {
      result(FlutterError(code: "unreadable", message: refused, details: nil))
      return
    }
    result(["path": file.path, "name": name])
  }

  /// [data] in [directory] under [name], the directory emptied first.
  private static func write(_ data: Data, as name: String) -> URL? {
    let manager = FileManager.default
    try? manager.removeItem(at: directory)
    guard
      (try? manager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
    else { return nil }
    let file = directory.appendingPathComponent(name)
    guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
    return file
  }

  /// What a picture with no name of its own is called once it is on the
  /// host, where the user reads it and types it at a prompt — as Android
  /// names one the clipboard gave no name worth keeping.
  private static func stamped(extension suffix: String) -> String {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.dateFormat = "yyyyMMdd-HHmmss"
    return "pasted-\(format.string(from: Date())).\(suffix)"
  }

  private static func `extension`(of type: NSPasteboard.PasteboardType) -> String {
    switch type {
    case .png: return "png"
    case .tiff: return "tiff"
    default: return "jpg"
    }
  }

  private static func tooBig(_ limit: Int) -> String {
    "That image is bigger than \(limit / (1024 * 1024)) MB — send it from "
      + "the files drawer instead."
  }
}
