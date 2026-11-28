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

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sshbox/main.dart' as app;

import 'mac_desk.dart';
import 'win_desk.dart';

import 'package:sshbox/src/telemetry/app_log.dart' show appLog;
import 'package:xterm2/xterm.dart' show TerminalKey, TerminalView;
import 'package:sshbox/src/ui/termul/tui_button.dart' show TuiButton;
import 'package:sshbox/src/ui/termul/tui_dialog.dart' show TuiDialog;
import 'package:sshbox/src/ui/text_size.dart' show uiTextSize;

const _phase = String.fromEnvironment('JEANSH_E2E_MWINDOW');

/// Where one run tells the next what it left, and the last run tells the
/// script what it saw.
final _dir = Directory(
  Platform.environment['JEANSH_E2E_MW_DIR'] ?? Directory.systemTemp.path,
);
File _note(String name) => File('${_dir.path}/jeansh-e2e-mw-$name.txt');

/// The shell's process id written to [file]: sh's `$$`, PowerShell's `$PID`.
String _pidCommand(File file) => Platform.isWindows
    ? '\$PID | Out-File -Encoding ascii "${file.path}"'
    : 'echo \$\$ > ${file.path}';

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
  if (Platform.isWindows) return _xdoWindows(args);
  if (Platform.isMacOS) return _xdoMac(args);
  // A time limit: `windowfocus --sync` waits for ever on a window that holds
  // the focus already.
  final result = await Process.run('timeout', ['15', 'xdotool', ...args]);
  expect(result.exitCode, 0, reason: 'xdotool $args: ${result.stderr}');
  return '${result.stdout}'.trim();
}

/// The view whose window the next click is aimed at (the click's height in
/// points is the view's, the title bar being above it).
int _clickView = 0;

final _windowsChannel = const MethodChannel('sshbox/windows');

/// The runner's ids of the windows by their number: the first window is 0
/// and each one opened after it takes the next, as the runner counts them. A
/// window is given its id when first seen, which is in the order they opened.
final _macIds = <String, int>{};
int _macNext = 0;

int _macRunnerId(String number) {
  final id = _macIds[number];
  if (id == null) fail('window $number has no runner id: $_macIds');
  return id;
}

/// Moves and sizes a window through the runner's own `place`, which takes the
/// frame with its origin at the bottom left of the screen.
Future<void> _macPlace(
  String number, {
  int? x,
  int? y,
  int? width,
  int? height,
}) async {
  final r = (await macRect(number)).split(' ').map(int.parse).toList();
  final (_, screenHeight) = await macScreen();
  final w = width ?? r[2];
  final h = height ?? r[3];
  final top = y ?? r[1];
  await _windowsChannel.invokeMethod<void>('place', {
    'id': _macRunnerId(number),
    'x': (x ?? r[0]).toDouble(),
    'y': (screenHeight - top - h).toDouble(),
    'width': w.toDouble(),
    'height': h.toDouble(),
  });
}

/// What xdotool calls this file makes, on macOS: see mac_desk.dart. The chords
/// are the Mac's own: Cmd+N opens a window where Ctrl+Shift+N does elsewhere,
/// Cmd+= zooms where Ctrl+= does.
Future<String> _xdoMac(List<String> a) async {
  switch (a.first) {
    case 'windowfocus':
      await _windowsChannel.invokeMethod<void>('activate', _macRunnerId(a[1]));
    case 'mousemove':
      final at = a.indexOf('--window');
      final x = int.parse(a[at + 2]);
      final y = int.parse(a[at + 3]);
      await Future<void>.delayed(
        Duration(
          milliseconds: (double.parse(a[a.indexOf('sleep') + 1]) * 1000)
              .round(),
        ),
      );
      final view = PlatformDispatcher.instance.view(id: _clickView)!;
      final ratio = view.devicePixelRatio;
      await macClick(
        a[at + 1],
        x / ratio,
        y / ratio,
        view.physicalSize.height / ratio,
        button: int.parse(a.last),
      );
    case 'key':
      final chord = switch (a[1]) {
        'ctrl+shift+n' => 'cmd+n',
        'ctrl+equal' => 'cmd+equal',
        final other => other,
      };
      _trace('key $chord');
      await macKey(chord);
    case 'windowmove':
      await _macPlace(a[1], x: int.parse(a[2]), y: int.parse(a[3]));
    case 'windowsize':
      await _macPlace(a[1], width: int.parse(a[2]), height: int.parse(a[3]));
    default:
      throw UnsupportedError('no macOS version of xdotool ${a.first}');
  }
  return '';
}

