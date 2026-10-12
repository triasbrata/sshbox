import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/data/known_host_store.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/notifications/notify_key.dart';
import 'package:sshbox/src/session/isolate_transport.dart';
import 'package:sshbox/src/session/session_manager.dart';

import 'fake_relay.dart';

/// The install of `jeansh` and the push key, over the REAL transport: the
/// app's own path, SessionManager → IsolateTransport → a real isolate →
/// dartssh2 → an sshd, with `beforeShell` running the install exec while the
/// connection is still being made.
///
/// Every earlier test of this ran against a stand-in session that let a
/// command run at any time. dartssh2's own refused one until the shell was up,
/// which is how the install never ran on a phone and no unit test noticed.
///
/// The sshd is the test's own: a private one on a free port, run as this user
/// with its own host key and one authorised key, and a ForceCommand that gives
/// every session a home of its own, so nothing of this user's is touched.
/// Skipped where there is no sshd or no ssh-keygen.
void main() {
  final sshd = _which('sshd');
  final keygen = _which('ssh-keygen');
  final skip = sshd == null || keygen == null
      ? 'no sshd or ssh-keygen here'
      : false;

  late Directory dir;
  late Process server;
  late int port;
  late String userKey;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('jeansh-sshd');
    final holder = await ServerSocket.bind('127.0.0.1', 0);
    port = holder.port;
    await holder.close();
    for (final name in ['hostkey', 'userkey']) {
      final made = await Process.run(keygen!, [
        '-q',
        '-t',
        'ed25519',
        '-N',
        '',
        '-f',
        '${dir.path}/$name',
      ]);
      expect(made.exitCode, 0, reason: '${made.stderr}');
    }
    userKey = File('${dir.path}/userkey').readAsStringSync();
    File('${dir.path}/authorized_keys')
        .writeAsStringSync(File('${dir.path}/userkey.pub').readAsStringSync());
    Process.runSync('chmod', ['600', '${dir.path}/authorized_keys']);
    Directory('${dir.path}/home').createSync();
    File('${dir.path}/wrap.sh').writeAsStringSync('''#!/bin/sh
export HOME="${dir.path}/home"
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
cd "\$HOME"
if [ -n "\$SSH_ORIGINAL_COMMAND" ]; then exec sh -c "\$SSH_ORIGINAL_COMMAND"; fi
exec sh
''');
    Process.runSync('chmod', ['755', '${dir.path}/wrap.sh']);
    File('${dir.path}/conf').writeAsStringSync('''
Port $port
ListenAddress 127.0.0.1
HostKey ${dir.path}/hostkey
PidFile ${dir.path}/sshd.pid
AuthorizedKeysFile ${dir.path}/authorized_keys
PasswordAuthentication no
UsePAM no
StrictModes no
AcceptEnv LANG LC_*
ForceCommand ${dir.path}/wrap.sh
''');
    server = await Process.start(sshd!, ['-D', '-e', '-f', '${dir.path}/conf']);
    unawaited(server.stdout.drain<void>());
    unawaited(server.stderr.drain<void>());
    // Listening when it takes a connection.
    for (var i = 0; i < 100; i++) {
      try {
        (await Socket.connect('127.0.0.1', port)).destroy();
        break;
      } on SocketException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  tearDown(() async {
    // The one this test started, by its own handle.
    server.kill();
    await server.exitCode;
    dir.deleteSync(recursive: true);
  });

  Future<(LiveSession, List<String>, String?)> connect({
    required bool withKey,
    bool installCommand = true,
  }) async {
    final keys = NotifyKeys(InMemorySecretStore(), relay: FakeRelay());
    await keys.useFcmToken('fcm-token');
    final said = <String>[];
    final manager = SessionManager(
      notifyKeys: withKey ? keys : null,
      onOpenProblem: said.add,
    );
    final session = manager.create(
      HostProfile(
        id: 'live',
        label: 'live',
        host: '127.0.0.1',
        port: port,
        username: Platform.environment['USER'] ?? 'claude',
        authMethod: SshAuthMethod.privateKey,
        installOpenCommand: installCommand,
      ),
      transport: (confirm, banner) =>
          IsolateTransport(knownHosts: _TrustAll(), onAuthBanner: banner),
    );
    addTearDown(session.dispose);
    await session.connect(
      secrets: InMemorySecretStore()
        ..write(SecretKeys.privateKey('live'), userKey),
    );
    return (session, said, withKey ? await keys.valueFor('live') : null);
  }

  test(
    'the install runs on the connection before the shell, and the open '
    'secret, the push key and the command are on the host',
    () async {
      final (session, said, key) = await connect(withKey: true);
      expect(session.error, isNull);
      expect(session.isConnected, isTrue);
      expect(said, isEmpty);
      final config = '${dir.path}/home/.config/jeansh';
      expect(File('$config/notify-key').readAsStringSync(), '$key\n');
      expect(File('$config/notify-key').statSync().mode & 0x1ff, 0x180);
      final secret = File('$config/open-secret').readAsStringSync().trim();
      expect(secret, hasLength(greaterThan(20)));
      expect(File('$config/open-secret').statSync().mode & 0x1ff, 0x180);
      expect(Directory(config).statSync().mode & 0x1ff, 0x1c0);
      final command = File('${dir.path}/home/.local/bin/jeansh');
      expect(command.existsSync(), isTrue);
      expect(command.statSync().mode & 0x49, 0x49);
      // The app took the same secret.
      expect(session.openRequests.ring.accepts(secret), isTrue);
      // The key is in no variable: the shell's environment has none of it.
      expect(File('${dir.path}/home/.ssh').existsSync(), isFalse);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'with the jeansh switch off only the push key is written, and the '
    'command is not',
    () async {
      final (session, said, key) = await connect(
        withKey: true,
        installCommand: false,
      );
      expect(session.isConnected, isTrue);
      expect(said, isEmpty);
      final config = '${dir.path}/home/.config/jeansh';
      expect(File('$config/notify-key').readAsStringSync(), '$key\n');
      expect(File('$config/open-secret').existsSync(), isFalse);
      expect(File('${dir.path}/home/.local/bin/jeansh').existsSync(), isFalse);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a host that will not take the install is said once the connect is '
    'over, and the shell is up',
    () async {
      // Something of somebody else's where the command goes.
      Directory('${dir.path}/home/.local/bin').createSync(recursive: true);
      File('${dir.path}/home/.local/bin/jeansh')
          .writeAsStringSync('#!/bin/sh\necho mine\n');
      final (session, said, _) = await connect(withKey: false);
      expect(session.isConnected, isTrue);
      // Held until the connect ended, then said: never under the sheet.
      expect(said.single, contains('left alone'));
      expect(
        File('${dir.path}/home/.local/bin/jeansh').readAsStringSync(),
        contains('mine'),
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

String? _which(String name) {
  for (final dir in [
    '/usr/sbin',
    '/usr/bin',
    '/sbin',
    '/bin',
    '/usr/local/bin',
    '/usr/local/sbin',
  ]) {
    if (File('$dir/$name').existsSync()) return '$dir/$name';
  }
  return null;
}

class _TrustAll extends KnownHostStore {
  @override
  Future<bool> trust(
    HostProfile host,
    String address,
    String fingerprint,
    Future<bool> Function(HostKeyCheck check)? confirm,
  ) async => true;

  @override
  Future<String?> pinnedKey(String host, int port) async => null;
}
