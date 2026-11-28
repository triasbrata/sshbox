import Cocoa
import FlutterMacOS
import desktop_drop
import UniformTypeIdentifiers

/// A log the runner writes itself, to runner.log in the app's Application
/// Support folder, one line at a time and synced, so a process that ends
/// without a word leaves how far it got: what the runner did to each window,
/// and how the process ended, by exit or by a signal with its backtrace.
/// Never anything a user typed or saw.
enum RunnerLog {
  private static var fd: Int32 = -1

  static func start() {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first
    guard
      let dir = base?.appendingPathComponent(
        Bundle.main.bundleIdentifier ?? "cloud.brata.terminal", isDirectory: true)
    else { return }
    try? FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    fd = open(dir.appendingPathComponent("runner.log").path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    write("---- start, pid \(getpid())")
    for number in [SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGTRAP] {
      signal(number) { received in
        RunnerLog.crash(received)
      }
    }
    NSSetUncaughtExceptionHandler { exception in
      RunnerLog.write("uncaught exception \(exception.name.rawValue)")
      for line in exception.callStackSymbols.prefix(30) { RunnerLog.write("  \(line)") }
    }
  }

  static func write(_ text: String) {
    guard fd >= 0 else { return }
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(stamp) \(text)\n"
    _ = line.withCString { Darwin.write(fd, $0, strlen($0)) }
    fsync(fd)
  }

  private static func crash(_ number: Int32) {
    if fd >= 0 {
      let head = "fatal signal \(number)\n"
      _ = head.withCString { Darwin.write(fd, $0, strlen($0)) }
      var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 40)
      let count = backtrace(&frames, 40)
      backtrace_symbols_fd(&frames, count, fd)
    }
    signal(number, SIG_DFL)
    raise(number)
  }
}

class MainFlutterWindow: NSWindow {
  /// Kept for as long as the window: it answers the tab strip's channel.
  private var titleBar: TitleBar?

  override func awakeFromNib() {
    // Several windows, where this Flutter can turn the engine's views on:
    // the engine is made here, with that on, since it cannot be once a view
    // is on it. Otherwise the engine comes with the view controller as it
    // always did, and the app has the one window.
    RunnerLog.start()
    let engine = Windows.makeEngine()
    let flutterViewController =
      engine.map { FlutterViewController(engine: $0, nibName: nil, bundle: nil) }
      ?? FlutterViewController()
    // The window can be closed while others stay up, and is then let go.
    isReleasedWhenClosed = false
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    // Where Dart starts sentry-cocoa, before it starts sentry_flutter.
    NativeCrashesChannel.register(
      with: flutterViewController.registrar(forPlugin: "NativeCrashes"))

    let windowChannel = FlutterMethodChannel(
      name: "sshbox/window", binaryMessenger: flutterViewController.engine.binaryMessenger)
    let bar = TitleBar(window: self, controller: flutterViewController, channel: windowChannel)
    titleBar = bar
    WindowPlace.restore(self)
    if let engine {
      // The engine has no first view for the plugin to find, so each
      // window's is handed to it.
      DesktopDropPlugin.attach(to: flutterViewController)
      Windows.shared.adopt(
        engine: engine, window: self, controller: flutterViewController, titleBar: bar,
        channel: windowChannel)
    }

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

    // The terminal font picker's list of what is installed. A family is
    // monospaced when any member of it is among the fixed-pitch fonts
    // NSFontManager names — the trait a font's own tables declare.
    let fonts = FlutterMethodChannel(
      name: "sshbox/fonts",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    fonts.setMethodCallHandler { call, result in
      guard call.method == "families" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let manager = NSFontManager.shared
      let fixed = Set(manager.availableFontNames(with: .fixedPitchFontMask) ?? [])
      result(
        manager.availableFontFamilies.map { family -> [String: Any] in
          // Each member is its PostScript name, style name, weight and traits.
          let names = manager.availableMembers(ofFontFamily: family)?
            .compactMap { $0.first as? String } ?? []
          return ["family": family, "mono": names.contains { fixed.contains($0) }]
        })
    }

    super.awakeFromNib()
  }
}

/// The window where it was when it last closed, at the size it was, and in
/// full screen if it was. AppKit keeps the frame in the app's own defaults
/// (~/Library/Preferences/<bundle id>.plist, "NSWindow Frame Jeansh") as the
/// window moves and resizes, so a restart into an update, which quits with
/// exit(), keeps it too; full screen is a flag beside it.
enum WindowPlace {
  private static let name = "Jeansh"
  private static let fullScreen = "JeanshWindowFullScreen"

