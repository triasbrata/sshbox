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
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart'
    show DropdownButton, IconButton, Icons, InkWell, TextField, Tooltip;
import 'package:flutter/rendering.dart' show OffsetLayer;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sshbox/main.dart' as app;
import 'package:sshbox/src/chat/claude_chat.dart' show ChatNotice, ChatSaid;
import 'package:sshbox/src/files/local_file_browser.dart';
import 'package:sshbox/src/ui/chat_page.dart' show ChatPage;
import 'package:sshbox/src/files/transfers.dart'
    show Transfer, TransferState, transfers;
import 'package:sshbox/src/platform.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/update/updater.dart'
    show Updater, downloadsFolder, updateAvailable, updateHost, updatePlatform;
import 'package:sshbox/src/ui/file_download.dart'
    show downloadFile, openDownload;
import 'package:sshbox/src/ui/git_diff_page.dart' show GitDiffPage;
import 'package:sshbox/src/ui/mermaid_view.dart' show MermaidView;
import 'package:sshbox/src/ui/termul/tui_chat.dart' show TuiChatBubble;
import 'package:sshbox/src/ui/termul/tui_toast.dart' show TuiToastCard;
import 'package:sshbox/src/ui/termul/tui_dialog.dart' show TuiDialog;
import 'package:sshbox/src/ui/settings_page.dart'
    show SettingsPage, localTmux, maxFontSize, terminalFonts, terminalSettings;
import 'package:sshbox/src/ui/termul/tui_slider.dart' show TuiSlider;
import 'package:sshbox/src/ui/text_size.dart';
import 'package:xterm2/xterm.dart';

/// Where [_shot] writes, from `--dart-define=JEANSH_SHOTS=folder`; empty, as
/// on CI, writes nothing.
const _shots = String.fromEnvironment('JEANSH_SHOTS');

/// The window as drawn, as [name].png in [_shots], for a person to look at.
Future<void> _shot(WidgetTester tester, String name) async {
  if (_shots.isEmpty) return;
  await tester.pumpAndSettle();
  final view = tester.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  final image = await layer.toImage(Offset.zero & view.paintBounds.size);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  await Directory(_shots).create(recursive: true);
  await File('$_shots/$name.png').writeAsBytes(png!.buffer.asUint8List());
}

/// The stand-in Claude where the chat's finder looks, taken away after: see
/// the chat tests, which skip where this machine has a Claude of its own.
void _standInClaudeFor() {
  final home = Platform.environment['HOME']!;
  final standIn = File('$home/.local/bin/claude');
  final config = Directory('$home/.claude');
  final hadConfig = config.existsSync();
  final hadBin = standIn.parent.existsSync();
  standIn.parent.createSync(recursive: true);
  standIn.writeAsStringSync(_standInClaude);
  Process.runSync('chmod', ['755', standIn.path]);
  addTearDown(() {
    if (standIn.readAsStringSync() == _standInClaude) standIn.deleteSync();
    if (!hadBin) standIn.parent.deleteSync(recursive: true);
    // A chat that never started a session wrote nothing there.
    final ours = hadConfig
        ? Directory('${config.path}/projects/jeansh-e2e')
        : config;
    if (ours.existsSync()) ours.deleteSync(recursive: true);
  });
}

/// The chat's composer.
final _composer = find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.prefixText == '❯ ',
);

/// The stand-in's answer.
final _answer = find.textContaining(
  'Echo from the stand-in',
  findRichText: true,
);

/// A Local shell's chat opened, a message sent, and the stand-in's answer in.
Future<void> _chatAnswered(WidgetTester tester) async {
  await _localShell(tester);
  await tester.tap(find.byTooltip('Chat with Claude'));
  await _until(
    tester,
    () => _composer.evaluate().isNotEmpty,
    'the chat tab to open, its version check passed',
  );
  await tester.enterText(_composer, 'hello from the e2e');
  await tester.pump();
  await tester.tap(find.byTooltip('Send'));
  await _until(
    tester,
    () => _answer.evaluate().isNotEmpty,
    "the stand-in's answer in the chat",
    timeout: const Duration(seconds: 40),
  );
}

