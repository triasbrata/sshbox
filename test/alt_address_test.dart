import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart' show SSHSocket;
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/dartssh2_transport.dart';
import 'package:sshbox/src/session/terminal_session.dart';

/// A socket that is never read or written: these tests are about which dial
/// wins the race and what happens to the losers.
class _FakeSocket implements SSHSocket {
  var destroyed = false;

  @override
  void destroy() => destroyed = true;

  @override
  Future<void> close() async {}

  @override
  Future<void> get done async {}

  @override
  Future<void> flush() async {}

  @override
  StreamSink<List<int>> get sink => throw UnimplementedError();

  @override
  Stream<Uint8List> get stream => const Stream.empty();
}

Future<SSHSocket> _after(Duration wait, _FakeSocket socket) =>
    Future.delayed(wait, () => socket);

const _host = HostProfile(
  id: 'box',
  label: 'box',
  host: '100.64.0.9',
  altHost: '192.168.1.20',
  username: 'me',
);

void main() {
  test('a host is dialled at its saved address, then its alternative', () {
    expect(_host.addresses, ['100.64.0.9', '192.168.1.20']);
    // No alternative, and one that repeats the address, are one dial.
    expect(_host.copyWith(altHost: '').addresses, ['100.64.0.9']);
    expect(_host.copyWith(altHost: '  ').addresses, ['100.64.0.9']);
    expect(_host.copyWith(altHost: ' 100.64.0.9 ').addresses, ['100.64.0.9']);
    // Typed with spaces round it, as a paste arrives.
    expect(_host.copyWith(altHost: ' 10.0.0.2 ').addresses.last, '10.0.0.2');
  });

  test('the alternative address survives a save, and a duplicate', () {
    expect(HostProfile.fromJson(_host.toJson()).altHost, '192.168.1.20');
    // A host saved before this field existed has none.
    expect(HostProfile.fromJson({'id': 'old'}).altHost, '');
    expect(_host.copyWith(id: 'copy').altHost, '192.168.1.20');
  });

  test('the saved address keeps its head start when it answers', () async {
    final saved = _FakeSocket();
    var alternativeDialled = false;
    final answered = await firstToAnswer({
      '100.64.0.9': () => _after(const Duration(milliseconds: 10), saved),
      '192.168.1.20': () {
        alternativeDialled = true;
        return _after(Duration.zero, _FakeSocket());
      },
    });

    expect(answered.address, '100.64.0.9');
    expect(answered.socket, same(saved));
    // Never dialled at all: nothing was opened to the other address, so
    // nothing is left to close.
    expect(alternativeDialled, isFalse);
  });

  test('a saved address that is not answering hands over to the alternative, '
      'and its socket is destroyed if it turns up late', () async {
    final late = _FakeSocket();
    final alternative = _FakeSocket();
    final answered = await firstToAnswer(
      {
        '100.64.0.9': () => _after(const Duration(milliseconds: 200), late),
        '192.168.1.20': () => _after(Duration.zero, alternative),
      },
      delay: const Duration(milliseconds: 20),
    );

    expect(answered.address, '192.168.1.20');
    expect(answered.socket, same(alternative));
    // The loser arrives after the winner is already in use: it has to be let
    // go, and no SSH handshake is ever started on it.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(late.destroyed, isTrue);
    expect(alternative.destroyed, isFalse);
  });

  test('a saved address that fails starts the alternative at once', () async {
    final clock = Stopwatch()..start();
    final answered = await firstToAnswer(
      {
        '100.64.0.9': () => Future.error(const SocketException('refused')),
        '192.168.1.20': () => _after(Duration.zero, _FakeSocket()),
      },
      // Long enough that waiting it out would show up here.
      delay: const Duration(seconds: 5),
    );

    expect(answered.address, '192.168.1.20');
    expect(clock.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test('both failing throws the saved address\'s error', () {
    expect(
      firstToAnswer(
        {
          '100.64.0.9': () => Future.error(const SocketException('no route')),
          '192.168.1.20': () =>
              Future.error(const SocketException('refused')),
        },
        delay: Duration.zero,
      ),
      throwsA(
        isA<SocketException>().having((e) => e.message, 'message', 'no route'),
      ),
    );
  });

  test('a connection falls over to the alternative address, and says so',
      () async {
    // Answers and hangs up: enough to prove which address was dialled, with
    // no SSH server to run.
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final reached = Completer<void>();
    server.listen((socket) {
      if (!reached.isCompleted) reached.complete();
      socket.destroy();
    });
    addTearDown(server.close);

    final notices = <String>[];
    final transport = Dartssh2Transport(onNotice: notices.add);
    final host = HostProfile(
      id: 'box',
      label: 'my box',
      // Reserved by RFC 2606: it never resolves, which is a host that cannot
      // be reached — a tailnet that is down.
      host: 'nothing-here.invalid',
      altHost: '127.0.0.1',
      port: server.port,
      username: 'me',
    );
    final secrets = InMemorySecretStore();
    await secrets.write(SecretKeys.password('box'), 'not a real password');

    // The handshake fails, there being no sshd behind that port.
    await expectLater(
      transport.connect(host: host, secrets: secrets, columns: 80, rows: 24),
      throwsA(isA<SshSessionException>()),
    );
    expect(reached.isCompleted, isTrue);
    expect(notices, hasLength(1));
    expect(notices.single, contains('my box'));
    expect(notices.single, contains('127.0.0.1'));
  });
}
