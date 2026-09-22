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

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show Card, InkWell, Tooltip;
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
  FutureOr<bool> Function() done,
  String what, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final end = DateTime.now().add(timeout);
  while (!await done()) {
    if (DateTime.now().isAfter(end)) fail('Gave up waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
}

/// A Local shell opened from its card, holding focus, ready to be typed into.
///
/// A plain login shell rather than tmux: tmux between a program and Jeansh
/// answers or drops some sequences itself, which would make these tests of
/// tmux. Saved, not only set, so the Local tabs an earlier test left come back
/// plain at the next launch too — held in memory alone, the next launch read
/// tmux on again and brought them back as tmux tabs whose session never was.
/// The run's data folder is its own (tools/e2e_desktop.sh), so nothing of this
/// machine's is changed.
Future<TerminalView> _localShell(WidgetTester tester) async {
  await localTmux.choose(on: false);
  // The card, not a tab of the same name brought back from a run before.
  await tester.tap(find.widgetWithText(Card, 'Local shell'));
  // Ready once it holds focus and its shell has drawn a prompt: typed before
  // that, a command can reach a terminal with no shell behind it yet. Looked
  // up afresh each time, since a restored tab gets a new terminal as it
  // reconnects.
  TerminalView view() => tester.widget<TerminalView>(find.byType(TerminalView));
  try {
    await _until(tester, () {
      if (find.byType(TerminalView).evaluate().isEmpty) return false;
      final shown = view();
      return (shown.focusNode?.hasFocus ?? false) && _text(shown).isNotEmpty;
    }, 'the Local shell to open, take focus and draw its prompt');
  } on TestFailure {
    // What there is instead: which terminals, where, and what is on screen.
    for (final element in find
        .byType(TerminalView, skipOffstage: false)
        .evaluate()) {
      final each = element.widget as TerminalView;
      final onstage = find.byWidget(each).evaluate().isNotEmpty;
      debugPrint(
        'terminal ${onstage ? 'on screen' : 'offstage'}, '
        'focused ${each.focusNode?.hasFocus}, '
        'lines with text ${_text(each).length}',
      );
    }
    final labels = find
        .byType(Text)
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .whereType<String>();
    debugPrint('On screen: ${labels.take(40).join(' | ')}');
    rethrow;
  }
  return view();
}

/// The lines [view] shows that hold anything.
List<String> _text(TerminalView view) {
  final lines = view.terminal.buffer.lines;
  return [
    for (var i = 0; i < lines.length; i++)
      if (lines[i].getText().trim().isNotEmpty) lines[i].getText(),
  ];
}

/// Runs [command] in [view]'s shell: what a key press ends in, typed where
/// the keyboard would type it.
void _run(TerminalView view, String command) {
  view.terminal.textInput(command);
  view.terminal.keyInput(TerminalKey.enter);
}

/// A folder of the test's own, gone after it. The Local shell runs on this
/// machine, so a test reads what a program left there straight off the disk.
Directory _scratch() {
  final dir = Directory.systemTemp.createTempSync('jeansh-e2e-');
  addTearDown(() => dir.deleteSync(recursive: true));
  return dir;
}

Future<String?> _clipboard() async =>
    (await Clipboard.getData(Clipboard.kTextPlain))?.text;

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
      final view = await _localShell(tester);

      final dir = _scratch();
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

      _run(view, 'sh ${script.path}');
      await _until(tester, done.existsSync, 'the query script to finish');

      expect(
        await _clipboard(),
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

      _run(view, 'exit');
    },
  );

  // #12, #10 and the terminal half of #11: what a mouse selects in a desktop
  // terminal is copied as it reads, gaps and all. Claude Code draws a gap by
  // moving the cursor over it rather than printing a space, and xterm2's own
  // getText leaves out every cell nothing was written to, so a line drawn
  // `git ESC[1C push ESC[1C origin` copied as gitpushorigin until every copy
  // went through selectedText. Drawn here the same way, selected with a real
  // mouse drag, which copy on select — on by default on a desktop — puts on
  // the clipboard, and copied again from the right-click menu.
  testWidgets(
    'a mouse selection copies what the line reads, a drawn gap as a space',
    skip: Platform.isWindows, // Its Local shell is PowerShell, not sh.
    (tester) async {
      await _launch(tester);
      final view = await _localShell(tester);
      final script = File('${_scratch().path}/draw.sh')
        ..writeAsStringSync("printf 'git\\033[1Cpush\\033[1Corigin\\n'\n");
      _run(view, 'sh ${script.path}');

      // Found by what xterm2 itself makes of the line, gaps or none.
      final lines = view.terminal.buffer.lines;
      final drawn = RegExp(r'^git ?push ?origin');
      var row = -1;
      try {
        await _until(tester, () {
          for (var i = 0; i < lines.length; i++) {
            if (drawn.hasMatch(lines[i].getText())) row = i;
          }
          return row >= 0;
        }, 'the line to be drawn');
      } on TestFailure {
        // What the terminal holds instead: this test's own shell and nothing
        // else, so it says whether the command ran at all.
        final shown = _text(view);
        final tail = shown.sublist(shown.length > 12 ? shown.length - 12 : 0);
        debugPrint('The terminal holds:\n${tail.join('\n')}');
        rethrow;
      }

      final render = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal;
      Offset cell(int col) => render.localToGlobal(
        render.getOffset(CellOffset(col, row)) +
            Offset(render.cellSize.width / 2, render.lineHeight / 2),
      );
      Future<String?> copied() async {
        String? now;
        await _until(
          tester,
          () async => (now = await _clipboard()) != 'untouched',
          'something to be copied',
        );
        return now;
      }

      // Across the fifteen cells of the line, a cell at a time.
      await Clipboard.setData(const ClipboardData(text: 'untouched'));
      final mouse = await tester.startGesture(
        cell(0),
        kind: PointerDeviceKind.mouse,
      );
      for (var col = 1; col < 15; col++) {
        await mouse.moveTo(cell(col));
        await tester.pump();
      }
      await mouse.up();
      expect(
        await copied(),
        'git push origin',
        reason: 'copy on select copied the selection without its drawn gaps',
      );

      await Clipboard.setData(const ClipboardData(text: 'untouched'));
      await tester.tapAt(
        cell(5),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await _until(
        tester,
        () => find.text('Copy').evaluate().isNotEmpty,
        'the right-click menu to offer Copy',
      );
      await tester.tap(find.text('Copy'));
      expect(
        await copied(),
        'git push origin',
        reason: 'the right-click menu copied the selection without its gaps',
      );

      _run(view, 'exit');
    },
  );

  // #9 and the tab half of #11. Duplicate session on a Local shell's tab
  // opened nothing and said "That host is no longer saved": openHost looked
  // every id up among the saved hosts, and `local` never is one. A mouse has
  // no long press, so on a desktop the tab's menu is a right-click away.
  testWidgets(
    'a right-click on a Local shell tab duplicates it',
    skip: Platform.isWindows, // Its Local shell is PowerShell, not sh.
    (tester) async {
      await _launch(tester);
      await _localShell(tester);
      // Counted rather than assumed one: the tests before this left Local
      // tabs, which come back with each launch.
      final shells = find.byType(TerminalView, skipOffstage: false);
      final before = shells.evaluate().length;

      // A tab reads whatever title its shell gives itself, so it is found by
      // its close button, "Close <title>", and right-clicked on the chip that
      // holds it. Any Local tab duplicates the same way.
      final close = find.byWidgetPredicate(
        (w) => w is Tooltip && (w.message ?? '').startsWith('Close '),
      );
      final chip = find
          .ancestor(of: close.first, matching: find.byType(InkWell))
          .first;
      await tester.tapAt(
        tester.getCenter(chip),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await _until(
        tester,
        () => find.text('Duplicate session').evaluate().isNotEmpty,
        "the tab's right-click menu",
      );
      await tester.tap(find.text('Duplicate session'));
      await _until(
        tester,
        () => shells.evaluate().length == before + 1,
        'a second Local shell',
      );
      expect(find.textContaining('no longer saved'), findsNothing);
    },
  );
}
