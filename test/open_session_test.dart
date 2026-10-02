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

class _Shell implements SessionTransport, TerminalSession, ForwardCapable {
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

String _osc(String secret, String path) =>
    '\x1b]7733;open;$secret;${base64.encode(utf8.encode(path))}\x07';

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
