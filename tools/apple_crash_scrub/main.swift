// A crash through apple/NativeCrashes.swift and a real sentry-cocoa, for
// tools/check_apple_crash_scrub.sh. Never part of the app.
//
//   check crash <dsn> <cache>        starts the SDK as the app does, fills the
//                                    scope with what a scope can leak, and
//                                    dies of EXC_BAD_ACCESS
//   check send <dsn> <cache> [raw]   starts it again, which sends that crash;
//                                    then an NSError captured natively and a
//                                    Dart-shaped envelope, as sentry_flutter
//                                    hands one over. raw: no beforeSend, the
//                                    way sentry_flutter used to start it
import Foundation
import Sentry
import Sentry._Hybrid

let args = CommandLine.arguments
let (mode, dsn, cache) = (args[1], args[2], args[3])
let raw = args.count > 4 && args[4] == "raw"

NativeCrashes.start(dsn: dsn, environment: "release") { o in
  o.cacheDirectoryPath = cache
  o.debug = ProcessInfo.processInfo.environment["SENTRY_DEBUG"] != nil
  if raw { o.beforeSend = nil }
}

switch mode {
case "crash":
  SentrySDK.configureScope { scope in
    scope.setUser(User(userId: "scope-user-leak"))
    scope.setTag(value: "tag-leak", key: "installerStore")
    scope.setExtra(value: "extra-leak /Users/someone/secret", key: "extra")
    scope.setContext(value: ["hostname": "context-leak"], key: "custom")
  }
  // Long enough for SentryCrash to write the scope into its report's header.
  Thread.sleep(forTimeInterval: 1)
  let nowhere = UnsafeMutablePointer<Int>(bitPattern: 0x8)!
  nowhere.pointee = 1
case "send":
  // The previous run's crash goes out from a queue of the SDK's own.
  Thread.sleep(forTimeInterval: 3)
  SentrySDK.capture(
    error: NSError(
      domain: "check", code: 7,
      userInfo: [NSLocalizedDescriptionKey: "error-message-leak /Users/someone/x"]))
  // What sentry_flutter's captureEnvelope does with the bytes Dart sends.
  let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  let payload = #"{"event_id":"\#(id)","platform":"dart","level":"error","#
    + #""exception":{"values":[{"type":"StateError","value":"from Dart, already scrubbed"}]},"#
    + #""extra":{"dart":"kept as Dart sent it"}}"#
  let envelope = #"{"event_id":"\#(id)"}"# + "\n"
    + #"{"type":"event","length":\#(payload.utf8.count)}"# + "\n" + payload
  PrivateSentrySDKOnly.capture(PrivateSentrySDKOnly.envelope(with: Data(envelope.utf8))!)
  SentrySDK.flush(timeout: 10)
  SentrySDK.close()
case "hang":
  // Which App Hangs go out: the verdicts of NativeCrashes.isIdleHang, with no
  // hang and no network. 2x2: an awake hang is sent whatever its frames, and
  // any hang is dropped while the Mac sleeps, then sent again after.
  func hang(_ functions: [String]) -> Event {
    let e = Event(level: .error)
    let x = Exception(value: "", type: "App Hanging")
    x.mechanism = Mechanism(type: "AppHang")
    x.stacktrace = SentryStacktrace(
      frames: functions.map { f in
        let frame = Frame()
        frame.function = f
        return frame
      }, registers: [:])
    e.exceptions = [x]
    return e
  }
  let withRunner = hang(["start", "main", "NSApplicationMain", "-[TitleBar layout]"])
  let systemOnly = hang(["start", "NSApplicationMain", "kevent_id"])
  var bad: [String] = []
  func expect(_ name: String, _ got: Bool, _ want: Bool) { if got != want { bad.append(name) } }
  let now = Date()
  expect("awake, Runner frame sent", NativeCrashes.isIdleHang(withRunner, now: now), false)
  expect("awake, system frames only sent", NativeCrashes.isIdleHang(systemOnly, now: now), false)
  NativeCrashes.quiet(until: .distantFuture)
  expect("asleep dropped", NativeCrashes.isIdleHang(systemOnly, now: now), true)
  expect("asleep, Runner frame dropped", NativeCrashes.isIdleHang(withRunner, now: now), true)
  NativeCrashes.quiet(until: .distantPast)
  expect("awake again sent", NativeCrashes.isIdleHang(systemOnly, now: now), false)
  let wait = [
    "start", "NSApplicationMain", "-[NSApplication run]", "_DPSNextEvent",
    "CFRunLoopRunSpecific", "__CFRunLoopRun", "__CFRunLoopServiceMachPort",
  ]
  let idle = hang(["start", "<redacted>"] + wait + ["mach_msg", "mach_msg2_trap"])
  let busy = hang(
    ["start", "NSApplicationMain", "__CFRunLoopRun", "__CFRunLoopDoSources0",
     "FlutterRunLoop.perform", "mach_msg2_trap"])
  let unsymbolised = hang(wait + ["<redacted>", "mach_msg2_trap"])
  let noSymbol = hang(wait + ["mach_msg2_trap"])
  noSymbol.exceptions![0].stacktrace!.frames.insert(Frame(), at: wait.count)
  expect("idle run loop dropped", NativeCrashes.isIdleRunLoopHang(idle), true)
  expect("busy main thread kept", NativeCrashes.isIdleRunLoopHang(busy), false)
  expect("runner frame kept", NativeCrashes.isIdleRunLoopHang(withRunner), false)
  expect("unsymbolised frame kept", NativeCrashes.isIdleRunLoopHang(unsymbolised), false)
  expect("frame without symbol kept", NativeCrashes.isIdleRunLoopHang(noSymbol), false)
  NativeCrashes.noteWake(at: now.addingTimeInterval(-10))
  NativeCrashes.noteOccluded(true)
  let tags = NativeCrashes.hangTags(now: now)
  expect("wake tag", tags["hang.since_wake"] == "<30s", true)
  expect("occluded tag", tags["hang.occluded"] == "true", true)
  expect("only constants", Set(tags.keys) == ["hang.since_wake", "hang.occluded"], true)
  expect("scrub drops idle hang", NativeCrashes.scrub(idle) == nil, true)
  expect("scrub keeps busy hang with only the tags", NativeCrashes.scrub(busy)?.tags == tags, true)
  print(bad.isEmpty ? "hang verdicts ok" : "hang verdicts wrong: \(bad)")
  exit(bad.isEmpty ? 0 : 1)
default:
  fatalError("crash, send or hang")
}
