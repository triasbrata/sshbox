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

  test('the key is pinned under the address that answered, and the prompt '
      'names it', () async {
    if (!await _sshdReachable()) {
      printOnFailure('skipped: nothing listening on 127.0.0.1:22');
      return;
    }

    SharedPreferences.setMockInitialValues({});

    final knownHosts = KnownHostStore();
    final asked = <HostKeyCheck>[];
    final transport = Dartssh2Transport(
      knownHosts: knownHosts,
      confirmHostKey: (check) async {
        asked.add(check);
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

    // Asked once, about the address that actually answered — never about the
    // saved address, which nothing was ever reached at: a user cannot rule on
    // a key shown under the name of a machine that never spoke.
    expect(asked, hasLength(1));
    expect(asked.single.address, '127.0.0.1');
    expect(asked.single.pinned, isNull);
    // The saved address has no key of its own to disagree with, so there is
    // nothing to warn about.
    expect(asked.single.otherAddress, isNull);
    expect(asked.single.fingerprint, startsWith('SHA256:'));
    // And pinned under that address, as OpenSSH's known_hosts would.
    expect(
      await knownHosts.pinnedKey('127.0.0.1', 22),
      asked.single.fingerprint,
    );
    expect(await knownHosts.pinnedKey('nothing-here.invalid', 22), isNull);
  }, timeout: const Timeout(Duration(seconds: 40)));
}
