import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/session/local_transport.dart';
import 'package:sshbox/src/session/open_command.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/open_request.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';

class _Shell
    implements
        SessionTransport,
        TerminalSession,
        ForwardCapable,
        CommandCapable {
  /// How far this host's clock is ahead, as its `date +%s` answers.
  int hostAhead = 0;

  @override
  Stream<String> run(String command, {bool pty = false}) => Stream.value(
    '${DateTime.now().millisecondsSinceEpoch ~/ 1000 + hostAhead}',
  );

  final out = StreamController<String>.broadcast();
  Map<String, String> environment = const {};

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
    Future<Map<String, String>> Function(ForwardCapable host)? beforeShell,
  }) async {
    this.environment = {...environment, ...?await beforeShell?.call(this)};
    return this;
  }

  @override
  Stream<String> get output => out.stream;

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// A keyring that answers [delay] after it is asked, as a locked one does
/// once it is unlocked.
class _SlowSecrets extends _Secrets {
  _SlowSecrets(this.delay);
  final Duration delay;
  @override
  Future<String?> read(String key) async {
    await Future<void>.delayed(delay);
    return map[key];
  }
}

class _Secrets implements SecretStore {
  final map = <String, String>{};
  @override
  Future<String?> read(String key) async => map[key];
  @override
  Future<void> write(String key, String? value) async => map[key] = value!;
  @override
  Future<void> purgeHost(String hostId) async {}
}

