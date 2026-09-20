import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'scrub.dart';
import 'telemetry.dart';

/// Whether this build knows where to send a crash at all: a DSN baked in with
/// `--dart-define JEANSH_SENTRY_DSN`. A debug build has none, so nothing a
/// developer breaks on their own machine is ever sent anywhere.
bool get crashReportingConfigured => sentryDsn.isNotEmpty;

/// Whether crashes are actually going out: configured, and the user has not
/// turned telemetry off.
bool get crashReportingOn => crashReportingConfigured && telemetryOn.value;

/// Whether Sentry was started when the app launched. Settings reads it to
/// know whether turning the switch off now leaves a native crash handler
/// loaded until the next start, or whether there was never one to leave.
bool get crashReportingStarted => _started;
bool _started = false;

/// Runs the app, with Sentry around it where it is wanted and nothing at all
/// where it is not.
///
/// Off means off: `SentryFlutter.init` is never called, so no native crash
/// handler is installed, no zone is wrapped and no DSN is ever resolved. That
/// is the difference between a switch and a mute, and it is what the switch
/// in Settings promises.
Future<void> runWithCrashReporting(FutureOr<void> Function() runTheApp) async {
  if (!crashReportingOn) {
    await runTheApp();
    _watchForFaults();
    return;
  }
  await SentryFlutter.init((options) {
    options.dsn = sentryDsn;
    options.environment = kReleaseMode ? 'release' : 'debug';

    // Nothing about the person. `sendDefaultPii` is what would otherwise
    // attach the device's IP address, its name and the logged-in user.
    options.sendDefaultPii = false;

    // Breadcrumbs in an SSH client are the trail of what somebody was doing:
    // which host they opened, which file they touched, which URL was fetched.
    // They are dropped one by one in [_noBreadcrumbs] and there is room for
    // none anyway, and the three sources that would fill them are off.
    options.maxBreadcrumbs = 0;
    options.beforeBreadcrumb = _noBreadcrumbs;
    // `print` and `debugPrint` become breadcrumbs by default, and this app
    // prints error text.
    options.enablePrintBreadcrumbs = false;
    options.enableUserInteractionBreadcrumbs = false;
    options.enableAutoNativeBreadcrumbs = false;

    // A failed HTTP request would be reported with its URL. The app talks to
    // the user's own machines.
    options.captureFailedRequests = false;

    // A screenshot of Jeansh is a screenshot of somebody's terminal. It is off
    // by Sentry's own default; it is written out because the day that default
    // changes is the day this file has to notice. `attachViewHierarchy`, which
    // would send the widget tree, is off by default too and is left unwritten
    // only because it is marked experimental and naming it fails analysis.
    options.attachScreenshot = false;

    // Performance tracing names routes and spans and buys nothing here.
    options.enableAutoPerformanceTracing = false;
    options.tracesSampleRate = null;
    // Release health sends a session per launch. Jeansh counts its own
    // installs, on its own Worker, and one count is enough.
    options.enableAutoSessionTracking = false;

    options.beforeSend = scrubEvent;
  }, appRunner: runTheApp);
  _started = true;
  _watchForFaults();
}

/// Stops everything Dart sends, for the switch being turned off while the app
/// runs.
///
/// What this cannot do is take back the native crash handler that
/// [runWithCrashReporting] installed on Android and iOS at startup: that is
/// loaded into the process and only a restart unloads it. Until then a native
/// crash could still be written to disk by it. [scrubEvent] returning null
/// while the switch is off is the belt beside this brace, so nothing Dart can
/// see goes out either way — and Settings says a restart finishes the job
/// rather than claiming it is already done.
Future<void> stopCrashReporting() async {
  if (!crashReportingConfigured) return;
  await Sentry.close();
}

Breadcrumb? _noBreadcrumbs(Breadcrumb? crumb, Hint hint) => null;

/// The last thing the framework caught, for the one offer a run makes to
/// report it. Null until something goes wrong, and set once: a fault that
/// repeats every frame would otherwise nag forever.
final lastFault = ValueNotifier<String?>(null);

/// Chains onto whatever error handler is already there — Sentry's, where
/// Sentry is on, and the framework's own where it is not — so that a caught
/// error can be offered to the user to report even with telemetry off. It
/// consumes nothing: the handler underneath still runs first.
void _watchForFaults() {
  final inner = FlutterError.onError;
  FlutterError.onError = (details) {
    inner?.call(details);
    if (lastFault.value != null) return;
    lastFault.value = faultText(details);
  };
}

