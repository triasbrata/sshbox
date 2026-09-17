import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/known_host_store.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/dartssh2_transport.dart';
import 'package:sshbox/src/session/terminal_session.dart';

/// Exercises a real SSH handshake against an sshd on localhost.
///
/// It authenticates with a credential that cannot possibly work on purpose.
/// Landing on a clean "authentication rejected" proves the socket, key
/// exchange, host key pinning and error mapping all work end to end — only
/// the credential check itself is left unproven, and that needs a secret this
/// test has no business holding.
///
/// Skips itself when nothing is listening on port 22, so it stays harmless
/// on a machine or CI runner without a local sshd.
Future<bool> _sshdReachable() async {
  try {
    final socket = await Socket.connect(
      '127.0.0.1',
      22,
      timeout: const Duration(seconds: 2),
    );
    socket.destroy();
    return true;
  } on Exception {
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reaches SSH auth against local sshd and pins the host key', () async {
    if (!await _sshdReachable()) {
      printOnFailure('skipped: nothing listening on 127.0.0.1:22');
      return;
    }

    SharedPreferences.setMockInitialValues({});

    final knownHosts = KnownHostStore();
    String? pinnedFingerprint;

    final transport = Dartssh2Transport(
      knownHosts: knownHosts,
      confirmHostKey: (check) async {
        pinnedFingerprint = check.fingerprint;
        return true;
      },
    );

    const host = HostProfile(
      id: 'live-test',
      label: 'local sshd',
      host: '127.0.0.1',
      username: 'sshbox-user-that-does-not-exist',
    );

    final secrets = InMemorySecretStore();
    await secrets.write(
      SecretKeys.password(host.id),
      'deliberately-wrong-password',
    );

    await expectLater(
      transport.connect(
        host: host,
        secrets: secrets,
        columns: 80,
        rows: 24,
      ),
      throwsA(isA<SshSessionException>()),
    );

    // Getting a fingerprint at all means the handshake ran and our
    // verification callback was consulted before authentication.
    expect(pinnedFingerprint, isNotNull);
    expect(pinnedFingerprint, startsWith('SHA256:'));
    expect(await knownHosts.pinnedKey('127.0.0.1', 22), pinnedFingerprint);
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('the key is pinned under the saved address, whichever one answered',
      () async {
    if (!await _sshdReachable()) {
      printOnFailure('skipped: nothing listening on 127.0.0.1:22');
      return;
    }

    SharedPreferences.setMockInitialValues({});

    final knownHosts = KnownHostStore();
    var asked = 0;
    String? pinnedFingerprint;
    final transport = Dartssh2Transport(
      knownHosts: knownHosts,
      confirmHostKey: (check) async {
        asked++;
        pinnedFingerprint = check.fingerprint;
        return true;
      },
    );

    const host = HostProfile(
      id: 'live-test',
      label: 'local sshd',
      // Reserved by RFC 2606, so it never resolves: the saved address is out
      // of reach, and only the alternative can answer.
      host: 'nothing-here.invalid',
      altHost: '127.0.0.1',
      username: 'sshbox-user-that-does-not-exist',
    );

    final secrets = InMemorySecretStore();
    await secrets.write(
      SecretKeys.password(host.id),
      'deliberately-wrong-password',
    );

    await expectLater(
      transport.connect(host: host, secrets: secrets, columns: 80, rows: 24),
      throwsA(isA<SshSessionException>()),
    );

    // Asked once, and pinned against the host as it is saved — not against
    // the address that answered. The same machine at either address is one
    // pinned key, so switching to the alternative neither asks again nor
    // cries "the host key has changed".
    expect(asked, 1);
    expect(pinnedFingerprint, startsWith('SHA256:'));
    expect(
      await knownHosts.pinnedKey('nothing-here.invalid', 22),
      pinnedFingerprint,
    );
    expect(await knownHosts.pinnedKey('127.0.0.1', 22), isNull);
  }, timeout: const Timeout(Duration(seconds: 40)));
}
