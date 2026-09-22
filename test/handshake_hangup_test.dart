import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/dartssh2_transport.dart';
import 'package:sshbox/src/session/terminal_session.dart';

/// Hands the transport its socket only once the host's hang-up has reached
/// it, which in the app is a race the host wins now and then: dartssh2 then
/// reads the end of the stream before its first writes fail, and closes the
/// socket while they do.
final class _AfterHangUp extends IOOverrides {
  _AfterHangUp(this.hungUp);

  final Future<void> hungUp;

  @override
  Future<Socket> socketConnect(
    host,
    int port, {
    sourceAddress,
    int sourcePort = 0,
    Duration? timeout,
  }) async {
    final socket = await super.socketConnect(
      host,
      port,
      sourceAddress: sourceAddress,
      sourcePort: sourcePort,
      timeout: timeout,
    );
    await hungUp;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return socket;
  }
}

void main() {
  test('a host that takes the connection and hangs up fails the connect, '
      'and leaves no error uncaught', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final hungUp = Completer<void>();
    server.listen((socket) {
      socket.destroy();
      if (!hungUp.isCompleted) hungUp.complete();
    });
    addTearDown(server.close);

    final secrets = InMemorySecretStore();
    await secrets.write(SecretKeys.password('box'), 'not a real password');
    final host = HostProfile(
      id: 'box',
      label: 'box',
      host: '127.0.0.1',
      port: server.port,
      username: 'me',
    );

    // An error nothing listens to fails the test from the test's own zone,
    // as it failed CI.
    await IOOverrides.runWithIOOverrides(() async {
      await expectLater(
        Dartssh2Transport().connect(
          host: host,
          secrets: secrets,
          columns: 80,
          rows: 24,
        ),
        throwsA(isA<SshSessionException>()),
      );
      // Room for what dartssh2 closes after the connect has failed.
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }, _AfterHangUp(hungUp.future));
  });
}
