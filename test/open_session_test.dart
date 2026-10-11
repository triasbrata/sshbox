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

  /// What the host says to the install script: its last line. `hang` never
  /// answers, `fail` ends with an error.
  String installAnswer = 'installed';
  final installs = <String>[];

  /// The secret the last install put in the host's file.
  String? get installedSecret {
    final match = RegExp(r"'\\''([A-Za-z0-9_-]{20,})'\\''")
        .firstMatch(installs.last);
    return match?[1];
  }

  @override
  Stream<String> run(String command, {bool pty = false}) {
    if (command.contains('jeansh-open')) {
      installs.add(command);
      if (installAnswer == 'hang') return StreamController<String>().stream;
      if (installAnswer == 'fail') return Stream.error(StateError('x'));
      return Stream.value(installAnswer);
    }
    return Stream.value(
      '${DateTime.now().millisecondsSinceEpoch ~/ 1000 + hostAhead}',
    );
  }

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

var _nonce = 0;
String _osc(String secret, String path, {String? nonce, int ahead = 0}) =>
    '\x1b]7733;open;$secret;'
    '${DateTime.now().millisecondsSinceEpoch ~/ 1000 + ahead};'
    '${nonce ?? (0x20000000 + _nonce++).toRadixString(16)};'
    '${base64.encode(utf8.encode(path))}\x07';

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  const host = HostProfile(
    id: 'host-1',
    label: 'box',
    host: '10.0.2.2',
    username: 'me',
    installOpenCommand: true,
  );

  test('the sequence from a session opens a file tab at that path, signed '
      "with the secret the install put in the host's file", () async {
    final manager = SessionManager();
    final shell = _Shell();
    final session = manager.create(host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _Secrets());
    manager.add(session);
    await _settle();

    // The secret rides in the install, and in nothing the shell inherits.
    final secret = shell.installedSecret!;
    expect(shell.environment.keys.where((k) => k.contains('OPEN')), isEmpty);
    expect(shell.environment.values, isNot(contains(secret)));

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

  test('a secret that was in the environment of an older install is refused: '
      'the old helper stops working', () async {
    final manager = SessionManager();
    final shell = _Shell();
    final session = manager.create(host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _Secrets());
    manager.add(session);
    await _settle();
    // What an older app kept in the secret store and sent as a variable.
    shell.out.add(_osc('stored-by-an-older-version', '/old.md'));
    await Future<void>.delayed(Duration.zero);
    expect(session.openFiles, isEmpty);
  });

  test('two tabs to one host both work, whichever connected last wrote the '
      'file, and one four connects behind does not', () async {
    final manager = SessionManager();
    final shells = [for (var i = 0; i < 5; i++) _Shell()];
    final sessions = [
      for (final shell in shells)
        manager.create(host, transport: (_, _) => shell),
    ];
    final secrets = _Secrets();
    for (final session in sessions) {
      addTearDown(session.dispose);
      await session.connect(secrets: secrets);
      manager.add(session);
      await _settle();
    }
    final made = [for (final shell in shells) shell.installedSecret!];
    expect(made.toSet(), hasLength(5));
    // The newest four are honoured in every tab, since the file holds the
    // latest and a pane reads it each time.
    for (var tab = 0; tab < 5; tab++) {
      shells[tab].out.add(_osc(made[4], '/latest-$tab.md'));
      shells[tab].out.add(_osc(made[1], '/older-$tab.md'));
      shells[tab].out.add(_osc(made[0], '/oldest-$tab.md'));
      await Future<void>.delayed(Duration.zero);
      expect(sessions[tab].openFiles, [
        '/latest-$tab.md',
        '/older-$tab.md',
      ], reason: 'tab $tab');
    }
  });

  test('a connect on another host does not take its tabs\' secrets', () async {
    final manager = SessionManager();
    final a = _Shell(), b = _Shell();
    final first = manager.create(host, transport: (_, _) => a);
    final second = manager.create(
      host.copyWith(id: 'host-2'),
      transport: (_, _) => b,
    );
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await first.connect(secrets: _Secrets());
    await second.connect(secrets: _Secrets());
    manager.add(first);
    manager.add(second);
    await _settle();
    final secretA = a.installedSecret!;
    expect(secretA, isNot(b.installedSecret));
    b.out.add(_osc(secretA, '/x'));
    await Future<void>.delayed(Duration.zero);
    expect(second.openFiles, isEmpty);
    expect(first.openFiles, isEmpty);
  });

  group('what went wrong with the install is said', () {
    Future<List<String>> installWith(String answer, {Duration? wait}) async {
      final said = <String>[];
      final manager = SessionManager(onOpenProblem: said.add);
      final shell = _Shell()..installAnswer = answer;
      final session = manager.create(host, transport: (_, _) => shell);
      addTearDown(session.dispose);
      await session.connect(secrets: _Secrets());
      await Future<void>.delayed(wait ?? const Duration(milliseconds: 100));
      return said;
    }

    test('installed and current say nothing', () async {
      expect(await installWith('installed'), isEmpty);
      expect(await installWith('current'), isEmpty);
    });

    test('a file left alone, a link, a failure and a host that does not '
        'answer each say so', () async {
      final alone = await installWith('left alone');
      expect(alone.single, contains('is not the app\'s own'));
      final link = await installWith('secret folder is a link');
      expect(link.single, contains('~/.config/jeansh is a link'));
      final failed = await installWith('fail');
      expect(failed.single, contains('failed'));
      final nothing = await installWith('');
      expect(nothing.single, contains('failed'));
      final old = LiveSession.openInstallTimeout;
      addTearDown(() => LiveSession.openInstallTimeout = old);
      LiveSession.openInstallTimeout = const Duration(milliseconds: 20);
      final hung = await installWith('hang');
      expect(hung.single, contains('did not answer'));
    });

    test('a host whose switch is off is not asked, nor told', () async {
      final said = <String>[];
      final manager = SessionManager(onOpenProblem: said.add);
      final shell = _Shell();
      final session = manager.create(
        host.copyWith(installOpenCommand: false),
        transport: (_, _) => shell,
      );
      addTearDown(session.dispose);
      await session.connect(secrets: _Secrets());
      await _settle();
      expect(shell.installs, isEmpty);
      expect(said, isEmpty);
    });
  });

  test('requests the app cannot take are said, with how many and why', () async {
    final said = <(int, String)>[];
    final manager = SessionManager(
      onOpenDropped: (count, why) => said.add((count, why)),
    );
    final shell = _Shell();
    final session = manager.create(host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _Secrets());
    manager.add(session);
    await _settle();
    final secret = shell.installedSecret!;
    shell.out.add(
      '\x1b]7733;open;$secret;${DateTime.now().millisecondsSinceEpoch ~/ 1000};'
      '${(0x41000000).toRadixString(16)};${base64.encode([0x2f, 0xff])}\x07',
    );
    await Future<void>.delayed(Duration.zero);
    expect(said, [(1, 'the name is not valid UTF-8')]);
    expect(session.openFiles, isEmpty);
  });

  test('a desktop Local shell gets the command on PATH and no secret in its '
      'environment', () async {
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
    );
    final bin = '${home.path}/.local/state/jeansh/bin';
    expect(seen!.keys.where((k) => k.contains('OPEN')), isEmpty);
    expect(seen!['PATH'], '$bin:/usr/bin:/bin');
    expect(File('$bin/jeansh').readAsStringSync(), openCommandScript);
  });

  test("a host's clock ten minutes ahead is measured at connect", () async {
    final manager = SessionManager();
    final shell = _Shell()..hostAhead = 600;
    final session = manager.create(host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _Secrets());
    manager.add(session);
    await _settle();
    final secret = shell.installedSecret!;
    shell.out.add(_osc(secret, '/skewed.md', ahead: 600));
    await Future<void>.delayed(Duration.zero);
    expect(session.openFiles, ['/skewed.md']);
    // And one with the device's own time is now the stale one.
    shell.out.add(_osc(secret, '/stale.md'));
    await Future<void>.delayed(Duration.zero);
    expect(session.openFiles, hasLength(1));
  });

  test('an absurd host clock is clamped, not overflowed', () async {
    final manager = SessionManager();
    final shell = _Shell()..hostAhead = 1 << 60;
    final session = manager.create(host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _Secrets());
    await _settle();
    expect(session.openRequests.clockOffset, OpenRequests.maxOffset);
  });

  group('a Local shell', () {
    test('writes a new secret into its own file at every connect, and the '
        'older ones still count', () async {
      final written = <String>[];
      final manager = SessionManager(writeLocalOpenSecret: written.add);
      final first = _Shell(), second = _Shell();
      final a = manager.create(localHost(), transport: (_, _) => first);
      await a.connect(secrets: _Secrets());
      final b = manager.create(localHost(), transport: (_, _) => second);
      await b.connect(secrets: _Secrets());
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      manager.add(a);
      manager.add(b);
      expect(written, hasLength(2));
      expect(written[0], isNot(written[1]));
      // Nothing in either shell's environment.
      expect(first.environment.keys.where((k) => k.contains('OPEN')), isEmpty);
      expect(second.environment.keys.where((k) => k.contains('OPEN')), isEmpty);
      // The first tab's pane now reads the second's secret, and works.
      first.out.add(_osc(written[1], '/second.md'));
      first.out.add(_osc(written[0], '/first.md'));
      await Future<void>.delayed(Duration.zero);
      expect(a.openFiles, ['/second.md', '/first.md']);
    });

    test('says so when the file cannot be written', () async {
      final said = <String>[];
      final manager = SessionManager(
        onOpenProblem: said.add,
        writeLocalOpenSecret: (_) =>
            throw const OpenInstallException('~/.config/jeansh is a link.'),
      );
      final session = manager.create(
        localHost(),
        transport: (_, _) => _Shell(),
      );
      addTearDown(session.dispose);
      await session.connect(secrets: _Secrets());
      expect(said, ['~/.config/jeansh is a link.']);
      // The shell still opens: only the jeansh command is lost.
      expect(session.isConnected, isTrue);
    });
  });
}