  /// Before the window is first shown, so it never jumps.
  static func restore(_ window: NSWindow) {
    // AppKit's own window restoration would put back, after this, the frame
    // it last encoded: one place that says where the window goes, not two.
    window.isRestorable = false
    window.setFrameUsingName(name)
    window.setFrameAutosaveName(name)

    // The screen its top strip, the part that moves it, is on; when that is
    // on none — a laptop undocked, a screen unplugged — the main one,
    // centred. Either way it comes back no bigger than that screen and
    // wholly on it. setFrameUsingName moves a frame saved on another screen
    // relative to it, but is not relied on to shrink one, so this decides.
    let frame = window.frame
    let strip = NSRect(x: frame.minX, y: frame.maxY - 40, width: frame.width, height: 40)
    let on = NSScreen.screens.first { $0.visibleFrame.intersects(strip) }
    if let area = (on ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
      let width = min(frame.width, area.width)
      let height = min(frame.height, area.height)
      let x = on == nil
        ? area.midX - width / 2 : min(max(frame.minX, area.minX), area.maxX - width)
      let y = on == nil
        ? area.midY - height / 2 : min(max(frame.minY, area.minY), area.maxY - height)
      let fitted = NSRect(x: x, y: y, width: width, height: height)
      if fitted != frame { window.setFrame(fitted, display: false) }
    }

    let defaults = UserDefaults.standard
    let center = NotificationCenter.default
    _ = center.addObserver(
      forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main
    ) { _ in defaults.set(true, forKey: fullScreen) }
    _ = center.addObserver(
      forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
    ) { _ in defaults.set(false, forKey: fullScreen) }
    // Full screen once the window is up, which it has to be to go there.
    if defaults.bool(forKey: fullScreen) {
      var launched: NSObjectProtocol?
      launched = center.addObserver(
        forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
      ) { _ in
        if let launched { center.removeObserver(launched) }
        if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
      }
    }
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
  private var observers: [NSObjectProtocol] = []

  deinit {
    for token in observers { NotificationCenter.default.removeObserver(token) }
  }

  /// Every window's, by the id of the view it draws in, and the first's:
  /// the one channel's calls name the view they are for, and a call that
  /// names none is the first window's.
  private static var all: [Int: TitleBar] = [:]
  private static var first: TitleBar?

  /// What the Dart side is told while full screen hides the buttons.
  private static let hidden: [String: Double] = ["inset": 0, "height": 0]

  /// The last measure taken outside full screen, sent again on the way out
  /// of it, before the buttons are back to be measured. AppKit's usual
  /// numbers until then, for a window that opens in full screen.
  private var measured: [String: Double] = ["inset": 78, "height": 28]

  /// Answers the calls the tab strip makes on `sshbox/window`, each for the
  /// window whose view it names.
  static func route(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    var target = first
    if let named = call.arguments as? [String: Any], let view = named["view"] as? Int {
      target = all[view]
    }
    guard let target else { return result(nil) }
    target.handle(call.method, result)
  }

  static var count: Int { all.count }

  /// A window going: its view's calls are answered no more.
  static func forget(viewIdentifier: Int) {
    let gone = all.removeValue(forKey: viewIdentifier)
    if first === gone { first = all.values.first }
  }

  init(window: NSWindow, controller: FlutterViewController, channel: FlutterMethodChannel) {
    self.window = window
    self.controller = controller
    self.channel = channel

    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.styleMask.insert(.fullSizeContentView)

    if Self.first == nil {
      Self.first = self
      channel.setMethodCallHandler { call, result in Self.route(call, result) }
    }
    Self.all[Int(controller.viewIdentifier)] = self

    // Full screen hides the buttons with the title bar and gives their room
    // back: once it is there, and before it leaves, so on neither way does a
    // button stand over a tab.
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main
      ) { [weak self] _ in
        self?.channel.invokeMethod("titleBar", arguments: Self.hidden)
      })
    observers.append(
      center.addObserver(
        forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        self.channel.invokeMethod("titleBar", arguments: self.measured)
      })
  }

