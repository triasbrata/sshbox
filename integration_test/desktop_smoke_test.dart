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
    show
        AlertDialog,
        Card,
        DropdownButton,
        InkWell,
        ListTile,
        PopupMenuDivider,
        SegmentedButton,
        SimpleDialogOption,
        TextField,
        Tooltip;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sshbox/main.dart' as app;
import 'package:sshbox/src/platform.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/update/updater.dart'
    show Updater, downloadsFolder, updateAvailable, updateHost, updatePlatform;
import 'package:sshbox/src/ui/git_diff_page.dart' show GitDiffPage;
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
  await tester.pumpAndSettle(const Duration(seconds: 5));
  // A fresh install shows the onboarding pager once before Home, where the
  // redesign has one; its Skip renders in capitals, so match any case. With
  // no pager, as on main before the redesign, this finds nothing.
  final skip = find.byWidgetPredicate(
    (w) => w is Text && w.data?.toLowerCase() == 'skip',
  );
  if (skip.evaluate().isNotEmpty) {
    await tester.tap(skip.first);
    await tester.pumpAndSettle(const Duration(seconds: 2));
  }
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
  await tester.tap(find.widgetWithText(Card, 'Local shell'));
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
  await tester.pageBack();
  await _until(
    tester,
    () => find.widgetWithText(Card, 'Local shell').evaluate().isNotEmpty,
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

/// A program in [view]'s shell that asks for bracketed paste, or turns it
/// off, and keeps every byte it reads until it is asked what it got: what a
/// paste or a drop really sends, which the prompt's own drawing of it hides.
Future<_Recording> _record(
  WidgetTester tester,
  TerminalView view, {
  required bool bracketed,
}) async {
  final dir = _scratch();
  final got = File('${dir.path}/got');
  final ready = File('${dir.path}/ready');
  final stop = File('${dir.path}/stop');
  final done = 'recorded-${dir.path.hashCode}';
  final script = File('${dir.path}/record.sh')
    ..writeAsStringSync(
      "printf '\\033[?2004${bracketed ? 'h' : 'l'}'\n"
      'stty raw -echo\n'
      'touch ${ready.path}\n'
      // From the terminal by name: a background job of a non-interactive sh
      // reads /dev/null otherwise.
      'dd bs=1 of=${got.path} </dev/tty 2>/dev/null &\n'
      'while [ ! -e ${stop.path} ]; do sleep 0.2; done\n'
      'kill \$! 2>/dev/null\n'
      'stty sane\n'
      "printf '\\033[?2004l'\n"
      'echo $done\n',
    );
  _run(view, 'sh ${script.path}');
  await _until(tester, ready.existsSync, 'the program to start reading');
  await tester.pump(const Duration(milliseconds: 300));
  return _Recording(tester, view, got, stop, done);
}

class _Recording {
  _Recording(this._tester, this._view, this._got, this._stop, this._done);

  final WidgetTester _tester;
  final TerminalView _view;
  final File _got;
  final File _stop;
  final String _done;

  /// What the program read, once [length] bytes are in or they have stopped
  /// coming for a second — so fewer than expected still reach the caller's
  /// comparison, which says what did come — and the program ended.
  Future<String> bytes(String what, {int? length}) async {
    var last = -1;
    var still = DateTime.now();
    await _until(_tester, () {
      final now = _got.existsSync() ? _got.lengthSync() : 0;
      if (length != null && now >= length) return true;
      if (now != last) {
        last = now;
        still = DateTime.now();
        return false;
      }
      return now > 0 &&
          DateTime.now().difference(still) > const Duration(seconds: 1);
    }, what);
    _stop.createSync();
    await _until(
      _tester,
      () => _text(_view).any((line) => line.contains(_done)),
      'the recording program to end',
    );
    return utf8.decode(_got.readAsBytesSync(), allowMalformed: true);
  }
}

/// xdotool, which drives this run's own Xvfb display as a person would.
Future<String> _xdo(List<String> args) async {
  final result = await Process.run('xdotool', args);
  expect(result.exitCode, 0, reason: 'xdotool $args: ${result.stderr}');
  return '${result.stdout}'.trim();
}

/// Jeansh's window on the display.
Future<String> _window() async => (await _xdo([
  'search',
  '--onlyvisible',
  '--name',
  r'^Jeansh$',
])).split('\n').first;

/// Escape as a keyboard sends it: on Linux a real key, through X and GTK to
/// the embedder, which is how a menu is shut. The test framework's own
/// simulated Escape left a popup menu open here even with the menu holding
/// the focus, so a menu's Escape is not checked with it.
Future<void> _escape(WidgetTester tester) async {
  if (Platform.isLinux) {
    await _xdo(['windowfocus', '--sync', await _window()]);
    await _xdo(['key', 'Escape']);
  } else {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  }
  await tester.pump(const Duration(milliseconds: 600));
}

/// A GTK window offering files for a drag, as a file manager does, put
/// below Jeansh's window, which fills the top 720 rows of the 1280x900
/// display tools/e2e_desktop.sh gives the run.
const _dragSource = r'''
import sys
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gdk, Gio, Gtk

uris = [Gio.File.new_for_path(p).get_uri() for p in sys.argv[1:]]
window = Gtk.Window(title='e2e drag source')
window.set_default_size(200, 100)
window.move(0, 760)
button = Gtk.Button(label='drag')
button.drag_source_set(Gdk.ModifierType.BUTTON1_MASK, [], Gdk.DragAction.COPY)
button.drag_source_add_uri_targets()
button.connect('drag-data-get', lambda w, c, data, i, t: data.set_uris(uris))
window.add(button)
window.connect('destroy', Gtk.main_quit)
window.show_all()
Gtk.main()
''';

/// Drags [path] from [_dragSource] onto the middle of Jeansh's window — the
/// terminal of the tab showing — with the X pointer, as a hand would.
Future<void> _drag(WidgetTester tester, String path, Directory dir) async {
  final source = File('${dir.path}/drag_source.py')
    ..writeAsStringSync(_dragSource);
  final process = await Process.start('python3', [source.path, path]);
  try {
    Future<void> xdo(List<String> args) async {
      final result = await Process.run('xdotool', args);
      expect(result.exitCode, 0, reason: 'xdotool $args: ${result.stderr}');
    }

    await xdo([
      'search',
      '--sync',
      '--onlyvisible',
      '--name',
      r'^e2e drag source$',
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await xdo(['mousemove', '100', '810']);
    await xdo(['mousedown', '1']);
    for (final (x, y) in [
      (110, 805),
      (130, 790),
      (300, 650),
      (500, 500),
      (640, 400),
      (645, 405),
    ]) {
      await xdo(['mousemove', '$x', '$y']);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await tester.pump();
    }
    await xdo(['mouseup', '1']);
    await tester.pump(const Duration(milliseconds: 500));
  } finally {
    process.kill();
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

  // #87: a right-click in a tab's page opens the tab's own menu there. In a
  // terminal its Paste comes first and the tab's items after a divider; a
  // program reading the mouse gets a plain right-click, and Shift keeps one
  // for the menu; and in a group the pane clicked takes focus and opens its
  // own menu, Take out of group among it.
  testWidgets(
    'a right-click in a terminal opens its tab\'s menu, unless a program '
    'reads the mouse',
    skip: Platform.isWindows, // Its Local shell is PowerShell, not sh.
    (tester) async {
      await _launch(tester);
      await _localShell(tester);
      final tabs = find.byWidgetPredicate(
        (w) =>
            w is Tooltip &&
            ((w.message ?? '').startsWith('Close ') ||
                w.message == 'Reconnect'),
      );
      final before = tabs.evaluate().length;

      // The terminals on screen: two in a group, one otherwise.
      List<TerminalView> shown() => find
          .byType(TerminalView)
          .evaluate()
          .map((element) => element.widget as TerminalView)
          .toList();
      TerminalView focused() =>
          shown().firstWhere((each) => each.focusNode?.hasFocus ?? false);
      // Found by its focus node, which the page keeps: the widget itself is
      // built anew as the shell draws.
      Future<void> rightClick(TerminalView view) => tester.tapAt(
        tester.getCenter(
          find.byWidgetPredicate(
            (w) => w is TerminalView && w.focusNode == view.focusNode,
          ),
        ),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      Future<void> menuWith(String item) async {
        await _until(
          tester,
          () => find.text(item).evaluate().isNotEmpty,
          'the menu to offer $item',
        );
        await tester.pump(const Duration(milliseconds: 600));
      }

      // Paste, a divider, then what the tab's chip offers.
      await rightClick(focused());
      await menuWith('Duplicate session');
      final paste = tester.getTopLeft(find.text('Paste')).dy;
      final divider = tester.getTopLeft(find.byType(PopupMenuDivider)).dy;
      final duplicate = tester.getTopLeft(find.text('Duplicate session')).dy;
      expect(
        paste < divider && divider < duplicate,
        isTrue,
        reason: 'Paste, a divider and the tab\'s items, in that order',
      );
      await tester.tap(find.text('Duplicate session'));
      await _until(
        tester,
        () => tabs.evaluate().length == before + 1,
        'a second Local shell',
      );

      // A program reading the mouse: a plain right-click reaches it as
      // xterm's ESC [ M, and no menu opens; Shift keeps the click for the
      // menu. It records what it reads until told to stop.
      final dir = _scratch();
      final got = File('${dir.path}/got');
      final ready = File('${dir.path}/ready');
      final stop = File('${dir.path}/stop');
      final script = File('${dir.path}/mouse.sh')
        ..writeAsStringSync(
          "printf '\\033[?1000h'\n"
          'stty raw -echo\n'
          'touch ${ready.path}\n'
          // From the terminal by name: a background job of a
          // non-interactive sh reads /dev/null otherwise.
          'dd bs=1 count=6 of=${got.path} </dev/tty 2>/dev/null &\n'
          'while [ ! -e ${stop.path} ]; do sleep 0.2; done\n'
          'kill \$! 2>/dev/null\n'
          'stty sane\n'
          "printf '\\033[?1000l'\n"
          'echo mouse-done\n',
        );
      final view = focused();
      _run(view, 'sh ${script.path}');
      try {
        await _until(tester, ready.existsSync, 'the program to read the mouse');
      } on TestFailure {
        debugPrint('The terminal holds:\n${_text(view).join('\n')}');
        rethrow;
      }
      await tester.pump(const Duration(milliseconds: 300));

      await rightClick(view);
      await _until(
        tester,
        () => got.existsSync() && got.lengthSync() >= 3,
        'the right-click to reach the program',
      );
      expect(got.readAsBytesSync().take(3), [0x1b, 0x5b, 0x4d]);
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        find.text('Duplicate session'),
        findsNothing,
        reason: 'a menu opened over a program that reads the mouse',
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await rightClick(view);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await menuWith('Duplicate session');
      // Escape shuts it. Found open on the Linux build (run 35782032581):
      // the menu's route held the focus, the Escape reached the app, and yet
      // the focus left for the page and the menu stayed.
      await _escape(tester);
      expect(
        find.text('Duplicate session'),
        findsNothing,
        reason: 'Escape did not close the terminal\'s menu',
      );

      stop.createSync();
      await _until(
        tester,
        () => _text(focused()).any((line) => line.contains('mouse-done')),
        'the program to finish',
      );

      // The two in a group: the pane that is not focused, right-clicked,
      // takes focus and opens its own menu.
      await rightClick(focused());
      await _pick(tester, 'Group with…');
      await _until(
        tester,
        () => find.byType(SimpleDialogOption).evaluate().isNotEmpty,
        'the tabs to group with',
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.byType(SimpleDialogOption).first);
      await _until(
        tester,
        () => shown().length == 2,
        'the two shells side by side',
      );
      final other = shown().firstWhere(
        (each) => !(each.focusNode?.hasFocus ?? false),
      );
      await rightClick(other);
      await menuWith('Take out of group');
      // The menu keeps the keys, so Escape closes it and the focus goes back
      // to the pane the click moved it to.
      await _escape(tester);
      expect(
        find.text('Take out of group'),
        findsNothing,
        reason: 'Escape did not close the menu: it did not hold the keys',
      );
      expect(
        other.focusNode?.hasFocus,
        isTrue,
        reason: 'the menu opened for a pane that did not take focus',
      );
      // And a menu opened on the pane, focused by now, stays open.
      await rightClick(other);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          find.text('Take out of group'),
          findsOneWidget,
          reason: 'the menu closed by itself ${(i + 1) * 100} ms after opening',
        );
      }
      await _escape(tester);

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

  // #67: a pasted picture's path goes in as a paste where the program asked
  // for bracketed paste, which is what Claude Code turns into [Image #N],
  // and typed where it did not: ESC[200~<path> ESC[201~, one space inside,
  // or <path> and a space.
  testWidgets(
    'a pasted picture\'s path is bracketed when the program asks for it',
    skip: !Platform.isLinux,
    (tester) async {
      final png = base64.decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAj'
        'CB0C8AAAAASUVORK5CYII=',
      );
      final picture = File('${_scratch().path}/picture.png')
        ..writeAsBytesSync(png);
      final put = await Process.run('sh', [
        '-c',
        r'xclip -selection clipboard -t image/png -i "$1" >/dev/null 2>&1',
        'sh',
        picture.path,
      ]);
      expect(put.exitCode, 0, reason: 'xclip could not take the picture');

      await _launch(tester);
      final view = await _localShell(tester);
      final pasted = RegExp(r'/\S*/pasted-\d{8}-\d{6}[^ \x1b]*\.png');
      for (final bracketed in [true, false]) {
        final got = await _record(tester, view, bracketed: bracketed);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        final bytes = await got.bytes('the pasted picture\'s path');
        final path = pasted.firstMatch(bytes)?.group(0);
        expect(path, isNotNull, reason: 'no picture path in ${jsonEncode(bytes)}');
        expect(
          bytes,
          bracketed ? '\x1b[200~$path \x1b[201~' : '$path ',
          reason: bracketed ? 'not sent as a paste' : 'not typed as it was',
        );
        expect(File(path!).readAsBytesSync(), png);
      }
      await _closeTabs(tester);
    },
  );

  // #67: a file dragged from the desktop onto a Local shell pastes its own
  // path, escaped as iTerm2 escapes one — a backslash before every character
  // a shell reads — bracketed where the program asked for it, typed with a
  // space where it did not. A folder, here on this machine, is pasted the
  // same way; only a shell elsewhere refuses one, being unable to upload it.
  //
  // The drag is a real X drag-and-drop: a small GTK window offers the file,
  // and xdotool presses on it, moves onto Jeansh's terminal and lets go.
  testWidgets(
    'a file or folder dropped on a Local shell pastes its escaped path',
    skip: !Platform.isLinux || Platform.environment['CI'] != 'true',
    (tester) async {
      final dir = _scratch();
      final file = File("${dir.path}/it's a shot (1).png")
        ..writeAsStringSync('png');
      final folder = Directory('${dir.path}/a folder')..createSync();
      String escaped(String path) => path.replaceAllMapped(
        RegExp(r'[^A-Za-z0-9._/-]'),
        (m) => '\\${m[0]}',
      );
      // Written out literally rather than through [escaped], so a change to
      // the rule the app and this test share cannot pass unnoticed.
      expect(escaped(file.path), endsWith(r"/it\'s\ a\ shot\ \(1\).png"));

      await _launch(tester);
      final view = await _localShell(tester);
      for (final (dropped, bracketed) in [
        (file.path, true),
        (folder.path, false),
      ]) {
        final got = await _record(tester, view, bracketed: bracketed);
        await _drag(tester, dropped, dir);
        final want = escaped(dropped);
        expect(
          await got.bytes('the dropped path', length: bracketed ? want.length + 13 : want.length + 1),
          bracketed ? '\x1b[200~$want \x1b[201~' : '$want ',
        );
      }
      expect(find.textContaining('cannot be uploaded'), findsNothing);
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
        () => find.text('Installed fonts').evaluate().isNotEmpty,
        'the font picker',
      );
      // Settings' own fields are behind the dialog.
      final picker = find.byType(AlertDialog);
      await tester.enterText(
        find.descendant(of: picker, matching: find.byType(TextField)),
        family,
      );
      await tester.pump(const Duration(milliseconds: 300));
      final entry = find.descendant(
        of: picker,
        matching: find.widgetWithText(ListTile, family),
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
      final check = find.text('Check for updates');
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
        () => find.text('Restart to update').evaluate().isNotEmpty,
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
      expect(find.text('Restart to update'), findsNothing);
      expect(kept.existsSync(), isFalse, reason: 'the wrong file was kept');
      expect(File('${kept.path}.part').existsSync(), isFalse);
    },
  );

  // #65: a newer release is said where the user will see it — the daily
  // check offers it, and once put off it stays marked on Home and in
  // Settings — and the window's own Help menu checks on demand, answering up
  // to date when it is, which clears the mark.
  //
  // The menu is GTK's, outside Flutter, so it is clicked as a person would:
  // xdotool on the window's menu bar under Xvfb. F10 and Alt+H are left to
  // the terminal on purpose, so the mouse is the way in.
  testWidgets(
    'Help checks for updates, and a newer release stays marked until a '
    'check finds none',
    skip: updateHost.isEmpty || !Platform.isLinux,
    (tester) async {
      // The build's own version, 1.0.0+1 in e2e.yml, is current; 9.9.8 is out.
      var latest = (version: '9.9.8', build: 998);
      final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        Uri.parse(updateHost).port,
      );
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        final response = request.response;
        if (request.uri.path == '/latest.json') {
          response.write(
            jsonEncode({
              'version': latest.version,
              'build': latest.build,
              'platforms': {
                updatePlatform: {
                  'path': 'desktop/$updatePlatform/jeansh.tar.gz',
                  'size': 1,
                  'sha256': '0' * 64,
                },
              },
            }),
          );
        } else {
          response.statusCode = HttpStatus.notFound;
        }
        unawaited(response.close());
      });

      // Today's check is due again, and nothing is marked yet: an earlier
      // test's check leaves both behind in this one process.
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(Updater.checkedKey);
      updateAvailable.value = null;

      await _launch(tester);
      await _until(
        tester,
        () => find.text('Jeansh 9.9.8 is out').evaluate().isNotEmpty,
        'the daily check to offer the newer release',
      );
      await _pick(tester, 'Not now');
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        find.text('Update 9.9.8'),
        findsOneWidget,
        reason: 'Home does not mark a release that was put off',
      );

      await _settings(tester);
      final available = find.text('Jeansh 9.9.8 is available');
      await tester.scrollUntilVisible(
        available,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(available, findsOneWidget);
      await _backHome(tester);

      // The menu bar's Help, then its one item.
      Future<void> helpCheck() async {
        await _xdo(['mousemove', '--window', await _window(), '20', '10']);
        await _xdo(['click', '1']);
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await _xdo(['key', 'Down', 'Return']);
      }

      await helpCheck();
      await _until(
        tester,
        () => find.text('Jeansh 9.9.8 is out').evaluate().isNotEmpty,
        'Help › Check for updates… to offer the newer release',
      );
      await _pick(tester, 'Not now');
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Update 9.9.8'), findsOneWidget);

      // Nothing newer any more: the menu says so, and the mark goes.
      latest = (version: '1.0.0', build: 1);
      await helpCheck();
      await _until(
        tester,
        () => find.text('Jeansh is up to date').evaluate().isNotEmpty,
        'Help › Check for updates… to say Jeansh is up to date',
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        find.text('Update 9.9.8'),
        findsNothing,
        reason: 'the mark outlived a check that found nothing newer',
      );
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
      final choice = find.byType(SegmentedButton<LinkModifier>);
      await tester.scrollUntilVisible(
        choice,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(choice);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(
        find.descendant(of: choice, matching: find.text('Alt')),
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