/// One fault, scrubbed, in the shape a bug report carries it: what it was, and
/// the first few frames of where.
///
/// The frames are cut at ten because a report is read by a person and because
/// the named route has to fit in a URL.
String faultText(FlutterErrorDetails details) {
  final what = scrub(details.exceptionAsString());
  final where = details.stack
      ?.toString()
      .split('\n')
      .take(10)
      .map((line) => scrubStackLine(line.trim()))
      .where((line) => line.isNotEmpty)
      .join('\n');
  return where == null || where.isEmpty ? what : '$what\n\n$where';
}

/// What actually leaves the device, and the reason this file exists.
///
/// The event Sentry hands over is not edited — it is rebuilt, field by field,
/// out of the few things worth keeping. An allowlist rather than a list of
/// things to strip, because a list of things to strip is only right until the
/// next version of the SDK starts attaching something new, and by then it has
/// already been sent.
///
/// What is deliberately not carried across: the user (their IP, their name),
/// the request (URLs and headers), the server name (this machine's own
/// hostname), the breadcrumbs, `extra`, `debugMeta`, and the threads — the
/// exception carries the stack that matters, and a thread dump is another
/// place for a path to hide.
SentryEvent? scrubEvent(SentryEvent event, Hint hint) {
  // The switch, read at the moment of sending rather than at startup: turned
  // off while the app runs, nothing more goes out.
  if (!telemetryOn.value) return null;

  final exceptions = event.exceptions;
  final first = (exceptions == null || exceptions.isEmpty)
      ? null
      : exceptions.first.type;
  if (first != null && ordinaryFailures.contains(first)) return null;

  final message = event.message;
  return SentryEvent(
    eventId: event.eventId,
    timestamp: event.timestamp,
    platform: event.platform,
    level: event.level,
    release: event.release,
    dist: event.dist,
    environment: event.environment,
    sdk: event.sdk,
    type: event.type,
    fingerprint: event.fingerprint,
    // The route the app was on, e.g. `/settings`: ours, not the user's, and
    // scrubbed anyway in case a route ever carries an argument.
    transaction: event.transaction == null ? null : scrub(event.transaction!),
    culprit: event.culprit == null ? null : scrub(event.culprit!),
    message: message == null ? null : SentryMessage(scrub(message.formatted)),
    exceptions: exceptions?.map(_exception).toList(),
    contexts: _contexts(event.contexts),
  );
}

SentryException _exception(SentryException exception) => SentryException(
  type: exception.type,
  value: scrubValue(exception.type, exception.value),
  module: exception.module,
  stackTrace: _stack(exception.stackTrace),
  // Rebuilt rather than carried: a mechanism's `data` and `meta` are free maps
  // an integration fills in, and what goes in them is not ours to promise.
  mechanism: exception.mechanism == null
      ? null
      : Mechanism(
          type: exception.mechanism!.type,
          handled: exception.mechanism!.handled,
          synthetic: exception.mechanism!.synthetic,
        ),
  threadId: exception.threadId,
);

SentryStackTrace? _stack(SentryStackTrace? stack) => stack == null
    ? null
    : SentryStackTrace(frames: stack.frames.map(_frame).toList());

/// A frame with its file name scrubbed and nothing else of the machine on it.
///
/// Gone with the rebuild: `contextLine`, `preContext` and `postContext`, which
/// are the source around the frame, and `vars`, which is the value of every
/// local in it — a password, a key, a host, whatever the frame happened to
/// hold.
SentryStackFrame _frame(SentryStackFrame frame) => SentryStackFrame(
  absPath: scrubFrame(frame.absPath),
  fileName: scrubFrame(frame.fileName),
  function: frame.function,
  module: frame.module,
  lineNo: frame.lineNo,
  colNo: frame.colNo,
  inApp: frame.inApp,
  package: frame.package,
  native: frame.native,
  platform: frame.platform,
);

/// The OS and what kind of machine it is, which is what a bug report wants,
/// and nothing that says whose machine.
///
/// The device's own `name` is the first thing dropped: on a phone it is
/// whatever the owner called it, which is often their name. `kernelVersion`
/// and `rawDescription` go with it — on Linux those are `uname` output, and
/// this file does not gamble on which fields of it Sentry chose to include.
Contexts _contexts(Contexts contexts) {
  final os = contexts.operatingSystem;
  final device = contexts.device;
  return Contexts(
    operatingSystem: os == null
        ? null
        : SentryOperatingSystem(name: os.name, version: os.version),
    device: device == null
        ? null
        : SentryDevice(
            family: device.family,
            model: device.model,
            manufacturer: device.manufacturer,
            brand: device.brand,
            arch: device.arch,
            simulator: device.simulator,
          ),
    // Dart's and Flutter's own versions.
    runtimes: contexts.runtimes,
  );
}