class _Pty implements Pty {
  @override
  Stream<Uint8List> get output => const Stream.empty();
  @override
  Future<int> get exitCode => Completer<int>().future;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

var _nonce = 0;
String _osc(String secret, String path, {String? nonce, int ahead = 0}) =>
    '\x1b]7733;open;$secret;'
    '${DateTime.now().millisecondsSinceEpoch ~/ 1000 + ahead};'
    '${nonce ?? (0x20000000 + _nonce++).toRadixString(16)};'
    '${base64.encode(utf8.encode(path))}\x07';

void main() {
  const host = HostProfile(
    id: 'host-1',
    label: 'box',
    host: '10.0.2.2',
    username: 'me',
  );

  test('the sequence from a session opens a file tab at that path', () async {
    final manager = SessionManager();
    final secrets = _Secrets();
    final shell = _Shell();
    final session = manager.create(host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: secrets);
    manager.add(session);
    await Future<void>.delayed(Duration.zero);

    // The shell is handed the secret kept for the host, which `jeansh` signs
    // with.
    final secret = shell.environment[openSecretVariable]!;
    expect(secrets.map[SecretKeys.openSecret('host-1')], secret);

    // Program output with the wrong secret, e.g. a file shown with cat.
    shell.out.add(_osc('guess', '/etc/passwd'));
    await Future<void>.delayed(Duration.zero);
    expect(session.openFiles, isEmpty);

    shell.out.add('before${_osc(secret, '/srv/app/notes.md')}after');
    await Future<void>.delayed(Duration.zero);
    expect(session.openFiles, ['/srv/app/notes.md']);
    expect(manager.activeKind, TabKind.file);
    expect(manager.activePath, '/srv/app/notes.md');

    // Asking again goes to the tab already there.
    shell.out.add(_osc(secret, '/srv/app/notes.md'));
    await Future<void>.delayed(Duration.zero);
    expect(session.openFiles, hasLength(1));

    // The same bytes again, from a record or a log, open nothing more.
    final replay = _osc(secret, '/srv/app/other.md', nonce: 'feedface99');
    shell.out.add(replay);
    shell.out.add(replay);
    await Future<void>.delayed(Duration.zero);
    expect(session.openFiles, ['/srv/app/notes.md', '/srv/app/other.md']);
  });

  test(
    'a desktop Local shell gets the command on PATH and the secret',
    () async {
      final home = Directory.systemTemp.createTempSync('jeansh-local');
      addTearDown(() => home.deleteSync(recursive: true));
      Map<String, String>? seen;
      final transport = LocalTransport(
        windows: false,
        environment: {'HOME': home.path, 'PATH': '/usr/bin:/bin'},
        startPty:
            (
              executable, {
              arguments = const [],
              workingDirectory,
              environment,
              rows = 25,
              columns = 80,
              ackRead = false,
            }) {
              seen = environment;
              return _Pty();
            },
      );
      await transport.connect(
        host: localHost(),
        secrets: InMemorySecretStore(),
        columns: 80,
        rows: 24,
        environment: {openSecretVariable: 'local-secret'},
      );
      final bin = '${home.path}/.local/state/jeansh/bin';
      expect(seen![openSecretVariable], 'local-secret');
      expect(seen!['PATH'], '$bin:/usr/bin:/bin');
      expect(File('$bin/jeansh').readAsStringSync(), openCommandScript);
    },
  );

  test("a host's clock ten minutes ahead is measured at connect", () async {
    final manager = SessionManager();
    final secrets = _Secrets();
    final shell = _Shell()..hostAhead = 600;
    final session = manager.create(host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: secrets);
    manager.add(session);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final secret = shell.environment[openSecretVariable]!;
    shell.out.add(_osc(secret, '/skewed.md', ahead: 600));
    await Future<void>.delayed(Duration.zero);
    expect(session.openFiles, ['/skewed.md']);
    // And one with the device's own time is now the stale one.
    shell.out.add(_osc(secret, '/stale.md'));
    await Future<void>.delayed(Duration.zero);
    expect(session.openFiles, hasLength(1));
  });

  test('a store that answers late does not change the secret a shell started '
      'with', () async {
    final secrets = _SlowSecrets(const Duration(milliseconds: 700))
      ..map[SecretKeys.openSecret('local')] = 'stored-secret';
    final shell = _Shell();
    final manager = SessionManager();
    final session = manager.create(localHost(), transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: secrets);
    manager.add(session);
    final started = shell.environment[openSecretVariable]!;
    expect(started, isNot('stored-secret'));
    await Future<void>.delayed(const Duration(milliseconds: 900));
    shell.out.add(_osc(started, '/mine.md'));
    shell.out.add(_osc('stored-secret', '/theirs.md'));
    await Future<void>.delayed(Duration.zero);
    expect(session.openFiles, ['/mine.md']);
  });

  test('a Local reconnect whose load times out again keeps the first '
      "connect's secret", () async {
    final secrets = _SlowSecrets(const Duration(milliseconds: 700));
    final first = _Shell(), second = _Shell();
    var shell = first;
    final manager = SessionManager();
    final session = manager.create(localHost(), transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: secrets);
    final started = first.environment[openSecretVariable]!;
    await session.disconnect();
    shell = second;
    await session.connect(secrets: secrets);
    expect(second.environment[openSecretVariable], started);
  });

  test('an absurd host clock is clamped, not overflowed', () async {
    final manager = SessionManager();
    final shell = _Shell()..hostAhead = 1 << 60;
    final session = manager.create(host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _Secrets());
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(session.openRequests.clockOffset, OpenRequests.maxOffset);
  });

  test('a Local shell keeps its secret across runs, as a restored tmux '
      "session's panes need", () async {
    final secrets = _Secrets();
    final first = _Shell(), second = _Shell();
    final a = SessionManager().create(localHost(), transport: (_, _) => first);
    await a.connect(secrets: secrets);
    final b = SessionManager().create(localHost(), transport: (_, _) => second);
    await b.connect(secrets: secrets);
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    final kept = secrets.map[SecretKeys.openSecret('local')];
    expect(kept, isNotNull);
    expect(first.environment[openSecretVariable], kept);
    expect(second.environment[openSecretVariable], kept);
  });

  test("one host's secret opens nothing on another host's tab", () async {
    final manager = SessionManager();
    final secrets = _Secrets();
    final a = _Shell(), b = _Shell();
    final first = manager.create(host, transport: (_, _) => a);
    final second = manager.create(
      host.copyWith(id: 'host-2'),
      transport: (_, _) => b,
    );
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await first.connect(secrets: secrets);
    await second.connect(secrets: secrets);
    manager.add(first);
    manager.add(second);
    final secretA = a.environment[openSecretVariable]!;
    expect(secretA, isNot(b.environment[openSecretVariable]));
    b.out.add(_osc(secretA, '/x'));
    await Future<void>.delayed(Duration.zero);
    expect(second.openFiles, isEmpty);
    expect(first.openFiles, isEmpty);
  });
}
