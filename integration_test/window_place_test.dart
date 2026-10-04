// The window comes back where it was, at the size it was, after the app is
// gone and started again — on the real desktop embedder, moved by the OS.
//
// A relaunch is a second run of the app, so this file runs once per phase,
// each started by tools/e2e_desktop.sh with --dart-define=JEANSH_E2E_WINDOW,
// in order, on the same data folder:
//
//   move       the OS moves and resizes the window; what it then is, is noted
//   restore    started again, it is there; then it is maximized (full screen
//              on a Mac, the green button's own)
//   maximized  started again, it is maximized, and restoring it gives back
//              the rectangle it had before
//   offscreen  the script has saved a rectangle off every screen: the window
//              comes back whole on the screen there is
//
// Each run ends with the app killed by flutter test rather than closed, which
// is how a restart into an update ends it too (exit()): what is kept has to
// be kept as it changes, not at close.

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sshbox/main.dart' as app;

/// Read at run time, not given as a --dart-define: a define is compiled in,
/// so each phase rebuilt the app, and the environment lets all four reuse one
/// build.
final _phase = Platform.environment['JEANSH_E2E_WINDOW'] ?? '';

/// Where one run tells the next what it left.
final _noted = File('${Directory.systemTemp.path}/jeansh-e2e-window.txt');

/// Where the window was moved to and how big, in the OS's own units: X's and
/// Win32's physical pixels, a Mac's points from the top left.
const _moved = Rect.fromLTWH(150, 110, 760, 520);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'the window comes back where it was ($_phase)',
    skip: _phase.isEmpty,
    (tester) async {
      await _launch(tester);
      final screen = await _screen();
      switch (_phase) {
        case 'move':
          await _place(_moved);
          await _settle(tester);
          final rect = await _rect();
          expect(rect.size, _moved.size, reason: 'the OS resized it to $rect');
          _note(rect);
        case 'restore':
          expect(
            await _rect(),
            _read(),
            reason: 'where the last run left it; kept: ${await _kept()}',
          );
          expect(await _maximized(), isFalse);
          await _maximize(tester, true);
          await _until(tester, _maximized, 'the window to maximize');
          await _settle(tester);
        case 'maximized':
          await _until(tester, _maximized, 'the window to come back maximized');
          final big = await _rect();
          expect(big.width, greaterThan(_moved.width), reason: '$big');
          await _maximize(tester, false);
          await _until(tester, () async => !await _maximized(), 'a restore');
          await _settle(tester);
          expect(await _rect(), _read(), reason: 'the size it had before');
        case 'offscreen':
          final rect = await _rect();
          expect(
            screen.intersect(rect),
            rect,
            reason: 'saved off every screen, it came back at $rect on $screen',
          );
        default:
          fail('No phase $_phase');
      }
    },
  );
}

/// Home, from a cold start; the first run's slides skipped.
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
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
}

Future<void> _until(
  WidgetTester tester,
  FutureOr<bool> Function() done,
  String what,
) async {
  final end = DateTime.now().add(const Duration(seconds: 20));
  while (!await done()) {
    if (DateTime.now().isAfter(end)) fail('Gave up waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pump();
  }
}

/// Past the half second the app waits before it writes, and some.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pump();
  }
}

void _note(Rect r) =>
    _noted.writeAsStringSync('${r.left} ${r.top} ${r.width} ${r.height}');

Rect _read() {
  final n = _noted.readAsStringSync().split(' ').map(double.parse).toList();
  return Rect.fromLTWH(n[0], n[1], n[2], n[3]);
}

Future<String> _run(String exe, List<String> args) async {
  final result = await Process.run(exe, args);
  expect(result.exitCode, 0, reason: '$exe $args: ${result.stderr}');
  return '${result.stdout}'.trim();
}

List<double> _numbers(String text) =>
    RegExp(r'-?\d+(\.\d+)?')
        .allMatches(text)
        .map((m) => double.parse(m[0]!))
        .toList();

/// What the app has kept, for a failure to show: the Mac's defaults, the
/// file elsewhere.
Future<String> _kept() async {
  if (!Platform.isMacOS) return 'see the data folder';
  final result = await Process.run('defaults', [
    'read',
    'dev.triasbrata.sshbox',
  ]);
  return '${result.stdout}';
}

/// Linux: X itself, through xdotool and xwininfo.
Future<String> _xWindow() async => (await _run('xdotool', [
  'search', '--onlyvisible', '--name', r'^Jeansh$', //
])).split('\n').first;

