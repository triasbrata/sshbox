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

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sshbox/main.dart' as app;
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

/// 6 and the negative of 4: the first window closed while the second stays,
/// a new one by the key, and the last closing with no question and the
/// process going.
Future<void> _last(WidgetTester tester) async {
  var ids = await _windowsAre(tester, 1);
  _trace('step 1');
  var a = _views().single;
  _trace('step 2');
  // A live shell in A, so closing it is asked.
  await _click(tester, ids[0], a, await _first(tester, _card, a, 'the card'));
  _trace('step 3');
  await tester.pump(const Duration(seconds: 4));
  _trace('step 4');
  await _newWindow(tester, ids[0], 2);
  _trace('step 5');
  ids = await _windows();
  final views = _views();
  _trace('step 6');
  a = views[0];
  final b = views[1];
  _trace('step 7');
  final xa = ids[0];
  _trace('step 8');
  final xb = ids[1];
  _trace('step 9');

  // Where B's card is, kept for a click made with no frame to wait for.
  final bCard = await _first(tester, _card, b, 'B\'s card');
  final bBox = bCard.renderObject! as RenderBox;
  final bAt = bBox.localToGlobal(bBox.size.center(Offset.zero));
  final bRatio = tester.binding.platformDispatcher
      .view(id: b)!
      .devicePixelRatio;

  // Close the first window: asked, as it holds a live shell; then B works.
  await _click(tester, xa, a, await _first(tester, _close, a, 'A\'s Close'));
  _trace('step 10');
  await _until(
    tester,
    () => _in(find.byType(TuiDialog), a).isNotEmpty,
    'the question before A closes',
  );
  _trace('step 11');
  await _click(
    tester,
    xa,
    a,
    await _first(tester, _button('Close window'), a, 'Close window'),
  );
  _trace('step 12');
  await _windowsAre(tester, 1);
  _trace('step 13');
  // Frames still come with the first window hidden? A pump waits for one.
  WidgetsBinding.instance.scheduleFrame();
  final frame = await Future.any([
    WidgetsBinding.instance.endOfFrame.then((_) => true),
    Future<bool>.delayed(const Duration(seconds: 8), () => false),
  ]);
  _trace('a frame after the first window closed: $frame');
  if (!frame) {
    // No frame: so is B dead, or only the test's pump? A click on its card
    // and a command typed into the shell it opens, answered by a file.
    IntegrationTestWidgetsFlutterBinding.instance
            .shouldPropagateDevicePointerEvents =
        true;
    await _xdo(['windowfocus', xb]);
    await _xdo([
      'mousemove',
      '--window',
      xb,
      '${(bAt.dx * bRatio).round()}',
      '${(bAt.dy * bRatio).round()}',
      'sleep',
      '0.3',
      'click',
      '1',
    ]);
    await Future<void>.delayed(const Duration(seconds: 5));
    final alive = _note('b-alive');
    if (alive.existsSync()) alive.deleteSync();
    await _xdo(['type', '--delay', '30', 'touch ${alive.path}']);
    await _xdo(['key', 'Return']);
    var answered = false;
    for (var i = 0; i < 100 && !answered; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      answered = alive.existsSync();
    }
    _trace('B opened a shell and ran a command with no frames: $answered');
    fail(
      'no frame came after the first window was closed; the second '
      '${answered ? 'still works, so only frames to the test stopped' : 'is dead too'}',
    );
  }
  expect(await _windows(), [xb], reason: 'the wrong window is left');
  await _click(tester, xb, b, await _first(tester, _card, b, 'B\'s card'));
  _trace('step 14');
  await _until(tester, () => _in(_tabClose, b).length == 1, 'a tab in B');
  _trace('step 15');
  debugPrint('multi-window: A closed, B still opens a Local shell');

  // The key brings a window back, with Home.
  await _newWindow(tester, xb, 2);
  _trace('step 16');
  ids = await _windows();
  final revived = ids.firstWhere((id) => id != xb);
  _trace('step 17');
  await _until(
    tester,
    () => _in(find.text('Home'), 0).isNotEmpty,
    'Home in the new window',
  );
  _trace('step 18');
  expect(_in(_tabClose, 0), isEmpty, reason: 'the new window has A\'s old tab');
  debugPrint('multi-window: a new window is back with Home and no tabs');
  await _click(
    tester,
    revived,
    0,
    await _first(tester, _close, 0, 'the new window\'s Close'),
  );
  _trace('step 19');
  await _windowsAre(tester, 1);
  _trace('step 20');

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
  await _click(tester, xb, b, await _first(tester, _close, b, 'B\'s Close'));
  _trace('step 21');
  final asked = _in(find.byType(TuiDialog), b).isNotEmpty;
  _trace('step 22');
  if (asked) marker.writeAsStringSync('asked\n', mode: FileMode.append);
  // No frame is waited for: the window may be gone, and a pump would wait.
  await Future<void>.delayed(const Duration(seconds: 3));
  _trace('step 23');
  marker.writeAsStringSync(
    'windows left ${(await _windows()).length}\n',
    mode: FileMode.append,
  );
  _trace('step 24');
  await Future<void>.delayed(const Duration(seconds: 20));
  _trace('step 25');
}
