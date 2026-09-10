import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';

const _host = HostProfile(
  id: 'host-1',
  label: 'box',
  host: '10.0.2.2',
  username: 'me',
);

const _otherHost = HostProfile(
  id: 'host-2',
  label: 'other',
  host: '10.0.2.3',
  username: 'me',
);

void main() {
  group('SessionManager resume rule', () {
    late SessionManager manager;

    setUp(() => manager = SessionManager());

    test('returns the same session for a host that is already open', () {
      final first = manager.openOrCreate(_host);
      final second = manager.openOrCreate(_host);

      // Identity matters, not equality: resuming means landing back on the
      // very same Terminal, with its scrollback intact.
      expect(identical(first, second), isTrue);
      expect(identical(first.terminal, second.terminal), isTrue);
    });

    test('keeps sessions for different hosts apart', () {
      final a = manager.openOrCreate(_host);
      final b = manager.openOrCreate(_otherHost);

      expect(identical(a, b), isFalse);
      expect(manager.sessions.length, 2);
    });

    test('creates a fresh session after the previous one is closed', () async {
      final first = manager.openOrCreate(_host);
      await manager.close(_host.id);

      expect(manager.hasSession(_host.id), isFalse);

      final second = manager.openOrCreate(_host);
      expect(identical(first, second), isFalse);
    });

    test('reports no session before one is opened', () {
      expect(manager.hasSession(_host.id), isFalse);
      expect(manager.isConnected(_host.id), isFalse);
      expect(manager.find(_host.id), isNull);
    });

    test('an opened but unconnected session is not counted as live', () {
      manager.openOrCreate(_host);

      // The session exists, so a tap resumes it — but nothing is attached yet,
      // which is what the host list badge reflects.
      expect(manager.hasSession(_host.id), isTrue);
      expect(manager.isConnected(_host.id), isFalse);
      expect(manager.liveCount, 0);
    });

    test('tracks the session a shared file should go to', () async {
      expect(manager.active, isNull);

      final first = manager.openOrCreate(_host);
      expect(identical(manager.active, first), isTrue);

      final second = manager.openOrCreate(_otherHost);
      expect(identical(manager.active, second), isTrue);

      // Resuming an older session makes it the active one again.
      manager.openOrCreate(_host);
      expect(identical(manager.active, first), isTrue);

      await manager.close(_host.id);
      expect(manager.active, isNull);
    });

    test('hands queued shares over exactly once', () {
      final session = manager.openOrCreate(_host);
      expect(session.hasPendingUploads, isFalse);

      session.queueUploads([(path: '/cache/a.txt', name: 'a.txt')]);
      expect(session.hasPendingUploads, isTrue);

      // Taking drains the queue: a rebuild must not upload the same file twice.
      expect(session.takePendingUploads(), hasLength(1));
      expect(session.hasPendingUploads, isFalse);
      expect(session.takePendingUploads(), isEmpty);
    });

    test('notifies listeners when a session opens and closes', () async {
      var notifications = 0;
      manager.addListener(() => notifications++);

      manager.openOrCreate(_host);
      expect(notifications, greaterThan(0));

      final afterOpen = notifications;
      await manager.close(_host.id);
      expect(notifications, greaterThan(afterOpen));
    });
  });
}