/// What xdotool calls this file makes, on Windows: see win_desk.dart.
Future<String> _xdoWindows(List<String> a) async {
  switch (a.first) {
    case 'windowfocus':
      final got = winFocus(a[1]);
      if (!got) {
        _trace(
          '${a[1]} did not take the foreground; ${winForeground()} has it',
        );
      }
    case 'mousemove':
      // mousemove --window ID X Y sleep S click B
      final at = a.indexOf('--window');
      final x = int.parse(a[at + 2]);
      final y = int.parse(a[at + 3]);
      await Future<void>.delayed(
        Duration(
          milliseconds: (double.parse(a[a.indexOf('sleep') + 1]) * 1000)
              .round(),
        ),
      );
      await winClick(a[at + 1], x, y, button: int.parse(a.last));
    case 'key':
      _trace('key ${a[1]}, foreground ${winForeground()}');
      winKey(a[1]);
    case 'windowmove':
      winPlace(a[1], x: int.parse(a[2]), y: int.parse(a[3]));
    case 'windowsize':
      winPlace(a[1], width: int.parse(a[2]), height: int.parse(a[3]));
    default:
      throw UnsupportedError('no Windows version of xdotool ${a.first}');
  }
  return '';
}

/// Where the two windows stand: side by side on Linux's 1280 wide display, and
/// within the 1024 wide screen of the Windows runner, where a window placed
/// further right has its buttons off the screen.
final _aX = Platform.isWindows ? '10' : (Platform.isMacOS ? '20' : '20');
final _aY = Platform.isWindows ? '10' : (Platform.isMacOS ? '60' : '20');
final _aW = Platform.isWindows ? '490' : (Platform.isMacOS ? '520' : '600');
final _aH = '450';
final _bX = Platform.isWindows ? '520' : (Platform.isMacOS ? '560' : '650');
final _bY = Platform.isWindows ? '10' : (Platform.isMacOS ? '60' : '40');
final _bW = Platform.isWindows ? '490' : (Platform.isMacOS ? '520' : '600');
final _bH = '450';

/// The Windows windows in the order they were first seen.
final _winOrder = <String>[];

Future<List<String>> _windows() async {
  if (Platform.isWindows || Platform.isMacOS) {
    // Oldest first, as the order they were first seen in: a window made later
    // can have a smaller handle than the first.
    final now = Platform.isWindows ? winWindows() : await macWindows();
    _winOrder.removeWhere((h) => !now.contains(h));
    for (final h in now) {
      if (!_winOrder.contains(h)) {
        _winOrder.add(h);
        if (Platform.isMacOS) _macIds[h] = _macIds.isEmpty ? 0 : ++_macNext;
      }
    }
    return List.of(_winOrder);
  }
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
  try {
    await _until(tester, () async {
      ids = await _windows();
      return ids.length == count;
    }, '$count windows');
  } on TestFailure {
    _trace('wanted $count windows, saw ${ids.length}: $ids');
    rethrow;
  }
  debugPrint('multi-window: $count windows: $ids');
  return ids;
}

/// A window's place and size as X reports them, the same way both times.
Future<String> _rect(String id) async {
  if (Platform.isWindows) return winRect(id);
  if (Platform.isMacOS) return macRect(id);
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

/// The views with a window, as the ones holding the tab strip: a Mac window's
/// Close is the title bar's own, not the app's.
List<int> _views() => {
  for (final e
      in (Platform.isMacOS
              ? find.byWidgetPredicate(
                  (w) => w is Tooltip && w.message == 'Home',
                )
              : _close)
          .evaluate())
    View.of(e).viewId,
}.toList()..sort();

/// A window's own close: the app's Close button where it draws one, ⌘W on a
/// Mac, whose title bar is the system's.
Future<void> _clickClose(WidgetTester tester, String xid, int viewId) async {
  if (Platform.isMacOS) {
    await _xdo(['windowfocus', xid]);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _xdo(['key', 'cmd+w']);
    await tester.pump(const Duration(milliseconds: 400));
    return;
  }
  await _clickClose(tester, xid, viewId);
}

List<Element> _in(Finder finder, int viewId) => [
  for (final e in finder.evaluate())
    if (View.of(e).viewId == viewId) e,
];

Future<Element> _first(
  WidgetTester tester,
  Finder f,
  int view,
  String what,
) async {
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
  _clickView = viewId;
  final binding = IntegrationTestWidgetsFlutterBinding.instance;
  final ratio = tester.binding.platformDispatcher
      .view(id: viewId)!
      .devicePixelRatio;
  final box = target.renderObject! as RenderBox;
  final at = box.localToGlobal(box.size.center(Offset.zero));
  binding.shouldPropagateDevicePointerEvents = true;
  final seen = <String>[];
  void heard(PointerEvent e) {
    if (e is PointerDownEvent || e is PointerUpEvent) {
      seen.add('${e.runtimeType} view ${e.viewId} at ${e.position}');
    }
  }

  if (Platform.isWindows) {
    GestureBinding.instance.pointerRouter.addGlobalRoute(heard);
  }
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
    if (Platform.isWindows) {
      _trace(
        'click: aimed at ${at.dx.round()},${at.dy.round()} in view $viewId of '
        'window $xid (${winRect(xid)}, ratio $ratio), the pointer is at '
        '${winCursor()}; the app saw $seen',
      );
    }
  } finally {
    binding.shouldPropagateDevicePointerEvents = false;
    if (Platform.isWindows) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(heard);
    }
  }
}

