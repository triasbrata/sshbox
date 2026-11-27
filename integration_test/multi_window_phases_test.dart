// Several windows on Linux (#344, #353), the half that needs the app started
// again or ended, or a window manager: run once a phase by
// tools/e2e_desktop.sh (mw-phases), each a fresh start of the app on the same
// data folder, under openbox, in order:
//
//   save      A with one Local shell, B with two; C opened and closed; A and
//             B moved and sized apart, and where they are noted
//   restore   started again: A and B are back, not C, each at its own frame
//             and with its own tabs
//   buttons   B's maximize and minimize act on B alone, and its Close closes
//             only it
//   last      the first window closed while the second stays working, the
//             new-window key bringing one back with Home, and the last window
//             closing with no question and ending the process
//
// Real X input throughout: keys and clicks through xdotool.

import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sshbox/main.dart' as app;
import 'package:sshbox/src/telemetry/app_log.dart' show appLog;
import 'package:xterm2/xterm.dart' show TerminalKey, TerminalView;
import 'package:sshbox/src/ui/termul/tui_button.dart' show TuiButton;
import 'package:sshbox/src/ui/termul/tui_dialog.dart' show TuiDialog;

const _phase = String.fromEnvironment('JEANSH_E2E_MWINDOW');

/// Where one run tells the next what it left, and the last run tells the
/// script what it saw.
final _dir = Directory(
  Platform.environment['JEANSH_E2E_MW_DIR'] ?? Directory.systemTemp.path,
);
File _note(String name) => File('${_dir.path}/jeansh-e2e-mw-$name.txt');

void _trace(String what) {
  debugPrint('multi-window: $what');
  _note('trace').writeAsStringSync('$what\n', mode: FileMode.append);
}

Future<void> _until(
  WidgetTester tester,
  FutureOr<bool> Function() done,
  String what, {
  Duration timeout = const Duration(seconds: 25),
}) async {
  final end = DateTime.now().add(timeout);
  while (!await done()) {
    if (DateTime.now().isAfter(end)) fail('Gave up waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
}

Future<String> _xdo(List<String> args) async {
  // A time limit: `windowfocus --sync` waits for ever on a window that holds
  // the focus already.
  final result = await Process.run('timeout', ['15', 'xdotool', ...args]);
  expect(result.exitCode, 0, reason: 'xdotool $args: ${result.stderr}');
  return '${result.stdout}'.trim();
}

Future<List<String>> _windows() async {
  final found = await Process.run('xdotool', [
    'search',
    '--onlyvisible',
    '--name',
    r'^Jeansh$',
  ]);
  if (found.exitCode != 0) return [];
  return [
    for (final id in '${found.stdout}'.split('\n'))
      if (id.trim().isNotEmpty) id.trim(),
  ]..sort((a, b) => int.parse(a).compareTo(int.parse(b)));
}

Future<List<String>> _windowsAre(WidgetTester tester, int count) async {
  var ids = <String>[];
  await _until(tester, () async {
    ids = await _windows();
    return ids.length == count;
  }, '$count windows (now ${ids.length}: $ids)');
  debugPrint('multi-window: $count windows: $ids');
  return ids;
}

/// A window's place and size as X reports them, the same way both times.
Future<String> _rect(String id) async {
  final info = await Process.run('xwininfo', ['-id', id]);
  expect(info.exitCode, 0, reason: 'xwininfo $id: ${info.stderr}');
  String value(String key) =>
      RegExp('$key:\\s+(-?\\d+)').firstMatch('${info.stdout}')!.group(1)!;
  return '${value('Absolute upper-left X')} ${value('Absolute upper-left Y')} '
      '${value('Width')} ${value('Height')}';
}

Future<String> _state(String id) async {
  final info = await Process.run('xwininfo', ['-id', id]);
  final map = RegExp(r'Map State:\s+(\w+)').firstMatch('${info.stdout}');
  final prop = await Process.run('xprop', ['-id', id, '_NET_WM_STATE']);
  return '${map?.group(1)} ${prop.stdout}'.trim();
}

final _close = find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.label == 'Close',
);

Finder _semantic(String label) => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.label == label,
);

