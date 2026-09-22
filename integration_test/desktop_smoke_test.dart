// The desktop build, driven on the real desktop embedder.
//
// Everything under test/ runs through `flutter test`, which reports Android —
// so `isDesktop` is false there and desktop_test.dart has to fake the platform
// with debugDefaultTargetPlatformOverride. Nothing under test/ has ever loaded
// the GTK, Win32 or Cocoa embedder, the real plugins, or a real window. These
// do, which is the only reason they are worth their minutes.
//
// Native and headless on each platform, which is what the user asked for:
//
//   Linux    xvfb-run -a dbus-run-session -- flutter test integration_test -d linux
//   Windows  flutter test integration_test -d windows   (in a runner session)
//   macOS    flutter test integration_test -d macos     (in a runner session)
//
// Only Linux is headless in the strict sense — a virtual framebuffer, no
// display at all. On Windows and macOS there is a window; it is simply that
// nobody is looking at it. tools/e2e_desktop.sh picks the right one.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Card;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sshbox/main.dart' as app;
import 'package:sshbox/src/platform.dart';
import 'package:sshbox/src/ui/settings_page.dart' show localTmux;
import 'package:xterm2/xterm.dart';

/// Home, from a cold start, settled.
///
/// A generous settle: this is a real app doing real work at launch — reading
/// preferences off disk, asking the keychain, starting notifications — not a
/// widget tree pumped in memory.
Future<void> _launch(WidgetTester tester) async {
  await app.main();
  await tester.pumpAndSettle(const Duration(seconds: 5));
}

