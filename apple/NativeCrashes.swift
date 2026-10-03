import Foundation
import Sentry
import Sentry._Hybrid

#if canImport(FlutterMacOS)
import FlutterMacOS
import AppKit
#elseif canImport(Flutter)
import Flutter
import UIKit
#endif

/// sentry-cocoa, started here rather than by sentry_flutter, for the one thing
/// sentry_flutter will not let the app set: a beforeSend of its own. The iOS
/// and macOS half of android/…/NativeCrashes.kt, and one file for both, built
/// into each Runner.
///
/// A native crash — a signal, a Mach exception, an uncaught NSException, an
/// app hang, a watchdog termination — is written by SentryCrash and sent by
/// sentry-cocoa at the next start, and never passes through Dart's
/// `scrubEvent`. sentry_flutter's own init sets `beforeSend` to a callback of
/// its own that only adds tags, so such an event would go out with the
/// kernel's uname (the build user and host of xnu), the install's Sentry id as
/// user.id, the locale, memory and free disk, the app's start time and hash,
/// the scope's tags and extras, every thread and every image's path — on a Mac
/// /Users/<name>/…. Dart turns sentry_flutter's init off
/// (`autoInitializeNativeSdk`) and calls [start] instead, with the DSN it was
/// built with.
///
/// Dart's own events are untouched by this: sentry_flutter hands them to
/// sentry-cocoa as finished envelopes (PrivateSentrySDKOnly.capture), which
/// go straight to the transport without beforeSend, already scrubbed on the
/// Dart side. They need a started SDK to go anywhere, which is why this starts
/// one rather than turning native capture off.
///
/// Without Flutter — tools/check_apple_crash_scrub.sh compiles this file with
/// swiftc alone — only [start], [stop] and [scrub] are built.
enum NativeCrashes {
  static func start(dsn: String, environment: String, configure: ((Options) -> Void)? = nil) {
    SentrySDK.start { o in
      o.dsn = dsn
      o.environment = environment
      // What sentry_flutter's initNativeSdk would set from crash_reporting.dart's
      // options, where that differs from sentry-cocoa's own default.
      // Everything else — the crash handler on, no PII, no screenshot or view
      // hierarchy, app hang and watchdog tracking on, 30 cached envelopes — is
      // already the default on both sides.
      o.enableAutoSessionTracking = false
      o.enableAutoBreadcrumbTracking = false
      o.maxBreadcrumbs = 0
      o.beforeBreadcrumb = { _ in nil }
      o.enableCaptureFailedRequests = false
      // sentry-cocoa's 2 s is short for a Mac that is waking or being napped;
      // [scrub] drops the rest of those, see [isIdleHang].
      o.appHangTimeoutInterval = 5
      // The release and dist Dart's LoadReleaseIntegration makes from the same
      // Info.plist, which are also sentry-cocoa's own defaults, spelled out.
      let info = Bundle.main.infoDictionary ?? [:]
      if let id = info["CFBundleIdentifier"] as? String,
         let version = info["CFBundleShortVersionString"] as? String,
         let build = info["CFBundleVersion"] as? String
      {
        o.releaseName = "\(id)@\(version)+\(build)"
        o.dist = build
      }
      PrivateSentrySDKOnly.setSdkName(
        "sentry.cocoa.flutter", andVersionString: PrivateSentrySDKOnly.getSdkVersionString())
      o.beforeSend = { scrub($0) }
      configure?(o)
    }
    // As sentry_flutter does: the SDK starts after the app became active, and
    // this stands in for the notification it missed.
    #if canImport(FlutterMacOS)
    let active = NSApplication.shared.isActive
    #elseif canImport(Flutter)
    let active = UIApplication.shared.applicationState == .active
    #endif
    #if canImport(FlutterMacOS) || canImport(Flutter)
    if active {
      NotificationCenter.default.post(
        name: Notification.Name("SentryHybridSdkDidBecomeActive"), object: nil)
    }
    #endif
    #if canImport(FlutterMacOS)
    watchSleep()
    #endif
  }

