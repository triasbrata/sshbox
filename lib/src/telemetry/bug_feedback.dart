import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'crash_reporting.dart';
import 'scrub.dart';

/// Where a bug report's log goes: Sentry, and only Sentry. The public issue
/// carries the event id and never the log, the repository being public.
abstract class BugFeedback {
  /// Whether this build can send the log at all: it has a DSN.
  bool get available;

  /// Sends the report as a feedback event with [log] attached, under [id].
  /// False when it could not be delivered.
  Future<bool> send({
    required SentryId id,
    required String message,
    String? log,
  });
}

/// The app's own.
class SentryBugFeedback implements BugFeedback {
  const SentryBugFeedback();

  @override
  bool get available => crashReportingConfigured;

  @override
  Future<bool> send({
    required SentryId id,
    required String message,
    String? log,
  }) async {
    if (!available) return false;
    // Telemetry off, or switched off since the app started, leaves Sentry
    // not running. The user has just asked for this one report, so it is
    // started for it alone — without the native SDK, which stays off — and
    // closed again, with the framework's handlers put back as they were.
    final started = Sentry.isEnabled;
    final onError = FlutterError.onError;
    final onPlatform = PlatformDispatcher.instance.onError;
    try {
      if (!started) {
        await SentryFlutter.init((options) {
          configureCrashReporting(options);
          options.autoInitializeNativeSdk = false;
        });
      }
      final sent = await sendFeedbackEvent(id: id, message: message, log: log);
      return sent;
    } catch (_) {
      return false;
    } finally {
      if (!started) {
        await Sentry.close();
        FlutterError.onError = onError;
        PlatformDispatcher.instance.onError = onPlatform;
      }
    }
  }
}

/// The event itself: a feedback event whose id is [id], so the dialog could
/// show it before anything was sent, and whose attachment is [log], already
/// scrubbed line by line when [AppLog] stored it.
Future<bool> sendFeedbackEvent({
  required SentryId id,
  required String message,
  String? log,
}) async {
  final hint =
      (log == null
            ? Hint()
            : Hint.withAttachment(
                SentryAttachment.fromUint8List(
                  utf8.encode(log),
                  'jeansh-log.txt',
                  contentType: 'text/plain',
                ),
              ))
        ..set(reportHintKey, true);
  final sent = await Sentry.captureEvent(
    SentryEvent(
      eventId: id,
      type: 'feedback',
      level: SentryLevel.info,
      contexts: Contexts(feedback: SentryFeedback(message: scrub(message))),
    ),
    hint: hint,
  );
  return sent == id;
}

/// The app's own, for the dialog; a test passes another.
const sentryBugFeedback = SentryBugFeedback();