List<int> _views() =>
    {
      for (final e in _close.evaluate()) View.of(e).viewId,
    }.toList()..sort();

List<Element> _in(Finder finder, int viewId) => [
  for (final e in finder.evaluate())
    if (View.of(e).viewId == viewId) e,
];

Future<Element> _first(WidgetTester tester, Finder f, int view, String what) async {
  await _until(tester, () => _in(f, view).isNotEmpty, '$what in view $view');
  return _in(f, view).first;
}

final _tabClose = find.byWidgetPredicate(
  (w) => w is Tooltip && (w.message ?? '').startsWith('Close '),
);

Finder _button(String label) => find.byWidgetPredicate(
  (w) => w is TuiButton && w.label.toLowerCase() == label.toLowerCase(),
);

Future<void> _click(
  WidgetTester tester,
  String xid,
  int viewId,
  Element target, {
  int button = 1,
}) async {
  final binding = IntegrationTestWidgetsFlutterBinding.instance;
  final ratio = tester.binding.platformDispatcher
      .view(id: viewId)!
      .devicePixelRatio;
  final box = target.renderObject! as RenderBox;
  final at = box.localToGlobal(box.size.center(Offset.zero));
  binding.shouldPropagateDevicePointerEvents = true;
  try {
    await _xdo(['windowfocus', xid]);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _xdo([
      'mousemove',
      '--window',
      xid,
      '${(at.dx * ratio).round()}',
      '${(at.dy * ratio).round()}',
      'sleep',
      '0.25',
      'click',
      '$button',
    ]);
    await tester.pump(const Duration(milliseconds: 400));
  } finally {
    binding.shouldPropagateDevicePointerEvents = false;
  }
}

Future<void> _newWindow(WidgetTester tester, String from, int count) async {
  await _xdo(['windowfocus', from]);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await _xdo(['key', 'ctrl+shift+n']);
  final ids = await _windowsAre(tester, count);
  await _until(tester, () => _views().length == count, 'a view a window');
  // Side by side, so a click in one lands on it and not on the one over it.
  if (count == 2) {
    await _xdo(['windowmove', ids[1], '650', '40']);
    await _xdo(['windowsize', ids[1], '600', '450']);
    await _xdo(['windowmove', ids[0], '20', '20']);
    await _xdo(['windowsize', ids[0], '600', '450']);
  }
}

Future<void> _launch(WidgetTester tester) async {
  await app.main();
  final skip = find.byWidgetPredicate(
    (w) =>
        w is Text &&
        (w.data ?? w.textSpan?.toPlainText())?.toLowerCase() == 'skip',
  );
  await _until(
    tester,
    () =>
        skip.evaluate().isNotEmpty ||
        find.byTooltip('Settings').evaluate().isNotEmpty,
    'Home, or the first-run slides',
  );
  if (skip.evaluate().isNotEmpty) await tester.tap(skip.first);
  await tester.pump(const Duration(milliseconds: 500));
}

Finder get _card => find.ancestor(
  of: find.text('Local shell'),
  matching: find.byWidgetPredicate((w) {
    final type = '${w.runtimeType}';
    return type == 'Card' || type == 'HomeRow';
  }),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'multi-window phase $_phase',
    skip: _phase.isEmpty || !Platform.isLinux,
    (tester) async {
      await _launch(tester);
      switch (_phase) {
        case 'save':
          await _save(tester);
        case 'restore':
          await _restore(tester);
        case 'buttons':
          await _buttons(tester);
        case 'bisect':
          await _bisect(tester);
        case 'churn':
          await _churn(tester);
        case 'last':
          await _last(tester);
        default:
          fail('No phase $_phase');
      }
    },
  );
}

