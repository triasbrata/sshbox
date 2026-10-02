import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:path_provider/path_provider.dart';

import 'scrub.dart';

/// What a bug report carries so a developer can see what happened, not only
/// what the user wrote: a bounded ring of the app's own recent events.
///
/// **Only the app writes to it, and only what the app itself says.** Every
/// call site passes a line it composed — a toast, a lifecycle step, an error's
/// type and trace — and nothing here reads a terminal, a text field, the
/// clipboard or a file. Each line is run through [scrub] before it is stored,
/// so a hostname or a path that slips into an error message is already gone
/// when the ring is written to disk, shown to the user or attached anywhere.
class AppLog {
  AppLog({
    this.maxLines = 1000,
    this.maxBytes = 256 * 1024,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int maxLines;
  final int maxBytes;
  final DateTime Function() _clock;

  /// The most one line may be: a stack frame or a long message is cut rather
  /// than let one line push the rest out.
  static const maxLine = 1000;

  final _lines = <String>[];
  var _bytes = 0;

  /// The run before this one, read at [load]: the half of a report that
  /// explains a crash.
  String _previous = '';

  File? _file;
  File? _previousFile;

  int get length => _lines.length;

  /// A line, scrubbed, with when it was and how serious.
  ///
  /// [scrubbed] says the caller already ran [scrub] (a stack trace goes
  /// through [scrubStackLine], which keeps `package:` frames readable and
  /// which a second pass would mangle).
  void add(String text, {String level = 'I', bool scrubbed = false}) {
    final flat = text.replaceAll(RegExp(r'\s*\n\s*'), ' ⏎ ').trim();
    var line = scrubbed ? flat : scrub(flat);
    if (line.isEmpty) return;
    if (line.length > maxLine) line = '${line.substring(0, maxLine)}…';
    final stamped = '${_clock().toUtc().toIso8601String()} $level $line';
    _lines.add(stamped);
    _bytes += utf8.encode(stamped).length + 1;
    while (_lines.isNotEmpty &&
        (_lines.length > maxLines || _bytes > maxBytes)) {
      _bytes -= utf8.encode(_lines.removeAt(0)).length + 1;
    }
  }

  void warn(String text) => add(text, level: 'W');
  void error(String text, {bool scrubbed = false}) =>
      add(text, level: 'E', scrubbed: scrubbed);

  /// This run's lines, oldest first.
  String get current => _lines.join('\n');

  /// Exactly what a report attaches and the dialog shows: the run before,
  /// then this one.
  String render() {
    final out = StringBuffer();
    if (_previous.isNotEmpty) {
      out
        ..writeln('--- previous run ---')
        ..writeln(_previous)
        ..writeln('--- this run ---');
    }
    out.write(current);
    return out.toString();
  }

  /// Opens the log in [dir] (the app's private support folder by default):
  /// what the last run left becomes the previous run, and anything older is
  /// gone.
  Future<void> load({Directory? dir}) async {
    try {
      dir ??= await getApplicationSupportDirectory();
      await dir.create(recursive: true);
      _file = File('${dir.path}/applog.current');
      _previousFile = File('${dir.path}/applog.previous');
      if (await _file!.exists()) {
        _previous = await _file!.readAsString();
        // Created and made private before a byte is written.
        if (!await _previousFile!.exists()) {
          await _previousFile!.create();
          await _private(_previousFile!);
        }
        await _previousFile!.writeAsString(_previous);
      } else if (await _previousFile!.exists()) {
        // Opened twice with nothing run between: still the run before.
        _previous = await _previousFile!.readAsString();
      }
    } catch (_) {
      // A log that cannot be kept is still a log in memory.
    }
  }

  /// Writes this run to disk, 0600: on pause and on a fatal error.
  Future<void> flush() async {
    final file = _file;
    if (file == null) return;
    try {
      if (!await file.exists()) {
        await file.create();
        await _private(file);
      }
      await file.writeAsString(current, flush: true);
    } catch (_) {}
  }

  /// Dart has no chmod; Windows keeps a file in the user's own profile and iOS
  /// cannot run one (its app folder is private to the app already).
  static Future<void> _private(File file) async {
    if (Platform.isWindows || Platform.isIOS) return;
    await Process.run('chmod', ['600', file.path]);
  }
}

/// The app's one.
final appLog = AppLog();

var _watching = false;

/// Chains the app's own error paths and `debugPrint` into [appLog], and
/// flushes it when the app pauses. Called once, after the framework's and
/// Sentry's handlers are in place, so it sees what they see and consumes
/// nothing.
///
/// **A `debugPrint` line goes into bug reports.** It is scrubbed, but a
/// pattern scrubber cannot know a file name or a session name, so a
/// `debugPrint` must never carry host text: print a type or a fixed phrase.
void watchAppLog() {
  if (_watching) return;
  _watching = true;
  final inner = FlutterError.onError;
  FlutterError.onError = (details) {
    inner?.call(details);
    appLog.error(
      _trace(
        'flutter',
        details.exception.runtimeType.toString(),
        details.exceptionAsString(),
        details.stack,
      ),
      scrubbed: true,
    );
    unawaited(appLog.flush());
  };
  final dispatcher = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    appLog.error(
      _trace('platform', error.runtimeType.toString(), error.toString(), stack),
      scrubbed: true,
    );
    unawaited(appLog.flush());
    return dispatcher?.call(error, stack) ?? false;
  };
  final print = debugPrint;
  debugPrint = (message, {wrapWidth}) {
    if (message != null) appLog.add('print $message');
    print(message, wrapWidth: wrapWidth);
  };
  // An observer, not an AppLifecycleListener: that one asserts on a state
  // jump such as resumed to hidden, which a real minimize on Linux makes.
  WidgetsBinding.instance.addObserver(_observer = _FlushOnLeave());
}

_FlushOnLeave? _observer;

/// Undoes [watchAppLog]'s observer and once-only guard, for a test that
/// watches more than once. The handlers it chained the test restores itself.
@visibleForTesting
void unwatchAppLog() {
  final observer = _observer;
  if (observer != null) WidgetsBinding.instance.removeObserver(observer);
  _observer = null;
  _watching = false;
}

/// Flushes the log whenever the app leaves the foreground, by any route.
/// Lives as long as the app, so it is never removed.
class _FlushOnLeave with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(appLog.flush());
  }
}

/// An error as one line: its text, then the first frames, in the same shape a
/// bug report's fault text takes ([scrubStackLine] keeps `package:` frames).
String _trace(String where, String type, String what, StackTrace? stack) {
  final frames = stack
      ?.toString()
      .split('\n')
      .take(8)
      .map((line) => scrubStackLine(line.trim()))
      .where((line) => line.isNotEmpty)
      .join(' | ');
  // The crash path's rule: an exception type whose text is host output by
  // construction keeps its type and frames, not its message.
  final message = scrubValue(type, what);
  return '$where $type: $message${frames == null || frames.isEmpty ? '' : ' | $frames'}';
}