Future<void> _newWindow(WidgetTester tester, String from, int count) async {
  await _xdo(['windowfocus', from]);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await _xdo(['key', 'ctrl+shift+n']);
  final ids = await _windowsAre(tester, count);
  await _until(tester, () => _views().length == count, 'a view a window');
  // A third window opens at the runner's own size, which on Windows is wider
  // than the screen, its buttons off it: it is put inside, over the others.
  if (count == 3 && (Platform.isWindows || Platform.isMacOS)) {
    await _xdo(['windowmove', ids[2], '260', '300']);
    await _xdo(['windowsize', ids[2], '490', '400']);
    await tester.pump(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
  }
  // Side by side, so a click in one lands on it and not on the one over it.
  if (count == 2) {
    await _xdo(['windowmove', ids[1], _bX, _bY]);
    await _xdo(['windowsize', ids[1], _bW, _bH]);
    await _xdo(['windowmove', ids[0], _aX, _aY]);
    await _xdo(['windowsize', ids[0], _aW, _aH]);
    // Both windows laid out at their new size before anything is clicked: a
    // click aimed at where a button was before the resize lands beside it.
    await tester.pump(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
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
  // The first window's view is 0 where the engine has an implicit view, and
  // the first one added on a Mac, whose runner turns the engine's views on.
  if (Platform.isMacOS) {
    await _until(tester, () => _views().isNotEmpty, 'the first window\'s view');
    _view0 = _views().first;
    _trace('the first window\'s view is $_view0');
  }
}

/// The view of the first window.
int _view0 = 0;

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
    skip:
        _phase.isEmpty ||
        !(Platform.isLinux || Platform.isWindows || Platform.isMacOS),
    (tester) async {
      await _launch(tester);
      // The app log's `win:` lines are written to the trace as they come, so a
      // process that ends leaves them behind (a failure prints them again).
      var seen = 0;
      final follow = Timer.periodic(const Duration(milliseconds: 200), (_) {
        final wins = appLog.current
            .split('\n')
            .where((l) => l.contains('win:') && !l.contains('multi-window:'))
            .toList();
        for (final line in wins.skip(seen)) {
          _trace('live app log: $line');
        }
        seen = wins.length;
      });
      // On Windows and macOS: a pointer packet for a view the test binding has no
      // render view for throws `Bad state: No element` from flutter_test's
      // LiveTestWidgetsFlutterBinding.handlePointerEvent (a firstWhere), where
      // the product's RendererBinding.hitTestInView does `_viewIdToRenderView
      // [viewId]?.hitTest`, so an unknown view is no error. Only that error,
      // from that frame, is let through, and each one is counted and traced.
      var tolerated = 0;
      final previous = FlutterError.onError;
      if (Platform.isWindows || Platform.isMacOS) {
        FlutterError.onError = (details) {
          final ex = details.exception;
          if (ex is StateError &&
              ex.message == 'No element' &&
              '${details.stack}'.contains(
                'LiveTestWidgetsFlutterBinding.handlePointerEvent',
              )) {
            tolerated++;
            _trace('tolerated Bad state: No element (#$tolerated, harness)');
            return;
          }
          previous?.call(details);
        };
      }
      try {
        await _runPhase(tester);
        _trace('phase $_phase done, bad state tolerated: $tolerated');
      } catch (_) {
        _trace('phase $_phase failed, bad state tolerated: $tolerated');
        // What the app's own log says of every close, from the click on.
        final wins = appLog.current
            .split('\n')
            .where((l) => l.contains('win:'))
            .toList();
        for (final line in wins.skip(wins.length > 80 ? wins.length - 80 : 0)) {
          _trace('app log: $line');
        }
        rethrow;
      } finally {
        follow.cancel();
        FlutterError.onError = previous;
      }
    },
  );
}

Future<void> _runPhase(WidgetTester tester) async {
  switch (_phase) {
    case 't1':
      await _t1(tester);
    case 't2':
      await _t2(tester);
    case 't3':
      await _t3(tester);
    case 't4':
      await _t4(tester);
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
    case 'drop':
      await _drop(tester);
    case 'last':
      await _last(tester);
    default:
      fail('No phase $_phase');
  }
}

/// 5, the first half: two windows with their own tabs and frames, and a
/// third that is closed again before the app goes.
Future<void> _save(WidgetTester tester) async {
  var ids = await _windowsAre(tester, 1);
  _trace('save step 1');
  await _xdo(['windowmove', ids[0], _aX, _aY]);
  _trace('save step 2');
  await _xdo(['windowsize', ids[0], _aW, _aH]);
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
  await _xdo(['windowmove', ids[1], _bX, _bY]);
  _trace('save step 10');
  await _xdo(['windowsize', ids[1], _bW, _bH]);
  _trace('save step 11');
  // A third window, closed again before the app goes. Not on Windows, where
  // closing a third window ends the whole app (run 46043697301): the case
  // this phase is for there is the two windows' frames.
  if (!Platform.isWindows) {
    await _newWindow(tester, ids[1], 3);
    _trace('save step 12');
    ids = await _windows();
    final c = _views()[2];
    _trace('save step 13');
    await _clickClose(tester, ids[2], c);
    _trace('save step 14');
    await _windowsAre(tester, 2);
    _trace('save step 15');
  }
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
  // On Windows the windows are listed by first sight, which for windows that
  // came up together is by handle, so the two frames are matched as a set.
  final asSet = Platform.isWindows || Platform.isMacOS;
  expect(
    asSet ? (List.of(now)..sort()) : now,
    asSet ? (List.of(saved)..sort()) : saved,
    reason: 'a window did not come back at its own frame',
  );
  await _until(tester, () => _views().length == 2, 'a view a window');
  final views = _views();
  await _until(
    tester,
    () =>
        _in(_tabClose, views[0]).length == 1 &&
        _in(_tabClose, views[1]).isEmpty,
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
  debugPrint(
    'multi-window: B ${await _state(ids[1])}; A ${await _state(ids[0])}',
  );

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
  expect(
    (await _state(ids[0])).startsWith('IsViewable'),
    isTrue,
    reason: 'A was minimized with B: ${await _state(ids[0])}',
  );
  expect(await _rect(ids[0]), aRect, reason: 'A moved or changed size');
  debugPrint(
    'multi-window: B minimized ${await _state(ids[1])}, '
    'A ${await _state(ids[0])}',
  );

  // Back, and its Close closes it alone.
  await _xdo(['windowmap', ids[1]]);
  await _xdo(['windowactivate', ids[1]]);
  await _until(
    tester,
    () async => (await _state(ids[1])).startsWith('IsViewable'),
    'B to come back',
  );
  await _clickClose(tester, ids[1], b);
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
    () => _in(find.byType(TerminalView), b).isNotEmpty && _drew(shellIn(b)),
    'B\'s shell to draw its prompt',
  );
  final pid1 = _note('pid1');
  if (pid1.existsSync()) pid1.deleteSync();
  shellIn(b).terminal.textInput(_pidCommand(pid1));
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
  await _clickClose(tester, xa, a);
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
  if (strict) {
    expect(left, [xa], reason: 'the window left is not the first one: $left');
  }
  final now = await _rect(xa);
  _trace('the first window is at $now, B was at $bRect');
  if (strict) {
    expect(now, bRect, reason: 'the first window is not at B\'s old frame');
  }
  // Negative: nothing left over, mapped or not, parked or not.
  final named = Platform.isMacOS
      ? await macWindows(all: true)
      : Platform.isWindows
      ? winWindows()
      : '${(await Process.run('xdotool', ['search', '--name', r'^Jeansh'])).stdout}'
            .trim()
            .split('\n')
            .where((x) => x.isNotEmpty);
  _trace('windows named Jeansh*, mapped or not: ${named.length}');
  if (strict) {
    expect(named, hasLength(1), reason: 'a window is left over: $named');
  }

  // Frames come, and B's tab is in window 0, the same shell.
  final frame = await _pumps(tester);
  _trace('a frame after the first window closed: $frame');
  _trace(
    'views: ${[for (final v in PlatformDispatcher.instance.views) '${v.viewId} ${v.physicalSize}']}, first View keys: ${_views()}',
  );
  _trace(
    'framesEnabled ${WidgetsBinding.instance.framesEnabled}, lifecycle '
    '${WidgetsBinding.instance.lifecycleState}',
  );
  for (final line
      in appLog.current
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
    IntegrationTestWidgetsFlutterBinding
            .instance
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
  await _until(
    tester,
    () => _in(_tabClose, _view0).length == 1,
    'B\'s tab in window 0',
  );
  await _until(
    tester,
    () => _in(find.byType(TerminalView), _view0).isNotEmpty,
    'B\'s terminal in window 0',
  );
  // Real input: a click on the terminal and a command typed to it, answered
  // by a file; no pump is waited for.
  final box =
      _in(find.byType(TerminalView), _view0).first.renderObject! as RenderBox;
  final at = box.localToGlobal(box.size.center(Offset.zero));
  final ratio = tester.binding.platformDispatcher
      .view(id: _view0)!
      .devicePixelRatio;
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
  if (Platform.isWindows || Platform.isMacOS) {
    // The job has no keyboard layer that types text: the command goes
    // to the terminal as the key bar's would, after the real click above.
    final term =
        _in(find.byType(TerminalView), _view0).first.widget as TerminalView;
    term.terminal.textInput(_pidCommand(pid2));
    term.terminal.keyInput(TerminalKey.enter);
  } else {
    await _xdo(['type', '--delay', '30', _pidCommand(pid2)]);
    await _xdo(['key', 'Return']);
  }
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
  await _clickClose(tester, ids[1], nowViews[1]);
  await _windowsAre(tester, 1);
  _trace('a new window opened and closed');

  // The last window, holding a live shell: nothing is asked, and the
  // process ends. A watcher outside it says when.
  final marker = _note('last');
  if (marker.existsSync()) marker.deleteSync();
  await Process.start(
    Platform.isWindows ? 'powershell' : 'sh',
    Platform.isWindows
        ? [
            '-NoProfile',
            '-Command',
            'while (Get-Process -Id $pid -ErrorAction SilentlyContinue) '
                '{ Start-Sleep -Milliseconds 100 }; '
                'Add-Content -Path "${marker.path}" -Value ended',
          ]
        : [
            '-c',
            'while kill -0 $pid 2>/dev/null; do sleep 0.1; done; '
                'echo ended >> ${marker.path}',
          ],
    mode: ProcessStartMode.detached,
  );
  marker.writeAsStringSync('ready\n', mode: FileMode.append);
  await _clickClose(tester, xa, _view0);
  final asked = _in(find.byType(TuiDialog), _view0).isNotEmpty;
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
    await _clickClose(tester, ids[2], views[2]);
    await _windowsAre(tester, 2);
    ids = await _windows();
    final left = _views();
    await _clickClose(tester, ids[1], left[1]);
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
  if (Platform.isWindows || Platform.isMacOS) return null;
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
    await _click(
      tester,
      ids[0],
      a0,
      await _first(tester, _card, a0, 'A\'s card'),
    );
    await _until(
      tester,
      () => _in(_tabClose, a0).length == 1,
      'A\'s shell tab',
    );
    await tester.pump(const Duration(seconds: 3));
  }
  await _newWindow(tester, ids[0], 2);
  ids = await _windows();
  final views = _views();
  final a = views[0];
  final b = views[1];
  if (live && target == 'B') {
    await _click(
      tester,
      ids[1],
      b,
      await _first(tester, _card, b, 'B\'s card'),
    );
    await _until(tester, () => _in(_tabClose, b).length == 1, 'B\'s shell tab');
    await tester.pump(const Duration(seconds: 3));
  }
  final x = target == 'A' ? ids[0] : ids[1];
  final v = target == 'A' ? a : b;
  if (how == 'button') {
    await _clickClose(tester, x, v);
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

// ---- Phases 1 to 4: the first checks, a process each. app.main() is not
// run twice in one process on a runner that opens windows, so these were not
// tests of the smoke file, where the second one met an app already started.

int _caretN(TerminalView view) {
  final lines = view.terminal.buffer.lines;
  var count = 0;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].getText().trim() == '^N') count++;
  }
  return count;
}