/// 5, the first half: two windows with their own tabs and frames, and a
/// third that is closed again before the app goes.
Future<void> _save(WidgetTester tester) async {
  var ids = await _windowsAre(tester, 1);
  _trace('save step 1');
  await _xdo(['windowmove', ids[0], '20', '20']);
  _trace('save step 2');
  await _xdo(['windowsize', ids[0], '600', '450']);
  _trace('save step 3');
  await _until(tester, () => _views().isNotEmpty, 'A to be drawn');
  _trace('save step 4');
  var a = _views().single;
  _trace('save step 5');
  await _click(tester, ids[0], a, await _first(tester, _card, a, 'the card'));
  _trace('save step 6');
  await _until(tester, () => _in(_tabClose, a).length == 1, 'A\'s shell tab');
  _trace('save step 7');

  await _newWindow(tester, ids[0], 2);
  _trace('save step 8');
  ids = await _windows();
  final views = _views();
  _trace('save step 9');
  a = views[0];
  await _xdo(['windowmove', ids[1], '650', '40']);
  _trace('save step 10');
  await _xdo(['windowsize', ids[1], '600', '450']);
  _trace('save step 11');
  // A third window, closed again before the app goes.
  await _newWindow(tester, ids[1], 3);
  _trace('save step 12');
  ids = await _windows();
  final c = _views()[2];
  _trace('save step 13');
  await _click(
    tester,
    ids[2],
    c,
    await _first(tester, _close, c, 'C\'s Close'),
  );
  _trace('save step 14');
  await _windowsAre(tester, 2);
  _trace('save step 15');
  await tester.pump(const Duration(seconds: 3));
  _trace('save step 16');

  ids = await _windows();
  final rects = [for (final id in ids) await _rect(id)];
  _trace('save step 17');
  debugPrint('multi-window: saved frames $rects, tabs A 1, B 0');
  _note('save').writeAsStringSync(rects.join('\n'));
}

/// 5, the second: back as they were.
Future<void> _restore(WidgetTester tester) async {
  final ids = await _windowsAre(tester, 2);
  // Negative: C, closed before the quit, stays closed.
  await tester.pump(const Duration(seconds: 4));
  expect(await _windows(), hasLength(2), reason: 'a closed window came back');
  final saved = _note('save').readAsLinesSync();
  final now = [for (final id in ids) await _rect(id)];
  debugPrint('multi-window: frames now $now, saved $saved');
  expect(now, saved, reason: 'a window did not come back at its own frame');
  await _until(tester, () => _views().length == 2, 'a view a window');
  final views = _views();
  await _until(
    tester,
    () => _in(_tabClose, views[0]).length == 1 && _in(_tabClose, views[1]).isEmpty,
    'A\'s one tab and B\'s none (now ${_in(_tabClose, views[0]).length} and '
    '${_in(_tabClose, views[1]).length})',
  );
  debugPrint('multi-window: A has 1 tab, B has none, as saved');
}

/// 7: B's buttons act on B.
Future<void> _buttons(WidgetTester tester) async {
  final ids = await _windowsAre(tester, 2);
  await _until(tester, () => _views().length == 2, 'a view a window');
  final views = _views();
  final b = views[1];
  final aRect = await _rect(ids[0]);

  await _click(
    tester,
    ids[1],
    b,
    await _first(tester, _semantic('Maximize'), b, 'B\'s Maximize'),
  );
  await _until(
    tester,
    () async => (await _state(ids[1])).contains('MAXIMIZED'),
    'B to maximize (${await _state(ids[1])})',
  );
  expect(await _state(ids[0]), isNot(contains('MAXIMIZED')), reason: 'A too');
  debugPrint('multi-window: B ${await _state(ids[1])}; A ${await _state(ids[0])}');

  await _click(
    tester,
    ids[1],
    b,
    await _first(tester, _semantic('Minimize'), b, 'B\'s Minimize'),
  );
  await _until(
    tester,
    () async => (await _state(ids[1])).startsWith('IsUnMapped'),
    'B to minimize (${await _state(ids[1])})',
  );
  expect((await _state(ids[0])).startsWith('IsViewable'), isTrue,
      reason: 'A was minimized with B: ${await _state(ids[0])}');
  expect(await _rect(ids[0]), aRect, reason: 'A moved or changed size');
  debugPrint('multi-window: B minimized ${await _state(ids[1])}, '
      'A ${await _state(ids[0])}');

  // Back, and its Close closes it alone.
  await _xdo(['windowmap', ids[1]]);
  await _xdo(['windowactivate', ids[1]]);
  await _until(
    tester,
    () async => (await _state(ids[1])).startsWith('IsViewable'),
    'B to come back',
  );
  await _click(
    tester,
    ids[1],
    b,
    await _first(tester, _close, b, 'B\'s Close'),
  );
  // Its tabs were never connected in this run, so there is nothing to ask.
  await _windowsAre(tester, 1);
  expect(await _windows(), [ids[0]], reason: 'the wrong window closed');
  expect(_in(_semantic('Close'), views[0]), isNotEmpty);
  debugPrint('multi-window: B closed, A is the one left');
}

