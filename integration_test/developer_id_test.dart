// An unsigned macOS build (no MACOS_KEYCHAIN_GROUP) and what a signed one may
// have left behind: a secret moved to the signed build's keychain, which this
// build cannot reach, says so once and never loops; with nothing moved it
// says nothing. Against the job's own sshd (e2e.yml), on the real macOS app.
//
// A relaunch is a new run of the app, so this file runs once per phase, each
// started by e2e.yml with --dart-define=JEANSH_E2E_DEVID, in order, on the
// same data (preferences, hosts and keychain):
//
//   add               a host with a password is saved and connected: the saved
//                     password authenticates, no notice
//   relaunch          started again, it connects with the saved password, no
//                     notice
//   rollback          a host whose key is noted as moved, with no keychain
//                     item: one notice and one toast, none on two more tries;
//                     the password entered again clears the note
//   rollback-relaunch started again, it connects, no notice, the note gone
//   none              a host with no note and no item: no notice, no toast,
//                     the usual "No password saved" answer

import 'dart:io';

import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/main.dart' as app;
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/ui/termul/tui_toast.dart' show TuiToastCard;
import 'package:xterm2/xterm.dart';

const _phase = String.fromEnvironment('JEANSH_E2E_DEVID');
const _movedKey = 'sshbox.secrets.movedToDataProtectionKeychain';

final _user = Platform.environment['SSH_USER'] ?? '';
final _password = Platform.environment['SSH_PASSWORD'] ?? '';
final _port = int.tryParse(Platform.environment['SSH_PORT'] ?? '') ?? 22;

String? get _skip => _phase.isEmpty
    ? 'run by e2e.yml, one phase at a time'
    : !Platform.isMacOS
    ? 'the unsigned macOS build'
    : macosKeychainGroup.isNotEmpty
    ? 'this build is signed with a keychain group'
    : Platform.environment['CI'] != 'true' || _user.isEmpty || _password.isEmpty
    ? "needs the job's own sshd and its throwaway user"
    : null;

const _movedText =
    "This secret was moved to the signed build's keychain; enter it again, "
    'or install the signed build.';
const _notMovedText =
    "A saved secret could not be moved to this build's keychain. The old "
    'copy is kept and used, and moving it is tried again next run.';
const _missing = 'No password saved for this host';

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

Finder _toast(String text) => find.descendant(
  of: find.byType(TuiToastCard),
  matching: find.textContaining(text, findRichText: true),
);