/// The second window closed by its own ✕, so the next phase starts from one.
Future<void> _closeSecond(WidgetTester tester) async {
  final ids = await _windows();
  final views = _views();
  await _clickClose(tester, ids[1], views[1]);
  await _windowsAre(tester, 1);
}

Future<void> _openSecond(WidgetTester tester) async {
  final ids = await _windowsAre(tester, 1);
  await _newWindow(tester, ids[0], 2);
}

/// 1. Ctrl+Shift+N opens a second window; plain Ctrl+N is the shell's key and
/// opens none, the terminal hearing it as ^N.
Future<void> _t1(WidgetTester tester) async {
  var ids = await _windowsAre(tester, 1);
  if (Platform.isWindows) {
    // The shell is PowerShell, where Ctrl+N is not an sh ^N to read back, so
    // only the key that opens is checked here.
    await _newWindow(tester, ids[0], 2);
    _trace('t1: Ctrl+Shift+N opened a second window: 2 windows (Windows)');
    await _closeSecond(tester);
    return;
  }
  final a0 = _views().single;
  await _click(tester, ids[0], a0, await _first(tester, _card, a0, 'the card'));
  await _until(tester, () => _in(_tabClose, a0).length == 1, 'a shell tab');
  TerminalView term() =>
      _in(find.byType(TerminalView), a0).first.widget as TerminalView;
  await _until(
    tester,
    () => _in(find.byType(TerminalView), a0).isNotEmpty && _drew(term()),
    'the shell to draw its prompt',
  );
  // No echo, so a ^N the tty drew itself is not read as the shell's.
  term().terminal.textInput('stty -echo; cat -v');
  term().terminal.keyInput(TerminalKey.enter);
  await tester.pump(const Duration(milliseconds: 500));

  // Negative: plain Ctrl+N.
  await _xdo(['windowfocus', ids[0]]);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await _xdo(['key', 'ctrl+n']);
  await _xdo(['key', 'Return']);
  await _until(tester, () => _caretN(term()) == 1, 'Ctrl+N to reach the shell');
  await tester.pump(const Duration(seconds: 2));
  expect(await _windows(), hasLength(1), reason: 'Ctrl+N opened a window');
  expect(_views(), hasLength(1));
  _trace('t1: Ctrl+N reached the shell as ^N and opened no window');

  // Positive: Ctrl+Shift+N, from the real main.
  await _newWindow(tester, ids[0], 2);
  ids = await _windows();
  _trace('t1: Ctrl+Shift+N opened a second window: ${ids.length} windows');
  // And the first window's terminal heard nothing of it.
  await _xdo(['windowfocus', ids[0]]);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await _xdo(['key', 'Return']);
  await tester.pump(const Duration(seconds: 1));
  expect(_caretN(term()), 1, reason: 'the terminal got ^N from Ctrl+Shift+N');
  _trace('t1: the terminal heard nothing of Ctrl+Shift+N');
  await _closeSecond(tester);
}