/// 6 and the negative of 4: closing the first window while the second is
/// open moves the second into the first's X window — its frame, its tabs, the
/// same shell — and closes the second's own; a new window by the key; and the
/// last window closing with no question and the process going.
Future<void> _last(WidgetTester tester) async {
  // Every error reported from here on, in the trace: a handover frame that
  // threw would explain a frame that never ends.
  final wasOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    _trace('FlutterError: ${details.exceptionAsString().split('\n').first}');
    _trace('  stack: ${'${details.stack}'.split('\n').take(6).join(' | ')}');
    wasOnError?.call(details);
  };
  final wasPlatform = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    _trace('PlatformDispatcher: ${'$error'.split('\n').first}');
    return wasPlatform?.call(error, stack) ?? false;
  };
  var ids = await _windowsAre(tester, 1);
  var a = _views().single;
  // A live shell in A, so closing it is asked.
  await _click(tester, ids[0], a, await _first(tester, _card, a, 'the card'));
  await _until(tester, () => _in(_tabClose, a).length == 1, 'A\'s shell tab');
  await tester.pump(const Duration(seconds: 3));
  await _newWindow(tester, ids[0], 2);
  ids = await _windows();
  final views = _views();
  a = views[0];
  final b = views[1];
  final xa = ids[0];
  final xb = ids[1];
  _trace('A and B open');

  // A shell in B, and its process id kept.
  await _click(tester, xb, b, await _first(tester, _card, b, 'B\'s card'));
  await _until(tester, () => _in(_tabClose, b).length == 1, 'a tab in B');
  TerminalView shellIn(int view) =>
      _in(find.byType(TerminalView), view).first.widget as TerminalView;
  await _until(
    tester,
    () =>
        _in(find.byType(TerminalView), b).isNotEmpty &&
        _drew(shellIn(b)),
    'B\'s shell to draw its prompt',
  );
  final pid1 = _note('pid1');
  if (pid1.existsSync()) pid1.deleteSync();
  shellIn(b).terminal.textInput('echo \$\$ > ${pid1.path}');
  shellIn(b).terminal.keyInput(TerminalKey.enter);
  await _until(
    tester,
    () => pid1.existsSync() && pid1.readAsStringSync().trim().isNotEmpty,
    'B\'s shell to write its process id',
  );
  final bRect = await _rect(xb);
  // The control for the pixel check below: a window that paints changes
  // its pixels when a command is typed into it.
  final before = await _grabWindow(bRect, 'control1');
  shellIn(b).terminal.textInput('echo JEANSH_CONTROL');
  shellIn(b).terminal.keyInput(TerminalKey.enter);
  await tester.pump(const Duration(seconds: 1));
  await Future<void>.delayed(const Duration(seconds: 1));
  final after = await _grabWindow(bRect, 'control2');
  final controlChanged =
      before != null && after != null && !_same(before, after);
  _trace('control: a window that paints changed its pixels: $controlChanged');
  _trace('B has a shell, pid ${pid1.readAsStringSync().trim()}, frame $bRect');

  // Close the first window: asked, as it holds a live shell.
  await _click(tester, xa, a, await _first(tester, _close, a, 'A\'s Close'));
  await _until(
    tester,
    () => _in(find.byType(TuiDialog), a).isNotEmpty,
    'the question before A closes',
  );
  await _click(
    tester,
    xa,
    a,
    await _first(tester, _button('Close window'), a, 'Close window'),
  );
  await _windowsAre(tester, 1);
  _trace('one window left');

  // Positive: window 0's own X window is the one left, at B's old frame.
  final left = await _windows();
  // An experiment only watches: what it changes is what is looked at.
  final strict = (Platform.environment['JEANSH_WIN_EXPERIMENT'] ?? '').isEmpty;
  if (strict) expect(left, [xa], reason: 'the window left is not the first one: $left');
  final now = await _rect(xa);
  _trace('the first window is at $now, B was at $bRect');
  if (strict) expect(now, bRect, reason: 'the first window is not at B\'s old frame');
  // Negative: nothing left over, mapped or not, parked or not.
  final all = await Process.run('xdotool', ['search', '--name', r'^Jeansh']);
  final named = '${all.stdout}'.trim().split('\n').where((x) => x.isNotEmpty);
  _trace('windows named Jeansh*, mapped or not: ${named.length}');
  if (strict) expect(named, hasLength(1), reason: 'a window is left over: $named');

  // Frames come, and B's tab is in window 0, the same shell.
  final frame = await _pumps(tester);
  _trace('a frame after the first window closed: $frame');
  _trace(
    'views: ${[
      for (final v in PlatformDispatcher.instance.views) '${v.viewId} ${v.physicalSize}',
    ]}, first View keys: ${_views()}',
  );
  _trace(
    'framesEnabled ${WidgetsBinding.instance.framesEnabled}, lifecycle '
    '${WidgetsBinding.instance.lifecycleState}',
  );
  for (final line in appLog.current
      .split('\n')
      .where((l) => l.contains('lifecycle'))
      .toList()
      .reversed
      .take(8)
      .toList()
      .reversed) {
    _trace('app log: $line');
  }
  if (!frame) {
    // No frame: is the window dead to input too, or only the test's frames
    // gone? A click in its middle (the shell's tab fills it) and a command
    // typed, answered by a file, with no pump waited for.
    IntegrationTestWidgetsFlutterBinding.instance
            .shouldPropagateDevicePointerEvents =
        true;
    final size = now.split(' ');
    final dead = _note('alive-no-frames');
    if (dead.existsSync()) dead.deleteSync();
    await _xdo(['windowfocus', xa]);
    await _xdo([
      'mousemove',
      '--window',
      xa,
      '${int.parse(size[2]) ~/ 2}',
      '${int.parse(size[3]) ~/ 2}',
      'sleep',
      '0.3',
      'click',
      '1',
    ]);
    await Future<void>.delayed(const Duration(seconds: 1));
    await _xdo(['type', '--delay', '30', 'touch ${dead.path}']);
    await _xdo(['key', 'Return']);
    var up = false;
    for (var i = 0; i < 100 && !up; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      up = dead.existsSync();
    }
    _trace('with no frames, the first window answered real input: $up');
    // And does the window repaint? Its pixels before a visible command and
    // after, compared.
    final shot1 = await _grabWindow(now, 'paint1');
    await _xdo(['type', '--delay', '30', 'echo JEANSH_PAINT_CHECK']);
    await _xdo(['key', 'Return']);
    await _pumps(tester);
    await Future<void>.delayed(const Duration(seconds: 2));
    final shot2 = await _grabWindow(now, 'paint2');
    _trace(
      'the window\'s pixels changed after a command was typed: '
      '${shot1 != null && shot2 != null && !_same(shot1, shot2)} '
      '(${shot1?.length} and ${shot2?.length} bytes)',
    );
    fail('no frame came after the first window closed (input answered: $up)');
  }
  await _until(tester, () => _in(_tabClose, 0).length == 1, 'B\'s tab in window 0');
  await _until(
    tester,
    () => _in(find.byType(TerminalView), 0).isNotEmpty,
    'B\'s terminal in window 0',
  );
  // Real input: a click on the terminal and a command typed to it, answered
  // by a file; no pump is waited for.
  final box = _in(find.byType(TerminalView), 0).first.renderObject! as RenderBox;
  final at = box.localToGlobal(box.size.center(Offset.zero));
  final ratio = tester.binding.platformDispatcher.view(id: 0)!.devicePixelRatio;
  final binding = IntegrationTestWidgetsFlutterBinding.instance;
  binding.shouldPropagateDevicePointerEvents = true;
  final pid2 = _note('pid2');
  if (pid2.existsSync()) pid2.deleteSync();
  await _xdo(['windowfocus', xa]);
  await _xdo([
    'mousemove',
    '--window',
    xa,
    '${(at.dx * ratio).round()}',
    '${(at.dy * ratio).round()}',
    'sleep',
    '0.3',
    'click',
    '1',
  ]);
  await Future<void>.delayed(const Duration(seconds: 1));
  await _xdo(['type', '--delay', '30', 'echo \$\$ > ${pid2.path}']);
  await _xdo(['key', 'Return']);
  var answered = false;
  for (var i = 0; i < 100 && !answered; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    answered = pid2.existsSync() && pid2.readAsStringSync().trim().isNotEmpty;
  }
  binding.shouldPropagateDevicePointerEvents = false;
  _trace('window 0 answered real input: $answered');
  expect(answered, isTrue, reason: 'window 0 did not answer real input');
  expect(
    pid2.readAsStringSync().trim(),
    pid1.readAsStringSync().trim(),
    reason: 'the shell was not the same one: it was started again',
  );
  _trace('the same shell, pid ${pid2.readAsStringSync().trim()}');

  // The key then opens a window as it always does, and it closes again.
  await _newWindow(tester, xa, 2);
  ids = await _windows();
  final nowViews = _views();
  expect(nowViews, hasLength(2));
  await _click(
    tester,
    ids[1],
    nowViews[1],
    await _first(tester, _close, nowViews[1], 'the new window\'s Close'),
  );
  await _windowsAre(tester, 1);
  _trace('a new window opened and closed');

  // The last window, holding a live shell: nothing is asked, and the
  // process ends. A watcher outside it says when.
  final marker = _note('last');
  if (marker.existsSync()) marker.deleteSync();
  await Process.start('sh', [
    '-c',
    'while kill -0 $pid 2>/dev/null; do sleep 0.1; done; '
        'echo ended >> ${marker.path}',
  ], mode: ProcessStartMode.detached);
  marker.writeAsStringSync('ready\n', mode: FileMode.append);
  await _click(tester, xa, 0, await _first(tester, _close, 0, 'the last Close'));
  final asked = _in(find.byType(TuiDialog), 0).isNotEmpty;
  if (asked) marker.writeAsStringSync('asked\n', mode: FileMode.append);
  // No frame is waited for: the window may be gone, and a pump would wait.
  await Future<void>.delayed(const Duration(seconds: 3));
  marker.writeAsStringSync(
    'windows left ${(await _windows()).length}\n',
    mode: FileMode.append,
  );
  await Future<void>.delayed(const Duration(seconds: 20));
}

