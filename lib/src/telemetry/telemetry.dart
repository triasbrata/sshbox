import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'scrub.dart';

/// Jeansh's own Worker: the daily count, and the bug reports somebody chose
/// to send without their name on them. Not a secret and not baked in the way
/// the update host is — there is nothing to hide about it, and the relay for
/// notifications is named in the source the same way.
const telemetryHost = 'https://jeansh-telemetry.brata.cloud';

/// Where crashes go, baked in at build time with
/// `--dart-define JEANSH_SENTRY_DSN=https://…` (see tools/build_desktop.sh,
/// tools/build_apple.sh and tool/release.sh). Empty — a debug build, or a
/// release built without it — means crash reporting is off, and Settings says
/// so rather than pretending.
///
/// A Sentry DSN is not really a secret: every web app that uses Sentry has
/// one in its JavaScript, and the worst somebody can do with it is send junk.
/// It is kept out of the source all the same, because this repository is
/// public, and a DSN sitting in it is an invitation to fill the quota.
const sentryDsn = String.fromEnvironment('JEANSH_SENTRY_DSN');

/// The most a bug report's body may be. The Worker refuses more, and the
/// named route has to fit in a URL besides — see `bug_report.dart`.
const maxReportBody = 8000;

/// Sends [body] to [url] and gives back what the server answered with, which
/// a test stands in for so nothing in one ever reaches the network — the same
/// shape as the updater's `Fetch`, and for the same reason.
typedef Post = Future<({int status, String body})> Function(
  Uri url,
  String body,
);

/// Whether anything at all is sent: the daily count and the crash reports
/// together, as the user asked for one switch rather than two.
///
/// On by default. That means the first launch of a new install sends its
/// count before the user has said anything, which is why the app shows
/// a one-time notice pointing at this switch — see [Telemetry.claimFirstRunNotice].
///
/// Reporting a bug is deliberately *not* governed by this: the user pressing
/// "Report a bug" and reading what will be sent is their own act, not
/// background collection, and it keeps working with this off.
class TelemetrySetting extends ValueNotifier<bool> {
  TelemetrySetting() : super(true);

  static const _key = 'sshbox.telemetry.on';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    value = prefs.getBool(_key) ?? true;
  }

  /// Turning it off takes effect on the spot for everything Dart sends: the
  /// daily count stops being sent and `beforeSend` drops every event. What it
  /// cannot undo until the app is started again is the native crash handler
  /// that `SentryFlutter.init` installed on Android and iOS — see
  /// `stopCrashReporting`.
  Future<void> choose(bool on) async {
    value = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, on);
  }
}

/// The app's one; `main` reads the saved choice into it before `runApp`,
/// because whether Sentry is started at all depends on it.
final telemetryOn = TelemetrySetting();

/// What Jeansh counts, and how it counts it.
///
/// The whole of it: an install id that is a random UUID made here and kept
/// here, the app's version and build, the platform, and the OS version —
/// sent at most once a day. Never a device id, an advertising id, a serial
/// number or anything else the hardware knows about itself, because a count
/// of people running Jeansh does not need one and a number that follows a
/// person around is not worth having.
class Telemetry {
  Telemetry({
    Post? post,
    this.host = telemetryHost,
    this.enabled,
    this.debugBuild = kDebugMode,
  }) : _post = post ?? _send;

  final Post _post;
  final String host;

  /// A debug build sends no count: every e2e run and every UAT APK is one,
  /// each starting from clean data with a new install id, so each would
  /// count as a new install. People run release builds. A test sets it.
  final bool debugBuild;

  /// Whether to send, for a test that must not depend on the app's own
  /// switch. Null reads [telemetryOn].
  final bool Function()? enabled;

  bool get _on => enabled?.call() ?? telemetryOn.value;

  static const installKey = 'sshbox.telemetry.install';
  static const pingedKey = 'sshbox.telemetry.pinged';
  static const noticeKey = 'sshbox.telemetry.notice';
  static const every = Duration(days: 1);