/// 2. The UI text size changed in A shows in B at once, and B's tabs are as
/// they were.
Future<void> _t2(WidgetTester tester) async {
  await uiTextSize.choose(1);
  await _openSecond(tester);
  final ids = await _windows();
  final views = _views();
  final a = views[0];
  final b = views[1];
  // What 100 px of text comes to in that window: its text scaler, which is
  // what the UI text size sets, read where the tab strip's text is.
  double scale(int view) =>
      MediaQuery.textScalerOf(_in(find.text('Home'), view).first).scale(100);
  await _until(
    tester,
    () =>
        _in(find.text('Home'), a).isNotEmpty &&
        _in(find.text('Home'), b).isNotEmpty,
    'Home in both windows',
  );
  final a0 = scale(a);
  final b0 = scale(b);
  List<String> texts(int view) => [
    for (final e in _in(find.byType(Text), view))
      if ((e.widget as Text).data case final t?)
        // Not a toast, and not the spinner's glyph, which turns.
        if (!t.startsWith('UI text size') && t.length > 1) t,
  ];
  final tabsB = texts(b);
  _trace('t2: 100 px of text is $a0 in A and $b0 in B');

  await _xdo(['windowfocus', ids[0]]);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await _xdo(['key', 'ctrl+equal']);
  await _xdo(['key', 'ctrl+equal']);
  await _until(tester, () => uiTextSize.value > 1.0, 'Ctrl+= to zoom');
  await tester.pump(const Duration(milliseconds: 800));
  _trace('t2: 100 px of text is now ${scale(a)} in A and ${scale(b)} in B');
  expect(scale(a), greaterThan(a0), reason: 'A did not grow');
  expect(scale(b), greaterThan(b0), reason: 'B did not show the new size');
  // Negative: B's tabs and rows are the same ones.
  expect(texts(b), tabsB, reason: 'B\'s tabs or rows changed');
  await uiTextSize.choose(1);
  await tester.pump(const Duration(seconds: 1));
  await Future<void>.delayed(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
  await _closeSecond(tester);
}

/// 3. A Local shell tab opened in A is not in B, whose Home still lists the
/// host.
Future<void> _t3(WidgetTester tester) async {
  await _openSecond(tester);
  final ids = await _windows();
  final views = _views();
  final a = views[0];
  final b = views[1];
  await _first(tester, _card, b, 'B\'s card');
  expect(_in(_tabClose, a), isEmpty);
  expect(_in(_tabClose, b), isEmpty);
  await _click(tester, ids[0], a, await _first(tester, _card, a, 'A\'s card'));
  await _until(
    tester,
    () => _in(_tabClose, a).length == 1,
    'a Local shell tab in A',
    timeout: const Duration(seconds: 30),
  );
  await tester.pump(const Duration(seconds: 2));
  _trace(
    't3: A has ${_in(_tabClose, a).length} tab, B has '
    '${_in(_tabClose, b).length}, B\'s Home lists the host '
    '${_in(_card, b).length} time',
  );
  // Negative: B shows no tab of it, and its Home still lists the host.
  expect(_in(_card, b), hasLength(1));
  expect(_in(_tabClose, b), isEmpty, reason: 'B has a tab');
  // Back to nothing: A's tab closed, then the second window.
  await _click(tester, ids[0], a, _in(_tabClose, a).first);
  await _until(tester, () => _in(_tabClose, a).isEmpty, 'A\'s tab to close');
  await _closeSecond(tester);
}

/// 4. Closing B while it holds a live shell asks first: Keep it keeps B and
/// its shell, Close window closes B and leaves A.
Future<void> _t4(WidgetTester tester) async {
  await _openSecond(tester);
  final ids = await _windows();
  final views = _views();
  final a = views[0];
  final b = views[1];
  await _click(tester, ids[1], b, await _first(tester, _card, b, 'B\'s card'));
  await _until(tester, () => _in(_tabClose, b).length == 1, 'a tab in B');
  await _until(
    tester,
    () =>
        _in(find.byType(TerminalView), b).isNotEmpty &&
        _drew(_in(find.byType(TerminalView), b).first.widget as TerminalView),
    'the shell in B to draw its prompt',
  );
  await tester.pump(const Duration(seconds: 1));

  Future<void> closeB() async => _clickClose(tester, ids[1], b);
  // Asked, and Keep it keeps B and its shell.
  await closeB();
  await _until(
    tester,
    () => _in(find.byType(TuiDialog), b).isNotEmpty,
    'the question before B closes',
  );
  expect(_in(find.textContaining('Close this window?'), b), isNotEmpty);
  await _click(
    tester,
    ids[1],
    b,
    await _first(tester, _button('Keep it'), b, 'Keep it'),
  );
  await tester.pump(const Duration(seconds: 2));
  expect(await _windows(), hasLength(2), reason: 'B closed on Keep it');
  expect(_in(find.byType(TuiDialog), b), isEmpty);
  expect(_in(_tabClose, b), hasLength(1), reason: 'B lost its shell');
  _trace('t4: Keep it kept B and its shell');

  // Asked again, and Close window closes B alone.
  await closeB();
  await _until(
    tester,
    () => _in(find.byType(TuiDialog), b).isNotEmpty,
    'the question again',
  );
  await _click(
    tester,
    ids[1],
    b,
    await _first(tester, _button('Close window'), b, 'Close window'),
  );
  await _windowsAre(tester, 1);
  expect(_in(find.text('Home'), a), isNotEmpty, reason: 'A is gone too');
  _trace('t4: Close window closed B alone');
}

/// A GTK window offering a file for a drag, as a file manager does, below the
/// two windows (which sit in the display's top 500 rows).
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

String _shellText(TerminalView view) {
  final lines = view.terminal.buffer.lines;
  return [for (var i = 0; i < lines.length; i++) lines[i].getText()].join('\n');
}

/// A file dropped on the second window lands in that window's tab, the shell
/// there being handed its path, and the first window's tab gets nothing. Three
/// drops, each said as it is: on the first window alone (what has always
/// worked), on the first window with a second open, and on the second.
Future<void> _drop(WidgetTester tester) async {
  var ids = await _windowsAre(tester, 1);
  final a0 = _views().single;
  await _click(
    tester,
    ids[0],
    a0,
    await _first(tester, _card, a0, 'A\'s card'),
  );
  await _until(tester, () => _in(_tabClose, a0).length == 1, 'A\'s shell tab');
  TerminalView shellIn(int view) =>
      _in(find.byType(TerminalView), view).first.widget as TerminalView;
  await _until(
    tester,
    () => _in(find.byType(TerminalView), a0).isNotEmpty && _drew(shellIn(a0)),
    'A\'s shell to draw its prompt',
  );
  final dir = Directory.systemTemp.createTempSync('jeansh-e2e-drop-');

  // One file, dragged with the X pointer from a source window of its own to
  // the middle of the window whose id is [target].
  Future<void> dragTo(File file, String target) async {
    final source = File('${dir.path}/drag_${file.uri.pathSegments.last}.py')
      ..writeAsStringSync(_dragSource);
    final process = await Process.start('python3', [source.path, file.path]);
    try {
      final sourceId = (await _xdo([
        'search',
        '--sync',
        '--onlyvisible',
        '--name',
        r'^e2e drag source$',
      ])).split('\n').first;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final geometry = await _xdo(['getwindowgeometry', '--shell', sourceId]);
      int geo(String key) =>
          int.parse(RegExp('$key=(-?\\d+)').firstMatch(geometry)!.group(1)!);
      final sx = geo('X') + geo('WIDTH') ~/ 2;
      final sy = geo('Y') + geo('HEIGHT') ~/ 2;
      final r = (await _rect(target)).split(' ').map(int.parse).toList();
      final cx = r[0] + r[2] ~/ 2;
      final cy = r[1] + r[3] ~/ 2;
      await _xdo(['mousemove', '$sx', '$sy']);
      await _xdo(['mousedown', '1']);
      for (final (x, y) in [
        (sx + 10, sy - 5),
        (sx + 30, sy - 20),
        (sx + 200, sy - 150),
        (cx - 200, cy + 150),
        (cx - 5, cy - 5),
        (cx, cy),
        (cx + 5, cy + 5),
      ]) {
        await _xdo(['mousemove', '$x', '$y']);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await tester.pump();
      }
      await _xdo(['mouseup', '1']);
      await tester.pump(const Duration(milliseconds: 500));
    } finally {
      process.kill();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  /// Whether [name] reached the shell of [view] within a few seconds.
  Future<bool> reached(int view, String name) async {
    final end = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(end)) {
      if (_shellText(shellIn(view)).contains(name)) return true;
      await tester.pump(const Duration(milliseconds: 200));
    }
    return false;
  }

  File made(String name) => File('${dir.path}/$name')..writeAsStringSync('x');

  // 1. The first window alone: the drop that has always worked.
  await dragTo(made('drop-one-alone.txt'), ids[0]);
  final alone = await reached(a0, 'drop-one-alone.txt');
  _trace('drop: on the first window alone: $alone');

  await _newWindow(tester, ids[0], 2);
  ids = await _windows();
  final views = _views();
  final a = views[0];
  final b = views[1];
  await _click(tester, ids[1], b, await _first(tester, _card, b, 'B\'s card'));
  await _until(tester, () => _in(_tabClose, b).length == 1, 'B\'s shell tab');
  await _until(
    tester,
    () => _in(find.byType(TerminalView), b).isNotEmpty && _drew(shellIn(b)),
    'B\'s shell to draw its prompt',
  );

  // 2. The first window with a second open.
  await dragTo(made('drop-two-first.txt'), ids[0]);
  final first = await reached(a, 'drop-two-first.txt');
  _trace('drop: on the first window, a second open: $first');

  // 3. The second window.
  await dragTo(made('drop-three-second.txt'), ids[1]);
  final second = await reached(b, 'drop-three-second.txt');
  final strayed = _shellText(shellIn(a)).contains('drop-three-second.txt');
  _trace(
    'drop: on the second window: $second; the first window got it too: '
    '$strayed',
  );

  // A real pointer crossing from one window to another can trip a debug
  // assertion of the framework's mouse tracker (added and removed events out
  // of turn between views). Said, not hidden, and the drops judged on their
  // own.
  final raised = tester.takeException();
  if (raised != null) {
    _trace(
      'drop: the framework raised during the drags: '
      '${'$raised'.split('\n').first}',
    );
  }
  expect(alone, isTrue, reason: 'a drop on the first window alone failed');
  expect(
    first,
    isTrue,
    reason: 'a drop on the first window, a second open, failed',
  );
  expect(
    second,
    isTrue,
    reason: 'a drop on the second window did not reach its shell',
  );
  expect(
    strayed,
    isFalse,
    reason: 'the first window\'s shell got the second\'s file',
  );
}