/// macOS: System Events, as the other Mac tests drive the menu.
Future<String> _mac(String command) => _run('osascript', [
  '-e',
  'tell application "System Events" to tell process "Jeansh" to $command',
]);

/// Windows: Win32 itself, from PowerShell.
Future<String> _win(String steps) async {
  final dir = Directory.systemTemp.createTempSync('jeansh-e2e-');
  try {
    final script = File('${dir.path}\\window.ps1')
      ..writeAsStringSync(_winScript);
    return await _run('powershell', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.path,
      steps, //
    ]);
  } finally {
    dir.deleteSync(recursive: true);
  }
}

const _winScript = r'''
param([string]$step)
$ErrorActionPreference = 'Stop'
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class W {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string c, string n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
[W]::SetProcessDPIAware() | Out-Null
$h = [W]::FindWindow('FLUTTER_RUNNER_WIN32_WINDOW', 'Jeansh')
if ($h -eq [IntPtr]::Zero) { throw 'no Jeansh window' }
$p = $step.Split(' ')
switch ($p[0]) {
  'place' { [W]::SetWindowPos($h, [IntPtr]::Zero, [int]$p[1], [int]$p[2], [int]$p[3], [int]$p[4], 0x14) | Out-Null }
  'rect' { $r = New-Object W+RECT; [W]::GetWindowRect($h, [ref]$r) | Out-Null; "$($r.L) $($r.T) $($r.R - $r.L) $($r.B - $r.T)" }
  'zoomed' { [W]::IsZoomed($h) }
  'screen' { "$([W]::GetSystemMetrics(76)) $([W]::GetSystemMetrics(77)) $([W]::GetSystemMetrics(78)) $([W]::GetSystemMetrics(79))" }
}
''';

Future<void> _place(Rect r) async {
  final [x, y, w, h] = [
    r.left,
    r.top,
    r.width,
    r.height,
  ].map((v) => '${v.round()}').toList();
  if (Platform.isLinux) {
    final id = await _xWindow();
    await _run('xdotool', ['windowsize', '--sync', id, w, h]);
    await _run('xdotool', ['windowmove', '--sync', id, x, y]);
  } else if (Platform.isWindows) {
    await _win('place $x $y $w $h');
  } else {
    await _mac('set position of window 1 to {$x, $y}');
    await _mac('set size of window 1 to {$w, $h}');
  }
}

Future<Rect> _rect() async {
  final List<double> n;
  if (Platform.isLinux) {
    final info = await _run('xwininfo', ['-id', await _xWindow()]);
    double value(String key) =>
        double.parse(RegExp('$key:\\s+(-?\\d+)').firstMatch(info)![1]!);
    n = [
      value('Absolute upper-left X'),
      value('Absolute upper-left Y'),
      value('Width'),
      value('Height'),
    ];
  } else if (Platform.isWindows) {
    n = _numbers(await _win('rect'));
  } else {
    n = _numbers(await _mac('get {position, size} of window 1'));
  }
  return Rect.fromLTWH(n[0], n[1], n[2], n[3]);
}

/// The whole screen, in the same units as [_rect].
Future<Rect> _screen() async {
  final List<double> n;
  if (Platform.isLinux) {
    final info = await _run('xwininfo', ['-root']);
    n = [
      0,
      0,
      ..._numbers(RegExp(r'-geometry (\S+)').firstMatch(info)![1]!).take(2),
    ];
  } else if (Platform.isWindows) {
    n = _numbers(await _win('screen'));
  } else {
    n = _numbers(
      await _run('osascript', [
        '-l', 'JavaScript', '-e', //
        'ObjC.import("AppKit"); var f = \$.NSScreen.mainScreen.frame; '
            '[0, 0, f.size.width, f.size.height].join(" ")',
      ]),
    );
  }
  return Rect.fromLTWH(n[0], n[1], n[2], n[3]);
}

/// Maximized on Linux and Windows, read off the app's own button, which the
/// window tells; full screen on a Mac, read off AppKit.
Future<bool> _maximized() async {
  if (Platform.isMacOS) {
    return await _mac('get value of attribute "AXFullScreen" of window 1') ==
        'true';
  }
  return _named('Restore').evaluate().isNotEmpty;
}

Future<void> _maximize(WidgetTester tester, bool on) async {
  if (Platform.isMacOS) {
    await _mac('set value of attribute "AXFullScreen" of window 1 to $on');
    return;
  }
  await tester.tap(_named(on ? 'Maximize' : 'Restore'));
  await tester.pump();
}

Finder _named(String label) => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.label == label,
);
