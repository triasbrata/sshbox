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
default:
  fatalError("crash or send")
}
