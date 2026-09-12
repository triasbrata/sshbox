import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/forward_setting.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/local_forwarder.dart';
import 'package:sshbox/src/session/port_forwards.dart';
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

/// A connection to the host that is up at once, and can forward.
class _Connection extends _Host implements SessionTransport, TerminalSession {
  /// Each connect's `shell`: a port forward never asks for one.
  final shells = <bool>[];
  var disposed = false;

  @override
  Future<TerminalSession> connect({
    required HostProfile host,
    required SecretStore secrets,
    required int columns,
    required int rows,
    bool shell = true,
  }) async {
    shells.add(shell);
    disposed = false;
    status.value = SessionStatus.connected;
    return this;
  }

  /// The test drops the connection by setting it.
  @override
  final ValueNotifier<SessionStatus> status = ValueNotifier(
    SessionStatus.connected,
  );

  @override
  Stream<String> get output => const Stream.empty();

  @override
  String? get failure => null;

  @override
  void send(String data) {}

  @override
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) {}

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

/// [count] ports nothing on this machine listens on, just now.
Future<List<int>> _freePorts(int count) async {
  final probes = [
    for (var i = 0; i < count; i++)
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
  ];
  final ports = [for (final probe in probes) probe.port];
  for (final probe in probes) {
    await probe.close();
  }
  return ports;
}

/// An app on the tablet, connecting to a forwarded port.
Future<Socket> _app(int port) =>
    Socket.connect(InternetAddress.loopbackIPv4, port);

/// Waits, a little at a time, for what real sockets do in their own time.
Future<void> until(bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue);
}

