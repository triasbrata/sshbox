import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/db/db_session.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/tabs_shell.dart';

/// A host that is up the moment it is asked for, answers the check for a tmux
/// session with [tmuxThere], and cannot start tmux itself, so a tab that gets
/// past the check falls back to a plain shell.
class _Host
    implements
        SessionTransport,
        TerminalSession,
        CommandCapable,
        ChannelCapable {
  _Host({this.tmuxThere = true});

  final bool tmuxThere;
  final ran = <String>[];
  final opened = <String>[];

  @override
  Future<TerminalSession> connect({
    required HostProfile host,
    required SecretStore secrets,
    required int columns,
    required int rows,
    bool shell = true,
    Map<String, String> environment = const {},
    Future<Map<String, String>> Function(ForwardCapable host)? beforeShell,
  }) async => this;

  @override
  Stream<String> run(String command, {bool pty = false}) {
    ran.add(command);
    return Stream.value(
      command.contains('has-session') ? (tmuxThere ? 'yes' : 'no') : '',
    );
  }

  @override
  Future<CommandChannel> open(String command) async {
    opened.add(command);
    throw const SshSessionException('tmux will not start here');
  }

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
}

/// A database with nothing in it.
class _Db extends DbSession {
  @override
  String get hint => '';

  @override
  Future<Map<String, List<String>>> objects(String filter) async => {};

  @override
  Future<String> queryFor(String group, String name) async => '';

  @override
  Future<DbResult> run(String query) async => const DbResult();
}

const _box = HostProfile(
  id: 'box',
  label: 'box',
  host: 'box.example',
  username: 'me',
  useTmux: true,
);
const _plain = HostProfile(
  id: 'plain',
  label: 'plain',
  host: 'plain.example',
  username: 'me',
);
const _redis = DbConnection(
  id: 'db1',
  kind: DbKind.redis,
  hostId: 'box',
  port: 6379,
);

Future<Object?> _saved() async {
  final raw = (await SharedPreferences.getInstance()).getString(
    'sshbox.tabs.v1',
  );
  return raw == null ? null : jsonDecode(raw);
}

