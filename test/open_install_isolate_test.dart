import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/data/known_host_store.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/notifications/notify_key.dart';
import 'package:sshbox/src/session/isolate_transport.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';

import 'fake_relay.dart';

/// The install of `jeansh` and the push key runs in `beforeShell`, which on a
/// phone is called across the isolate boundary while the far side is still
/// connecting. The unit fakes call it with a session that can run commands, so
/// they never showed that the real wire could not: the far side had no
/// session yet to run one on.
///
/// Here the transport is the real [IsolateTransport] over a real isolate, with
/// only the SSH session behind it a stand-in, one that answers the install the
/// way the host does, by what it was sent on its standard input.
void main() {
  const host = HostProfile(
    id: 'host-1',
    label: 'box',
    host: '10.0.2.2',
    username: 'me',
    installOpenCommand: true,
  );

  Future<LiveSession> connect(
    SessionManager manager, {
    HostProfile profile = host,
  }) async {
    final session = manager.create(
      profile,
      transport: (confirm, banner) => IsolateTransport(
        knownHosts: _NoKnownHosts(),
        entryPoint: installIsolate,
        onAuthBanner: banner,
      ),
    );
    addTearDown(session.dispose);
    await session.connect(secrets: InMemorySecretStore());
    return session;
  }

  test('the install exec runs through the isolate, before the shell, and '
      'gets the open secret and the push key on its stdin', () async {
    final keys = NotifyKeys(InMemorySecretStore(), relay: FakeRelay());
    await keys.useFcmToken('fcm-token');
    final said = <String>[];
    final session = await connect(
      SessionManager(notifyKeys: keys, onOpenProblem: said.add),
    );
    expect(session.isConnected, isTrue);
    // The far side answers "installed" only to an exec that got both lines.
    expect(said, isEmpty);
  });

  test('with the switch off and no key there is nothing to install, and '
      'nothing is said', () async {
    final said = <String>[];
    final session = await connect(
      SessionManager(onOpenProblem: said.add),
      profile: host.copyWith(installOpenCommand: false),
    );
    expect(session.isConnected, isTrue);
    expect(said, isEmpty);
  });

  test('an exec that cannot be run is said, and the shell opens', () async {
    // The far side answers "bad stdin" to anything but both lines: with no
    // relay key the second line is the placeholder.
    final said = <String>[];
    final session = await connect(SessionManager(onOpenProblem: said.add));
    expect(session.isConnected, isTrue);
    expect(said.single, contains('failed'));
  });
}

void installIsolate(SendPort toProxy) => runSessionIsolate(
  toProxy,
  transport: ({
    required knownHosts,
    required confirmHostKey,
    required onAuthBanner,
    required onNotice,
    required loadHosts,
  }) => _Transport(),
);

class _Transport implements SessionTransport {
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
    final session = _Session();
    // As the SSH one does: before there is a session, with the connection.
    await beforeShell?.call(session);
    return session;
  }
}

class _Session
    implements TerminalSession, CommandCapable, ChannelCapable, ForwardCapable {
  final _status = ValueNotifier(SessionStatus.connected);

  @override
  Stream<String> get output => const Stream.empty();

  @override
  ValueListenable<SessionStatus> get status => _status;

  @override
  String? get failure => null;

  @override
  void send(String data) {}

  @override
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) {}

  @override
  Stream<String> run(String command, {bool pty = false}) =>
      const Stream.empty();

  @override
  Future<CommandChannel> open(String command) async {
    final back = StreamController<Uint8List>();
    return (
      output: back.stream,
      write: (Uint8List data) {
        final lines = utf8.decode(data).split('\n');
        final ok =
            RegExp(r'^[A-Za-z0-9_-]{20,}$').hasMatch(lines[0]) &&
            lines.length == 3 &&
            lines[1].startsWith('jnk_') &&
            command.contains('jeansh-open');
        back.add(
          Uint8List.fromList(utf8.encode(ok ? 'installed\n' : 'bad stdin\n')),
        );
        back.close();
      },
      close: () {},
    );
  }

  @override
  Future<void> dispose() async {
    _status.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _NoKnownHosts extends KnownHostStore {
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
