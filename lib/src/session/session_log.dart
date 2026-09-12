import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/host_profile.dart';
import 'session_manager.dart';

/// One session that connected: the host as it was then, so the entry still
/// reads right once the host is renamed or deleted, and when it ran.
class SessionLogEntry {
  SessionLogEntry(this.host, this.start, {this.end, this.saved = false});

  factory SessionLogEntry.fromJson(Map<String, dynamic> json) =>
      SessionLogEntry(
        HostProfile.fromJson(json['host'] as Map<String, dynamic>),
        DateTime.fromMicrosecondsSinceEpoch(json['start'] as int),
        end: switch (json['end']) {
          final int end => DateTime.fromMicrosecondsSinceEpoch(end),
          _ => null,
        },
        saved: json['saved'] as bool? ?? false,
      );

  /// The whole profile, which holds no secret — see [HostProfile].
  final HostProfile host;
  final DateTime start;

  /// Null while the session runs, and for good when the app was killed
  /// under it.
  DateTime? end;

  /// Bookmarked on the Logs page: kept past [SessionLog.keepUnsaved].
  bool saved;

  Map<String, dynamic> toJson() => {
    'host': host.toJson(),
    'start': start.microsecondsSinceEpoch,
    'end': end?.microsecondsSinceEpoch,
    'saved': saved,
  };
}

/// Every session that connected, newest first: what the Logs page lists.
///
/// Saved as one JSON list, written when a session starts or ends and when an
/// entry is bookmarked, never while one runs.
class SessionLog extends ChangeNotifier {
  static const _key = 'sshbox.sessionLog.v1';

  /// Unsaved entries kept, newest first. Older ones go at the next write; a
  /// saved one stays until it is unsaved.
  static const keepUnsaved = 200;

  final entries = <SessionLogEntry>[];

  /// An install from before the log, or a corrupt one, starts empty.
  Future<void> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    entries.clear();
    try {
      entries.addAll([
        for (final json in jsonDecode(raw ?? '[]') as List)
          SessionLogEntry.fromJson(json as Map<String, dynamic>),
      ]);
    } catch (_) {
      // A corrupt log costs its entries, not the app's start.
    }
    notifyListeners();
  }

  SessionLogEntry start(HostProfile host) {
    final entry = SessionLogEntry(host, DateTime.now());
    entries.insert(0, entry);
    _changed();
    return entry;
  }

  void end(SessionLogEntry entry) {
    entry.end = DateTime.now();
    _changed();
  }

  void toggleSaved(SessionLogEntry entry) {
    entry.saved = !entry.saved;
    _changed();
  }

  void _changed() {
    final dropped = entries.where((e) => !e.saved).skip(keepUnsaved).toSet();
    entries.removeWhere(dropped.contains);
    notifyListeners();
    unawaited(_write());
  }

  /// The whole list each time, encoded after the await: writes run in the
  /// order they were asked for, and each carries the latest state.
  Future<void> _write() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(entries));
  }

  /// Logs each tab of [sessions] from the moment its shell is up until it
  /// goes down or the tab closes. A reconnect is a new entry, and a connect
  /// that fails is none. Read off the registry's own notifications, so no
  /// session code has to know about the log.
  void follow(SessionManager sessions) {
    final open = <LiveSession, SessionLogEntry>{};
    sessions.addListener(() {
      final live = sessions.sessions;
      // A closed tab can still read as connected while its teardown runs.
      open.removeWhere((session, entry) {
        final over = !session.isConnected || !live.contains(session);
        if (over) end(entry);
        return over;
      });
      for (final session in live) {
        if (session.isConnected && !open.containsKey(session)) {
          open[session] = start(session.host);
        }
      }
    });
  }
}

/// The app's one: `main` loads it, and the app hands it the sessions.
final sessionLog = SessionLog();
