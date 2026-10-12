// macOS keeps what the keychain answered for the run, so a reconnect asks it
// nothing and no prompt can come up; Linux does not keep, so there every
// reconnect asks again. On the real desktop build, against the job's own
// sshd (e2e.yml), through KeystoreSecretStore's own counters.
//
// 2x2: the kept read (macOS) shows 0 reads on a reconnect and the unkept
// (Linux) shows more; a changed password is read once and used, so the stale
// one is never sent, and the same password again is not written.
//
// The job's user is throwaway: its password is changed here, on the machine,
// with sudo, as the user changing it would.

import 'dart:io';

import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sshbox/main.dart' as app;
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:xterm2/xterm.dart';

final _user = Platform.environment['SSH_USER'] ?? '';
final _password = Platform.environment['SSH_PASSWORD'] ?? '';
final _port = int.tryParse(Platform.environment['SSH_PORT'] ?? '') ?? 22;

String? get _skip => !(Platform.isMacOS || Platform.isLinux)
    ? 'the keychain read count is for macOS and Linux'
    : Platform.environment['CI'] != 'true'
    ? "needs the job's own sshd and its throwaway user"
    : null;

/// On CI a missing sshd is a failure, not a skip: a skip hid a job whose setup
/// never ran.
String? get _missing {
  final missing = [
    if (_user.isEmpty) 'SSH_USER',
    if (_password.isEmpty) 'SSH_PASSWORD',
    if (Platform.isMacOS && _port == 22) 'SSH_PORT',
  ];
  return missing.isEmpty ? null : missing.join(', ');
}

Future<void> _until(
  WidgetTester tester,
  bool Function() done,
  String what, {
  Duration timeout = const Duration(seconds: 40),
}) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('Gave up waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
}

Future<void> _sudo(List<String> args, {int ok = 0}) async {
  final done = await Process.run('sudo', args);
  expect(done.exitCode, ok, reason: 'sudo $args: ${done.stderr}');
}

/// What the throwaway user runs now, by command name.
Future<List<String>> _theirs() async {
  final done = await Process.run('ps', ['-u', _user, '-o', 'comm=']);
  return '${done.stdout}'
      .split('\n')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
}

bool _hasShell(List<String> comms) =>
    comms.any((c) => c.endsWith('sh') && !c.contains('sshd'));

Future<void> _setServerPassword(String password) async {
  if (Platform.isMacOS) {
    await _sudo(['dscl', '.', '-passwd', '/Users/$_user', password]);
  } else {
    final p = await Process.start('sudo', ['chpasswd']);
    p.stdin.write('$_user:$password\n');
    await p.stdin.close();
    await p.stdout.drain<void>();
    expect(await p.exitCode, 0, reason: 'chpasswd');
  }
}

