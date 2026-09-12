import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/local_forwarder.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';

/// A host whose end of each tunnel the test holds.
class _Host implements ForwardCapable {
  final opened = <String>[];
  final tunnels =
      <({StreamController<List<int>> sent, StreamController<Uint8List> reply})>[];

  /// Why the destination refuses, while it does.
  SshSessionException? refusal;

  @override
  Future<Tunnel> forward(String host, int port) async {
    opened.add('$host:$port');
    final refusal = this.refusal;
    if (refusal != null) throw refusal;
    final sent = StreamController<List<int>>();
    final reply = StreamController<Uint8List>();
    tunnels.add((sent: sent, reply: reply));
    return (output: reply.stream, input: sent.sink);
  }
}

/// A port nothing on this machine listens on, just now.
Future<int> _freePort() async {
  final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  await probe.close();
  return port;
}

/// Waits, a little at a time, for what real sockets do in their own time.
Future<void> until(bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue);
}

/// A connection to the host that is up at once, and can forward.
class _Connection extends _Host implements SessionTransport, TerminalSession {
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
}

void main() {
  test('rules are saved with the host, and a host saved before them loads '
      'with none and otherwise as it was', () {
    const rules = [
      LocalForward(localPort: 5432, destPort: 5432),
      LocalForward(localPort: 16379, destHost: '10.0.0.9', destPort: 6379),
    ];
    const profile = HostProfile(
      id: 'db',
      label: 'db',
      host: 'db.example',
      username: 'me',
      localForwards: rules,
    );
    final saved =
        jsonDecode(jsonEncode(profile.toJson())) as Map<String, dynamic>;
    expect(HostProfile.fromJson(saved).localForwards, rules);

    final old = <String, dynamic>{
      'id': 'db',
      'label': 'db',
      'host': 'db.example',
      'username': 'me',
      'port': 2222,
      'authMethod': 'privateKey',
      'fileRoot': '/srv',
      'forwardPorts': true,
      'useTmux': true,
      'jumpHostId': 'gw',
    };
    final loaded = HostProfile.fromJson(old);
    expect(loaded.localForwards, isEmpty);
    expect(loaded.toJson(), {...old, 'localForwards': <Object>[]});
  });

  test('a forward port is 1 to 65535, and 1024 or above on the tablet', () {
    expect(LocalForward.portError('5432', local: true), isNull);
    expect(LocalForward.portError(' 80 '), isNull);
    expect(LocalForward.portError('80', local: true), contains('1024'));
    for (final bad in [null, '', '0', '65536', 'pg']) {
      expect(LocalForward.portError(bad), isNotNull, reason: '$bad');
    }
  });

  group('LocalForwarder', () {
    late _Host host;
    late LocalForwarder forwarder;
    late LocalForward rule;
    late List<ForwardNews> said;

    setUp(() async {
      host = _Host();
      said = [];
      forwarder = LocalForwarder(
        onChanged: () => said.addAll(forwarder.takeNews()),
      );
      rule = LocalForward(localPort: await _freePort(), destPort: 5432);
      addTearDown(forwarder.stop);
    });

    Future<Socket> app() =>
        Socket.connect(InternetAddress.loopbackIPv4, rule.localPort);

    Future<void> open() async {
      final before = said.length;
      forwarder.sync(host, [rule]);
      await until(() => said.length > before);
      expect(said.last, (message: 'Forwarding ${rule.label}', failed: false));
    }

    test('pipes an app on the tablet to the destination and back', () async {
      await open();
      final socket = await app();
      await until(() => host.tunnels.isNotEmpty);
      expect(host.opened, ['localhost:5432']);
      final tunnel = host.tunnels.single;
      final sent = <int>[];
      var hungUp = false;
      tunnel.sent.stream.listen(sent.addAll, onDone: () => hungUp = true);
      final replied = <int>[];
      socket.listen(replied.addAll, onError: (Object _) {});

      socket.add(utf8.encode('SELECT 1;'));
      await until(() => sent.length == 9);
      expect(utf8.decode(sent), 'SELECT 1;');

      tunnel.reply.add(Uint8List.fromList(utf8.encode('1')));
      await until(() => replied.isNotEmpty);
      expect(utf8.decode(replied), '1');

      // The app hanging up closes the channel.
      socket.destroy();
      await until(() => hungUp);
    });

    test('a destination that refuses costs that connection, not the port',
        () async {
      await open();
      host.refusal =
          const SshSessionException('connect failed: Connection refused');
      final refused = await app();
      var ended = false;
      refused.listen(null, onDone: () => ended = true, onError: (Object _) {});
      await until(() => ended);
      expect(said.last.failed, isTrue);
      expect(said.last.message, endsWith('connect failed: Connection refused'));

      host.refusal = null;
      final next = await app();
      await until(() => host.tunnels.isNotEmpty);
      next.destroy();
    });

    test('stopping lets go of the port and what is connected through it, '
        'and the next connect opens it again', () async {
      await open();
      final socket = await app();
      await until(() => host.tunnels.isNotEmpty);
      var ended = false;
      socket.listen(null, onDone: () => ended = true, onError: (Object _) {});

      await forwarder.stop();
      await until(() => ended);
      await expectLater(app(), throwsA(isA<SocketException>()));

      await open();
      expect(said.where((news) => news.failed), isEmpty);
    });
  });

  test('two sessions on one host hold a port once, silently, and the other '
      'takes it over when the first closes', () async {
    final rule = LocalForward(localPort: await _freePort(), destPort: 5432);
    final box = HostProfile(
      id: 'box',
      label: 'box',
      host: 'db.example',
      username: 'me',
      localForwards: [rule],
    );
    final manager = SessionManager();
    addTearDown(manager.closeAll);
    final first = manager.open(box, transport: _Connection());
    final second = manager.open(box, transport: _Connection());
    await first.connect(secrets: InMemorySecretStore());
    await second.connect(secrets: InMemorySecretStore());

    final firstSaid = <ForwardNews>[];
    await until(() {
      firstSaid.addAll(first.localForwarder.takeNews());
      return firstSaid.isNotEmpty;
    });
    expect(firstSaid.single.failed, isFalse);
    expect(second.localForwarder.isHolding(rule.localPort), isFalse);
    expect(second.localForwarder.takeNews(), isEmpty);

    await manager.close(first.id);
    final secondSaid = <ForwardNews>[];
    await until(() {
      secondSaid.addAll(second.localForwarder.takeNews());
      return secondSaid.isNotEmpty;
    });
    expect(secondSaid, [(message: 'Forwarding ${rule.label}', failed: false)]);
    (await Socket.connect(InternetAddress.loopbackIPv4, rule.localPort))
        .destroy();
  });
}