/// 10 rounds of A, B and C opened and closed, C first: the sequence that
/// sometimes ended the whole app. The app is still here after each, and the
/// script counts the rounds from the trace.
Future<void> _churn(WidgetTester tester) async {
  const rounds = 10;
  var ids = await _windowsAre(tester, 1);
  for (var round = 1; round <= rounds; round++) {
    await _newWindow(tester, ids[0], 2);
    ids = await _windows();
    await _newWindow(tester, ids[1], 3);
    ids = await _windows();
    final views = _views();
    await _click(
      tester,
      ids[2],
      views[2],
      await _first(tester, _close, views[2], 'C\'s Close'),
    );
    await _windowsAre(tester, 2);
    ids = await _windows();
    final left = _views();
    await _click(
      tester,
      ids[1],
      left[1],
      await _first(tester, _close, left[1], 'B\'s Close'),
    );
    ids = await _windowsAre(tester, 1);
    _trace('churn round $round done');
  }
}

bool _drew(TerminalView view) {
  final lines = view.terminal.buffer.lines;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].getText().trim().isNotEmpty) return true;
  }
  return false;
}

/// The window's pixels, [rect] being "x y w h", as the PNG ffmpeg grabs from
/// the display; null when it cannot.
Future<List<int>?> _grabWindow(String rect, String name) async {
  final r = rect.split(' ');
  final file = File('${_dir.path}/jeansh-e2e-mw-$name.png');
  final done = await Process.run('ffmpeg', [
    '-loglevel', 'error', '-y', '-f', 'x11grab', '-draw_mouse', '0', //
    '-video_size', '${r[2]}x${r[3]}', //
    '-i', '${Platform.environment['DISPLAY']}+${r[0]},${r[1]}', //
    '-frames:v', '1', file.path,
  ]);
  if (done.exitCode != 0 || !file.existsSync()) {
    debugPrint('multi-window: grab failed: ${done.stderr}');
    return null;
  }
  return file.readAsBytesSync();
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// What makes the first window's close stall the frames, when the second's
/// does not: which window closes (BISECT_TARGET A or B), whether it holds a
/// live shell (BISECT_LIVE 1 or 0), and how (BISECT_HOW button, the app's
/// own ✕, or wm, the window manager's delete). The answer is one trace line.
Future<void> _bisect(WidgetTester tester) async {
  final target = Platform.environment['BISECT_TARGET'] ?? 'A';
  final live = Platform.environment['BISECT_LIVE'] == '1';
  final how = Platform.environment['BISECT_HOW'] ?? 'button';
  var ids = await _windowsAre(tester, 1);
  final a0 = _views().single;
  if (live && target == 'A') {
    await _click(tester, ids[0], a0, await _first(tester, _card, a0, 'A\'s card'));
    await _until(tester, () => _in(_tabClose, a0).length == 1, 'A\'s shell tab');
    await tester.pump(const Duration(seconds: 3));
  }
  await _newWindow(tester, ids[0], 2);
  ids = await _windows();
  final views = _views();
  final a = views[0];
  final b = views[1];
  if (live && target == 'B') {
    await _click(tester, ids[1], b, await _first(tester, _card, b, 'B\'s card'));
    await _until(tester, () => _in(_tabClose, b).length == 1, 'B\'s shell tab');
    await tester.pump(const Duration(seconds: 3));
  }
  final x = target == 'A' ? ids[0] : ids[1];
  final v = target == 'A' ? a : b;
  if (how == 'button') {
    await _click(tester, x, v, await _first(tester, _close, v, 'its Close'));
  } else {
    await _xdo(['windowfocus', x]);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _xdo(['key', 'alt+F4']);
  }
  if (live) {
    await _until(
      tester,
      () => _in(find.byType(TuiDialog), v).isNotEmpty,
      'the question before the window closes',
    );
    await _click(
      tester,
      x,
      v,
      await _first(tester, _button('Close window'), v, 'Close window'),
    );
  }
  // Counted with no pump, which may not come back.
  var windows = 99;
  var pumped = true;
  for (var i = 0; i < 100 && windows != 1; i++) {
    pumped = await _pumps(tester) && pumped;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    windows = (await _windows()).length;
  }
  _trace('the pump came back throughout the close: $pumped');
  final frame = await _pumps(tester);
  _trace(
    'bisect target=$target live=${live ? 1 : 0} how=$how windows=$windows '
    'frame=$frame',
  );
}

/// Whether the test's own pump comes back: the binding draws only when it
/// is pumped, so this, and not a frame waited for, says whether frames work.
Future<bool> _pumps(WidgetTester tester) => Future.any([
  tester.pump(const Duration(milliseconds: 50)).then((_) => true),
  Future<bool>.delayed(const Duration(seconds: 10), () => false),
]);