final _reconnect = find.byWidgetPredicate(
  (w) => w is Tooltip && w.message == 'Reconnect',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'keychain reads: kept on macOS, asked each time on Linux',
    skip: _skip != null,
    (tester) async {
      final missing = _missing;
      if (missing != null) {
        fail("the job's sshd step did not run: no $missing in the environment");
      }
      final keeps = Platform.isMacOS;
      final secrets = KeystoreSecretStore();
      final hosts = HostRepository(secrets);
      const id = 'e2e-keychain';
      final key = SecretKeys.password(id);
      final changed = 'changed-${_password.substring(0, 8)}';
      addTearDown(() async {
        await hosts.delete(id);
        await _setServerPassword(_password);
      });

      // The host editor's own save: the password to the keychain, then the host.
      Future<void> save(String password) async {
        await secrets
            .write(key, password)
            .timeout(
              const Duration(seconds: 30),
              onTimeout: () => fail('the keychain never took the password'),
            );
        await hosts.upsert(
          HostProfile(
            id: id,
            label: 'e2e keychain',
            host: '127.0.0.1',
            port: _port,
            username: _user,
          ),
        );
      }

      await save(_password);

      await app.main();
      await _until(
        tester,
        () =>
            find.text('Skip').evaluate().isNotEmpty ||
            find.byTooltip('Settings').evaluate().isNotEmpty,
        'Home, or the first-run slides',
      );
      if (find.text('Skip').evaluate().isNotEmpty) {
        await tester.tap(find.text('Skip').first);
      }
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      TerminalView? shown() => find.byType(TerminalView).evaluate().isEmpty
          ? null
          : find.byType(TerminalView).evaluate().first.widget as TerminalView;

      // Connected: a terminal drawn and the user's shell running on the host.
      Future<void> shellUp(String what) async {
        await _until(tester, () => shown() != null, '$what: the terminal');
        for (var i = 0; i < 100 && !_hasShell(await _theirs()); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          await tester.pump();
        }
        expect(_hasShell(await _theirs()), isTrue, reason: '$what: a shell');
        expect(_reconnect.evaluate(), isEmpty, reason: '$what: not ended');
      }

      // The connection cut from the host, as a dropped one is.
      Future<void> drop() async {
        await _sudo(['pkill', '-KILL', '-u', _user], ok: 0);
        await _until(
          tester,
          () => _reconnect.evaluate().isNotEmpty,
          'the tab to offer Reconnect',
        );
        expect(_hasShell(await _theirs()), isFalse, reason: 'cut');
      }

      Future<void> reconnect() async {
        await tester.tap(_reconnect.first);
        await tester.pump(const Duration(milliseconds: 300));
      }

      // 1. Positive: connect, drop, reconnect.
      KeystoreSecretStore.keychainReads = 0;
      KeystoreSecretStore.keychainWrites = 0;
      await tester.tap(
        find.ancestor(
          of: find.text('e2e keychain'),
          matching: find.byWidgetPredicate((w) {
            final t = '${w.runtimeType}';
            return t == 'Card' || t == 'HomeRow';
          }),
        ),
      );
      await _until(
        tester,
        () =>
            find.text('Trust').evaluate().isNotEmpty ||
            find.text('TRUST').evaluate().isNotEmpty,
        "the host key's Trust",
      );
      await tester.tap(
        find.text('Trust').evaluate().isNotEmpty
            ? find.text('Trust')
            : find.text('TRUST'),
      );
      await shellUp('first connect');
      final r1 = KeystoreSecretStore.keychainReads;
      expect(r1, greaterThan(0), reason: 'the first connect read the password');

      await drop();
      await reconnect();
      await shellUp('reconnect');
      final delta = KeystoreSecretStore.keychainReads - r1;
      if (keeps) {
        expect(delta, 0, reason: 'macOS: a reconnect reads nothing');
      } else {
        expect(
          delta,
          greaterThan(0),
          reason: 'Linux keeps nothing: a reconnect asks again',
        );
      }
      debugPrint(
        'STEP 1 PASS: first connect read $r1, reconnect read $delta '
        '(${keeps ? 'kept' : 'not kept'})',
      );

      // 2. Negative: the password changed on the host and saved here.
      final reads2 = KeystoreSecretStore.keychainReads;
      final writes2 = KeystoreSecretStore.keychainWrites;
      await _setServerPassword(changed);
      await save(changed);
      expect(
        KeystoreSecretStore.keychainWrites,
        writes2 + 1,
        reason: 'a new password is written once',
      );
      await drop();
      await reconnect();
      await shellUp('reconnect with the new password');
      if (keeps) {
        expect(
          KeystoreSecretStore.keychainReads - reads2,
          1,
          reason: 'the changed key is read once, afresh',
        );
      }
      debugPrint(
        'STEP 2 PASS: new password written once and used; reads +'
        '${KeystoreSecretStore.keychainReads - reads2}',
      );

      // 3. The same password again.
      final writes3 = KeystoreSecretStore.keychainWrites;
      await save(changed);
      expect(
        KeystoreSecretStore.keychainWrites - writes3,
        keeps ? 0 : 1,
        reason: keeps
            ? 'the same password is not written again'
            : 'Linux keeps nothing: every save writes',
      );
      debugPrint(
        'STEP 3 PASS: same password, writes +'
        '${KeystoreSecretStore.keychainWrites - writes3}',
      );
    },
  );
}
