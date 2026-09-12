import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_log.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/logs_page.dart';

class _NoSecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String? value) async {}

  @override
  Future<void> purgeHost(String hostId) async {}
}

/// A shell that comes up the moment it is asked for, unless it refuses.
class _Shell implements SessionTransport, TerminalSession {
  _Shell({this.refuse = false});

  final bool refuse;

  @override
  final status = ValueNotifier(SessionStatus.connected);

  @override
  Future<TerminalSession> connect({
    required HostProfile host,
    required SecretStore secrets,
    required int columns,
    required int rows,
    bool shell = true,
    Map<String, String> environment = const {},
  }) async {
    if (refuse) throw const SshSessionException('Connection refused.');
    return this;
  }

  @override
  Stream<String> get output => const Stream.empty();

  @override
  Future<void> dispose() async {}

  /// send, resize and failure: nothing to do, nothing to say.
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

const _host = HostProfile(id: 'h', label: 'WSL', host: 'box', username: 'me');

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// The log as the next app start reads it. Whoever changed it did not wait
  /// for the write.
  Future<SessionLog> reloaded() async {
    await pumpEventQueue();
    final log = SessionLog();
    await log.load();
    return log;
  }

  test('an entry starts open, ends, and reads back the same', () async {
    final log = SessionLog();
    await log.load();
    // An install from before the log.
    expect(log.entries, isEmpty);

    final entry = log.start(_host);
    expect((await reloaded()).entries.single.end, isNull);

    log.end(entry);
    final back = (await reloaded()).entries.single;
    expect(back.host.toJson(), _host.toJson());
    expect(back.start, entry.start);
    expect(back.end, entry.end);
    expect(back.saved, isFalse);
  });

  test('keeps every saved entry and the newest 200 unsaved', () async {
    final log = SessionLog();
    final kept = log.start(_host.copyWith(label: 'kept'));
    log.toggleSaved(kept);
    for (var i = 0; i < 210; i++) {
      log.start(_host.copyWith(label: '$i'));
    }

    for (final entries in [log.entries, (await reloaded()).entries]) {
      expect(entries, hasLength(201));
      expect(entries.first.host.label, '209');
      expect(entries[199].host.label, '10');
      expect(entries.last.host.label, 'kept');
      expect(entries.last.saved, isTrue);
    }
  });

  test('times read as a range, with the days it ran past midnight', () {
    expect(
      sessionTimes(DateTime(2026, 9, 12, 5, 56), DateTime(2026, 9, 12, 10, 38)),
      '05:56 – 10:38',
    );
    expect(
      sessionTimes(DateTime(2026, 9, 4, 16, 12), DateTime(2026, 9, 5, 11, 14)),
      '16:12 – 11:14 (+1d)',
    );
    // The app was killed under it.
    expect(sessionTimes(DateTime(2026, 9, 1, 20, 52), null), '20:52');
  });

  test('a tab is logged from connect to close, a reconnect anew', () async {
    final log = SessionLog();
    final sessions = SessionManager();
    log.follow(sessions);

    final refused = sessions.open(
      _host,
      transport: (_, _) => _Shell(refuse: true),
    );
    await refused.connect(secrets: _NoSecrets());
    expect(log.entries, isEmpty);

    final session = sessions.open(_host, transport: (_, _) => _Shell());
    expect(log.entries, isEmpty);
    await session.connect(secrets: _NoSecrets());
    expect(log.entries.single.end, isNull);

    await session.reconnect(secrets: _NoSecrets());
    expect(log.entries, hasLength(2));
    expect(log.entries.last.end, isNotNull);
    expect(log.entries.first.end, isNull);

    await sessions.close(session.id);
    expect(log.entries.first.end, isNotNull);
  });
}