Future<List<String>> _noted() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  return prefs.getStringList(_movedKey) ?? const [];
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a secret moved away, on an unsigned build ($_phase)',
    skip: _skip != null,
    (tester) async {
      final secrets = KeystoreSecretStore();
      final hosts = HostRepository(secrets);
      final id = {
        'add': 'e2e-dev-ok',
        'relaunch': 'e2e-dev-ok',
        'rollback': 'e2e-dev-moved',
        'rollback-relaunch': 'e2e-dev-moved',
        'none': 'e2e-dev-none',
      }[_phase]!;
      final label = 'e2e $id';
      final key = SecretKeys.password(id);

      // Every notice this run, counted whatever the toast does.
      final said = <String>[];
      void listen() {
        final n = secretNotice.value;
        if (n != null) said.add(n.message);
      }

      secretNotice.addListener(listen);
      addTearDown(() => secretNotice.removeListener(listen));

      Future<void> seedHost() => hosts.upsert(
        HostProfile(
          id: id,
          label: label,
          host: '127.0.0.1',
          port: _port,
          username: _user,
        ),
      );

      // What the phase needs before the app starts.
      switch (_phase) {
        case 'add':
          await secrets
              .write(key, _password)
              .timeout(
                const Duration(seconds: 30),
                onTimeout: () => fail('the keychain never took the password'),
              );
          await seedHost();
        case 'rollback':
          // As a signed build leaves it: the note, and no keychain item (never
          // touched here: a read would be kept, and the app would not ask).
          final prefs = await SharedPreferences.getInstance();
          await prefs.setStringList(_movedKey, [key]);
          await seedHost();
          // The write above must not have taken the note: seeded after it.
          expect(await _noted(), [key]);
        case 'none':
          await seedHost();
          expect(await _noted(), isNot(contains(key)));
        default:
          break;
      }
      said.clear();

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

      final card = find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((w) {
          final t = '${w.runtimeType}';
          return t == 'Card' || t == 'HomeRow';
        }),
      );
      final trust = find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').toLowerCase() == 'trust',
      );
      final reconnect = find.byWidgetPredicate(
        (w) => w is Tooltip && w.message == 'Reconnect',
      );

      // A connect that gets as far as a shell on the host.
      Future<void> connected() async {
        await tester.tap(card.first);
        await _until(
          tester,
          () =>
              trust.evaluate().isNotEmpty ||
              find.byType(TerminalView).evaluate().isNotEmpty,
          'the host key prompt, or the terminal',
        );
        if (trust.evaluate().isNotEmpty) await tester.tap(trust.first);
        await _until(
          tester,
          () => find.byType(TerminalView).evaluate().isNotEmpty,
          'the terminal',
        );
        for (var i = 0; i < 100 && !_hasShell(await _theirs()); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          await tester.pump();
        }
        expect(
          _hasShell(await _theirs()),
          isTrue,
          reason: 'a shell on the host',
        );
        expect(
          find.textContaining(_missing).evaluate(),
          isEmpty,
          reason: 'the saved password was used',
        );
      }

      // A connect that stops at the missing password.
      Future<void> refused() async {
        await tester.tap(card.first);
        await _until(
          tester,
          () => find.textContaining(_missing).evaluate().isNotEmpty,
          'the missing-password answer',
        );
        expect(
          find.byType(TerminalView).evaluate(),
          isEmpty,
          reason: 'no tab opened without a password',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump(const Duration(milliseconds: 500));
      }

      switch (_phase) {
        case 'add':
        case 'relaunch':
          await connected();
          expect(said, isEmpty, reason: 'nothing to say about a saved secret');
          expect(_toast(_movedText).evaluate(), isEmpty);
          expect(_toast(_notMovedText).evaluate(), isEmpty);
          debugPrint('STEP PASS ($_phase): authenticated, no notice');
        case 'rollback':
          await refused();
          expect(said, [_movedText], reason: 'one notice, the moved one');
          expect(_toast(_movedText), findsOneWidget);
          expect(_toast(_notMovedText).evaluate(), isEmpty);
          // Twice more: the connect asks again, the notice does not.
          await refused();
          await refused();
          expect(said, [_movedText], reason: 'no second notice');
          expect(_toast(_movedText).evaluate().length, lessThanOrEqualTo(1));
          // The password entered again and saved.
          expect(await _noted(), [key], reason: 'the note stays until a save');
          await secrets.write(key, _password);
          expect(
            await _noted(),
            isNot(contains(key)),
            reason: 'saving a password drops the note',
          );
          debugPrint('STEP PASS (rollback): one notice, none on two tries');
        case 'rollback-relaunch':
          expect(await _noted(), isNot(contains(key)), reason: 'note gone');
          await connected();
          expect(said, isEmpty, reason: 'no notice once entered again');
          expect(_toast(_movedText).evaluate(), isEmpty);
          debugPrint('STEP PASS (rollback-relaunch): connected, no notice');
        case 'none':
          await refused();
          await refused();
          expect(said, isEmpty, reason: 'no note and no item: nothing said');
          expect(_toast(_movedText).evaluate(), isEmpty);
          expect(_toast(_notMovedText).evaluate(), isEmpty);
          expect(reconnect.evaluate(), isEmpty);
          debugPrint('STEP PASS (none): the usual missing-password answer');
      }
    },
  );
}