  // MARK: App hangs that are the Mac's, not the app's

  private static let quietLock = NSLock()
  private static var quietUntil = Date.distantPast
  private static var watching = false

  /// While the Mac sleeps or the app is occluded (App Nap) the main thread is
  /// stopped by the system, and sentry-cocoa reads the stop as a hang when it
  /// runs again. The window stays shut for 30 s after the Mac wakes or the app
  /// is visible again.
  static func quiet(until: Date) {
    quietLock.lock()
    quietUntil = until
    quietLock.unlock()
  }

  #if canImport(FlutterMacOS)
  private static func watchSleep() {
    quietLock.lock()
    let already = watching
    watching = true
    quietLock.unlock()
    if already { return }
    let ws = NSWorkspace.shared.notificationCenter
    ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in
      quiet(until: .distantFuture)
    }
    for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
      ws.addObserver(forName: name, object: nil, queue: nil) { _ in
        quiet(until: Date().addingTimeInterval(30))
      }
    }
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeOcclusionStateNotification, object: nil, queue: nil
    ) { _ in
      let visible = NSApplication.shared.occlusionState.contains(.visible)
      quiet(until: visible ? Date().addingTimeInterval(30) : .distantFuture)
    }
  }
  #endif

  /// An App Hang that is not ours to report: the Mac was asleep, napping or
  /// just woke, or the main thread's stack holds no frame of the app's own
  /// executable between NSApplicationMain and where it stopped — the run loop,
  /// AppKit's state restoration and Flutter's engine, which the user can do
  /// nothing about. A hang with a frame of the Runner's in it is still sent.
  static func isIdleHang(_ event: Event, now: Date = Date(), executable: String? = nil) -> Bool {
    guard event.exceptions?.first?.mechanism?.type == "AppHang" else { return false }
    quietLock.lock()
    let until = quietUntil
    quietLock.unlock()
    if now < until { return true }
    let exe = executable ?? Bundle.main.executableURL?.lastPathComponent ?? ""
    let frames = event.exceptions?.first?.stacktrace?.frames ?? []
    // Frames run oldest first: everything up to NSApplicationMain is the entry.
    let entry = frames.firstIndex { $0.function == "NSApplicationMain" } ?? -1
    return !frames.dropFirst(entry + 1).contains { $0.package.map(lastComponent) == exe }
  }

  /// For the switch being turned off while the app runs.
  static func stop() { SentrySDK.close() }

  /// The native half of `scrubEvent` in lib/src/telemetry/crash_reporting.dart,
  /// field for field what NativeCrashes.kt keeps: the event rebuilt from what
  /// is worth keeping, never edited, so a field a later sentry-cocoa starts
  /// filling in is dropped without anyone having to notice it.
  ///
  /// Gone by construction: the user (the install's Sentry id), the request,
  /// the server name, the message, tags, extras, breadcrumbs, modules and
  /// every thread; every context but os and device, so the app's start time,
  /// install hash and in-foreground flag, the trace, the culture and the
  /// runtime; the OS's build, kernel version (xnu's uname, root:xnu-… and
  /// all) and rooted flag; the device's name, model_id, memory, free and
  /// total storage, boot time, locale, timezone, battery and screen. Swift
  /// has no scrubber, so an exception's value goes too: SentryCrash fills it
  /// with an NSException's reason, a Swift runtime message, or strings read
  /// from the crashed thread's registers.
  ///
  /// What symbolication needs is kept, reduced: each frame's instruction
  /// address, and each debug image by its format, ids, load address and size,
  /// its file cut to a bare name — on a Mac an image's path holds the user's
  /// name, on iOS a folder made per install. A load address is where this one
  /// process happened to put the image, chosen afresh each run, and an
  /// image's ids name the build it came from, the same for everyone running
  /// it; neither says whose machine it was.
  static func scrub(_ event: Event) -> Event? {
    // A transaction reaches beforeSend too, and rebuilt it would go out as an
    // error. Tracing is off, so there are none; one that turns up goes.
    if event.type == "transaction" { return nil }
    if isIdleHang(event) { return nil }

    let out = Event(level: event.level)
    out.eventId = event.eventId
    out.timestamp = event.timestamp
    out.platform = event.platform
    out.releaseName = event.releaseName
    out.dist = event.dist
    out.environment = event.environment
    out.sdk = event.sdk
    out.fingerprint = event.fingerprint
    out.exceptions = event.exceptions?.map(exception)
    out.debugMeta = event.debugMeta?.map(image)

    var context: [String: [String: Any]] = [:]
    if let os = event.context?["os"] {
      context["os"] = pick(os, ["name", "version"])
    }
    if let device = event.context?["device"] {
      // `arch` is sentry-cocoa's one string for what Android lists as `archs`.
      context["device"] = pick(
        device, ["family", "model", "manufacturer", "brand", "archs", "arch", "simulator"])
    }
    out.context = context.isEmpty ? nil : context
    return out
  }

  private static func pick(_ from: [String: Any], _ keys: [String]) -> [String: Any] {
    var kept: [String: Any] = [:]
    for key in keys { kept[key] = from[key] }
    return kept
  }

  private static func exception(_ e: Exception) -> Exception {
    let out = Exception(value: "", type: e.type)
    out.module = e.module
    out.threadId = e.threadId
    // A mechanism's data, meta and description are free; SentryCrash's meta
    // holds the signal and Mach codes and its data the relevant address.
    if let m = e.mechanism {
      let mechanism = Mechanism(type: m.type)
      mechanism.handled = m.handled
      mechanism.synthetic = m.synthetic
      out.mechanism = mechanism
    }
    if let s = e.stacktrace {
      out.stacktrace = SentryStacktrace(frames: s.frames.map(frame), registers: [:])
    }
    return out
  }

  /// A frame by name and instruction address. An image's path is cut to its
  /// file name.
  private static func frame(_ f: Frame) -> Frame {
    let out = Frame()
    out.instructionAddress = f.instructionAddress
    out.function = f.function
    out.module = f.module
    out.fileName = f.fileName.map(lastComponent)
    out.package = f.package.map(lastComponent)
    out.lineNumber = f.lineNumber
    out.columnNumber = f.columnNumber
    out.inApp = f.inApp
    out.platform = f.platform
    return out
  }

  /// An image as symbolication needs it. `type` says whether the ids are a
  /// Mach-O's or something else's, without which Sentry reads none of it.
  private static func image(_ i: DebugMeta) -> DebugMeta {
    let out = DebugMeta()
    out.type = i.type
    out.uuid = i.uuid
    out.debugID = i.debugID
    out.imageAddress = i.imageAddress
    out.imageSize = i.imageSize
    out.codeFile = i.codeFile.map(lastComponent)
    return out
  }

  private static func lastComponent(_ path: String) -> String {
    path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? path
  }
}

#if canImport(FlutterMacOS) || canImport(Flutter)
/// The channel Dart starts and stops it through: see crash_reporting.dart.
final class NativeCrashesChannel {
  static func register(with registrar: FlutterPluginRegistrar) {
    #if canImport(FlutterMacOS)
    let messenger = registrar.messenger
    #else
    let messenger = registrar.messenger()
    #endif
    FlutterMethodChannel(name: "sshbox/crashes", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in
        switch call.method {
        case "startCrashReporting":
          guard let args = call.arguments as? [String: Any],
                let dsn = args["dsn"] as? String,
                let environment = args["environment"] as? String
          else {
            result(FlutterError(code: "args", message: "dsn and environment", details: nil))
            return
          }
          NativeCrashes.start(dsn: dsn, environment: environment)
          result(nil)
        case "stopCrashReporting":
          NativeCrashes.stop()
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
  }
}
#endif