  private func handle(_ method: String, _ result: FlutterResult) {
    switch method {
    case "titleBar":
      result(window.styleMask.contains(.fullScreen) ? Self.hidden : measure())
    case "drag":
      drag()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
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

/// More than one window, on the one engine: every window has a
/// FlutterViewController of its own on it. The engine's views are turned on
/// by a call Flutter does not publish yet, `enableMultiView`, so it is asked
/// for only where the engine answers to it — a Flutter without it leaves the
/// app one window, and the Dart side, told the runner opens no more, offers
/// no key for one.
///
/// With the views on, the engine has no first view of its own: every window,
/// the first included, draws in a view numbered from 1, and a plugin that
/// asks its registrar for "the" view, as the file dialogs' and drag and
/// drop's do, is given none. The ones this app uses are patched to find the
/// window in front instead (third_party/).
final class Windows {
  static let shared = Windows()

  /// Set once the engine runs with several views.
  private(set) var engine: FlutterEngine?
  private var channel: FlutterMethodChannel?
  private var windowChannel: FlutterMethodChannel?
  private var entries: [Int: Entry] = [:]
  private var nextId = 1
  /// Windows the app has said may close, rather than be asked.
  private var allowed: Set<Int> = []
  /// Whether the app has asked for several windows: before it has, a window
  /// closes as it always did.
  private var multi = false

  private final class Entry {
    let id: Int
    let window: NSWindow
    var controller: FlutterViewController?
    let observer: WindowObserver
    init(id: Int, window: NSWindow, controller: FlutterViewController, observer: WindowObserver) {
      self.id = id
      self.window = window
      self.controller = controller
      self.observer = observer
    }
  }

  /// Whether [object] answers to [selector]: the guard the engine's
  /// unpublished call is made behind. A Flutter that has dropped or renamed
  /// it gives false, and nothing else is done.
  static func responds(_ object: NSObject, to selector: Selector) -> Bool {
    object.responds(to: selector)
  }

  private static let enableMultiView = NSSelectorFromString("enableMultiView")

  /// The engine, running, with its views on, or nil where this Flutter
  /// cannot: then the view controller makes its own engine.
  static func makeEngine() -> FlutterEngine? {
    let engine = FlutterEngine(name: "io.flutter", project: nil, allowHeadlessExecution: true)
    guard responds(engine, to: enableMultiView) else { return nil }
    _ = engine.perform(enableMultiView)
    // Running before any view is added, so each view added is told to the
    // engine as it is.
    guard engine.run(withEntrypoint: nil) else { return nil }
    return engine
  }

  /// The window the xib made, now that its engine and view are up.
  func adopt(
    engine: FlutterEngine, window: NSWindow, controller: FlutterViewController,
    titleBar: TitleBar, channel windowChannel: FlutterMethodChannel
  ) {
    self.engine = engine
    self.windowChannel = windowChannel
    let observer = WindowObserver(id: 0, windows: self)
    window.delegate = observer
    entries[0] = Entry(id: 0, window: window, controller: controller, observer: observer)
    let channel = FlutterMethodChannel(
      name: "sshbox/windows", binaryMessenger: engine.binaryMessenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result) ?? result(nil)
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "supported":
      multi = engine != nil
      result(multi)
    case "firstView":
      result(entries[0]?.controller?.viewIdentifier ?? 0)
    case "open":
      let id = open(frame: call.arguments as? [String: Any])
      RunnerLog.write("call open -> id \(id.map(String.init) ?? "nil")")
      result(id)
    case "close":
      RunnerLog.write("call close \(call.arguments ?? "?"), \(entries.count) windows")
      if let id = call.arguments as? Int, let entry = entries[id] {
        allowed.insert(id)
        entry.window.close()
      }
      result(nil)
    case "hide":
      // A window about to close takes no more input: its view is about to
      // leave the app's tree.
      RunnerLog.write("call hide \(call.arguments ?? "?")")
      if let id = call.arguments as? Int, let entry = entries[id] {
        entry.window.orderOut(nil)
      }
      result(nil)
    case "place":
      // The first window takes the place of another that has closed.
      if let args = call.arguments as? [String: Any], let id = args["id"] as? Int,
        let entry = entries[id], let rect = Self.rect(of: args)
      {
        entry.window.setFrame(Self.fitted(rect), display: true)
        if args["maximized"] as? Bool == true && !entry.window.isZoomed {
          entry.window.zoom(nil)
        }
      }
      result(nil)
    case "activate":
      if let id = call.arguments as? Int, let entry = entries[id] {
        if entry.window.isMiniaturized { entry.window.deminiaturize(nil) }
        entry.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// A window after the first, at [frame] when the app sent one that is
  /// anywhere on a screen, else a little lower and to the right of the last.
  private func open(frame: [String: Any]?) -> Int? {
    guard let engine else { return nil }
    let id = nextId
    nextId += 1
    let controller = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.title = "Jeansh"
    window.contentViewController = controller
    window.minSize = NSSize(width: 300, height: 200)
    // Taking a view controller as its content makes the window the view's
    // fitting size, a point or so, and centring or cascading it then keeps
    // that. So it is given a size first: the first window's, never under
    // 640 by 400.
    let first = entries[0]?.window.frame.size ?? NSSize(width: 1280, height: 720)
    window.setContentSize(
      NSSize(width: max(first.width, 640), height: max(first.height, 400)))
    if let rect = Self.rect(of: frame) {
      window.setFrame(Self.fitted(rect), display: false)
    } else {
      window.center()
      if let last = entries.values.map({ $0.window }).max(by: { $0.frame.minX < $1.frame.minX }) {
        window.setFrameTopLeftPoint(
          NSPoint(x: last.frame.minX + 30, y: last.frame.maxY - 30))
      }
    }
    guard let windowChannel else { return nil }
    _ = TitleBar(window: window, controller: controller, channel: windowChannel)
    DesktopDropPlugin.attach(to: controller)
    let observer = WindowObserver(id: id, windows: self)
    window.delegate = observer
    entries[id] = Entry(id: id, window: window, controller: controller, observer: observer)
    if frame?["maximized"] as? Bool == true { window.zoom(nil) }
    window.makeKeyAndOrderFront(nil)
    channel?.invokeMethod(
      "opened", arguments: ["id": id, "viewId": controller.viewIdentifier])
    return id
  }

  /// A frame the app sent, if it is one: numbers within ±100000 and a size
  /// of at least 200 by 150.
  private static func rect(of frame: [String: Any]?) -> NSRect? {
    guard let frame else { return nil }
    func number(_ key: String) -> Double? {
      guard let value = (frame[key] as? NSNumber)?.doubleValue, abs(value) <= 100000
      else { return nil }
      return value
    }
    guard
      let x = number("x"), let y = number("y"),
      let width = number("width"), let height = number("height"),
      width >= 200, height >= 150
    else { return nil }
    return NSRect(x: x, y: y, width: width, height: height)
  }

  /// [rect] no bigger than the screen its top strip is on, and wholly on it;
  /// when that strip is on none — a screen unplugged — the main screen,
  /// centred. As the first window's place is kept (WindowPlace).
  private static func fitted(_ rect: NSRect) -> NSRect {
    let strip = NSRect(x: rect.minX, y: rect.maxY - 40, width: rect.width, height: 40)
    let on = NSScreen.screens.first { $0.visibleFrame.intersects(strip) }
    guard let area = (on ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
    else { return rect }
    let width = min(rect.width, area.width)
    let height = min(rect.height, area.height)
    let x = on == nil
      ? area.midX - width / 2 : min(max(rect.minX, area.minX), area.maxX - width)
    let y = on == nil
      ? area.midY - height / 2 : min(max(rect.minY, area.minY), area.maxY - height)
    return NSRect(x: x, y: y, width: width, height: height)
  }

  // What the windows' delegates say.

  /// Whether window [id] may close now. Once the app has asked for several
  /// windows it decides, and is asked; it answers with `close`.
  func shouldClose(_ id: Int) -> Bool {
    RunnerLog.write("window id \(id): should close, allowed \(allowed.contains(id))")
    if !multi || allowed.contains(id) { return true }
    channel?.invokeMethod("closeRequested", arguments: id)
    return false
  }

  func didClose(_ id: Int) {
    guard let entry = entries.removeValue(forKey: id) else { return }
    RunnerLog.write("window id \(id): closed, releasing its view")
    // Whether the NSWindow is really let go: checked a little later, when
    // nothing here holds it. The window server lists a closed window for a
    // while whether or not the object is gone.
    weak var released = entry.window
    for delay in [3.0, 15.0] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        if let held = released {
          RunnerLog.write(
            "window id \(id): NSWindow STILL HELD after \(Int(delay)) s, retain count "
              + "\(CFGetRetainCount(held)), visible \(held.isVisible), "
              + "content \(held.contentView == nil ? "nil" : "set"), "
              + "delegate \(held.delegate == nil ? "nil" : "set"), "
              + "titlebars \(TitleBar.count)")
        } else {
          RunnerLog.write("window id \(id): NSWindow released after \(Int(delay)) s")
        }
      }
    }
    allowed.remove(id)
    if let view = entry.controller?.viewIdentifier {
      TitleBar.forget(viewIdentifier: Int(view))
    }
    entry.window.delegate = nil
    entry.observer.stop()
    // Nothing of its own left in it: no view, no pending drag, out of sight.
    entry.window.orderOut(nil)
    // Its view goes with it, and the engine stays for the others.
    entry.window.contentViewController = nil
    entry.controller = nil
    RunnerLog.write("window id \(id): view released")
    channel?.invokeMethod("closed", arguments: id)
  }

  func didFocus(_ id: Int) {
    channel?.invokeMethod("focused", arguments: id)
  }

  func didMove(_ id: Int) {
    guard multi, let window = entries[id]?.window, !window.styleMask.contains(.fullScreen),
      !window.isMiniaturized
    else { return }
    let frame = window.frame
    channel?.invokeMethod(
      "moved",
      arguments: [
        "id": id, "x": frame.minX, "y": frame.minY, "width": frame.width,
        "height": frame.height, "maximized": window.isZoomed,
      ])
  }
}

/// One window's delegate: what it hears of the window, said to [Windows].
final class WindowObserver: NSObject, NSWindowDelegate {
  private let id: Int
  private unowned let windows: Windows
  private var pending: DispatchWorkItem?

  init(id: Int, windows: Windows) {
    self.id = id
    self.windows = windows
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool { windows.shouldClose(id) }

  /// The window is going: nothing it said is to be said again.
  func stop() {
    pending?.cancel()
    pending = nil
  }

  func windowWillClose(_ notification: Notification) {
    pending?.cancel()
    windows.didClose(id)
  }

  func windowDidBecomeKey(_ notification: Notification) { windows.didFocus(id) }

  func windowDidMove(_ notification: Notification) { moved() }

  func windowDidResize(_ notification: Notification) { moved() }

  /// Once the window has held still: a drag says it once.
  private func moved() {
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.windows.didMove(self.id)
    }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
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