/// Home, from a cold start, settled.
///
/// A generous settle: this is a real app doing real work at launch — reading
/// preferences off disk, asking the keychain, starting notifications — not a
/// widget tree pumped in memory.
Future<void> _launch(WidgetTester tester) async {
  await app.main();
  // A fresh install opens on the redesign's first-run slides, which animate,
  // so nothing settles until they are skipped; main has none and opens on
  // Home. Waited for rather than settled, for either.
  final skip = _label('Skip');
  await _until(
    tester,
    () =>
        skip.evaluate().isNotEmpty ||
        find.byTooltip('Settings').evaluate().isNotEmpty,
    'Home, or the first-run slides',
  );
  if (skip.evaluate().isNotEmpty) await tester.tap(skip.first);
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
      debugPrint(
        'On screen: ${words<Text>((t) => t.data ?? t.textSpan?.toPlainText())}',
      );
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
  await tester.tap(_homeCard('Local shell'));
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
    for (final element
        in find.byType(TerminalView, skipOffstage: false).evaluate()) {
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

/// Text reading [text] in any case: the redesign's buttons draw their labels
/// in capitals, and main's as written.
Finder _label(String text) => find.byWidgetPredicate(
  (w) =>
      w is Text &&
      (w.data ?? w.textSpan?.toPlainText())?.toLowerCase() ==
          text.toLowerCase(),
);

/// Widgets whose type is named one of [names], generics and all: main's
/// Material widget beside the redesign's termul one, found by name so this
/// file builds on both.
Finder _kind(String a, String b) => find.byWidgetPredicate((w) {
  final type = '${w.runtimeType}';
  return type == a || type == b;
});

/// Home's own card or row for [title], not a tab of the same name: a Card on
/// main, a HomeRow in the redesign.
Finder _homeCard(String title) =>
    find.ancestor(of: find.text(title), matching: _kind('Card', 'HomeRow'));

/// Picks [item] from a menu once it has finished opening. A menu grows open,
/// and its items are built before they can be hit: tapped as soon as one is
/// built, the tap can land on the barrier beside a clipped item, which shuts
/// the menu and does nothing — a test that passed or failed on the machine's
/// speed.
Future<void> _pick(WidgetTester tester, String item) async {
  await _until(
    tester,
    () => _label(item).evaluate().isNotEmpty,
    'the menu to offer $item',
  );
  await tester.pump(const Duration(milliseconds: 600));
  // A pane's menu is taller than a small window, and scrolls.
  await tester.ensureVisible(_label(item));
  await tester.pump();
  await tester.tap(_label(item));
}

/// Settings, opened from Home and slid all the way in. Scrolled sooner, a
/// drag lands on what Home still shows beneath it — its tab strip is a list
/// too, and first in the tree.
Future<void> _settings(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Settings'));
  // Waited for, not assumed after a fixed time: on 22.04's runner Settings
  // was not on screen yet 600 ms after the tap.
  await _until(
    tester,
    () =>
        find.text('LOOK · TERMINAL · KEYBOARD · PRIVACY').evaluate().isNotEmpty,
    'Settings to open',
  );
  await tester.pump(const Duration(milliseconds: 600));
}

/// Back from Settings to Home, and Settings all the way gone. Home's card is
/// found while Settings is still sliding out over it, and a tap on it then
/// lands on the page leaving — a Mac run opened no shell that way.
Future<void> _backHome(WidgetTester tester) async {
  // An AppBar's BackButton on main, its tooltip Back; the redesign's ← BACK,
  // which has no tooltip and is named Back for accessibility instead.
  final material = find.byTooltip('Back');
  await tester.tap(
    material.evaluate().isNotEmpty
        ? material.last
        : find.bySemanticsLabel('Back').last,
  );
  await _until(
    tester,
    () => _homeCard('Local shell').evaluate().isNotEmpty,
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
  bool mouse = false,
}) async {
  final dir = _scratch();
  final got = File('${dir.path}/got');
  final ready = File('${dir.path}/ready');
  final stop = File('${dir.path}/stop');
  final done = 'recorded-${dir.path.hashCode}';
  final script = File('${dir.path}/record.sh')
    ..writeAsStringSync(
      "printf '\\033[?2004${bracketed ? 'h' : 'l'}'\n"
      // Every mouse mode, in SGR, as Claude Code's fullscreen view asks.
      "${mouse ? r"printf '\033[?1000h\033[?1002h\033[?1003h\033[?1006h'" : ':'}\n"
      'stty raw -echo\n'
      'touch ${ready.path}\n'
      // From the terminal by name: a background job of a non-interactive sh
      // reads /dev/null otherwise.
      'dd bs=1 of=${got.path} </dev/tty 2>/dev/null &\n'
      'while [ ! -e ${stop.path} ]; do sleep 0.2; done\n'
      'kill \$! 2>/dev/null\n'
      'stty sane\n'
      "printf '\\033[?1006l\\033[?1003l\\033[?1002l\\033[?1000l\\033[?2004l'\n"
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
Future<String> _window() async =>
    (await _xdo(['search', '--onlyvisible', '--name', r'^Jeansh$']))
        .split('\n')
        .first;

/// Escape as a keyboard sends it: on Linux a real key, through X and GTK to
/// the embedder, which is how a menu is shut.
///
/// A menu it shuts is gone only once its closing animation has run, and this
/// binding draws a frame only when pumped: one pump after the key is the
/// animation's first tick, the menu still fully drawn. So a check that it
/// closed waits for it with [_until], as the one after this does — a single
/// pump read an open menu that had already been popped (run 35782032581).
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

/// Drags [path], and [more] with it, from [_dragSource] onto the middle of
/// Jeansh's window — the terminal of the tab showing — with the X pointer,
/// as a hand would.
Future<void> _drag(
  WidgetTester tester,
  String path,
  Directory dir, {
  List<String> more = const [],
}) async {
  final source = File('${dir.path}/drag_source.py')
    ..writeAsStringSync(_dragSource);
  final process = await Process.start('python3', [source.path, path, ...more]);
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

/// Opens the Git panel from a Local shell and picks [repo] in it.
///
/// On a runner the home holds this repository alone and it is picked
/// already; on a machine with others it is picked from the list.
Future<void> _gitPanelOn(WidgetTester tester, Directory repo) async {
  await tester.tap(find.byTooltip('Git'));
  final name = repo.path.split('/').last;
  bool ours(String? root) => root != null && root.endsWith('/$name');
  // Material's DropdownButton on main, the redesign's TuiDropdown: both
  // hold a value, an onChanged and choices that each have a value.
  final picker = _kind('DropdownButton<String>', 'TuiDropdown<String>');
  dynamic shown() => tester.widget(picker.first);
  Iterable<String?> choices() => [
    for (final dynamic item
        in shown() is DropdownButton
            ? shown().items as List
            : shown().options as List)
      item.value as String?,
  ];
  await _until(
    tester,
    () => picker.evaluate().isNotEmpty && choices().any(ours),
    "the Git panel to find this test's repository",
  );
  if (!ours(shown().value as String?)) {
    // Picked through the picker's own onChanged, which is what choosing it
    // from the list calls: a long list in a small menu is its own fight.
    final root = choices().firstWhere(ours);
    shown().onChanged!(root);
    await _until(
      tester,
      () => ours(shown().value as String?),
      "this test's repository to be picked",
    );
  }
}

/// testWidgets, with a skip that says why in the log: flutter test prints only
/// a skipped test's name, and a skip is no coverage, so it has to be read as
/// one.
void _test(String name, WidgetTesterCallback body, {String? skip}) {
  if (skip != null) {
    debugPrint('Skipped on ${Platform.operatingSystem}: $name: $skip');
  }
  testWidgets(name, body, skip: skip != null);
}

const _powershell =
    'its Local shell is PowerShell under ConPTY, which '
    'redraws what a program writes, and this test drives sh';

/// Why a picture-paste test skips here, or null where it runs.
final _pictureSkip = Platform.isWindows
    ? 'a picture pasted into PowerShell goes through %TEMP%, which this test '
          'does not check'
    : Platform.isMacOS && Platform.environment['CI'] != 'true'
    ? "off CI a Mac's pasteboard is its user's own"
    : null;

/// Check for updates… as a person picks it: on Linux and Windows from Help,
/// the ⋯ the app draws beside the window's buttons, the title bar and its
/// menu bar being gone; on macOS from the Jeansh menu, through System
/// Events, the menu being outside Flutter.
Future<void> _menuCheckForUpdates(WidgetTester tester) async {
  if (!Platform.isMacOS) {
    await tester.tap(_named('Help'));
    await _pick(tester, 'Check for updates…');
    return;
  }
  final done = await Process.run('osascript', [
    '-e',
    'tell application "System Events" to tell process "Jeansh"',
    '-e',
    'set frontmost to true',
    '-e',
    'click menu item "Check for Updates…" of menu 1 of menu bar item 2 '
        'of menu bar 1',
    '-e',
    'end tell',
  ]);
  expect(done.exitCode, 0, reason: 'the Jeansh menu: ${done.stderr}');
}

/// [body] with the real pointer reaching the app, given back however it
/// ends: left on after a failure, it fails every test after this one.
Future<void> _realPointer(Future<void> Function() body) async {
  final binding = IntegrationTestWidgetsFlutterBinding.instance;
  binding.shouldPropagateDevicePointerEvents = true;
  try {
    await body();
  } finally {
    binding.shouldPropagateDevicePointerEvents = false;
  }
}

/// [body], and on a failure what reached the app of the keys and the
/// buttons meanwhile: whether a real key arrived at all.
Future<void> _hearing(Future<void> Function() body) async {
  final heard = <String>[];
  bool key(KeyEvent event) {
    heard.add('${event.runtimeType} ${event.logicalKey.debugName}');
    return false;
  }

  void pointer(PointerEvent event) {
    if (event is PointerDownEvent || event is PointerUpEvent) {
      heard.add(
        '${event.runtimeType} buttons ${event.buttons}, keys held '
        '${HardwareKeyboard.instance.logicalKeysPressed}',
      );
    }
  }

  HardwareKeyboard.instance.addHandler(key);
  GestureBinding.instance.pointerRouter.addGlobalRoute(pointer);
  try {
    await body();
  } on TestFailure {
    debugPrint('What the app heard:\n${heard.join('\n')}');
    rethrow;
  } finally {
    HardwareKeyboard.instance.removeHandler(key);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(pointer);
  }
}

/// Two fingers on a Mac's trackpad, pushing the content down over [at], a
/// global position in this window: the phased scroll events a trackpad
/// makes — began, changed a step at a time, ended — posted through
/// CoreGraphics at the HID tap, as the hardware's would be, with the pointer
/// moved over this window first; the Cocoa embedder turns them into a pan as
/// it does a real one. (Posted to the pid instead, none arrived.) The window
/// is found by this process's pid; its content
/// fills its bottom, under whatever title bar there is.
Future<void> _trackpad(WidgetTester tester, Offset at) async {
  final dir = Directory.systemTemp.createTempSync('jeansh-e2e-');
  try {
    final script = File('${dir.path}/trackpad.swift')
      ..writeAsStringSync(_trackpadScript);
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    var done = false;
    // What reached the app, for a failure to say whether the pan arrived.
    final seen = <String>[];
    void hear(PointerEvent event) => seen.add('${event.runtimeType}');
    GestureBinding.instance.pointerRouter.addGlobalRoute(hear);
    final run = Process.run('swift', [
      script.path, '$pid', '${at.dx}', '${at.dy}', '${size.height}', //
    ]).whenComplete(() => done = true);
    // Pumped while it runs, so the pan is drawn as it comes.
    while (!done) {
      await tester.pump(const Duration(milliseconds: 16));
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    final ran = await run;
    expect(ran.exitCode, 0, reason: 'the trackpad: ${ran.stderr}${ran.stdout}');
    await tester.pump(const Duration(seconds: 1));
    GestureBinding.instance.pointerRouter.removeGlobalRoute(hear);
    debugPrint(
      'The trackpad posted ${'${ran.stdout}'.trim()}; '
      'the app heard ${seen.toSet()} (${seen.length} events)',
    );
  } finally {
    dir.deleteSync(recursive: true);
  }
}

const _trackpadScript = r"""
import AppKit
import ApplicationServices
import CoreGraphics

let args = CommandLine.arguments
let pid = pid_t(args[1])!
let x = Double(args[2])!, y = Double(args[3])!, viewHeight = Double(args[4])!

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
  as! [[String: Any]]
guard let window = windows.first(where: {
  ($0[kCGWindowOwnerPID as String] as? pid_t) == pid
    && ($0[kCGWindowLayer as String] as? Int) == 0
}) else { print("no window for \(pid)"); exit(1) }
let bounds = CGRect(
  dictionaryRepresentation: window[kCGWindowBounds as String] as! CFDictionary)!
let at = CGPoint(x: bounds.minX + x, y: bounds.maxY - viewHeight + y)
print("at \(at) in \(bounds), trusted \(AXIsProcessTrusted())")

NSRunningApplication(processIdentifier: pid)?.activate()
usleep(300_000)
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: at,
        mouseButton: .left)!.post(tap: .cghidEventTap)
usleep(100_000)

func scroll(_ dy: Int32, _ phase: Int64) {
  let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                  wheel1: dy, wheel2: 0, wheel3: 0)!
  e.location = at
  e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
  e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
  e.post(tap: .cghidEventTap)
  usleep(16_000)
}
// kCGScrollPhaseBegan, Changed, Ended.
scroll(0, 1)
for _ in 0..<40 { scroll(4, 2) }
scroll(0, 4)
""";

/// A widget by the name it gives a screen reader, with no semantics tree
/// asked for: the window's buttons have no text or tooltip to find them by.
Finder _named(String label) => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.label == label,
);

/// Where the window's content is on the screen. Linux through xwininfo, not
/// xdotool's geometry, which counts a window manager's title bar twice once
/// the window sits in its frame; Windows through [_winMouse] with nothing to
/// do.
Future<Rect> _windowRect() async {
  if (Platform.isWindows) return (await _winMouse(const [])).rect;
  final info = await Process.run('xwininfo', ['-id', await _window()]);
  double value(String key) => double.parse(
    RegExp('$key:\\s+(-?\\d+)').firstMatch('${info.stdout}')!.group(1)!,
  );
  return Rect.fromLTWH(
    value('Absolute upper-left X'),
    value('Absolute upper-left Y'),
    value('Width'),
    value('Height'),
  );
}

/// The real pointer on Windows, moved and pressed as a hand would: each
/// step `move x y` in the client area's physical pixels, `moveby dx dy` on
/// the screen, `down`, `up`, `restore` (the window, from minimized) or
/// `sleep ms`. Answers where the window is then, and whether it is
/// maximized or minimized, read off Win32 itself.
Future<({Rect rect, bool zoomed, bool iconic})> _winMouse(
  List<String> steps,
) async {
  final dir = Directory.systemTemp.createTempSync('jeansh-e2e-');
  try {
    final script = File('${dir.path}\\mouse.ps1')
      ..writeAsStringSync(_winMouseScript);
    final done = await Process.run('powershell', [
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script.path, //
      steps.join(';'),
    ]);
    expect(done.exitCode, 0, reason: 'the mouse: ${done.stderr}${done.stdout}');
    final [l, t, r, b, zoomed, iconic] = '${done.stdout}'.trim().split(' ');
    return (
      rect: Rect.fromLTRB(
        double.parse(l),
        double.parse(t),
        double.parse(r),
        double.parse(b),
      ),
      zoomed: zoomed == 'True',
      iconic: iconic == 'True',
    );
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// The real pointer, moved and pressed as a hand would, over this window:
/// each step `move x y` to a point in the app (logical pixels, as a finder
/// gives them), `down`, `up` (the primary button), `rdown`, `rup` (the
/// secondary, #132's), `sleep ms`, or
/// `shiftdown` and `shiftup` (Linux and macOS only), or `cmdc`, ⌘ held, C
/// typed and ⌘ let go as three key events (macOS only). On Linux
/// through xdotool on this run's Xvfb, on Windows through [_winMouse], on a
/// Mac through CoreGraphics at the HID tap, as [_trackpad] posts its pan.
/// Not pumped while it goes: the app takes the pointer on its own, and a
/// check failing inside a pump would be lost to it.
Future<void> _osMouse(WidgetTester tester, List<String> steps) async {
  final ratio = tester.view.devicePixelRatio;
  final Future<Object?> run;
  if (Platform.isWindows) {
    run = _winMouse([
      for (final step in steps)
        if (step.split(' ') case ['move', final x, final y])
          'move ${(double.parse(x) * ratio).round()} '
              '${(double.parse(y) * ratio).round()}'
        else
          step,
    ]);
  } else if (Platform.isLinux) {
    final window = await _windowRect();
    final frame = (window.width - tester.view.physicalSize.width) / 2;
    final origin = window.topLeft + Offset(frame, frame);
    // Keys go to the focused window, which Xvfb with no window manager
    // gives nobody: as _escape does.
    await _xdo(['windowfocus', '--sync', await _window()]);
    run = _xdo([
      for (final step in steps)
        ...switch (step.split(' ')) {
          ['move', final x, final y] => [
            'mousemove',
            '${(origin.dx + double.parse(x) * ratio).round()}',
            '${(origin.dy + double.parse(y) * ratio).round()}',
          ],
          ['down'] => ['mousedown', '1'],
          ['rdown'] => ['mousedown', '3'],
          ['rup'] => ['mouseup', '3'],
          ['shiftdown'] => ['keydown', 'Shift_L'],
          ['shiftup'] => ['keyup', 'Shift_L'],
          ['up'] => ['mouseup', '1'],
          ['sleep', final ms] => ['sleep', '${int.parse(ms) / 1000}'],
          _ => throw ArgumentError(step),
        },
    ]);
  } else {
    final dir = Directory.systemTemp.createTempSync('jeansh-e2e-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final script = File('${dir.path}/mouse.swift')
      ..writeAsStringSync(_macMouseScript);
    final size = tester.view.physicalSize / ratio;
    // Frontmost, for its keys: the pointer reaches the window under it
    // anyway, but keys go to the active app, and a Mac will not let the
    // script's own activate() take that from another app.
    final front = await Process.run('osascript', [
      '-e',
      'tell application "System Events" to set frontmost of '
          '(first process whose unix id is $pid) to true',
    ]);
    expect(front.exitCode, 0, reason: 'frontmost: ${front.stderr}');
    run =
        Process.run('swift', [
          script.path, '$pid', '${size.height}', steps.join(';'), //
        ]).then((ran) {
          expect(
            ran.exitCode,
            0,
            reason: 'the mouse: ${ran.stderr}${ran.stdout}',
          );
          debugPrint('The mouse said: ${ran.stdout}');
          return ran;
        });
  }
  await run;
  await tester.pump(const Duration(milliseconds: 300));
}

const _macMouseScript = r"""
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let pid = pid_t(args[1])!
let viewHeight = Double(args[2])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
  as! [[String: Any]]
guard let window = windows.first(where: {
  ($0[kCGWindowOwnerPID as String] as? pid_t) == pid
    && ($0[kCGWindowLayer as String] as? Int) == 0
}) else { print("no window for \(pid)"); exit(1) }
let bounds = CGRect(
  dictionaryRepresentation: window[kCGWindowBounds as String] as! CFDictionary)!
NSRunningApplication(processIdentifier: pid)?.activate()
usleep(300_000)

var at = CGPoint(x: bounds.midX, y: bounds.midY)
var pressed = false
var flags: CGEventFlags = []
func post(_ type: CGEventType, _ button: CGMouseButton = .left) {
  let e = CGEvent(mouseEventSource: nil, mouseType: type,
                  mouseCursorPosition: at, mouseButton: button)!
  e.flags = flags
  e.post(tap: .cghidEventTap)
  usleep(10_000)
}
// Keys from the HID system's own source, so a modifier pressed changes the
// state the window server stamps on every event after it: from no source,
// its flags were put back to the real keyboard's, which holds nothing.
let keys = CGEventSource(stateID: .hidSystemState)
// Each flag with the bit naming its left key, as a keyboard sets it
// (NX_DEVICELSHIFTKEYMASK, NX_DEVICELCMDKEYMASK): Flutter tells a modifier's
// press from its release by that bit, and without it heard neither.
let shiftLeft = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x2)
let commandLeft =
  CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x8)
func modifier(_ key: CGKeyCode, _ mask: CGEventFlags, _ down: Bool) {
  flags = down ? mask : []
  let e = CGEvent(keyboardEventSource: keys, virtualKey: key, keyDown: down)!
  e.flags = flags
  e.post(tap: .cghidEventTap)
  usleep(150_000)
  print("after \(key) \(down ? "down" : "up"): hid "
    + "\(CGEventSource.flagsState(.hidSystemState).rawValue), session "
    + "\(CGEventSource.flagsState(.combinedSessionState).rawValue)")
}
for step in args[3].split(separator: ";") {
  let p = step.split(separator: " ")
  switch p[0] {
  case "move":
    at = CGPoint(x: bounds.minX + Double(p[1])!,
                 y: bounds.maxY - viewHeight + Double(p[2])!)
    post(pressed ? .leftMouseDragged : .mouseMoved)
  case "down": pressed = true; post(.leftMouseDown)
  case "up": pressed = false; post(.leftMouseUp)
  case "rdown": post(.rightMouseDown, .right)
  case "rup": post(.rightMouseUp, .right)
  case "shiftdown": modifier(56, shiftLeft, true)
  case "cmdc":
    modifier(55, commandLeft, true)
    for down in [true, false] {
      let e = CGEvent(keyboardEventSource: keys, virtualKey: 8, keyDown: down)!
      e.flags = commandLeft
      e.post(tap: .cghidEventTap)
      usleep(150_000)
    }
    modifier(55, commandLeft, false)
  case "shiftup": modifier(56, shiftLeft, false)
  case "sleep": usleep(useconds_t(Int(p[1])! * 1000))
  default: print("unknown step \(step)"); exit(1)
  }
}
""";

/// A right-click with the real pointer at [local], a point in the app, sent
/// through the OS as a hand sends it, by [_osMouse].
///
/// [shift] holds Shift down around it, as a hand does: Windows has no test
/// that asks for it.
///
/// Wants the binding's shouldPropagateDevicePointerEvents on, or the
/// integration binding drops what the device sends.
Future<void> _realRightClick(
  WidgetTester tester,
  Offset local, {
  bool shift = false,
}) async {
  assert(!shift || !Platform.isWindows, 'no Shift on Windows here');
  await _osMouse(tester, [
    'move ${local.dx} ${local.dy}',
    if (shift) ...['shiftdown', 'sleep 100'],
    'rdown',
    'sleep 40',
    'rup',
    if (shift) ...['sleep 100', 'shiftup'],
  ]);
}

const _winMouseScript = r'''
param([string]$steps)
$ErrorActionPreference = 'Stop'
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class W {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string c, string n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
[W]::SetProcessDPIAware() | Out-Null
$h = [W]::FindWindow('FLUTTER_RUNNER_WIN32_WINDOW', 'Jeansh')
if ($h -eq [IntPtr]::Zero) { throw 'no Jeansh window' }
if ($steps) {
  [W]::SetForegroundWindow($h) | Out-Null
  foreach ($step in $steps.Split(';')) {
    $p = $step.Split(' ')
    switch ($p[0]) {
      'move' {
        $pt = New-Object W+POINT
        $pt.X = [int]$p[1]; $pt.Y = [int]$p[2]
        [W]::ClientToScreen($h, [ref]$pt) | Out-Null
        [W]::SetCursorPos($pt.X, $pt.Y) | Out-Null
        [W]::mouse_event(1, 0, 0, 0, [UIntPtr]::Zero)
      }
      'moveby' {
        $pt = New-Object W+POINT
        [W]::GetCursorPos([ref]$pt) | Out-Null
        [W]::SetCursorPos($pt.X + [int]$p[1], $pt.Y + [int]$p[2]) | Out-Null
        [W]::mouse_event(1, 0, 0, 0, [UIntPtr]::Zero)
      }
      'restore' { [W]::ShowWindow($h, 9) | Out-Null }
      'down' { [W]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero) }
      'up' { [W]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero) }
      'rdown' { [W]::mouse_event(8, 0, 0, 0, [UIntPtr]::Zero) }
      'rup' { [W]::mouse_event(16, 0, 0, 0, [UIntPtr]::Zero) }
      'sleep' { Start-Sleep -Milliseconds ([int]$p[1]) }
    }
  }
  Start-Sleep -Milliseconds 500
}
$r = New-Object W+RECT
[W]::GetWindowRect($h, [ref]$r) | Out-Null
"$($r.L) $($r.T) $($r.R) $($r.B) $([W]::IsZoomed($h)) $([W]::IsIconic($h))"
''';

/// [png] on the machine's clipboard as a picture: xclip on Linux's X11,
/// AppleScript's PNG class on macOS.
Future<void> _putPicture(String png) async {
  final put = Platform.isMacOS
      ? await Process.run('osascript', [
          '-e', 'on run argv', //
          '-e', 'set the clipboard to (read (POSIX file (item 1 of argv)) as «class PNGf»)',
          '-e', 'end run',
          png,
        ])
      // xclip stays behind to hand the picture over, so it is given nothing
      // of ours to hold open, or this would wait for it.
      : await Process.run('sh', [
          '-c',
          r'xclip -selection clipboard -t image/png -i "$1" >/dev/null 2>&1',
          'sh',
          png,
        ]);
  expect(
    put.exitCode,
    0,
    reason: 'the clipboard would not take the picture: ${put.stderr}',
  );
}

/// The paste chord: ⌘V on a Mac, Ctrl+V elsewhere.
Future<void> _paste(WidgetTester tester) async {
  final key = Platform.isMacOS
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
  await tester.sendKeyUpEvent(key);
}

/// Whether chat's finder would find a Claude Code on this machine: on PATH,
/// where its installers put it, or on the login shell's PATH.
bool _claudeInstalled() {
  final home = Platform.environment['HOME'] ?? '';
  for (final path in [
    '$home/.local/bin/claude',
    '$home/.claude/local/claude',
    '$home/.bun/bin/claude',
    '/opt/homebrew/bin/claude',
    '/usr/local/bin/claude',
  ]) {
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) {
      return true;
    }
  }
  final found = Process.runSync('/bin/sh', [
    '-c',
    'command -v claude || "\${SHELL:-/bin/sh}" -lc "command -v claude" '
        '</dev/null',
  ]);
  return '${found.stdout}'.trim().isNotEmpty;
}

/// A stand-in for Claude Code, as much of it as a new chat goes through: its
/// version, `--bg` starting a session whose transcript holds one answer,
/// `agents --json` listing it, and a `-p` that answers each message after.
const _standInClaude = r'''#!/bin/sh
# Jeansh e2e stand-in for Claude Code.
d="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
sid=0e2e0000-0000-4000-8000-00000000c0de
t="$d/projects/jeansh-e2e/$sid.jsonl"
# Thirty diagrams after it (#131): a long reply's worth, past the 27 a Mac
# preview once drew as one grey area.
fences=''
i=1
while [ $i -le 30 ]; do
  fences="$fences\\n\\n\`\`\`mermaid\\ngraph LR\\n  E2E$i --> Done$i\\n\`\`\`"
  i=$((i + 1))
done
answer='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Echo from the stand-in'"$fences"'"}]}}'
case "$1" in
  --version) echo "2.1.300 (Claude Code)" ;;
  --bg)
    mkdir -p "$d/projects/jeansh-e2e"
    # The message, the last argument, as the session's first turn.
    for last; do :; done
    python3 -c 'import json, sys
print(json.dumps({"type": "user", "message": {"role": "user", "content": sys.argv[1]}}))' \
      "$last" >"$t"
    printf '%s\n' "$answer" >>"$t"
    echo "backgrounded · e2e0c0de · e2e" ;;
  agents)
    if [ -f "$t" ]; then
      printf '[{"id":"e2e0c0de","sessionId":"%s","name":"e2e","cwd":"%s","kind":"background","state":"done","startedAt":1}]\n' "$sid" "$HOME"
    else
      echo '[]'
    fi ;;
  -p)
    printf '{"type":"system","subtype":"init","session_id":"%s"}\n' "$sid"
    while IFS= read -r line; do
      printf '%s\n' "$answer" '{"type":"result","subtype":"success"}'
    done ;;
esac
''';

/// The X display as it is now, as [name].png in E2E_SHOTS, for a person to
/// look at on CI: evidence, never checked. Nothing where E2E_SHOTS is unset.
/// Beside [_shot], which renders the layer and settles first, and so stays
/// off on CI.
Future<void> _grab(WidgetTester tester, String name) async {
  final dir = Platform.environment['E2E_SHOTS'];
  final display = Platform.environment['DISPLAY'];
  if (dir == null || dir.isEmpty || display == null) return;
  Directory(dir).createSync(recursive: true);
  // This binding draws only when pumped, and X shows a frame a moment after
  // it is drawn: without this the grab was a frame or two behind.
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  await Process.run('ffmpeg', [
    '-loglevel', 'error', '-y', '-f', 'x11grab', '-draw_mouse', '0', //
    '-i', display, '-frames:v', '1', '$dir/$name.png',
  ]);
}


/// Answers the desktop's save dialog as a person would, once it is up: saves
/// to [path], or cancels it when [path] is null. A Mac's panel saves where it
/// opens, so [path] there only says to save. Done outside Flutter, which the
/// dialog is too, and waited on outside the test's own pumping.
Future<ProcessResult> _answerSaveDialog(String? path) {
  if (Platform.isMacOS) {
    final key = path == null ? 'key code 53' : 'keystroke return';
    return Process.run('osascript', [
      '-e',
      'tell application "System Events" to tell process "Jeansh"',
      '-e',
      'set frontmost to true',
      '-e',
      'repeat 120 times',
      '-e',
      'repeat with w in windows',
      '-e',
      'if exists sheet 1 of w then',
      '-e',
      'delay 1',
      '-e',
      key,
      '-e',
      'return "answered"',
      '-e',
      'end if',
      '-e',
      'end repeat',
      '-e',
      'delay 0.5',
      '-e',
      'end repeat',
      '-e',
      'error "no save sheet, windows: " & (name of every window as text)',
      '-e',
      'end tell',
    ]);
  }
  if (Platform.isLinux) {
    // Focused rather than activated: Xvfb has no window manager to ask.
    // Return in a call of its own: xdotool's type takes every word after it
    // as text to type.
    const dialog =
        r'timeout 60 xdotool search --sync --name "^Save File$" '
        r'windowfocus --sync %1 sleep 1';
    return Process.run('sh', [
      '-c',
      path == null
          ? '$dialog && xdotool key Escape'
          : '$dialog key ctrl+a type "\$1" && xdotool key Return',
      if (path != null) ...['sh', path],
    ]);
  }

  // SendKeys reads +^%~(){}[] as keys of its own: each goes in braces.
  final keys = path == null
      ? '{ESC}'
      : '${path.replaceAllMapped(RegExp(r'[+^%~(){}\[\]]'), (m) => '{${m[0]}}')}'
            '{ENTER}';
  return Process.run('powershell', [
    '-NoProfile',
    '-Command',
    r"$ws = New-Object -ComObject WScript.Shell; "
        r"for ($i = 0; $i -lt 120; $i++) { "
        r"if ($ws.AppActivate('Save As')) { break }; "
        r"Start-Sleep -Milliseconds 500 }; "
        r"if ($i -eq 120) { throw 'no Save As window' }; "
        r"Start-Sleep -Milliseconds 1000; "
        "\$ws.SendKeys('${keys.replaceAll("'", "''")}')",
  ]);
}

/// Readies this desktop to see a text file opened, and hands back what waits
/// for it: on Linux a stand-in handler for text/plain in the run's own data
/// folder, which notes what it is given; on a Mac TextEdit, and on Windows
/// Notepad, each closed once seen. CI only, as the test is.
Future<Future<void> Function(String path)> _opener() async {
  if (Platform.isLinux) {
    final data = Platform.environment['XDG_DATA_HOME']!;
    final noted = File('$data/e2e-opened-files');
    final opener = File('$data/e2e-opener')
      ..writeAsStringSync(
        '#!/bin/sh\nprintf "%s\\n" "\$1" >> \'${noted.path}\'\n',
      );
    Process.runSync('chmod', ['755', opener.path]);
    Directory('$data/applications').createSync(recursive: true);
    File('$data/applications/e2e-opener.desktop').writeAsStringSync(
      '[Desktop Entry]\nType=Application\nName=e2e opener\nNoDisplay=true\n'
      'Exec=${opener.path} %f\n'
      'MimeType=text/plain;x-scheme-handler/file;\n',
    );
    // Added to, not written over: the link test keeps its browser here.
    final apps = File('$data/applications/mimeapps.list');
    apps.writeAsStringSync(
      '${apps.existsSync() ? apps.readAsStringSync() : '[Default Applications]\n'}'
      // The file scheme too: GIO asks a scheme's handler before the file's
      // type, and a desktop may have one, as WSL's wslview is.
      'text/plain=e2e-opener.desktop\n'
      'x-scheme-handler/file=e2e-opener.desktop\n',
    );
    return (path) async {
      final end = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(end)) {
        if (noted.existsSync() && noted.readAsStringSync().contains(path)) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      fail('nothing opened $path');
    };
  }
  final (name, look, kill) = Platform.isMacOS
      ? ('TextEdit', ['pgrep', '-x', 'TextEdit'], ['pkill', '-x', 'TextEdit'])
      : (
          'Notepad',
          ['tasklist', '/FI', 'IMAGENAME eq notepad.exe', '/NH'],
          ['taskkill', '/IM', 'notepad.exe', '/F'],
        );
  return (path) async {
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(end)) {
      final seen = await Process.run(look.first, look.skip(1).toList());
      final up = Platform.isMacOS
          ? seen.exitCode == 0
          : '${seen.stdout}'.toLowerCase().contains('notepad.exe');
      if (up) {
        await Process.run(kill.first, kill.skip(1).toList());
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    fail('$name never opened $path');
  };
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  _test('it is a real desktop, not a faked one', (tester) async {
    // No override anywhere: this is what the embedder really reports. If this
    // ever passes under `flutter test` the suite is not running where it
    // claims to be.
    expect(
      defaultTargetPlatform,
      anyOf(TargetPlatform.linux, TargetPlatform.windows, TargetPlatform.macOS),
    );
    expect(isDesktop, isTrue);
  });

  // Issue #133: the UI text size at its largest, set as a person sets it, by
  // a drag on Settings' own slider, and the app still usable on the real
  // embedder: Settings to its end, Home, and a Local shell whose terminal
  // keeps the columns and rows it had. Any overflow on the way fails it.
  _test('the UI text size at its largest leaves Home, Settings and a '
      'terminal usable, the terminal at its own size', (tester) async {
    addTearDown(() => uiTextSize.choose(1));
    await uiTextSize.choose(1);
    await _launch(tester);
    await _shot(tester, 'desktop-home-default');
    final before = await _localShell(tester);
    final columns = before.terminal.viewWidth;
    final rows = before.terminal.viewHeight;
    await _shot(tester, 'desktop-terminal-default');
    await _closeTabs(tester);

    await _settings(tester);
    await _shot(tester, 'desktop-settings-default');
    // Settings' own list: Home's tab strip under it is a list too.
    final page = find
        .descendant(
          of: find.byType(SettingsPage),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      _label('UI text size'),
      300,
      scrollable: page,
    );
    await tester.scrollUntilVisible(
      find.byType(TuiSlider).first,
      100,
      scrollable: page,
    );
    final slider = find.byType(TuiSlider).first;
    await tester.pumpAndSettle();
    await tester.drag(slider, const Offset(3000, 0));
    await tester.pumpAndSettle();
    expect(uiTextSize.value, UiTextSize.max);
    expect(find.text('160%'), findsOneWidget);
    await _shot(tester, 'desktop-settings-largest');

    // Settings to its end at that size.
    await tester.scrollUntilVisible(_label('About'), 300, scrollable: page);
    await tester.pumpAndSettle();
    await _backHome(tester);
    expect(
      MediaQuery.textScalerOf(tester.element(find.byTooltip('Settings')))
          .scale(13),
      closeTo(13 * UiTextSize.max, 0.01),
    );
    await _shot(tester, 'desktop-home-largest');

    final after = await _localShell(tester);
    expect(
      MediaQuery.textScalerOf(tester.element(find.byWidget(after))).scale(13),
      13,
      reason: 'a terminal takes the content size alone',
    );
    expect(after.terminal.viewWidth, columns);
    expect(after.terminal.viewHeight, rows);
    await _shot(tester, 'desktop-terminal-largest');
    await _closeTabs(tester);
  });

  _test('the app boots and draws Home', (tester) async {
    await _launch(tester);

    // If a plugin threw on the way up — secure storage with no Secret Service,
    // notifications, app_links — this is where it shows, as nothing drawn.
    expect(_label('Jeansh'), findsWidgets);
    expect(find.text('Terminal buddy in your pocket'), findsOneWidget);
  });

  _test('a desktop offers a shell on the machine itself', (tester) async {
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

  _test('Settings offers updates, and says so honestly when it cannot', (
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
      _label('Check for updates'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    // Desktop only: Android updates through Play, so this section is not built
    // there at all.
    expect(_label('Updates'), findsOneWidget);
    expect(_label('Check for updates'), findsOneWidget);

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
  _test(
    'a program in the shell cannot read the clipboard back',
    skip: Platform.isWindows ? _powershell : null,
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
  _test(
    'a mouse selection copies what the line reads, a drawn gap as a space',
    skip: Platform.isWindows ? _powershell : null,
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
      // Every toast gone first: toasts sit over every menu, and on Windows
      // and Linux, below the window's buttons, one covers the menu's Copy.
      // A moment first, for a toast the click itself brings up.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      await _until(
        tester,
        () => find.byType(TuiToastCard).evaluate().isEmpty,
        'the toasts to go',
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

  // #131: a terminal selection holding Mermaid is shown as a diagram, where
  // a web view draws one — the Mac — from the right-click menu, and not
  // offered at all where none does.
  _test(
    'a selection holding Mermaid is shown as a diagram',
    skip: Platform.isWindows ? _powershell : null,
    (tester) async {
      await _launch(tester);
      final view = await _localShell(tester);
      final script = File('${_scratch().path}/diagram.sh')
        ..writeAsStringSync(
          "printf '  \\140\\140\\140mermaid\\n  graph TD\\n    A --> B\\n"
          "  \\140\\140\\140\\n'\n",
        );
      _run(view, 'sh ${script.path}');

      final lines = view.terminal.buffer.lines;
      var open = -1;
      await _until(tester, () {
        for (var i = 0; i + 3 < lines.length; i++) {
          if (lines[i].getText().trim() == '```mermaid' &&
              lines[i + 3].getText().trim() == '```') {
            open = i;
          }
        }
        return open >= 0;
      }, 'the mermaid block to be drawn');

      final render = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal;
      Offset cell(int col, int row) => render.localToGlobal(
        render.getOffset(CellOffset(col, row)) +
            Offset(render.cellSize.width / 2, render.lineHeight / 2),
      );
      final mouse = await tester.startGesture(
        cell(0, open),
        kind: PointerDeviceKind.mouse,
      );
      for (final (col, row) in [(6, open + 1), (10, open + 2), (5, open + 3)]) {
        await mouse.moveTo(cell(col, row));
        await tester.pump();
      }
      await mouse.up();
      await tester.pump(const Duration(milliseconds: 300));
      await _until(
        tester,
        () => find.byType(TuiToastCard).evaluate().isEmpty,
        'the toasts to go',
      );
      await tester.tapAt(
        cell(4, open + 1),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await _until(
        tester,
        () => _label('Copy').evaluate().isNotEmpty,
        'the menu to open',
      );
      if (!hasWebView) {
        expect(_label('Show as diagram'), findsNothing);
        await _escape(tester);
      } else {
        await _pick(tester, 'Show as diagram');
        await _until(
          tester,
          () => find.byType(MermaidView).evaluate().isNotEmpty,
          'the diagram dialog',
        );
        expect(
          tester.widget<MermaidView>(find.byType(MermaidView)).source,
          'graph TD\n  A --> B\n',
        );
        await _until(
          tester,
          () => find
              .descendant(
                of: find.byType(MermaidView),
                matching: find.byIcon(Icons.account_tree_outlined),
              )
              .evaluate()
              .isEmpty,
          'the diagram to be drawn',
          timeout: const Duration(seconds: 30),
        );
        await tester.tap(_label('Close'));
        await tester.pump(const Duration(milliseconds: 600));
      }
      await _closeTabs(tester);
    },
  );

  // #9 and the tab half of #11. Duplicate session on a Local shell's tab
  // opened nothing and said "That host is no longer saved": openHost looked
  // every id up among the saved hosts, and `local` never is one. A mouse has
  // no long press, so on a desktop the tab's menu is a right-click away.
  _test('a right-click on a Local shell tab duplicates it', (tester) async {
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
          ((w.message ?? '').startsWith('Close ') || w.message == 'Reconnect'),
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
  });

  // #87 and #132: a right-click in a tab's page opens the tab's own menu
  // there, in a terminal iTerm2's pane menu with the tab's items in it. It
  // opens even over a program reading the mouse, which hears nothing of it;
  // Shift+right-click is the program's. In a group the pane clicked takes
  // focus and opens its own menu, Take out of group among it.
  _test(
    'a right-click in a terminal opens its menu, even over a program that '
    'reads the mouse, and Shift+right-click reaches the program',
    skip: Platform.isWindows ? _powershell : null,
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

      // #132: the same click as the OS sends it, Shift and all.
      final binding = IntegrationTestWidgetsFlutterBinding.instance;
      binding.shouldPropagateDevicePointerEvents = true;
      // A failure here must not leave it on for the next test.
      addTearDown(() => binding.shouldPropagateDevicePointerEvents = false);
      Future<void> realClick(TerminalView view, {bool shift = false}) =>
          _realRightClick(
            tester,
            tester.getCenter(
              find.byWidgetPredicate(
                (w) => w is TerminalView && w.focusNode == view.focusNode,
              ),
            ),
            shift: shift,
          );

      // iTerm2's pane menu, in its order: New tab first, the clipboard,
      // then the session's own.
      await realClick(focused());
      await menuWith('Paste');
      final newTab = tester.getTopLeft(find.text('New tab…')).dy;
      final paste = tester.getTopLeft(find.text('Paste')).dy;
      final duplicate = tester.getTopLeft(find.text('Duplicate session')).dy;
      expect(
        newTab < paste && paste < duplicate,
        isTrue,
        reason: 'New tab…, Paste and Duplicate session, in that order',
      );
      await _pick(tester, 'Duplicate session');
      await _until(
        tester,
        () => tabs.evaluate().length == before + 1,
        'a second Local shell',
      );

      // A program reading the mouse: a plain right-click still opens the
      // menu and the program hears nothing of it; Shift+right-click is the
      // program's, reaching it as xterm's ESC [ M. It records what it reads
      // until told to stop.
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

      await realClick(view);
      await menuWith('Paste');
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        got.existsSync() ? got.readAsBytesSync() : const <int>[],
        isEmpty,
        reason: 'the program heard the right-click that opened the menu',
      );
      // Escape shuts it, and the focus goes back to the terminal.
      await _escape(tester);
      await _until(
        tester,
        () => find.text('Paste').evaluate().isEmpty,
        'Escape to close the terminal\'s menu',
      );

      await realClick(view, shift: true);
      await _until(
        tester,
        () => got.existsSync() && got.lengthSync() >= 3,
        'Shift+right-click to reach the program',
      );
      expect(got.readAsBytesSync().take(4), [0x1b, 0x5b, 0x4d, 0x22]);
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        find.text('Paste'),
        findsNothing,
        reason: 'a menu opened for a Shift+right-click meant for the program',
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
      await _pick(tester, 'Move into a group…');
      await _until(
        tester,
        () =>
            _kind('SimpleDialogOption', 'TuiSheetOption').evaluate().isNotEmpty,
        'the tabs to group with',
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(_kind('SimpleDialogOption', 'TuiSheetOption').first);
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
      await _until(
        tester,
        () => find.text('Take out of group').evaluate().isEmpty,
        'Escape to close the menu: it did not hold the keys',
      );
      // Given back as the menu's route finishes going, which on a slow
      // runner is after its items are gone: waited for, and a focus that
      // never comes back is named.
      try {
        await _until(
          tester,
          () => other.focusNode?.hasFocus ?? false,
          'the focus to come back to the pane the menu opened for',
          timeout: const Duration(seconds: 5),
        );
      } on TestFailure {
        debugPrint('Focus is on ${FocusManager.instance.primaryFocus}');
        rethrow;
      }
      // And a menu opened on the pane, focused by now, stays open: counted
      // from when it is on screen, which on a slow runner is past the first
      // 100 ms — showMenuAt waits out a frame, and the route builds in the
      // next one.
      await rightClick(other);
      await _until(
        tester,
        () => find.text('Take out of group').evaluate().isNotEmpty,
        'the focused pane\'s menu to open',
      );
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
      // In the body: the binding checks it is back before any tear-down runs.
      binding.shouldPropagateDevicePointerEvents = false;
    },
  );

  // #3: a diff opens split on a wide page, as GitHub's does — old on the
  // left, new on the right, a changed line level with the line that replaced
  // it; a narrow one stacks them. This window is past the 900 dp where split
  // begins, so the check is that the two sit on one row, side by side.
  _test(
    'a diff on a wide page opens split, the old line beside the new',
    skip: Platform.isWindows
        ? 'the repository is made under HOME for a POSIX login shell to find; '
              'a Windows Local shell is PowerShell, with no HOME'
        : null,
    (tester) async {
      // Where a Local shell's Git panel looks: the login home, a folder or
      // two down. Made for this test and gone after it.
      final repo = Directory(Platform.environment['HOME']!)
          .createTempSync('jeansh-e2e-repo-');
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
      await _gitPanelOn(tester, repo);
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
        expect(
          find.byTooltip('Unified view'),
          findsOneWidget,
          reason: 'a wide page did not open split',
        );
        expect(
          old.dy,
          closeTo(now.dy, 1),
          reason: 'the changed line is not level with what replaced it',
        );
        expect(
          old.dx,
          lessThan(now.dx),
          reason: 'the old line is not on the left',
        );
      } else {
        expect(
          find.byTooltip('Split view'),
          findsOneWidget,
          reason: 'a narrow page did not open unified',
        );
        expect(
          old.dy,
          lessThan(now.dy),
          reason: 'the old line is not above the new',
        );
      }
      await _closeTabs(tester);
    },
  );

  // #128: the Git panel switches branch, from the branch in its header,
  // after a dialog naming both, and the header follows — the files on disk
  // with it.
  _test(
    'the Git panel switches branch from its header, and the header follows',
    skip: Platform.isWindows
        ? 'the repository is made under HOME for a POSIX login shell to find; '
              'a Windows Local shell is PowerShell, with no HOME'
        : null,
    (tester) async {
      final repo = Directory(Platform.environment['HOME']!)
          .createTempSync('jeansh-e2e-repo-');
      addTearDown(() => repo.deleteSync(recursive: true));
      Future<String> git(List<String> args) async {
        final done = await Process.run('git', ['-C', repo.path, ...args]);
        expect(done.exitCode, 0, reason: '${done.stderr}');
        return '${done.stdout}'.trim();
      }

      await git(['init', '-q']);
      await git([
        '-c', 'user.name=e2e', '-c', 'user.email=e2e@example.invalid', //
        'commit', '-q', '--allow-empty', '-m', 'e2e',
      ]);
      await git(['branch', 'e2e-other']);
      final first = await git(['rev-parse', '--abbrev-ref', 'HEAD']);

      await _launch(tester);
      await _localShell(tester);
      await _gitPanelOn(tester, repo);
      await _until(
        tester,
        () => find.byTooltip('Switch branch').evaluate().isNotEmpty,
        'the branch in the header',
      );
      expect(find.text(first), findsWidgets);
      // Every toast gone first: toasts sit over every menu, and the header's
      // opens at the top of the window, where they are.
      await _until(
        tester,
        () => find.byType(TuiToastCard).evaluate().isEmpty,
        'the toasts to go',
      );
      await tester.tap(find.byTooltip('Switch branch'));
      // Waited out, as every menu here is: a tap while it slides in is lost.
      await _pick(tester, 'Switch to e2e-other');
      await _until(
        tester,
        () =>
            find.text('Switch from $first to e2e-other?').evaluate().isNotEmpty,
        'the dialog naming both branches',
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(
        find.descendant(
          of: find.byType(TuiDialog),
          matching: find.bySemanticsLabel('Switch'),
        ),
      );
      await _until(
        tester,
        () => find.text('e2e-other').evaluate().isNotEmpty,
        'the header to name the branch switched to',
      );
      expect(
        await git(['rev-parse', '--abbrev-ref', 'HEAD']),
        'e2e-other',
        reason: 'the header changed but the checkout did not',
      );
      await _closeTabs(tester);
    },
  );

  // #127: a Local shell's files drawer reads this machine's own disk, rooted
  // at the login home, as a host's reads it over SFTP.
  _test(
    "a Local shell's files drawer shows what is in the home",
    skip: Platform.isWindows
        ? 'a Windows Local shell is PowerShell, whose Windows paths the tree '
              'does not hold'
        : null,
    (tester) async {
      // A digit first, so it sorts ahead of every other folder in a home
      // with many and is drawn without a scroll.
      final dir = Directory(Platform.environment['HOME']!)
          .createTempSync('0-jeansh-e2e-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final name = 'made-by-the-e2e-${dir.path.hashCode}.txt';
      File('${dir.path}/$name').writeAsStringSync('hello from the e2e\n');

      await _launch(tester);
      await _localShell(tester);
      await tester.tap(find.byTooltip('Browse files'));
      final folder = find.text(dir.path.split('/').last);
      await _until(
        tester,
        () => folder.evaluate().isNotEmpty,
        "the drawer to list the test's folder in the home",
      );
      await tester.tap(folder);
      await _until(
        tester,
        () => find.text(name).evaluate().isNotEmpty,
        "the drawer to show the test's file in it",
      );
      await _closeTabs(tester);
    },
  );

  // #136: Download saves through the desktop's own save dialog, and Open
  // opens what it saved. file_picker's save failed on every desktop: on a Mac
  // refused for a sandbox entitlement this unsandboxed app lacks, on Linux
  // the XDG portal or nothing. The dialog is outside Flutter, so it is
  // answered as a person would: System Events' keys on a Mac, xdotool on
  // Linux, SendKeys on Windows.
  //
  // On a Mac and Linux from a Local shell's files drawer. A Windows Local
  // shell is PowerShell, whose drawer the tree cannot hold, so there the
  // drawer's own downloadFile is called over the same LocalFileBrowser.
  _test(
    'Download saves through the save dialog, Open opens it, a cancel leaves '
    'nothing',
    skip: Platform.environment['CI'] != 'true'
        ? "off CI the save dialog and the app Open starts are the user's own"
        : null,
    (tester) async {
      // Linux, when tools/e2e_desktop.sh is asked for a bus with no XDG
      // portal: none offered or running before the save or after it, the
      // case file_picker, the portal or nothing, could not save in at all.
      Future<void> noPortal(String when) async {
        if (!Platform.isLinux) return;
        if (Platform.environment['JEANSH_E2E_NO_PORTAL'] == null) return;
        for (final method in ['ListNames', 'ListActivatableNames']) {
          final names = await Process.run('dbus-send', [
            '--session',
            '--print-reply',
            '--dest=org.freedesktop.DBus',
            '/org/freedesktop/DBus',
            'org.freedesktop.DBus.$method',
          ]);
          expect(names.exitCode, 0, reason: 'dbus-send: ${names.stderr}');
          expect(
            '${names.stdout}',
            isNot(contains('portal')),
            reason: '$method names an XDG portal $when',
          );
        }
      }

      await noPortal('before the save');
      final dir = Directory(
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE']!,
      ).createTempSync('0-jeansh-e2e-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final name = 'download-by-the-e2e-${dir.path.hashCode}.txt';
      const body = 'saved through the dialog\n';
      final source = File('${dir.path}/$name')..writeAsStringSync(body);
      // Where Linux and Windows are told to save; a Mac saves where its
      // panel opens, read back from the transfer.
      final out = _scratch();
      final target = '${out.path}${Platform.pathSeparator}$name';

      // Before the launch, so the desktop's own idea of who opens text is
      // read with the stand-in already in it.
      final opened = await _opener();
      await _launch(tester);
      Future<void> download() async {
        if (Platform.isWindows) {
          final context = tester.element(find.byTooltip('Settings'));
          unawaited(
            downloadFile(
              context,
              LocalFileBrowser(
                process: (command) => Process.start('cmd', ['/c', command]),
                windows: true,
              ),
              source.path.replaceAll(r'\', '/'),
              host: 'Local shell',
              onTransfer: (_) {},
            ),
          );
          return;
        }
        final file = find.text(name);
        if (file.evaluate().isEmpty) {
          await _localShell(tester);
          await tester.tap(find.byTooltip('Browse files'));
          final folder = find.text(dir.path.split('/').last);
          await _until(
            tester,
            () => folder.evaluate().isNotEmpty,
            "the drawer to list the test's folder in the home",
          );
          // The drawer slides in: tapped while it does, the folder is still
          // off the window's edge and the tap lands nowhere.
          await tester.pump(const Duration(milliseconds: 600));
          await tester.tap(folder);
          await _until(
            tester,
            () => file.evaluate().isNotEmpty,
            "the drawer to show the test's file in it",
          );
        }
        await tester.tapAt(
          tester.getCenter(file),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await _pick(tester, 'Download');
      }

      // Downloads, answers the dialog by [save] or cancelling it, and hands
      // back the transfer once it has ended.
      Future<Transfer> run({required bool save}) async {
        final before = transfers.items.length;
        await download();
        ProcessResult? answer;
        unawaited(
          _answerSaveDialog(save ? target : null).then((r) => answer = r),
        );
        Transfer? transfer() {
          final mine = transfers.items
              .take(transfers.items.length - before)
              .where((t) => t.name == name);
          return mine.isEmpty ? null : mine.first;
        }

        await _until(
          tester,
          () =>
              (transfer() != null &&
                  transfer()!.state != TransferState.running) ||
              (answer != null && answer!.exitCode != 0),
          'the download to end',
          timeout: const Duration(seconds: 90),
        );
        // A download that failed says why first: the dialog it never showed
        // is only the consequence.
        final ended = transfer();
        if (ended != null && ended.state == TransferState.failed) {
          fail('the download failed: ${ended.error}');
        }
        await _until(tester, () => answer != null, 'the dialog answered');
        expect(
          answer!.exitCode,
          0,
          reason: 'the save dialog: ${answer!.stdout} ${answer!.stderr}',
        );
        return transfer()!;
      }

      final saved = await run(save: true);
      expect(
        saved.state,
        TransferState.done,
        reason: 'the download did not save: ${saved.error}',
      );
      final kept = File(Uri.parse(saved.saved!).toFilePath());
      addTearDown(() {
        if (kept.existsSync()) kept.deleteSync();
      });
      // The same file, not the same spelling: Windows' temp folder may be
      // named by its 8.3 short name, RUNNER~1 for runneradmin.
      if (!Platform.isMacOS) {
        expect(FileSystemEntity.identicalSync(kept.path, target), isTrue);
      }
      expect(kept.readAsStringSync(), body);
      await noPortal('after the save');
      // Marked as from the internet, as Windows reads it, so a host's .bat
      // or .exe is not run unwarned.
      if (Platform.isWindows) {
        final zone = await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          r'Get-Content -LiteralPath $env:JEANSH_SAVED -Stream Zone.Identifier',
        ], environment: {'JEANSH_SAVED': kept.path});
        expect(zone.stdout, contains('ZoneId=3'), reason: '${zone.stderr}');
      }

      // Open: the file handed to whatever this desktop opens text with.
      expect(await openDownload(saved.saved!, name), isTrue);
      await opened(kept.path);

      // Cancelled: nothing saved, and the transfer says so.
      kept.deleteSync();
      final cancelled = await run(save: false);
      expect(cancelled.state, TransferState.cancelled);
      expect(kept.existsSync(), isFalse, reason: 'a cancel saved the file');
      await tester.pump(const Duration(seconds: 2));
      await _closeTabs(tester);
    },
  );

  // #127: chat in a Local shell runs Claude beside it as a process, found and
  // quoted as over an exec channel. Never this machine's own Claude: a
  // stand-in is put where the finder looks only where none is installed —
  // a runner — and taken away after.
  _test(
    'chat in a Local shell starts a session and shows its answer',
    skip: Platform.isWindows
        ? 'a Windows Local shell is PowerShell, with no sh for Claude'
        : _claudeInstalled()
        ? 'this machine has a Claude Code of its own, which this would run'
        : null,
    (tester) async {
      _standInClaudeFor();
      await _launch(tester);
      await _chatAnswered(tester);
      await _closeTabs(tester);
    },
  );

  // Issue #133: "di chat size fontnya tidak mengikuti dari size font yang ada
  // di settings". The content size raised with Settings' own slider, and a
  // chat's answer and composer drawn at it.
  _test(
    'chat draws at the content size Settings sets',
    skip: Platform.isWindows
        ? 'a Windows Local shell is PowerShell, with no sh for Claude'
        : _claudeInstalled()
        ? 'this machine has a Claude Code of its own, which this would run'
        : null,
    (tester) async {
      _standInClaudeFor();
      addTearDown(() => terminalSettings.choose(size: 13));
      await terminalSettings.choose(size: 13);
      await _launch(tester);

      await _settings(tester);
      final page = find
          .descendant(
            of: find.byType(SettingsPage),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        _label('Content text size'),
        300,
        scrollable: page,
      );
      await tester.scrollUntilVisible(
        find.byType(TuiSlider).last,
        100,
        scrollable: page,
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(TuiSlider).last, const Offset(3000, 0));
      await tester.pumpAndSettle();
      expect(terminalSettings.value.fontSize, maxFontSize);
      await _backHome(tester);

      await _chatAnswered(tester);
      await _shot(tester, 'desktop-chat-content-largest');
      double at13(Finder finder) =>
          MediaQuery.textScalerOf(tester.element(finder.first)).scale(13);
      expect(at13(_answer), closeTo(maxFontSize, 0.01), reason: 'the answer');
      expect(
        at13(_composer),
        closeTo(maxFontSize, 0.01),
        reason: 'the composer',
      );

      // #131: its mermaid fences are diagrams where a web view draws them,
      // the Mac, and their source as code where none does.
      final diagrams = find.byType(MermaidView);
      if (!hasWebView) {
        expect(diagrams, findsNothing);
        expect(
          find.textContaining('E2E1 --> Done1', findRichText: true),
          findsWidgets,
        );
      } else {
        // Drawn: the placeholder a view shows until the page says its height.
        Finder waiting() => find.descendant(
          of: diagrams,
          matching: find.byIcon(Icons.account_tree_outlined),
        );
        expect(diagrams, findsWidgets);
        expect(
          find.textContaining('E2E1 --> Done1', findRichText: true),
          findsNothing,
          reason: 'a diagram shown as its source',
        );
        await _until(
          tester,
          () => waiting().evaluate().length < diagrams.evaluate().length,
          'a diagram in the reply to be drawn',
          timeout: const Duration(seconds: 60),
        );
        // Given the time, how many of those built came to be drawn, and none
        // as the grey of a widget that threw.
        await tester.pump(const Duration(seconds: 5));
        debugPrint(
          'Diagrams built ${diagrams.evaluate().length}, '
          'still waiting ${waiting().evaluate().length}',
        );
        expect(find.byType(ErrorWidget), findsNothing);
      }
      await _closeTabs(tester);
    },
  );

  // #141: the chat box as Discord's — typing on the keyboard while the box
  // has no focus types into it, once; Markdown is styled as it is typed and
  // drawn as Markdown once sent; a plain Enter is a new line and Ctrl+Enter
  // sends. Real keys, through X and GTK, as a person types them: that the
  // first key lands once, neither lost nor doubled, is the platform's to
  // show, which a widget test cannot.
  _test(
    'the chat box takes typing, draws Markdown, and sends on Ctrl+Enter',
    skip: !Platform.isLinux
        ? 'xdotool drives the Linux build only'
        : _claudeInstalled()
        ? 'this machine has a Claude Code of its own, which this would run'
        : null,
    (tester) async {
      _standInClaudeFor();
      await _launch(tester);
      await _localShell(tester);
      await tester.tap(find.byTooltip('Chat with Claude'));
      final input = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.prefixText == '❯ ',
      );
      await _until(
        tester,
        () => input.evaluate().isNotEmpty,
        'the chat tab to open, its version check passed',
      );
      TextField box() => tester.widget<TextField>(input);
      // On a desktop, a chat shown has its box focused.
      await _until(
        tester,
        () => box().focusNode!.hasFocus,
        'the box to take the focus as the chat is shown',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(box().focusNode!.hasFocus, isFalse);

      const typed = '**bold** and `code`';
      await _xdo(['windowfocus', '--sync', await _window()]);
      await _xdo(['type', '--delay', '60', typed]);
      await _until(
        tester,
        () => box().controller!.text.length >= typed.length,
        'what was typed to reach the box',
      );
      await tester.pump(const Duration(milliseconds: 500));
      // Every key once: the first, which moved the focus, neither lost nor
      // typed a second time.
      expect(box().controller!.text, typed);
      expect(box().focusNode!.hasFocus, isTrue);
      await _grab(tester, 'chat-composer-typing');

      // A plain Enter is a new line, and sends nothing.
      await _xdo(['key', 'Return']);
      await tester.pump(const Duration(milliseconds: 500));
      expect(box().controller!.text, '$typed\n');
      expect(find.byType(TuiChatBubble), findsNothing);

      await _xdo(['key', 'ctrl+Return']);
      await _until(
        tester,
        () => find
            .textContaining('Echo from the stand-in', findRichText: true)
            .evaluate()
            .isNotEmpty,
        "the stand-in's answer in the chat",
        timeout: const Duration(seconds: 40),
      );
      expect(box().controller!.text, isEmpty);
      // Drawn as Markdown: bold is bold, and no marker is left on screen.
      final spans = <TextSpan>[];
      for (final text in tester.widgetList<RichText>(
        find.descendant(
          of: find.byType(TuiChatBubble),
          matching: find.byType(RichText),
        ),
      )) {
        text.text.visitChildren((span) {
          if (span is TextSpan && span.text != null) spans.add(span);
          return true;
        });
      }
      expect(
        spans.any(
          (s) => s.text == 'bold' && s.style?.fontWeight == FontWeight.bold,
        ),
        isTrue,
        reason: 'the bubble draws **bold** bold: ${spans.map((s) => s.text)}',
      );
      expect(spans.any((s) => s.text!.contains('**')), isFalse);
      expect(spans.any((s) => s.text!.contains('`')), isFalse);
      await _grab(tester, 'chat-composer-sent');
      await _closeTabs(tester);
    },
  );

  // #18: where the machine has tmux, the Local shell runs in it, as a tmux
  // host's tabs do — an sshbox- session on the machine's own tmux server, a
  // tab that splits into panes, and the session ended by the tab's ✕.
  //
  // Linux, where tools/e2e_desktop.sh gives the run a tmux server of its own
  // through TMUX_TMPDIR, and a Mac on CI, a runner nobody else's tmux is on;
  // on a Mac someone uses this would open sessions on their own server.
  _test(
    'a Local shell runs in tmux where the machine has it',
    skip: Platform.isWindows
        ? 'a Windows Local shell is PowerShell, with no tmux'
        : Platform.isMacOS && Platform.environment['CI'] != 'true'
        ? "off CI a Mac's tmux server is its user's own"
        : null,
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

      // #111: a mouse drags the border between them, and tmux itself, not
      // only the page, gives the left pane the room.
      Future<List<int>> widths() async {
        final listed = await Process.run('tmux', [
          'list-panes',
          '-a',
          '-F',
          '#{pane_left} #{pane_width}',
        ]);
        final panes = '${listed.stdout}'.trim().split('\n').map((line) {
          final [left, width] = line.split(' ').map(int.parse).toList();
          return (left, width);
        }).toList()..sort((a, b) => a.$1.compareTo(b.$1));
        return [for (final (_, width) in panes) width];
      }

      final before = await widths();
      final views =
          find
              .byType(TerminalView)
              .evaluate()
              .map((e) => tester.getRect(find.byWidget(e.widget)))
              .toList()
            ..sort((a, b) => a.left.compareTo(b.left));
      final gap = Offset(
        (views[0].right + views[1].left) / 2,
        views[0].center.dy,
      );
      final cell = views[0].width / before[0];
      final drag = await tester.startGesture(
        gap,
        kind: PointerDeviceKind.mouse,
      );
      for (var i = 0; i < 10; i++) {
        await drag.moveBy(Offset(cell, 0));
        await tester.pump(const Duration(milliseconds: 30));
      }
      await drag.up();
      await _until(tester, () async {
        final after = await widths();
        return after.length == 2 && after[0] >= before[0] + 5;
      }, 'tmux to widen the left pane after its border was dragged');

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
  // On Linux the picture goes on Xvfb's clipboard with xclip, and on a Mac on
  // the pasteboard through AppleScript, then ⌘V. Off CI a Mac's pasteboard is
  // its user's own, so it is left alone there.
  _test(
    "a picture pasted into a Local shell is copied and its path typed",
    skip: _pictureSkip,
    (tester) async {
      // One transparent pixel: a real PNG, small enough to write out here.
      final png = base64.decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAj'
        'CB0C8AAAAASUVORK5CYII=',
      );
      final picture = File('${_scratch().path}/picture.png')
        ..writeAsBytesSync(png);
      await _putPicture(picture.path);

      await _launch(tester);
      final view = await _localShell(tester);
      await _paste(tester);

      final typed = RegExp(r'(/\S*/pasted-\d{8}-\d{6}\.png)');
      String? path;
      await _until(tester, () {
        // Whole lines, rows a long path wrapped onto joined back: a Mac's
        // $TMPDIR is long enough to wrap.
        final lines = view.terminal.buffer.lines;
        final joined = <String>[];
        for (var i = 0; i < lines.length; i++) {
          final row = lines[i].getText().trimRight();
          if (lines[i].isWrapped && joined.isNotEmpty) {
            joined.last += row;
          } else {
            joined.add(row);
          }
        }
        for (final line in joined) {
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
  _test(
    'a pasted picture\'s path is bracketed when the program asks for it',
    skip: _pictureSkip,
    (tester) async {
      final png = base64.decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAj'
        'CB0C8AAAAASUVORK5CYII=',
      );
      final picture = File('${_scratch().path}/picture.png')
        ..writeAsBytesSync(png);
      await _putPicture(picture.path);

      await _launch(tester);
      final view = await _localShell(tester);
      final pasted = RegExp(r'/\S*/pasted-\d{8}-\d{6}[^ \x1b]*\.png');
      for (final bracketed in [true, false]) {
        final got = await _record(tester, view, bracketed: bracketed);
        await _paste(tester);
        final bytes = await got.bytes('the pasted picture\'s path');
        final path = pasted.firstMatch(bytes)?.group(0);
        expect(
          path,
          isNotNull,
          reason: 'no picture path in ${jsonEncode(bytes)}',
        );
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
  _test(
    'a file or folder dropped on a Local shell pastes its escaped path',
    skip: !Platform.isLinux
        ? 'the drag is a real X drag, made with xdotool and a GTK window'
        : Platform.environment['CI'] != 'true'
        ? "off CI it would drag with the user's own pointer"
        : null,
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
          await got.bytes(
            'the dropped path',
            length: bracketed ? want.length + 13 : want.length + 1,
          ),
          bracketed ? '\x1b[200~$want \x1b[201~' : '$want ',
        );
      }
      expect(find.textContaining('cannot be uploaded'), findsNothing);
      await _closeTabs(tester);
    },
  );

  // #146: files dropped from the file manager on a desktop chat. A picture
  // becomes a card above the box and its [Image #1] in it; a folder dropped
  // with it is refused, saying it is a folder, and so is a file that is no
  // picture Claude reads. A real X drag, as the terminal's above.
  _test(
    'a picture dropped on a chat becomes a card, a folder is refused',
    skip: !Platform.isLinux
        ? 'the drag is a real X drag, made with xdotool and a GTK window'
        : Platform.environment['CI'] != 'true'
        ? "off CI it would drag with the user's own pointer"
        : _claudeInstalled()
        ? 'this machine has a Claude Code of its own, which this would run'
        : null,
    (tester) async {
      _standInClaudeFor();
      final dir = _scratch();
      // A 1x1 PNG.
      final picture = File('${dir.path}/e2e-drop.png')
        ..writeAsBytesSync(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8Dw'
            'HwAFBQIAX8jx0gAAAABJRU5ErkJggg==',
          ),
        );
      final folder = Directory('${dir.path}/e2e-folder')..createSync();
      final notes = File('${dir.path}/e2e-notes.txt')..writeAsStringSync('x');
      await _launch(tester);
      await _localShell(tester);
      await tester.tap(find.byTooltip('Chat with Claude'));
      await _until(
        tester,
        () => _composer.evaluate().isNotEmpty,
        'the chat tab to open, its version check passed',
      );
      Finder toast(String text) => find.descendant(
        of: find.byType(TuiToastCard),
        matching: find.textContaining(text, findRichText: true),
      );
      final cards = find.byWidgetPredicate(
        (w) => w is Tooltip && (w.message ?? '').startsWith('Remove '),
      );

      await _drag(tester, picture.path, dir, more: [folder.path]);
      await _until(
        tester,
        () =>
            toast('A folder is not a picture: e2e-folder')
                .evaluate()
                .isNotEmpty,
        'the folder refused, saying it is a folder',
      );
      await _until(
        tester,
        () => find.text('[Image #1] e2e-drop.png').evaluate().isNotEmpty,
        "the picture's card",
      );
      expect(cards, findsOneWidget, reason: 'one card, for the picture alone');
      expect(
        tester.widget<TextField>(_composer).controller!.text,
        '[Image #1] ',
      );
      await _shot(tester, 'desktop-chat-dropped-picture');

      await _drag(tester, notes.path, dir);
      await _until(
        tester,
        () =>
            toast('Not a picture Claude can read: e2e-notes.txt')
                .evaluate()
                .isNotEmpty,
        'the text file refused',
      );
      expect(cards, findsOneWidget);
      await _closeTabs(tester);
    },
  );

  // #14: a desktop's terminal can use a font the machine has, not only the
  // five the app bundles — listed from the machine itself, monospaced ones
  // marked, used by name. Menlo on a Mac, which every Mac has; on Linux the
  // first monospaced family fontconfig lists that the app does not bundle.
  _test("the terminal takes a font installed on the machine", (tester) async {
    final bundled = terminalFonts.map((font) => font.family).toSet();
    final String family;
    if (Platform.isMacOS) {
      family = 'Menlo';
    } else if (Platform.isWindows) {
      // Listed through GDI, and marked monospaced by its FIXED_PITCH.
      family = 'Consolas';
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
      () => find
          .textContaining('families, monospaced first')
          .evaluate()
          .isNotEmpty,
      "this computer's fonts to be listed",
    );
    // Built is not on screen: a list builds a little past its edge.
    await tester.ensureVisible(row);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(row);
    await _until(
      tester,
      () => _label('Installed fonts').evaluate().isNotEmpty,
      'the font picker',
    );
    // Settings' own fields are behind the dialog.
    final picker = _kind('AlertDialog', 'TuiDialog');
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
  });

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
  _test(
    'an update is kept only when its hash is the release\'s',
    skip: updateHost.isEmpty ? 'this build has no update host baked in' : null,
    (tester) async {
      final build = utf8.encode('not a real build, only bytes to be checked');
      const name = 'jeansh-e2e-update.tar.gz';
      // Where the app puts it: Downloads, or the home where there is none.
      final kept = File('${downloadsFolder().path}/$name');
      addTearDown(() {
        if (kept.existsSync()) kept.deleteSync();
      });
      var digest = '${sha256.convert(build)}';
      // The build's second half waits for this, so the download can be
      // closed on while it runs (#116).
      final rest = Completer<void>();
      // Launched first: the app looks for an update itself as it starts,
      // and that one should find nothing to offer over this test.
      await _launch(tester);
      final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        Uri.parse(updateHost).port,
      );
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
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
            response.contentLength = build.length;
            response.add(build.sublist(0, build.length ~/ 2));
            await response.flush();
            await rest.future;
            response.add(build.sublist(build.length ~/ 2));
          default:
            response.statusCode = HttpStatus.notFound;
        }
        unawaited(response.close());
      });

      // Asked from Settings, opening it first when it is not open.
      final check = _label('Check for updates');
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
        () => find.text('Downloading Jeansh 9.9.9').evaluate().isNotEmpty,
        'the download to start',
      );

      // #116: a click outside the dialog while it downloads puts the
      // download in the background rather than cancelling it, and Settings
      // shows it going on, then Restart to update.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tapAt(const Offset(4, 4));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Downloading Jeansh 9.9.9'), findsNothing);
      final going = find.text('Jeansh 9.9.9 is downloading');
      if (check.evaluate().isEmpty) await _settings(tester);
      await tester.scrollUntilVisible(
        going,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(going, findsOneWidget);
      expect(_label('Cancel'), findsOneWidget);
      rest.complete();
      await _until(
        tester,
        () => _label('Restart to update').evaluate().isNotEmpty,
        'Settings to offer Restart to update once the download is checked',
      );
      expect(
        find.text('Jeansh 9.9.9 is downloaded and checked.'),
        findsOneWidget,
      );
      expect(kept.readAsBytesSync(), build);
      kept.deleteSync();

      // A build whose hash is not the release's: refused, and nothing kept.
      digest = '0' * 64;
      await tester.pump(const Duration(milliseconds: 600));
      await askSettings();
      await _pick(tester, 'Download');
      await _until(
        tester,
        () => find
            .textContaining('is not the file the release describes')
            .evaluate()
            .isNotEmpty,
        'a download of the wrong file to be refused',
      );
      expect(_label('Restart to update'), findsNothing);
      expect(kept.existsSync(), isFalse, reason: 'the wrong file was kept');
      expect(File('${kept.path}.part').existsSync(), isFalse);
    },
  );

  // #65: a newer release is said where the user will see it — the daily
  // check offers it, and once put off it stays marked on Home and in
  // Settings — and Help checks on demand, answering up to date when it is,
  // which clears the mark.
  //
  // Help is the Mac's Jeansh menu, outside Flutter and clicked through System
  // Events, and on Linux and Windows the ⋯ beside the window's buttons
  // (#117): see _menuCheckForUpdates.
  _test(
    'Help checks for updates, and a newer release stays marked until a '
    'check finds none',
    skip: updateHost.isEmpty ? 'this build has no update host baked in' : null,
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
        _label('Update 9.9.8'),
        findsOneWidget,
        reason: 'Home does not mark a release that was put off',
      );

      await _settings(tester);
      final available = _label('Jeansh 9.9.8 is available');
      await tester.scrollUntilVisible(
        available,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(available, findsOneWidget);
      await _backHome(tester);

      Future<void> helpCheck() => _menuCheckForUpdates(tester);

      await helpCheck();
      await _until(
        tester,
        () => find.text('Jeansh 9.9.8 is out').evaluate().isNotEmpty,
        'Help › Check for updates… to offer the newer release',
      );
      await _pick(tester, 'Not now');
      await tester.pump(const Duration(milliseconds: 600));
      expect(_label('Update 9.9.8'), findsOneWidget);

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
        _label('Update 9.9.8'),
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
  _test(
    'a link opens with the key Settings names, and not the other',
    skip: !Platform.isLinux
        ? 'the stand-in browser is registered through XDG mime handlers, '
              'which only Linux reads'
        : Platform.environment['CI'] != 'true'
        ? "off CI the machine's own browser would open"
        : null,
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
      final choice = _kind(
        'SegmentedButton<LinkModifier>',
        'TuiSelect<LinkModifier>',
      );
      await tester.scrollUntilVisible(
        choice,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(choice);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.descendant(of: choice, matching: _label('Alt')));
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

  // #126, with the real pointer. In a shell: a double click selects a word,
  // and selecting more after it — a longer drag, then a fresh one elsewhere
  // — copies each, a few times over, the user having seen it fail often and
  // not always.
  _test('after a double click on a word, a drag still selects more, and a '
      'fresh drag elsewhere too', (tester) async {
    await _realPointer(() async {
      await _launch(tester);
      final view = await _localShell(tester);
      // Quoted: PowerShell's echo puts each word on a line of its own.
      _run(view, "echo 'jeansh select me please'; echo 'second line here'");
      final lines = view.terminal.buffer.lines;
      int row(String text) {
        for (var i = lines.length - 1; i >= 0; i--) {
          if (lines[i].getText().startsWith(text)) return i;
        }
        return -1;
      }

      await _until(
        tester,
        () => row('second line here') >= 0,
        'the lines to be printed',
      );
      final first = row('jeansh select me please');
      final second = row('second line here');
      final render = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal;
      String cell(int col, int line) {
        final at = render.localToGlobal(
          render.getOffset(CellOffset(col, line)) +
              Offset(render.cellSize.width / 2, render.lineHeight / 2),
        );
        return 'move ${at.dx} ${at.dy}';
      }

      Future<void> copies(List<String> steps, String text) async {
        await Clipboard.setData(const ClipboardData(text: 'untouched'));
        await _osMouse(tester, steps);
        await _until(
          tester,
          () async => await _clipboard() != 'untouched',
          'something to be copied, expecting "$text"',
        );
        expect(await _clipboard(), text);
      }

      List<String> drag(int from, int to, int line) => [
        cell(from, line),
        'down',
        // Held, as a hand does before it moves.
        'sleep 300',
        for (var col = from + 1; col <= to; col++) cell(col, line),
        'up',
      ];

      for (var round = 0; round < 3; round++) {
        await copies([
          cell(8, first),
          for (var i = 0; i < 2; i++) ...['down', 'sleep 30', 'up', 'sleep 60'],
          'sleep 400',
        ], 'select');
        await copies(drag(0, 22, first), 'jeansh select me please');
        await copies(drag(0, 10, second), 'second line');
      }
      await _closeTabs(tester);
    });
  });

  // #126: under a program that tracks the mouse — every mode on, as Claude
  // Code's fullscreen view asks — a drag is the program's, so it selects and
  // copies for itself: the press, the moves and the release, a double click
  // as two whole clicks, and never a press left without its release, which
  // used to leave Claude Code dragging. Shift+drag stays the terminal's own
  // selection and copies. The program here records what it is sent.
  _test(
    'a program tracking the mouse gets a drag and a double click whole, and '
    'Shift+drag still copies',
    skip: Platform.isWindows ? _powershell : null,
    (tester) async {
      await _realPointer(() async {
        await _launch(tester);
        final view = await _localShell(tester);
        _run(view, 'echo jeansh select me');
        final lines = view.terminal.buffer.lines;
        var row = -1;
        await _until(tester, () {
          for (var i = 0; i < lines.length; i++) {
            if (lines[i].getText().startsWith('jeansh select me')) row = i;
          }
          return row >= 0;
        }, 'the line to be printed');
        final got = await _record(tester, view, bracketed: false, mouse: true);

        final render = tester
            .state<TerminalViewState>(find.byType(TerminalView))
            .renderTerminal;
        String cell(int col) {
          final at = render.localToGlobal(
            render.getOffset(CellOffset(col, row)) +
                Offset(render.cellSize.width / 2, render.lineHeight / 2),
          );
          return 'move ${at.dx} ${at.dy}';
        }

        final drag = [
          cell(0),
          'down',
          'sleep 300',
          for (var col = 1; col <= 15; col++) cell(col),
          'up',
        ];
        await _osMouse(tester, drag);
        await _osMouse(tester, [
          cell(8),
          for (var i = 0; i < 2; i++) ...['down', 'sleep 30', 'up', 'sleep 60'],
          'sleep 400',
        ]);

        await Clipboard.setData(const ClipboardData(text: 'untouched'));
        await _hearing(() async {
          // Shift held past the release, as a hand holds it: the app may
        // hear a key before the pointer events sent ahead of it, and xterm2
        // reads Shift as the drag starts, not at the press.
        await _osMouse(tester, [
          'shiftdown',
          'sleep 200',
          ...drag,
          'sleep 500',
          'shiftup',
        ]);
          await _until(
            tester,
            () async => await _clipboard() != 'untouched',
            'Shift+drag to copy',
          );
        });
        expect(await _clipboard(), 'jeansh select me');

        final bytes = await got.bytes('the mouse');
        final said = bytes.replaceAll('\x1b', 'ESC');
        int count(String pattern) => RegExp(pattern).allMatches(bytes).length;
        // The drag's press and the double click's two, each with its release.
        expect(count(r'\x1b\[<0;\d+;\d+M'), 3, reason: said);
        expect(count(r'\x1b\[<0;\d+;\d+m'), 3, reason: said);
        expect(count(r'\x1b\[<32;\d+;\d+M'), greaterThan(0), reason: said);
        expect(
          bytes,
          matches(RegExp(r'\x1b\[<0;1;\d+M')),
          reason: 'a press where the drag began: $said',
        );

        await _closeTabs(tester);
      });
    },
  );

  // #126: on a Mac ⌘ is the link key as well as the copy key. Under the
  // kitty protocol, which Claude Code turns on, xterm2 sent a lone ⌘ to the
  // program as a key, and a key sent lets the selection go, so ⌘C copied
  // nothing. Selected with the real pointer and copied with real keys.
  _test(
    'on a Mac, ⌘C copies a selection under the kitty keyboard protocol',
    skip: Platform.isMacOS ? null : '⌘ is the link key on a Mac alone',
    (tester) async {
      await _realPointer(() async {
        await _launch(tester);
        final view = await _localShell(tester);
        _run(view, 'echo jeansh select me');
        final lines = view.terminal.buffer.lines;
        var row = -1;
        await _until(tester, () {
          for (var i = 0; i < lines.length; i++) {
            if (lines[i].getText().startsWith('jeansh select me')) row = i;
          }
          return row >= 0;
        }, 'the line to be printed');
        // Flags 1 and 4, Claude Code's.
        _run(view, r"printf '\033[>5u'");
        await _until(
          tester,
          () => view.terminal.kittyKeyboardMode == 5,
          'the kitty protocol to be on',
        );

        final render = tester
            .state<TerminalViewState>(find.byType(TerminalView))
            .renderTerminal;
        String cell(int col) {
          final at = render.localToGlobal(
            render.getOffset(CellOffset(col, row)) +
                Offset(render.cellSize.width / 2, render.lineHeight / 2),
          );
          return 'move ${at.dx} ${at.dy}';
        }

        await _osMouse(tester, [
          cell(0),
          'down',
          'sleep 300',
          for (var col = 1; col <= 15; col++) cell(col),
          'up',
        ]);
        // Copy on select has copied it already; ⌘C must copy it again.
        await Clipboard.setData(const ClipboardData(text: 'untouched'));
        await _hearing(() async {
          await _osMouse(tester, ['cmdc']);
          await _until(
            tester,
            () async => await _clipboard() != 'untouched',
            '⌘C to copy',
          );
        });
        expect(await _clipboard(), 'jeansh select me');

        _run(view, r"printf '\033[<u'");
        await _closeTabs(tester);
      });
    },
  );

  // #126: on a Mac a trackpad's two-finger scroll reaches Flutter as a pan,
  // never a wheel, and only the Cocoa embedder makes one from the system's
  // own phased scroll events. So the scroll is posted to this process as
  // AppKit would get it from a trackpad (see [_trackpad]): over a plain
  // shell's scrollback, and over a program reading the mouse after a click
  // on its bottom row, where Claude Code's prompt is — a pan's wheel events
  // went to that click's cell rather than the pointer's.
  _test(
    'a trackpad scroll moves the scrollback and reaches a program that reads '
    'the mouse at the pointer',
    skip: Platform.isMacOS
        ? null
        : "a phased trackpad scroll is posted through a Mac's CoreGraphics",
    (tester) async {
      await _realPointer(() async {
        await _launch(tester);
        final dir = _scratch();

        final view = await _localShell(tester);
        _run(view, 'seq 1 400');
        await _until(
          tester,
          () => _text(view).any((line) => line.trim() == '400'),
          'seq to print 400 lines',
        );
        final scroll = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byType(TerminalView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        // Off the bottom first, so a pan either way has room to move it.
        scroll.position.jumpTo(scroll.position.maxScrollExtent - 600);
        await tester.pump();
        final from = scroll.position.pixels;
        final box = tester.getRect(find.byType(TerminalView));
        await _trackpad(tester, box.center);
        expect(
          scroll.position.pixels,
          isNot(from),
          reason: 'the scrollback, from $from',
        );

        // writing what it is sent to a file a byte at a time: cat would hold it
        // in its buffer.
        // writing what it is sent to a file a byte at a time, as cat would buffer it.
        final got = File('${dir.path}/wheel');
        _run(
          view,
          r"printf '\033[?1049h\033[?1000h\033[?1006h'; stty raw -echo; "
          'dd bs=1 of=${got.path} 2>/dev/null',
        );
        await _until(
          tester,
          () => view.terminal.isUsingAltBuffer && got.existsSync(),
          'the program to take the mouse',
        );
        await tester.tapAt(Offset(box.center.dx, box.bottom - 12));
        await tester.pump(const Duration(milliseconds: 500));
        final render = tester
            .state<TerminalViewState>(find.byType(TerminalView))
            .renderTerminal;
        final cell = render.getCellOffset(render.globalToLocal(box.center));
        await _trackpad(tester, box.center);
        final wheel = RegExp(r'\x1b\[<6[45];(\d+);(\d+)M');
        await _until(
          tester,
          () => wheel.hasMatch(got.readAsStringSync()),
          'a wheel event to reach the program',
        );
        final at = {
          for (final m in wheel.allMatches(got.readAsStringSync()))
            '${m[1]};${m[2]}',
        };
        expect(at, {'${cell.x + 1};${cell.y + 1}'}, reason: 'the pointer cell');

        view.terminal.keyInput(TerminalKey.keyC, ctrl: true);
        await _closeTabs(tester);
      });
    },
  );

  // #117: on Linux and Windows the runner draws no title bar, and the app
  // draws its buttons and moves the window from the tab strip's empty space.
  // Pressed with the real pointer, as each goes a way no widget test reaches:
  // on Windows the maximize button is Windows' own to answer, for the snap
  // layouts, and a press on the strip is Flutter's first and then the window
  // manager's, which moves the window while the button is held.
  //
  // Last, as it moves the window every test before it expects where it was.
  // Linux maximizes through a window manager, which Xvfb has none of, so this
  // test starts openbox for itself and stops it after.
  _test(
    'the window buttons and the tab strip move, maximize and restore the '
    'real window',
    skip: Platform.isMacOS
        ? "a Mac's window keeps its own buttons"
        : Platform.isLinux &&
              Process.runSync('sh', ['-c', 'command -v openbox']).exitCode != 0
        ? 'maximizing wants a window manager, and openbox is not installed'
        : null,
    (tester) async {
      final binding = IntegrationTestWidgetsFlutterBinding.instance;
      binding.shouldPropagateDevicePointerEvents = true;
      await _launch(tester);
      if (Platform.isLinux) {
        await _window();
        final wm = await Process.start('openbox', []);
        addTearDown(wm.kill);
        await Future<void>.delayed(const Duration(seconds: 2));
        await tester.pump();
      }
      final ratio = tester.view.devicePixelRatio;

      // [local], a point in the app, where the real pointer finds it: on
      // Windows the client area's physical pixels, on Linux the screen's,
      // past the frame GTK draws around the view.
      Future<Offset> real(Offset local) async {
        if (Platform.isWindows) return local * ratio;
        final window = await _windowRect();
        final frame = (window.width - tester.view.physicalSize.width) / 2;
        return window.topLeft + Offset(frame, frame) + local * ratio;
      }

      Future<void> click(Offset local, {int times = 1}) async {
        final at = await real(local);
        if (Platform.isWindows) {
          await _winMouse([
            'move ${at.dx.round()} ${at.dy.round()}',
            for (var i = 0; i < times; i++) ...[
              'down',
              'sleep 40',
              'up',
              'sleep 60',
            ],
          ]);
        } else {
          await _xdo(['mousemove', '${at.dx.round()}', '${at.dy.round()}']);
          await _xdo(['click', '--repeat', '$times', '--delay', '100', '1']);
        }
        await tester.pump(const Duration(milliseconds: 300));
      }

      final restored = tester.view.physicalSize;
      Future<void> becomes(String button, String what) =>
          _until(tester, () => _named(button).evaluate().isNotEmpty, what);

      // Maximize, and back.
      await click(tester.getCenter(_named('Maximize')));
      await becomes('Restore', 'the maximize button to maximize the window');
      expect(tester.view.physicalSize.height, greaterThan(restored.height));
      await click(tester.getCenter(_named('Restore')));
      await becomes('Maximize', 'the restore button to restore the window');
      await _until(
        tester,
        () => tester.view.physicalSize == restored,
        'the window to come back to its size',
      );

      // A double-click on the strip's empty space, beside the buttons, does
      // the same, as on any title bar.
      Offset strip() => tester.getCenter(_named('Help')) - const Offset(60, 0);
      await click(strip(), times: 2);
      await becomes('Restore', 'a double-click on the strip to maximize');
      await click(strip(), times: 2);
      await becomes('Maximize', 'a double-click on the strip to restore');
      await _until(
        tester,
        () => tester.view.physicalSize == restored,
        'the window to come back to its size',
      );

      // A drag on the strip moves the window.
      final before = await _windowRect();
      final from = await real(strip());
      if (Platform.isWindows) {
        await _winMouse([
          'move ${from.dx.round()} ${from.dy.round()}',
          'down',
          'sleep 150',
          for (var i = 0; i < 6; i++) ...['moveby -10 8', 'sleep 50'],
          'up',
        ]);
      } else {
        await _xdo(['mousemove', '${from.dx.round()}', '${from.dy.round()}']);
        await _xdo(['mousedown', '1']);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        for (var i = 1; i <= 6; i++) {
          await _xdo([
            'mousemove',
            '${from.dx.round() - 10 * i}',
            '${from.dy.round() + 8 * i}',
          ]);
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        await _xdo(['mouseup', '1']);
      }
      await tester.pump(const Duration(milliseconds: 500));
      final moved = (await _windowRect()).topLeft - before.topLeft;
      expect(moved.dx, closeTo(-60, 12), reason: 'the drag moved it $moved');
      expect(moved.dy, closeTo(48, 12), reason: 'the drag moved it $moved');

      // Minimize, and back by the desktop's own hand.
      await tester.tap(_named('Minimize'));
      await tester.pump(const Duration(milliseconds: 800));
      if (Platform.isWindows) {
        expect((await _winMouse(const [])).iconic, isTrue);
        await _winMouse(const ['restore']);
      } else {
        final shown = await Process.run('xdotool', [
          'search', '--onlyvisible', '--name', r'^Jeansh$', //
        ]);
        expect('${shown.stdout}'.trim(), isEmpty, reason: 'still on screen');
        final hidden = (await _xdo(['search', '--name', r'^Jeansh$']))
            .split('\n')
            .first;
        await _xdo(['windowmap', '--sync', hidden]);
      }
      await tester.pump(const Duration(milliseconds: 800));
      expect(_named('Close'), findsOneWidget);
      // In the body: the binding checks it is back before any tear-down runs.
      binding.shouldPropagateDevicePointerEvents = false;
    },
  );

  // #137: a Local shell's chat types into an interactive Claude in a tmux
  // pane, as an SSH host's does (.maestro/chat_two_way on Android). The
  // session is tools/e2e_live_claude.py in a pane of the run's own tmux
  // server (tools/e2e_desktop.sh), with a stand-in claude that lists it, both
  // in the runner's home, which on CI holds no Claude Code of its own.
  _test(
    "a Local shell's chat types into a session's tmux pane, and its answer "
    'comes back',
    skip: !Platform.isLinux
        ? "the session's pane needs the run's own tmux server, which "
              'tools/e2e_desktop.sh gives Linux alone'
        : Platform.environment['CI'] != 'true' || _claudeInstalled()
        ? "off CI it would write a claude into the user's own home"
        : null,
    (tester) async {
      final home = Platform.environment['HOME']!;
      const sid = 'e2e00005-0000-4000-8000-000000000005';
      final claude = File('$home/.local/bin/claude');
      final config = Directory('$home/.claude');
      final agents = File('$home/.e2e-agents.json');
      final script = File('tools/e2e_live_claude.py').absolute;
      expect(script.existsSync(), isTrue, reason: 'no ${script.path}');
      expect(agents.existsSync(), isFalse, reason: '${agents.path} is there');
      final hadConfig = config.existsSync();
      addTearDown(() {
        final shown = Process.runSync('tmux', [
          'capture-pane',
          '-p',
          '-t',
          'e2e-pane',
        ]);
        debugPrint('Pane: ${shown.stdout}${shown.stderr}');
        Process.runSync('tmux', ['kill-session', '-t', 'e2e-pane']);
        if (claude.existsSync()) claude.deleteSync();
        if (agents.existsSync()) agents.deleteSync();
        if (!hadConfig && config.existsSync()) {
          config.deleteSync(recursive: true);
        }
      });
      claude.parent.createSync(recursive: true);
      claude.writeAsStringSync(
        '#!/bin/sh\ncase "\$1" in\n'
        "  --version) echo '2.1.300 (Claude Code)' ;;\n"
        '  agents) cat "\$HOME/.e2e-agents.json" ;;\n'
        '  *) exec cat >/dev/null ;;\nesac\n',
      );
      Process.runSync('chmod', ['755', claude.path]);
      final projects = Directory(
        '${config.path}/projects/${home.replaceAll(RegExp('[/.]'), '-')}',
      )..createSync(recursive: true);
      final transcript = File('${projects.path}/$sid.jsonl')
        ..writeAsStringSync(
          '${jsonEncode({
            'type': 'user',
            'message': {'role': 'user', 'content': 'Earlier question'},
          })}\n'
          '${jsonEncode({
            'type': 'assistant',
            'message': {
              'role': 'assistant',
              'content': [
                {'type': 'text', 'text': 'Earlier answer'},
              ],
            },
          })}\n',
        );
      agents.writeAsStringSync('[]');
      final pane = await Process.run(
        'tmux',
        [
          'new-session', '-d', '-s', 'e2e-pane', '-x', '120', '-y', '30', //
          '-c', home,
          'env PYTHONIOENCODING=utf-8 python3 ${script.path} $sid',
        ],
        environment: const {'LANG': 'C.UTF-8', 'LC_ALL': 'C.UTF-8'},
      );
      expect(pane.exitCode, 0, reason: 'tmux: ${pane.stderr}');
      // The stand-in's own pid, as `claude agents` gives Claude's.
      final states = Directory('${config.path}/sessions');
      final started = DateTime.now().add(const Duration(seconds: 10));
      String? state;
      while ((state = states.existsSync()
              ? states
                    .listSync()
                    .map((f) => f.path)
                    .where((p) => File(p).readAsStringSync().contains(sid))
                    .firstOrNull
              : null) ==
          null) {
        if (DateTime.now().isAfter(started)) fail('the stand-in never started');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final pid = int.parse(state!.split('/').last.replaceAll('.json', ''));
      agents.writeAsStringSync(
        jsonEncode([
          {
            'kind': 'interactive', 'pid': pid, 'sessionId': sid, //
            'name': 'E2E pane session', 'cwd': home, 'status': 'idle',
            'startedAt': 1790000000100,
          },
        ]),
      );

      await _launch(tester);
      await _localShell(tester);
      await tester.tap(find.byTooltip('Chat with Claude'));
      final row = find.text('E2E pane session');
      await _until(
        tester,
        () =>
            row.evaluate().isNotEmpty ||
            find.byTooltip('Sessions on this host').evaluate().isNotEmpty,
        'the chat to open',
      );
      if (row.evaluate().isEmpty) {
        await tester.tap(find.byTooltip('Sessions on this host'));
      }
      await _until(
        tester,
        () => row.evaluate().isNotEmpty,
        'the live session listed',
      );
      await tester.tap(row.first);
      await _until(
        tester,
        () => find.textContaining('typed into that pane').evaluate().isNotEmpty,
        'the chat to watch the session, typing into its pane',
      );
      final chat = tester.widget<ChatPage>(find.byType(ChatPage)).session.chat;
      String said() => chat.entries
          .map(
            (e) => switch (e) {
              ChatSaid(:final text, :final why) => '$text${why ?? ''}',
              ChatNotice(:final text) => text,
              _ => '$e',
            },
          )
          .join(' | ');

      final field = find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.decoration?.hintText == 'Message “E2E pane session”…',
      );
      await _until(tester, () => field.evaluate().isNotEmpty, 'the field');
      await tester.enterText(field, 'hello from the desktop');
      // Send turns on in the frame after the text goes in. Tapped sooner it
      // is still off and sends nothing — which, with no frame waited for,
      // read as a chat that never typed into the pane (run 36875853136).
      await _until(
        tester,
        () =>
            tester
                .widget<IconButton>(
                  find
                      .ancestor(
                        of: find.byTooltip('Send'),
                        matching: find.byType(IconButton),
                      )
                      .first,
                )
                .onPressed !=
            null,
        'Send to turn on',
      );
      await tester.tap(find.byTooltip('Send'));
      final end = DateTime.now().add(const Duration(seconds: 40));
      while (!transcript.readAsStringSync().contains(
        'hello from the desktop',
      )) {
        if (DateTime.now().isAfter(end)) {
          fail('never reached the pane; the chat said: ${said()}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
      await _until(
        tester,
        () => chat.entries.whereType<ChatSaid>().any(
          (e) => e.text == 'Echo: hello from the desktop',
        ),
        "the stand-in's answer in the chat",
      );
      await _closeTabs(tester);
    },
  );

  // #132. A tab's menu from a right-click the OS itself sends, not one the
  // test makes up inside Flutter: on a desktop the strip is the window's
  // title bar, and what the runner, the window manager or AppKit does with a
  // press there comes before any widget. Not a Mac's Ctrl+click: the
  // binding that makes it a right-click (JeanshBinding) is the app's, and
  // integration_test's is made first; right_click_test.dart holds that one.
  // On Linux under openbox, where there is one, since a
  // window manager is what turns a right-click on a title bar into its
  // window menu; after the window-buttons test, as it may move the window.
  _test('a real right-click on a tab opens its menu', (tester) async {
    final binding = IntegrationTestWidgetsFlutterBinding.instance;
    binding.shouldPropagateDevicePointerEvents = true;
    addTearDown(() => binding.shouldPropagateDevicePointerEvents = false);
    await _launch(tester);
    if (Platform.isLinux &&
        Process.runSync('sh', ['-c', 'command -v openbox']).exitCode == 0) {
      await _window();
      final wm = await Process.start('openbox', []);
      addTearDown(wm.kill);
      await Future<void>.delayed(const Duration(seconds: 2));
      await tester.pump();
    }
    await _localShell(tester);
    final close = find.byWidgetPredicate(
      (w) => w is Tooltip && (w.message ?? '').startsWith('Close '),
    );
    final tabs = find.byWidgetPredicate(
      (w) =>
          w is Tooltip &&
          ((w.message ?? '').startsWith('Close ') || w.message == 'Reconnect'),
    );
    // Left of its close button, on the chip's title: where a hand aims.
    Offset chip() => tester.getCenter(close.first) - const Offset(40, 0);

    final before = tabs.evaluate().length;
    await _realRightClick(tester, chip());
    await _pick(tester, 'Duplicate session');
    await _until(
      tester,
      () => tabs.evaluate().length == before + 1,
      'a second Local shell',
    );
    await _closeTabs(tester);
    // In the body: the binding checks it is back before any tear-down runs.
    binding.shouldPropagateDevicePointerEvents = false;
  });
}