/// Pumps until [done] says so, failing with [what] after [timeout]. A live
/// terminal never settles — its cursor blinks — so pumpAndSettle cannot wait
/// on one.
Future<void> _until(
  WidgetTester tester,
  bool Function() done,
  String what, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('Gave up waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('it is a real desktop, not a faked one', (tester) async {
    // No override anywhere: this is what the embedder really reports. If this
    // ever passes under `flutter test` the suite is not running where it
    // claims to be.
    expect(
      defaultTargetPlatform,
      anyOf(
        TargetPlatform.linux,
        TargetPlatform.windows,
        TargetPlatform.macOS,
      ),
    );
    expect(isDesktop, isTrue);
  });

  testWidgets('the app boots and draws Home', (tester) async {
    await _launch(tester);

    // If a plugin threw on the way up — secure storage with no Secret Service,
    // notifications, app_links — this is where it shows, as nothing drawn.
    expect(find.text('Jeansh'), findsWidgets);
    expect(find.text('Terminal buddy in your pocket'), findsOneWidget);
  });

  testWidgets('a desktop offers a shell on the machine itself', (tester) async {
    await _launch(tester);

    // Desktop only, through flutter_pty: a phone has no pty to open. This is
    // native code, so no widget test can reach it — the card being here means
    // the plugin loaded on this embedder.
    expect(find.text('Local shell'), findsOneWidget);
  });

  // Deliberately not tested here: that a desktop drops the key bar and the
  // magic key. Both only exist on a terminal page, so asserting their absence
  // on Home would pass on a phone too — a test that cannot fail. It needs a
  // live session, which means the runner's own sshd; it belongs with that work
  // rather than as a green tick that proves nothing. desktop_test.dart covers
  // the choice itself against a faked platform.

  testWidgets('Settings offers updates, and says so honestly when it cannot', (
    tester,
  ) async {
    await _launch(tester);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // Asserted before scrolling, so a Settings page that never opened fails
    // saying that rather than "no Updates section", which would send the next
    // reader looking at the updater.
    expect(find.text('Settings'), findsWidgets);

    // Updates is the last section, well below the fold: a ListView does not
    // build what is off screen, so find.text would report it missing on a page
    // that has it. Scroll until it is built rather than weakening the
    // assertion.
    await tester.scrollUntilVisible(
      find.text('Check for updates'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    // Desktop only: Android updates through Play, so this section is not built
    // there at all.
    expect(find.text('Updates'), findsOneWidget);
    expect(find.text('Check for updates'), findsOneWidget);

    // With no JEANSH_UPDATE_HOST baked in — which is every build until the
    // bucket is served — the row must say the build takes no updates rather
    // than offering a check that could only fail. A release build with a host
    // baked in says which version it is instead, so accept either and fail on
    // silence.
    expect(
      find.textContaining(RegExp('takes no updates|This is Jeansh')),
      findsOneWidget,
    );
  });

  // UAT issue #13. OSC 52 lets a program copy to the clipboard, which Jeansh
  // allows, and also ask for it back, `ESC ] 52 ; c ; ? BEL`, which it must
  // never answer: the answer goes to the host, password and all. xterm2's own
  // view answers it for a focused terminal, and every build before b11f5bc
  // let it. ClipboardTerminal is what refuses.
  //
  // Here rather than on Android: xterm2 answers only while its view holds
  // focus, and a Maestro flow typing through the soft keyboard never gives it
  // focus, so a leaking build read as refused there — twice, in mutation runs.
  // A desktop terminal holds focus the way a hardware keyboard gives it.
  //
  // Three things make the silence mean something, and each is asserted: the
  // view has focus; the program's copy of a canary landed on the clipboard,
  // which _programCopied only lets a focused terminal do, so there is
  // something to leak; and the reply is read where the program read it. A
  // mutation run of the pre-fix terminal must fail this test.
  testWidgets(
    'a program in the shell cannot read the clipboard back',
    skip: Platform.isWindows, // Its Local shell is PowerShell, not sh.
    (tester) async {
      await _launch(tester);
      // A plain login shell. tmux between the program and Jeansh answers or
      // drops the query itself, which would make this a test of tmux. In memory
      // only: the saved choice is left alone.
      localTmux.value = (on: false, path: '');

      // The Local shell runs on this machine, so the test reads what the
      // program recorded straight off the disk.
      final dir = Directory.systemTemp.createTempSync('jeansh-osc52-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final reply = File('${dir.path}/reply');
      final done = File('${dir.path}/done');
      // Plain sh, and no `timeout`, which a Mac does not have. The reader is
      // given the terminal outright: sh hands a background job /dev/null.
      final script = File('${dir.path}/query.sh')
        ..writeAsStringSync('''
printf '\\033]52;c;%s\\a' "\$(printf e2e-canary | base64)"
sleep 1
stty -echo raw
printf '\\033]52;c;?\\a'
cat -v < /dev/tty > '${reply.path}' & reader=\$!
sleep 2
kill \$reader
stty sane
touch '${done.path}'
''');

      // The card, not a tab of the same name brought back from a run before.
      await tester.tap(find.widgetWithText(Card, 'Local shell'));
      await _until(
        tester,
        () => find.byType(TerminalView).evaluate().isNotEmpty,
        'the Local shell to open',
      );
      final view = tester.widget<TerminalView>(find.byType(TerminalView));
      await _until(
        tester,
        () => view.focusNode?.hasFocus ?? false,
        'the terminal to take focus, without which xterm2 would stay silent '
        'even on a leaking build',
      );

      // What a key press ends in, typed where the keyboard would type it.
      view.terminal.textInput('sh ${script.path}');
      view.terminal.keyInput(TerminalKey.enter);
      await _until(tester, done.existsSync, 'the query script to finish');

      expect(
        (await Clipboard.getData(Clipboard.kTextPlain))?.text,
        'e2e-canary',
        reason:
            'the program\'s copy never reached the clipboard, so an empty reply '
            'would prove nothing: a leaking terminal answers from the clipboard, '
            'and an empty one gives it nothing to send',
      );
      final answer = reply.readAsStringSync();
      // The length is what is logged. A failure shows the bytes too, which
      // can only be the canary above: the clipboard is this run's own display's.
      debugPrint('OSC 52 query reply: ${answer.length} bytes');
      expect(
        answer,
        isEmpty,
        reason: 'the terminal answered a clipboard query: a host can read it',
      );

      view.terminal.textInput('exit');
      view.terminal.keyInput(TerminalKey.enter);
    },
  );
}
