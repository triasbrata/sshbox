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

const _thirdHost = HostProfile(
  id: 'host-3',
  label: 'third',
  host: '10.0.2.4',
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

    test('opening a host from the list again starts another session', () {
      final first = manager.open(_host);
      final second = manager.open(_host);

      expect(identical(first, second), isFalse);
      expect(manager.sessionsFor(_host.id), [first, second]);
      expect(manager.activeId, second.id);
    });

    test('resuming a host with several sessions picks the one you were in', () {
      final first = manager.open(_host);
      final second = manager.open(_host);

      manager.select(first.id);
      expect(identical(manager.openOrCreate(_host), first), isTrue);

      // The host list leaves it standing as the one you were in.
      manager.select(null);
      expect(identical(manager.openOrCreate(_host), first), isTrue);

      // Coming from another host there is no "last", so the newest wins.
      manager.open(_otherHost);
      expect(identical(manager.openOrCreate(_host), second), isTrue);
      expect(manager.sessions, hasLength(3));
    });

    test('creates a fresh session after the previous one is closed', () async {
      final first = manager.openOrCreate(_host);
      await manager.close(first.id);

      expect(manager.sessionsFor(_host.id), isEmpty);

      final second = manager.openOrCreate(_host);
      expect(identical(first, second), isFalse);
    });

    test('reports no session before one is opened', () {
      expect(manager.sessionsFor(_host.id), isEmpty);
    });

    test('an opened but unconnected session is not counted as live', () {
      final session = manager.openOrCreate(_host);

      // The session exists, so a notification tap resumes it — but nothing is
      // attached yet, which is what the host list badge reflects.
      expect(manager.sessionsFor(_host.id), [session]);
      expect(session.isConnected, isFalse);
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

      await manager.close(first.id);
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

    test('opening a host makes it the showing tab', () {
      expect(manager.activeId, isNull);

      final first = manager.openOrCreate(_host);
      expect(manager.activeId, first.id);

      final second = manager.openOrCreate(_otherHost);
      expect(manager.activeId, second.id);

      // Resuming is a selection too — this is the notification-tap path.
      manager.openOrCreate(_host);
      expect(manager.activeId, first.id);
    });

    test('closing the showing tab falls back to its left neighbour', () async {
      final first = manager.openOrCreate(_host);
      final second = manager.openOrCreate(_otherHost);
      final third = manager.openOrCreate(_thirdHost);

      await manager.close(third.id);
      expect(manager.activeId, second.id);

      await manager.close(second.id);
      expect(manager.activeId, first.id);

      // Nothing to the left of the first session: the host list is home.
      await manager.close(first.id);
      expect(manager.activeId, isNull);
    });

    test('closing a tab you are not looking at keeps the selection', () async {
      final first = manager.openOrCreate(_host);
      final second = manager.openOrCreate(_otherHost);

      await manager.close(first.id);
      expect(manager.activeId, second.id);
    });

    test('closing a host closes every session on it', () async {
      manager.open(_host);
      manager.open(_host);
      final other = manager.open(_otherHost);

      await manager.closeHost(_host.id);

      expect(manager.sessionsFor(_host.id), isEmpty);
      expect(manager.sessions, [other]);
    });

    test('an edited host reaches every session open on it, and no other',
        () {
      manager.open(_host);
      manager.open(_host);
      final other = manager.open(_otherHost);

      // A file tree root saved from one tab is where the next reconnect of
      // any tab on that host should open.
      manager.updateHost(_host.copyWith(fileRoot: '/srv'));

      expect(
        manager.sessionsFor(_host.id).map((s) => s.host.fileRoot),
        ['/srv', '/srv'],
      );
      expect(other.host.fileRoot, isEmpty);
    });

    test('a file picked in the drawer gets its own tab', () {
      final session = manager.openOrCreate(_host);

      manager.openFile(session.id, '/etc/nginx/nginx.conf');
      expect(session.openFiles, ['/etc/nginx/nginx.conf']);
      expect(manager.activeId, session.id);
      expect(manager.activeKind, TabKind.file);
      expect(manager.activePath, '/etc/nginx/nginx.conf');

      // Closing it lands on the shell it was opened from; the session itself
      // is untouched.
      manager.closeFile(session.id, '/etc/nginx/nginx.conf');
      expect(session.openFiles, isEmpty);
      expect(manager.activeKind, TabKind.terminal);
      expect(manager.sessionsFor(_host.id), [session]);
    });

    test('picking the same file again returns to its tab', () {
      final session = manager.openOrCreate(_host);
      manager.openFile(session.id, '/etc/hosts');
      manager.select(session.id);

      manager.openFile(session.id, '/etc/hosts');

      // One tab, not two — and it is the one showing.
      expect(session.openFiles, ['/etc/hosts']);
      expect(manager.activeKind, TabKind.file);
      expect(manager.activePath, '/etc/hosts');
    });

    test('several files from one session each get a tab, in order', () {
      final session = manager.openOrCreate(_host);

      manager.openFile(session.id, '/etc/hosts');
      manager.openFile(session.id, '/var/log/syslog');

      expect(session.openFiles, ['/etc/hosts', '/var/log/syslog']);
    });

    test('a file tab is named host > file', () {
      final session = manager.openOrCreate(_host);

      expect(
        session.fileTabTitle('/etc/nginx/nginx.conf'),
        'box > nginx.conf',
      );
    });

    test('closing a session takes its file tabs with it', () async {
      final session = manager.openOrCreate(_host);
      manager.openFile(session.id, '/etc/hosts');

      await manager.close(session.id);

      expect(manager.sessionsFor(_host.id), isEmpty);
      // Not left pointing at a file tab whose session is gone.
      expect(manager.activeId, isNull);
      expect(manager.activeKind, TabKind.terminal);
      expect(manager.activePath, isNull);
    });

    test('notifies listeners when a session opens and closes', () async {
      var notifications = 0;
      manager.addListener(() => notifications++);

      final session = manager.openOrCreate(_host);
      expect(notifications, greaterThan(0));

      final afterOpen = notifications;
      await manager.close(session.id);
      expect(notifications, greaterThan(afterOpen));
    });
  });
}