  /// True exactly once, on the first run of a new install: whether to say
  /// that telemetry is on and where to turn it off.
  ///
  /// It is opt-out, so the first count goes before the user has said
  /// anything. Telling them afterwards is not as good as asking first, but a
  /// dialog in the way of the first launch is worse, and this is the shape
  /// the user chose.
  Future<bool> claimFirstRunNotice() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(noticeKey) ?? false) return false;
    await prefs.setBool(noticeKey, true);
    return true;
  }

  /// This install's random id, made the first time it is asked for and kept
  /// in the same settings file as everything else. Clearing the app's data
  /// makes a new one, which is the right answer: it is an install, not a
  /// person.
  Future<String> installId() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(installKey);
    if (saved != null && saved.isNotEmpty) return saved;
    // v4: random, from the platform's own source, with nothing of the machine
    // in it — a v1 would carry a MAC address.
    final id = const Uuid().v4();
    await prefs.setString(installKey, id);
    return id;
  }

  /// The five things a report or a count carries, and nothing else.
  ///
  /// The OS version is `dart:io`'s, which on Linux and Android is the kernel's
  /// `uname` release and version — no machine name in it, `uname` keeping
  /// that in a field of its own that Dart does not read. It is scrubbed and
  /// cut short all the same, on the grounds that a string from the outside
  /// world gets the same treatment wherever it came from.
  ///
  /// ponytail: on Android that means a kernel string rather than "Android 15",
  /// which is a rougher answer than it could be. device_info_plus would give
  /// the real one, and is a new dependency for one field.
  Future<Map<String, Object>> facts() async {
    final info = await PackageInfo.fromPlatform();
    final version = scrub(Platform.operatingSystemVersion);
    return {
      'version': info.version,
      'build': info.buildNumber,
      'platform': Platform.operatingSystem,
      'os': version.length > 120 ? version.substring(0, 120) : version,
    };
  }

  /// The count, at most once a day, and never a word about it if it fails.
  ///
  /// Nothing waits on this and nothing retries it: a Worker that is down, a
  /// tablet with no signal or a DNS that will not answer costs the user
  /// nothing at all, and the day is marked as counted either way so a machine
  /// that cannot reach the Worker does not try again at every launch.
  Future<void> pingDaily() async {
    if (debugBuild || !_on) return;
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt(pingedKey) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - last < every.inMilliseconds) return;
    await prefs.setInt(pingedKey, now);
    try {
      final body = jsonEncode({'install': await installId(), ...await facts()});
      await _post(Uri.parse('$host/ping'), body);
    } catch (_) {
      // A count is not worth a word to the user or a line in a log.
    }
  }

  /// A bug report sent without the user's name on it: the Worker opens the
  /// issue itself. Gives back where it landed, and throws a line fit to show
  /// when it did not.
  ///
  /// Not governed by [telemetryOn] — the user pressed the button.
  Future<String> report(String title, String body) async {
    final ({int status, String body}) answer;
    try {
      answer = await _post(
        Uri.parse('$host/issue'),
        jsonEncode({
          'install': await installId(),
          'title': title,
          'body': body.length > maxReportBody
              ? body.substring(0, maxReportBody)
              : body,
        }),
      );
    } catch (error) {
      throw TelemetryException(
        'Could not reach the bug relay: ${scrub('$error')}',
      );
    }
    if (answer.status == 429) {
      throw const TelemetryException(
        'That is several reports from here today already. Try tomorrow, or '
        'send it under your own name on GitHub.',
      );
    }
    if (answer.status == 403) {
      throw const TelemetryException(
        'Anonymous reports are switched off at the moment. Sending it under '
        'your own name on GitHub still works.',
      );
    }
    if (answer.status != 200) {
      throw TelemetryException(
        'The bug relay answered ${answer.status}. Sending it under your own '
        'name on GitHub still works.',
      );
    }
    final Object? decoded = jsonDecode(answer.body);
    final url = decoded is Map ? decoded['url'] : null;
    if (url is! String || url.isEmpty) {
      throw const TelemetryException(
        'The bug relay took it but said nothing about where it went.',
      );
    }
    return url;
  }

  /// One POST of JSON, with no credential of any kind: the Worker takes an
  /// anonymous body and that is the whole of the protocol.
  static Future<({int status, String body})> _send(Uri url, String body) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent = 'Jeansh';
    try {
      final request = await client.postUrl(url);
      request.headers.contentType = ContentType.json;
      request.write(body);
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final answer = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 20));
      return (status: response.statusCode, body: answer);
    } finally {
      client.close(force: true);
    }
  }
}

/// Anything the telemetry has to say for itself, in a line fit to show.
class TelemetryException implements Exception {
  const TelemetryException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The app's own, which the startup ping and the bug report share.
final telemetry = Telemetry();
