import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';

class _NoSecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String? value) async {}

  @override
  Future<void> purgeHost(String hostId) async {}
}

/// A shell that is up the moment it is asked for, on a host that answers
/// every command with [reply], whenever the test completes it.
class _Host implements SessionTransport, TerminalSession, CommandCapable {
  final commands = <String>[];
  final reply = Completer<List<String>>();

  @override
  Future<TerminalSession> connect({
    required HostProfile host,
    required SecretStore secrets,
    required int columns,
    required int rows,
    bool shell = true,
  }) async => this;

  @override
  final status = ValueNotifier(SessionStatus.connected);

  @override
  Stream<String> get output => const Stream.empty();

  @override
  String? get failure => null;

  @override
  void send(String data) {}

  @override
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) {}

  @override
  Future<void> dispose() async {}

  @override
  Stream<String> run(String command, {bool pty = false}) {
    commands.add(command);
    return Stream.fromFuture(reply.future).expand((lines) => lines);
  }
}

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
      final first = manager.open(_host);
      final second = manager.resume(_host.id)!;

      // Identity matters, not equality: resuming means landing back on the
      // very same Terminal, with its scrollback intact.
      expect(identical(first, second), isTrue);
      expect(identical(first.terminal, second.terminal), isTrue);
    });

    test('keeps sessions for different hosts apart', () {
      manager.open(_host);

      expect(manager.resume(_otherHost.id), isNull);
      expect(manager.sessions.length, 1);
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
      expect(identical(manager.resume(_host.id), first), isTrue);

      // The host list leaves it standing as the one you were in.
      manager.select(null);
      expect(identical(manager.resume(_host.id), first), isTrue);

      // Coming from another host there is no "last", so the newest wins.
      manager.open(_otherHost);
      expect(identical(manager.resume(_host.id), second), isTrue);
      expect(manager.sessions, hasLength(3));
    });

    test('has nothing to resume once its only session is closed', () async {
      final first = manager.open(_host);
      await manager.close(first.id);

      expect(manager.sessionsFor(_host.id), isEmpty);
      expect(manager.resume(_host.id), isNull);
    });

    test('reports no session before one is opened', () {
      expect(manager.sessionsFor(_host.id), isEmpty);
    });

    test('an opened but unconnected session is not counted as live', () {
      final session = manager.open(_host);

      // The session exists, so a notification tap resumes it — but nothing is
      // attached yet, which is what the host list badge reflects.
      expect(manager.sessionsFor(_host.id), [session]);
      expect(session.isConnected, isFalse);
      expect(manager.liveCount, 0);
    });

    test('tracks the session a shared file should go to', () async {
      expect(manager.active, isNull);

      final first = manager.open(_host);
      expect(identical(manager.active, first), isTrue);

      final second = manager.open(_otherHost);
      expect(identical(manager.active, second), isTrue);

      // Resuming an older session makes it the active one again.
      manager.resume(_host.id);
      expect(identical(manager.active, first), isTrue);

      await manager.close(first.id);
      expect(manager.active, isNull);
    });

    test('hands queued shares over exactly once', () {
      final session = manager.open(_host);
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

      final first = manager.open(_host);
      expect(manager.activeId, first.id);

      final second = manager.open(_otherHost);
      expect(manager.activeId, second.id);

      // Resuming is a selection too — this is the notification-tap path.
      manager.resume(_host.id);
      expect(manager.activeId, first.id);
    });

    test('closing the showing tab falls back to its left neighbour', () async {
      final first = manager.open(_host);
      final second = manager.open(_otherHost);
      final third = manager.open(_thirdHost);

      await manager.close(third.id);
      expect(manager.activeId, second.id);

      await manager.close(second.id);
      expect(manager.activeId, first.id);

      // Nothing to the left of the first session: the host list is home.
      await manager.close(first.id);
      expect(manager.activeId, isNull);
    });

    test('closing a tab you are not looking at keeps the selection', () async {
      final first = manager.open(_host);
      final second = manager.open(_otherHost);

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
      final session = manager.open(_host);

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

    test('a search result carries its line to the file tab it opens', () {
      final session = manager.open(_host);

      manager.openFile(session.id, '/etc/hosts', line: 12);
      expect(manager.activeLine, 12);

      // Another result in the same file moves it there.
      manager.openFile(session.id, '/etc/hosts', line: 40);
      expect(manager.activePath, '/etc/hosts');
      expect(manager.activeLine, 40);

      // Shown again from the tab strip, it stays where the user left it.
      manager.select(session.id);
      manager.select(session.id, kind: TabKind.file, path: '/etc/hosts');
      expect(manager.activeLine, isNull);
    });

    test('picking the same file again returns to its tab', () {
      final session = manager.open(_host);
      manager.openFile(session.id, '/etc/hosts');
      manager.select(session.id);

      manager.openFile(session.id, '/etc/hosts');

      // One tab, not two — and it is the one showing.
      expect(session.openFiles, ['/etc/hosts']);
      expect(manager.activeKind, TabKind.file);
      expect(manager.activePath, '/etc/hosts');
    });

    test('several files from one session each get a tab, in order', () {
      final session = manager.open(_host);

      manager.openFile(session.id, '/etc/hosts');
      manager.openFile(session.id, '/var/log/syslog');

      expect(session.openFiles, ['/etc/hosts', '/var/log/syslog']);
    });

    test('a file tab is named host · file, by the host list until connected',
        () {
      final session = manager.open(_host);

      expect(
        session.fileTabTitle('/etc/nginx/nginx.conf'),
        'box · nginx.conf',
      );
    });

    test('closing a session takes its file tabs with it', () async {
      final session = manager.open(_host);
      manager.openFile(session.id, '/etc/hosts');

      await manager.close(session.id);

      expect(manager.sessionsFor(_host.id), isEmpty);
      // Not left pointing at a file tab whose session is gone.
      expect(manager.activeId, isNull);
      expect(manager.activeKind, TabKind.terminal);
      expect(manager.activePath, isNull);
    });

    test('a link opens as a web tab beside its shell', () {
      final session = manager.open(_host);
      final url = Uri.parse('http://box.ts.net:3001/');

      manager.openWeb(session.id, url);
      final page = session.webTabs.single;
      expect(page.url, url);
      expect(manager.activeKind, TabKind.web);
      expect(manager.activeWeb, same(page));

      // The same link again goes back to its tab rather than stacking another.
      manager.select(session.id);
      manager.openWeb(session.id, url);
      expect(session.webTabs, [page]);
      expect(manager.activeWeb, same(page));

      // Closing it lands on the shell that opened it, which keeps running.
      manager.closeWeb(session.id, page);
      expect(session.webTabs, isEmpty);
      expect(manager.activeKind, TabKind.terminal);
      expect(manager.activeWeb, isNull);
      expect(manager.sessionsFor(_host.id), [session]);
    });

    test('a web tab is named by its page title, and by its host till then',
        () {
      final session = manager.open(_host);
      final page = session.openWeb(Uri.parse('https://vitejs.dev/guide/'));
      expect(page.title, 'vitejs.dev');

      session.updateWeb(page, url: page.url, title: 'Getting Started | Vite');
      expect(page.title, 'Getting Started | Vite');

      // A new page is named by its host until it has loaded a title of its
      // own, and a page with none keeps it.
      final next = Uri.parse('https://github.com/vitejs/vite');
      session.updateWeb(page, url: next);
      expect(page.title, 'github.com');
      session.updateWeb(page, url: next, title: '  ');
      expect(page.title, 'github.com');
    });

    test('a web tab stays open while its shell reconnects', () async {
      final session = manager.open(_host);
      final page = session.openWeb(Uri.parse('https://dart.dev'));

      // No password saved, so this fails before a socket is opened — but the
      // page never needed the connection, and is left where it was.
      await session.reconnect(secrets: _NoSecrets());

      expect(session.webTabs, [page]);
    });

    test('closing a session takes its web tabs with it', () async {
      final session = manager.open(_host);
      manager.openWeb(session.id, Uri.parse('https://dart.dev'));

      await manager.close(session.id);

      expect(manager.sessionsFor(_host.id), isEmpty);
      // Not left pointing at a web tab whose session is gone.
      expect(manager.activeId, isNull);
      expect(manager.activeKind, TabKind.terminal);
      expect(manager.activeWeb, isNull);
    });

    test('notifies listeners when a session opens and closes', () async {
      var notifications = 0;
      manager.addListener(() => notifications++);

      final session = manager.open(_host);
      expect(notifications, greaterThan(0));

      final afterOpen = notifications;
      await manager.close(session.id);
      expect(notifications, greaterThan(afterOpen));
    });
  });

  group("a file tab names the host by the host's own name", () {
    late _Host host;
    late LiveSession session;

    setUp(() async {
      host = _Host();
      session = LiveSession(host: _host, transport: (_, _) => host);
      addTearDown(session.dispose);
      await session.connect(secrets: _NoSecrets());
    });

    test('once the host has said it, redrawing an open tab', () async {
      var notified = 0;
      session.addListener(() => notified++);

      // Asked on connect, not when a tab is drawn; the host list's name holds
      // the place until the answer comes.
      expect(host.commands, contains('uname -n'));
      expect(session.fileTabTitle('/home/me/main.dart'), 'box · main.dart');

      host.reply.complete(['DESKTOP-L2EPDPG']);
      await pumpEventQueue();

      expect(
        session.fileTabTitle('/home/me/main.dart'),
        'DESKTOP-L2EPDPG · main.dart',
      );
      expect(notified, greaterThan(0));
    });

    test('cut at the first dot, as a prompt cuts it', () async {
      host.reply.complete(['build.example.com']);
      await pumpEventQueue();

      expect(session.fileTabTitle('/srv/app.py'), 'build · app.py');
    });

    test('keeps the host list name when the host prints nothing', () async {
      host.reply.complete([]);
      await pumpEventQueue();

      expect(session.fileTabTitle('/srv/app.py'), 'box · app.py');
    });

    test('keeps the host list name when the command fails', () async {
      host.reply.completeError(const SshSessionException('Not connected.'));
      await pumpEventQueue();

      expect(session.fileTabTitle('/srv/app.py'), 'box · app.py');
    });
  });
}
