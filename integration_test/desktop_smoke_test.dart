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
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart'
    show DropdownButton, InkWell, TextField, Tooltip;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sshbox/main.dart' as app;
import 'package:sshbox/src/platform.dart';
import 'package:sshbox/src/ui/tui.dart';
import 'package:sshbox/src/update/updater.dart'
    show downloadsFolder, updateHost, updatePlatform;
import 'package:sshbox/src/ui/git_diff_page.dart' show GitDiffPage;
import 'package:sshbox/src/ui/hosts_page.dart' show HomeRow;
import 'package:sshbox/src/ui/settings_page.dart'
    show LinkModifier, localTmux, terminalFonts;
import 'package:xterm2/xterm.dart';

/// Home, from a cold start, settled.
///
/// A generous settle: this is a real app doing real work at launch — reading
/// preferences off disk, asking the keychain, starting notifications — not a
/// widget tree pumped in memory.
Future<void> _launch(WidgetTester tester) async {
  await app.main();
  // A fresh data folder is a fresh install, which opens on the slides. They
  // animate, so nothing settles until they are skipped.
  final skip = find.bySemanticsLabel('Skip');
  await _until(
    tester,
    () =>
        skip.evaluate().isNotEmpty ||
        find.byTooltip('Settings').evaluate().isNotEmpty,
    'Home, or the first-run slides',
  );
  if (skip.evaluate().isNotEmpty) await tester.tap(skip);
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
    if (DateTime.now().isAfter(end)) {
      // What the screen showed instead: its labels and its buttons' tooltips,
      // the app's own words. A terminal's text is painted, not a widget, so
      // none of it is here.
      String words<T extends Widget>(String? Function(T) of) => find
          .byType(T)
          .evaluate()
          .map((e) => of(e.widget as T))
          .whereType<String>()
          .take(60)
          .join(' | ');
      debugPrint('On screen: ${words<Text>((t) => t.data ?? t.textSpan?.toPlainText())}');
      debugPrint('Buttons: ${words<Tooltip>((t) => t.message)}');
      fail('Gave up waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
}

/// A Local shell opened from its card, holding focus, ready to be typed into.
///
/// A plain login shell unless [tmux]: tmux between a program and Jeansh
/// answers or drops some sequences itself, which would make the other tests
/// ones of tmux. Saved, not only set, so a later launch reads the same — held
/// in memory alone, the next launch read tmux on again. The run's data folder
/// is its own (tools/e2e_desktop.sh), so nothing of this machine's is changed.
Future<TerminalView> _localShell(
  WidgetTester tester, {
  bool tmux = false,
}) async {
  await localTmux.choose(on: tmux);
  // Whatever a test before this one left open, had it failed before closing
  // its tabs, goes first, so one failure does not become the next test's.
  await _closeTabs(tester);
  // The card, not a tab of the same name brought back from a run before.
  await tester.tap(find.widgetWithText(HomeRow, 'Local shell'));
  // Ready once a terminal holds focus and its shell has drawn a prompt: typed
  // before that, a command can reach a terminal with no shell behind it yet.
  // The focused one, where a tab shows several panes; looked up afresh each
  // time, since a restored tab gets a new terminal as it reconnects.
  TerminalView? view() => find
      .byType(TerminalView)
      .evaluate()
      .map((element) => element.widget as TerminalView)
      .where((each) => each.focusNode?.hasFocus ?? false)
      .firstOrNull;
  try {
    await _until(tester, () {
      final shown = view();
      return shown != null && _text(shown).isNotEmpty;
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
    rethrow;
  }
  return view()!;
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

/// Picks [item] from a menu once it has finished opening. A menu grows open,
/// and its items are built before they can be hit: tapped as soon as one is
/// built, the tap can land on the barrier beside a clipped item, which shuts
/// the menu and does nothing — a test that passed or failed on the machine's
/// speed.
Future<void> _pick(WidgetTester tester, String item) async {
  await _until(
    tester,
    () => find.text(item).evaluate().isNotEmpty,
    'the menu to offer $item',
  );
  await tester.pump(const Duration(milliseconds: 600));
  await tester.tap(find.text(item));
}

/// Settings, opened from Home and slid all the way in. Scrolled sooner, a
/// drag lands on what Home still shows beneath it — its tab strip is a list
/// too, and first in the tree.
Future<void> _settings(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Settings'));
  await tester.pump(const Duration(milliseconds: 600));
}

/// Back from Settings to Home, and Settings all the way gone. Home's card is
/// found while Settings is still sliding out over it, and a tap on it then
/// lands on the page leaving — a Mac run opened no shell that way.
Future<void> _backHome(WidgetTester tester) async {
  // termul's ← BACK, named Back.
  await tester.tap(find.bySemanticsLabel('Back'));
  await _until(
    tester,
    () => find.widgetWithText(HomeRow, 'Local shell').evaluate().isNotEmpty,
    'Home again',
  );
  await tester.pump(const Duration(milliseconds: 600));
}

/// Closes every tab, so the next test's launch brings none back. A Local tab
/// left open is saved and restored at the next launch, and that restore
/// lands whenever it lands — before or after the next test taps the card or
/// counts its tabs — which made a test pass or fail by timing alone.
Future<void> _closeTabs(WidgetTester tester) async {
  final close = find.byWidgetPredicate(
    (w) => w is Tooltip && (w.message ?? '').startsWith('Close '),
  );
  // Capped, so a "Close …" that closes nothing cannot hold the run.
  for (var i = 0; i < 20 && close.evaluate().isNotEmpty; i++) {
    await tester.tap(close.first);
    await tester.pump(const Duration(milliseconds: 300));
  }
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
      find.bySemanticsLabel('Check for updates'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    // Desktop only: Android updates through Play, so this section is not built
    // there at all.
    expect(find.bySemanticsLabel('Updates'), findsOneWidget);
    expect(find.bySemanticsLabel('Check for updates'), findsOneWidget);

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

      await _closeTabs(tester);
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
      await _pick(tester, 'Copy');
      expect(
        await copied(),
        'git push origin',
        reason: 'the right-click menu copied the selection without its gaps',
      );

      await _closeTabs(tester);
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
      // A tab reads whatever title its shell gives itself, so tabs are found
      // by their close button, "Close <title>" — "Reconnect" once its shell
      // has ended. Counted on the strip rather than by terminals, which a
      // restored tab builds and swaps as it reconnects.
      final close = find.byWidgetPredicate(
        (w) => w is Tooltip && (w.message ?? '').startsWith('Close '),
      );
      final tabs = find.byWidgetPredicate(
        (w) =>
            w is Tooltip &&
            ((w.message ?? '').startsWith('Close ') ||
                w.message == 'Reconnect'),
      );
      final before = tabs.evaluate().length;

      // Right-clicked on the chip that holds a close button. Any Local tab
      // duplicates the same way.
      final chip = find
          .ancestor(of: close.first, matching: find.byType(InkWell))
          .first;
      await tester.tapAt(
        tester.getCenter(chip),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await _pick(tester, 'Duplicate session');
      await _until(
        tester,
        () => tabs.evaluate().length == before + 1,
        'a second Local shell',
      );
      expect(find.textContaining('no longer saved'), findsNothing);
      await _closeTabs(tester);
    },
  );

  // #3: a diff opens split on a wide page, as GitHub's does — old on the
  // left, new on the right, a changed line level with the line that replaced
  // it; a narrow one stacks them. This window is past the 900 dp where split
  // begins, so the check is that the two sit on one row, side by side.
  testWidgets(
    'a diff on a wide page opens split, the old line beside the new',
    skip: Platform.isWindows, // Its Local shell is PowerShell, not sh.
    (tester) async {
      // Where a Local shell's Git panel looks: the login home, a folder or
      // two down. Made for this test and gone after it.
      final repo = Directory(
        Platform.environment['HOME']!,
      ).createTempSync('jeansh-e2e-repo-');
      addTearDown(() => repo.deleteSync(recursive: true));
      Future<void> git(List<String> args) async {
        final done = await Process.run('git', ['-C', repo.path, ...args]);
        expect(done.exitCode, 0, reason: '${done.stderr}');
      }

      final file = File('${repo.path}/e2e.txt');
      await git(['init', '-q']);
      file.writeAsStringSync('first\nbefore-e2e\nlast\n');
      await git(['add', 'e2e.txt']);
      await git([
        '-c', 'user.name=e2e', '-c', 'user.email=e2e@example.invalid', //
        'commit', '-q', '-m', 'e2e',
      ]);
      file.writeAsStringSync('first\nafter-e2e\nlast\n');

      await _launch(tester);
      await _localShell(tester);
      await tester.tap(find.byTooltip('Git'));

      // On a runner the home holds this repository alone and it is picked
      // already; on a machine with others it is picked from the list.
      final name = repo.path.split('/').last;
      bool ours(String? root) => root != null && root.endsWith('/$name');
      final picker = find.byType(DropdownButton<String>);
      DropdownButton<String> shown() => tester.widget(picker);
      await _until(
        tester,
        () =>
            picker.evaluate().isNotEmpty &&
            shown().items!.any((item) => ours(item.value)),
        "the Git panel to find this test's repository",
      );
      if (!ours(shown().value)) {
        // Picked through the picker's own onChanged, which is what choosing
        // it from the list calls: this test is of the diff, and a long list
        // in a small menu is its own fight.
        final root = shown().items!.map((item) => item.value).firstWhere(ours);
        shown().onChanged!(root);
        await _until(
          tester,
          () => ours(shown().value),
          "this test's repository to be picked",
        );
      }
      await _until(
        tester,
        () => find.textContaining('e2e.txt').evaluate().isNotEmpty,
        'the changed file under Changes',
      );
      await tester.tap(find.textContaining('e2e.txt').first);

      final before = find.textContaining('before-e2e', findRichText: true);
      final after = find.textContaining('after-e2e', findRichText: true);
      await _until(
        tester,
        () => before.evaluate().isNotEmpty && after.evaluate().isNotEmpty,
        'the diff',
      );
      final old = tester.getCenter(before.first);
      final now = tester.getCenter(after.first);
      // Split from 900 dp of page. This Linux window is past it; a Mac's
      // starts narrower, where unified is right, so the page's own width
      // says which to expect, and both are held to it.
      final wide = tester.getSize(find.byType(GitDiffPage)).width >= 900;
      if (wide) {
        expect(find.byTooltip('Unified view'), findsOneWidget,
            reason: 'a wide page did not open split');
        expect(old.dy, closeTo(now.dy, 1),
            reason: 'the changed line is not level with what replaced it');
        expect(old.dx, lessThan(now.dx),
            reason: 'the old line is not on the left');
      } else {
        expect(find.byTooltip('Split view'), findsOneWidget,
            reason: 'a narrow page did not open unified');
        expect(old.dy, lessThan(now.dy),
            reason: 'the old line is not above the new');
      }
      await _closeTabs(tester);
    },
  );

  // #18: where the machine has tmux, the Local shell runs in it, as a tmux
  // host's tabs do — an sshbox- session on the machine's own tmux server, a
  // tab that splits into panes, and the session ended by the tab's ✕.
  //
  // Linux only: tools/e2e_desktop.sh gives the run a tmux server of its own
  // there, through TMUX_TMPDIR, and elsewhere this would open sessions on the
  // server of whoever runs it.
  testWidgets(
    'a Local shell runs in tmux where the machine has it',
    skip: !Platform.isLinux,
    (tester) async {
      Future<List<String>> sessions() async {
        final listed = await Process.run('tmux', [
          'list-sessions',
          '-F',
          '#{session_name}',
        ]);
        return '${listed.stdout}'
            .split('\n')
            .where((name) => name.startsWith('sshbox-'))
            .toList();
      }

      expect(await sessions(), isEmpty, reason: 'the run began with a session');
      await _launch(tester);
      await _localShell(tester, tmux: true);
      await _until(
        tester,
        () async => (await sessions()).length == 1,
        'an sshbox- session on the tmux server',
      );

      // A tmux tab's menu, which a plain shell's lacks, splits it.
      final close = find.byWidgetPredicate(
        (w) => w is Tooltip && (w.message ?? '').startsWith('Close '),
      );
      await tester.tapAt(
        tester.getCenter(
          find.ancestor(of: close.first, matching: find.byType(InkWell)).first,
        ),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await _pick(tester, 'Split right');
      await _until(tester, () async {
        final listed = await Process.run('tmux', [
          'list-panes',
          '-a',
          '-F',
          '#{pane_id}',
        ]);
        return '${listed.stdout}'.trim().split('\n').length == 2;
      }, 'tmux to split the session in two');
      await _until(
        tester,
        () => find.byType(TerminalView).evaluate().length == 2,
        'two panes side by side',
      );

      await _closeTabs(tester);
      await _until(
        tester,
        () async => (await sessions()).isEmpty,
        "the session to end with its tab's ✕",
      );
    },
  );

  // #15 and #19: a picture on the clipboard, pasted into a Local shell with
  // Ctrl+V, is copied on this machine and its path typed at the prompt, as an
  // upload's is over SSH — where it used to end in "This session cannot
  // transfer files" and type nothing. Read off the X11 clipboard by xclip,
  // as a Linux desktop without Wayland has it; copied into a folder only its
  // owner can enter, the file only its owner can read.
  //
  // Linux only: the picture is put on the clipboard with xclip, and the run's
  // display is Xvfb's own (tools/e2e_desktop.sh).
  testWidgets(
    "a picture pasted into a Local shell is copied and its path typed",
    skip: !Platform.isLinux,
    (tester) async {
      // One transparent pixel: a real PNG, small enough to write out here.
      final png = base64.decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAj'
        'CB0C8AAAAASUVORK5CYII=',
      );
      final picture = File('${_scratch().path}/picture.png')
        ..writeAsBytesSync(png);
      // xclip stays behind to hand the picture over, so it is given nothing
      // of ours to hold open, or this would wait for it.
      final put = await Process.run('sh', [
        '-c',
        r'xclip -selection clipboard -t image/png -i "$1" >/dev/null 2>&1',
        'sh',
        picture.path,
      ]);
      expect(put.exitCode, 0, reason: 'xclip could not take the picture');

      await _launch(tester);
      final view = await _localShell(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      final typed = RegExp(r'(/\S*/pasted-\d{8}-\d{6}\.png)');
      String? path;
      await _until(tester, () {
        for (final line in _text(view)) {
          path = typed.firstMatch(line)?.group(1) ?? path;
        }
        return path != null;
      }, 'the path of the pasted picture at the prompt');

      final copy = File(path!);
      expect(copy.readAsBytesSync(), png, reason: 'not the picture pasted');
      String mode(FileSystemEntity entry) =>
          (entry.statSync().mode & 0x1ff).toRadixString(8);
      expect(mode(copy), '600', reason: 'others can read the picture');
      expect(mode(copy.parent), '700', reason: 'others can enter its folder');
      await _closeTabs(tester);
    },
  );

  // #14: a desktop's terminal can use a font the machine has, not only the
  // five the app bundles — listed from the machine itself, monospaced ones
  // marked, used by name. Menlo on a Mac, which every Mac has; on Linux the
  // first monospaced family fontconfig lists that the app does not bundle.
  testWidgets(
    "the terminal takes a font installed on the machine",
    skip: Platform.isWindows,
    (tester) async {
      final bundled = terminalFonts.map((font) => font.family).toSet();
      final String family;
      if (Platform.isMacOS) {
        family = 'Menlo';
      } else {
        final listed = await Process.run('fc-list', [':spacing=mono', 'family']);
        final mono =
            LineSplitter.split('${listed.stdout}')
                .map((line) => line.split(',').first.trim())
                .where((name) => name.isNotEmpty && !bundled.contains(name))
                .toList()
              ..sort();
        // DejaVu Sans Mono where it is there, which on Ubuntu it is.
        family = mono.contains('DejaVu Sans Mono')
            ? 'DejaVu Sans Mono'
            : mono.first;
      }

      await _launch(tester);
      await _settings(tester);
      // Not findRichText: that would match the Text.rich and the RichText it
      // draws with, twice over.
      final row = find.textContaining('Installed on this computer');
      await tester.scrollUntilVisible(
        row,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await _until(
        tester,
        () => find.textContaining('families, monospaced first').evaluate().isNotEmpty,
        "this computer's fonts to be listed",
      );
      // Built is not on screen: a list builds a little past its edge.
      await tester.ensureVisible(row);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(row);
      await _until(
        tester,
        () => find.bySemanticsLabel('Installed fonts').evaluate().isNotEmpty,
        'the font picker',
      );
      // Settings' own fields are behind the dialog.
      final picker = find.byType(TuiDialog);
      await tester.enterText(
        find.descendant(of: picker, matching: find.byType(TextField)),
        family,
      );
      await tester.pump(const Duration(milliseconds: 300));
      final entry = find.descendant(
        of: picker,
        matching: find.widgetWithText(InkWell, family),
      );
      expect(
        find.descendant(of: entry, matching: find.text('monospaced')),
        findsOneWidget,
        reason: '$family is not marked monospaced',
      );
      await tester.tap(entry);
      await _until(
        tester,
        () => find.textContaining('on this computer').evaluate().isNotEmpty,
        'Settings to show the font chosen',
      );

      // The picker closing still holds a barrier over the page, which takes
      // a tap on Back as its own.
      await tester.pump(const Duration(milliseconds: 600));
      await _backHome(tester);
      final view = await _localShell(tester);
      expect(
        view.textStyle.fontFamily,
        family,
        reason: 'the terminal does not draw in the font chosen',
      );
      await _closeTabs(tester);
    },
  );

  // #8, the desktop updater, as far as it goes before anything is replaced: a
  // newer release is offered, downloaded, and kept only when its SHA-256 is
  // the feed's — Restart to update is offered then — while a download whose
  // hash is not is refused and deleted. Restart itself would swap the running
  // bundle, so it is not pressed.
  //
  // Only in a build made for it: the host, the version and a feed on this
  // machine are baked in with --dart-define, which e2e.yml's Linux job
  // passes, and a download lands in the user's Downloads — a runner's, then,
  // not a machine someone uses.
  testWidgets(
    'an update is kept only when its hash is the release\'s',
    skip: updateHost.isEmpty,
    (tester) async {
      final build = utf8.encode('not a real build, only bytes to be checked');
      const name = 'jeansh-e2e-update.tar.gz';
      // Where the app puts it: Downloads, or the home where there is none.
      final kept = File('${downloadsFolder().path}/$name');
      addTearDown(() {
        if (kept.existsSync()) kept.deleteSync();
      });
      var digest = '${sha256.convert(build)}';
      // Launched first: the app looks for an update itself as it starts,
      // and that one should find nothing to offer over this test.
      await _launch(tester);
      final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        Uri.parse(updateHost).port,
      );
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        final response = request.response;
        switch (request.uri.path) {
          case '/latest.json':
            response.write(
              jsonEncode({
                'version': '9.9.9',
                'build': 999,
                'platforms': {
                  updatePlatform: {
                    'path': 'desktop/$updatePlatform/$name',
                    'size': build.length,
                    'sha256': digest,
                  },
                },
              }),
            );
          case final path when path.endsWith('/$name'):
            response.add(build);
          default:
            response.statusCode = HttpStatus.notFound;
        }
        unawaited(response.close());
      });

      // Asked from Settings, opening it first when it is not open.
      final check = find.bySemanticsLabel('Check for updates');
      Future<void> askSettings() async {
        if (check.evaluate().isEmpty) {
          await _settings(tester);
          await tester.scrollUntilVisible(
            check,
            300,
            scrollable: find.byType(Scrollable).first,
          );
        }
        await tester.ensureVisible(check);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(check);
      }

      // The app's own look at startup can reach this feed too, if it asked
      // after the feed came up, and offer the release by itself: that offer is
      // as good as the one Settings gives, so a moment is given for it and it
      // is taken if it comes.
      final offer = find.text('Jeansh 9.9.9 is out');
      final end = DateTime.now().add(const Duration(seconds: 3));
      while (offer.evaluate().isEmpty && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
      if (offer.evaluate().isEmpty) await askSettings();
      await _pick(tester, 'Download');
      await _until(
        tester,
        () => find.bySemanticsLabel('Restart to update').evaluate().isNotEmpty,
        'the download to be checked and offered to install',
      );
      expect(find.text('Jeansh 9.9.9 is ready'), findsOneWidget);
      expect(kept.readAsBytesSync(), build);
      await _pick(tester, 'Later');
      kept.deleteSync();

      // A build whose hash is not the release's: refused, and nothing kept.
      digest = '0' * 64;
      await tester.pump(const Duration(milliseconds: 600));
      await askSettings();
      await _pick(tester, 'Download');
      await _until(
        tester,
        () =>
            find.textContaining('is not the file the release describes')
                .evaluate()
                .isNotEmpty,
        'a download of the wrong file to be refused',
      );
      expect(find.bySemanticsLabel('Restart to update'), findsNothing);
      expect(kept.existsSync(), isFalse, reason: 'the wrong file was kept');
      expect(File('${kept.path}.part').existsSync(), isFalse);
    },
  );

  // #20: Settings' Open links with picks the key a click holds to open a link
  // in the terminal — Ctrl or Alt on Linux — and only that key opens one.
  // Picked Alt here: an Alt+click on a link a program printed hands it to the
  // machine's browser, and a Ctrl+click opens nothing.
  //
  // The browser is this desktop's own stand-in: a handler for http and https,
  // put in the run's data folder, that notes each address it is given. On CI
  // alone — on a machine someone uses, their own browser choice, which the
  // desktop reads first, would open a real window instead.
  testWidgets(
    'a link opens with the key Settings names, and not the other',
    skip: !Platform.isLinux || Platform.environment['CI'] != 'true',
    (tester) async {
      final data = Platform.environment['XDG_DATA_HOME']!;
      final opened = File('$data/e2e-opened-links');
      final browser = File('$data/e2e-browser')
        ..writeAsStringSync(
          '#!/bin/sh\nprintf "%s\\n" "\$1" >> \'${opened.path}\'\n',
        );
      Process.runSync('chmod', ['755', browser.path]);
      Directory('$data/applications').createSync(recursive: true);
      File('$data/applications/e2e-browser.desktop').writeAsStringSync(
        '[Desktop Entry]\nType=Application\nName=e2e browser\nNoDisplay=true\n'
        'Exec=${browser.path} %u\n'
        'MimeType=x-scheme-handler/http;x-scheme-handler/https;\n',
      );
      File('$data/applications/mimeapps.list').writeAsStringSync(
        '[Default Applications]\n'
        'x-scheme-handler/http=e2e-browser.desktop\n'
        'x-scheme-handler/https=e2e-browser.desktop\n',
      );
      const url = 'https://example.invalid/e2e-link';

      await _launch(tester);
      await _settings(tester);
      final choice = find.byType(TuiSelect<LinkModifier>);
      await tester.scrollUntilVisible(
        choice,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(choice);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(
        find.descendant(of: choice, matching: find.bySemanticsLabel('Alt')),
      );
      await _until(
        tester,
        () => find.textContaining('Hold Alt and click').evaluate().isNotEmpty,
        'Settings to say Alt opens links',
      );
      await _backHome(tester);

      // A link as a program prints one, OSC 8: its label, its address hidden.
      final view = await _localShell(tester);
      final script = File('${_scratch().path}/link.sh')
        ..writeAsStringSync(
          "printf '\\033]8;;$url\\033\\\\open me\\033]8;;\\033\\\\\\n'\n",
        );
      _run(view, 'sh ${script.path}');
      final lines = view.terminal.buffer.lines;
      var row = -1;
      await _until(tester, () {
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].getText().startsWith('open me')) row = i;
        }
        return row >= 0;
      }, 'the link to be printed');
      final render = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal;
      final label = render.localToGlobal(
        render.getOffset(CellOffset(2, row)) +
            Offset(render.cellSize.width / 2, render.lineHeight / 2),
      );
      Future<void> clickWith(LogicalKeyboardKey key) async {
        await tester.sendKeyDownEvent(key);
        await tester.tapAt(label, kind: PointerDeviceKind.mouse);
        await tester.sendKeyUpEvent(key);
        await tester.pump(const Duration(milliseconds: 300));
      }

      // Not the key that was not picked.
      await clickWith(LogicalKeyboardKey.controlLeft);
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(opened.existsSync(), isFalse, reason: 'Ctrl+click opened it');

      await clickWith(LogicalKeyboardKey.altLeft);
      await _until(
        tester,
        () => opened.existsSync() && opened.readAsStringSync().contains(url),
        'Alt+click to hand the link to the browser',
      );
      await _closeTabs(tester);
    },
  );
}