void _saveBefore(Map<String, Object?> tabs) =>
    SharedPreferences.setMockInitialValues({
      'sshbox.tabs.v1': jsonEncode(tabs),
    });

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('open tabs are saved as they change, with nothing secret in them', () async {
    final manager = SessionManager();
    await manager.restoreTabs(hosts: [_box], databases: [_redis]);
    final session = manager.open(_box);
    manager
      ..openFile(session.id, '/etc/hosts')
      ..openWeb(
        session.id,
        Uri.parse('https://me:pw@dev.example:8443/app?token=abc#top'),
      )
      ..openWeb(session.id, Uri.parse('https://login.tailscale.com/a/123'))
      ..openDb(_redis, 'Redis on box');
    await pumpEventQueue();
    expect(await _saved(), {
      'sessions': [
        {
          'hostId': 'box',
          'tmux': session.tmuxName,
          'files': ['/etc/hosts'],
          'web': ['https://dev.example:8443/app'],
        },
      ],
      'databases': ['db1'],
    });

    // Closing a tab takes it off the list.
    await manager.close(session.id);
    manager.closeDb(manager.dbTabs.single);
    await pumpEventQueue();
    expect(await _saved(), {'sessions': [], 'databases': []});
  });

  test('a chat tab is saved and comes back, without a word of what was '
      'said in it', () async {
    final manager = SessionManager();
    await manager.restoreTabs(hosts: [_box], databases: []);
    final session = manager.open(_box);
    manager.openChat(session.id);
    await pumpEventQueue();
    expect(await _saved(), {
      'sessions': [
        {
          'hostId': 'box',
          'tmux': session.tmuxName,
          'chat': true,
          'files': <String>[],
          'web': <String>[],
        },
      ],
      'databases': <String>[],
    });

    // Closing the chat takes it off the strip and off the list.
    manager.closeChat(session.id);
    await pumpEventQueue();
    expect(session.chatOpen, isFalse);
    expect(
      (((await _saved())! as Map)['sessions'] as List).single,
      isNot(contains('chat')),
    );
  });

  test('a chat tab brought back is on the strip, and starts nothing until '
      'it is shown', () async {
    _saveBefore({
      'sessions': [
        {'hostId': 'box', 'tmux': 'sshbox-abc', 'chat': true},
      ],
      'databases': <String>[],
    });
    final host = _Host();
    final manager = SessionManager();
    await manager.restoreTabs(
      hosts: [_box],
      databases: [],
      transport: (_, _) => host,
    );
    final session = manager.sessions.single;
    expect(session.chatOpen, isTrue);
    // Nothing has run on the host: the page starts Claude when it first
    // shows, and it has not.
    expect(host.opened, isEmpty);
  });

  test('saved tabs come back unconnected, and each connects when asked, '
      'checking once that its tmux session is still there', () async {
    _saveBefore({
      'sessions': [
        {
          'hostId': 'box',
          'tmux': 'sshbox-abc',
          'files': ['/etc/hosts'],
          'web': ['https://dev.example/app'],
        },
        {'hostId': 'deleted', 'tmux': 'sshbox-def'},
        {'hostId': 'plain', 'tmux': 'x; rm -rf ~'},
      ],
      'databases': ['db1', 'deleted'],
    });
    final host = _Host();
    final manager = SessionManager();
    await manager.restoreTabs(
      hosts: [_box, _plain],
      databases: [_redis],
      transport: (_, _) => host,
    );
    final [box, plain] = manager.sessions;
    expect(box.tmuxName, 'sshbox-abc');
    // A name that is not one of ours never reaches the host.
    expect(plain.tmuxName, matches(LiveSession.tmuxNamePattern));
    expect(box.isConnected, isFalse);
    expect([for (final web in box.webTabs) '${web.url}'], [
      'https://dev.example/app',
    ]);
    // A file tab reads through the connection, so it waits for one.
    expect(box.openFiles, isEmpty);
    expect([for (final tab in manager.dbTabs) tab.title], ['Redis on box']);
    expect(manager.activeId, isNull);
    expect(box.takeAutoConnect(), isTrue);
    expect(box.takeAutoConnect(), isFalse);

    await box.connect(secrets: InMemorySecretStore());
    expect(
      host.ran.where((run) => run.contains('has-session -t "=sshbox-abc"')),
      hasLength(1),
    );
    expect(host.opened.single, contains('new-session -A -s sshbox-abc'));
    expect(box.isConnected, isTrue);
    expect(box.openFiles, ['/etc/hosts']);

    // Once connected, a reconnect attaches without asking first.
    await box.reconnect(secrets: InMemorySecretStore());
    expect(host.ran.where((run) => run.contains('has-session')), hasLength(1));
  });

  test('a tab brought back whose tmux session has gone says so, and makes a '
      'new one only when asked', () async {
    _saveBefore({
      'sessions': [
        {'hostId': 'box', 'tmux': 'sshbox-abc'},
      ],
    });
    final host = _Host(tmuxThere: false);
    final manager = SessionManager();
    await manager.restoreTabs(
      hosts: [_box],
      databases: const [],
      transport: (_, _) => host,
    );
    final box = manager.sessions.single;

    await box.connect(secrets: InMemorySecretStore());
    expect(box.tmuxGone, isTrue);
    expect(box.error, contains('sshbox-abc is no longer on box'));
    expect(box.isConnected, isFalse);
    expect(host.opened, isEmpty);

    box.startNewTmux();
    await box.connect(secrets: InMemorySecretStore());
    expect(box.tmuxGone, isFalse);
    expect(host.opened.single, contains('new-session -A -s sshbox-abc'));
  });

  test('the app going away leaves the saved tabs as they were', () async {
    final manager = SessionManager();
    await manager.restoreTabs(hosts: [_box], databases: const []);
    final session = manager.open(_box);
    await pumpEventQueue();
    final saved = await _saved();
    expect(saved, isNotNull);

    await manager.shutdown();
    // What closing every tab would save, were it still saving.
    await manager.close(session.id);
    await pumpEventQueue();
    expect(await _saved(), saved);
  });

  testWidgets('a tab brought back connects the first time it shows, and a '
      'database tab opens its connection only then', (tester) async {
    _saveBefore({
      'sessions': [
        {'hostId': 'plain', 'tmux': 'sshbox-abc'},
      ],
      'databases': ['db2'],
    });
    const db = DbConnection(
      id: 'db2',
      kind: DbKind.redis,
      hostId: 'plain',
      port: 6379,
    );
    final host = _Host();
    final manager = SessionManager();
    addTearDown(manager.closeAll);
    await manager.restoreTabs(
      hosts: [_plain],
      databases: [db],
      transport: (_, _) => host,
    );
    var opens = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: TabsShell(
          repository: HostRepository(InMemorySecretStore()),
          secrets: InMemorySecretStore(),
          sessions: manager,
          onOpenHost: (_) async {},
          openDatabase: (db, {required confirmHostKey, required onSignIn}) async {
            opens++;
            return _Db();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final session = manager.sessions.single;
    expect(session.isConnected, isFalse);
    expect(opens, 0);

    await tester.tap(find.text('plain'));
    await tester.pumpAndSettle();
    expect(session.isConnected, isTrue);

    await tester.tap(find.text('Redis on plain'));
    await tester.pumpAndSettle();
    expect(opens, 1);
  });
}