void main() {
  group('ForwardSetting', () {
    const setting = ForwardSetting(
      id: 'f',
      hostId: 'db',
      name: 'Postgres',
      mappings: [
        LocalForward(localPort: 5432, destPort: 5432),
        LocalForward(localPort: 16379, destHost: '10.0.0.9', destPort: 6379),
      ],
    );

    test('survives JSON, and reads as its ports', () {
      final saved =
          jsonDecode(jsonEncode(setting.toJson())) as Map<String, dynamic>;
      final loaded = ForwardSetting.fromJson(saved);
      expect(loaded.toJson(), setting.toJson());
      expect(loaded.mappings, setting.mappings);
      expect(
        setting.summary,
        '5432 → localhost:5432 · 16379 → 10.0.0.9:6379',
      );
    });

    test("is named after its host until it is given a name", () {
      const host = HostProfile(
        id: 'db',
        label: 'db box',
        host: 'db.example',
        username: 'me',
      );
      const unnamed = ForwardSetting(id: 'g', hostId: 'db');
      expect(setting.displayName(host), 'Postgres');
      expect(unnamed.displayName(host), 'db box');
      expect(unnamed.displayName(null), 'Deleted host');
    });

    test('a port is 1 to 65535, and 1024 or above on the tablet', () {
      expect(LocalForward.portError('5432', local: true), isNull);
      expect(LocalForward.portError(' 80 '), isNull);
      expect(LocalForward.portError('80', local: true), contains('1024'));
      for (final bad in [null, '', '0', '65536', 'pg']) {
        expect(LocalForward.portError(bad), isNotNull, reason: '$bad');
      }
    });
  });

  test("the first load makes each host's port forwards a setting, switched "
      'off, once; the host loads with everything else as it was', () async {
    final db = <String, dynamic>{
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
    SharedPreferences.setMockInitialValues({
      HostRepository.storageKey: jsonEncode([
        {
          ...db,
          'localForwards': [
            {'localPort': 5432, 'destHost': 'localhost', 'destPort': 5432},
            {'localPort': 16379, 'destHost': '10.0.0.9', 'destPort': 6379},
          ],
        },
        // Saved before port forwards existed.
        {'id': 'gw', 'label': 'gw', 'host': 'gw.example', 'username': 'me'},
        {
          'id': 'web',
          'label': 'web',
          'host': 'web.example',
          'username': 'me',
          'localForwards': <Object>[],
        },
      ]),
    });

    final forwards = PortForwards(secrets: InMemorySecretStore());
    await forwards.load();
    final run = forwards.runs.single;
    expect(run.setting.hostId, 'db');
    expect(run.setting.mappings, const [
      LocalForward(localPort: 5432, destPort: 5432),
      LocalForward(localPort: 16379, destHost: '10.0.0.9', destPort: 6379),
    ]);
    expect(run.status, ForwardStatus.stopped);

    final hosts = await HostRepository(InMemorySecretStore()).load();
    expect(hosts.map((host) => host.id), ['db', 'gw', 'web']);
    expect(hosts.first.toJson(), db);

    // Once: a setting deleted since stays deleted.
    await forwards.delete(run.setting.id);
    final again = PortForwards(secrets: InMemorySecretStore());
    await again.load();
    expect(again.runs, isEmpty);
  });

  group('LocalForwarder', () {
    late _Host host;
    late LocalForwarder forwarder;
    late LocalForward rule;
    late List<(int, String?)> problems;

    setUp(() async {
      host = _Host();
      problems = [];
      forwarder = LocalForwarder(
        onProblem: (rule, problem) => problems.add((rule.localPort, problem)),
      );
      rule = LocalForward(
        localPort: (await _freePorts(1)).single,
        destPort: 5432,
      );
      addTearDown(forwarder.stop);
    });

    Future<Socket> app() => _app(rule.localPort);

    test('pipes an app on the tablet to the destination and back', () async {
      await forwarder.sync(host, [rule]);
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

    test('a destination that refuses costs that connection, not the port, '
        'and says so until one gets through', () async {
      await forwarder.sync(host, [rule]);
      host.refusal =
          const SshSessionException('connect failed: Connection refused');
      final refused = await app();
      var ended = false;
      refused.listen(null, onDone: () => ended = true, onError: (Object _) {});
      await until(() => ended);
      expect(problems.last, (
        rule.localPort,
        'cannot reach localhost:5432: connect failed: Connection refused',
      ));

      host.refusal = null;
      final next = await app();
      await until(() => host.tunnels.isNotEmpty);
      expect(problems.last, (rule.localPort, null));
      next.destroy();
    });

    test('a port something else holds says why', () async {
      final taken = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        rule.localPort,
      );
      addTearDown(taken.close);
      await forwarder.sync(host, [rule]);
      expect(problems.single.$1, rule.localPort);
      expect(problems.single.$2, isNotEmpty);
    });

    test('stopping lets go of the port and what is connected through it, '
        'and the next connect opens it again', () async {
      await forwarder.sync(host, [rule]);
      final socket = await app();
      await until(() => host.tunnels.isNotEmpty);
      var ended = false;
      socket.listen(null, onDone: () => ended = true, onError: (Object _) {});

      await forwarder.stop();
      await until(() => ended);
      await expectLater(app(), throwsA(isA<SocketException>()));

      await forwarder.sync(host, [rule]);
      (await app()).destroy();
      expect(problems.where((problem) => problem.$2 != null), isEmpty);
    });
  });

  group('PortForwards', () {
    late _Connection connection;
    late PortForwards forwards;
    late List<ForwardNotice> said;
    late List<int> ports;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final secrets = InMemorySecretStore();
      await HostRepository(secrets).upsert(
        const HostProfile(
          id: 'db',
          label: 'db',
          host: 'db.example',
          username: 'me',
        ),
      );
      said = [];
      connection = _Connection();
      forwards = PortForwards(secrets: secrets, transport: connection)
        ..onNotice = said.add;
      await forwards.load();
      ports = await _freePorts(2);
      await forwards.save(
        ForwardSetting(
          id: 'f',
          hostId: 'db',
          mappings: [
            for (final port in ports) LocalForward(localPort: port, destPort: 5432),
          ],
        ),
      );
      addTearDown(() => forwards.stop('f'));
    });

    test('switching on opens a connection with no shell and binds every port '
        'on loopback; switching off closes them all', () async {
      await forwards.start('f');
      final run = forwards.runs.single;
      expect(run.status, ForwardStatus.running);
      expect(forwards.onCount, 1);
      expect(connection.shells, [false]);
      expect(said, [
        (
          message: 'Forwarding 127.0.0.1:${ports.join(', ')}',
          failed: false,
          link: null,
        ),
      ]);

      final ended = <int>{};
      for (final port in ports) {
        (await _app(port)).listen(
          null,
          onDone: () => ended.add(port),
          onError: (Object _) {},
        );
      }
      await until(() => connection.tunnels.length == 2);
      expect(connection.opened, ['localhost:5432', 'localhost:5432']);

      await forwards.stop('f');
      expect(run.status, ForwardStatus.stopped);
      expect(forwards.onCount, 0);
      expect(connection.disposed, isTrue);
      await until(() => ended.length == 2);
      for (final port in ports) {
        await expectLater(_app(port), throwsA(isA<SocketException>()));
      }
    });

    test('a dropped connection comes back after a moment, ports and all, '
        'and not once switched off', () async {
      await forwards.start('f');
      final run = forwards.runs.single;

      connection.status.value = SessionStatus.closed;
      expect(run.status, ForwardStatus.reconnecting);
      expect(forwards.onCount, 1);
      await until(() => run.status == ForwardStatus.running);
      expect(connection.shells, [false, false]);
      (await _app(ports.first)).destroy();

      connection.status.value = SessionStatus.closed;
      await forwards.stop('f');
      await Future<void>.delayed(
        PortForwards.retryDelays.first + const Duration(milliseconds: 500),
      );
      expect(connection.shells, hasLength(2));
      expect(run.status, ForwardStatus.stopped);
    });

    test('a first connect that fails says why, and stays off', () async {
      await forwards.save(
        const ForwardSetting(
          id: 'g',
          hostId: 'deleted-since',
          mappings: [LocalForward(localPort: 15432, destPort: 5432)],
        ),
      );
      await forwards.start('g');
      final run = forwards.runs.last;
      expect(run.status, ForwardStatus.error);
      expect(run.on, isFalse);
      expect(run.error, contains('deleted'));
      expect(said.single.failed, isTrue);
      expect(connection.shells, isEmpty);
    });
  });
}
