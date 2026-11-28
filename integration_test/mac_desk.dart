// What xdotool is on Linux, for the macOS job: the app's windows found with
// their frames, real mouse and key events posted to the HID system, by the
// small tool tools/mw_mac_tool.swift (compiled by tools/e2e_desktop.sh and
// named by JEANSH_E2E_MW_TOOL). Run as a child of the app, so the events are
// posted under the same permissions the other macOS tests' swift scripts
// have. Frames are in points, origin at the top left of the main screen.
//
// Only macOS loads this: nothing here is called anywhere else.

import 'dart:io';

Future<String> _tool(List<String> args) async {
  final path = Platform.environment['JEANSH_E2E_MW_TOOL'];
  if (path == null || path.isEmpty) {
    throw StateError('JEANSH_E2E_MW_TOOL names no compiled mw_mac_tool');
  }
  final result = await Process.run(path, args);
  if (result.exitCode != 0) {
    throw StateError('mwtool $args: ${result.stdout} ${result.stderr}');
  }
  return '${result.stdout}'.trim();
}

/// This process's windows, oldest number first; with [all], those off the
/// screen too (a window taken off it by `orderOut`).
Future<List<String>> macWindows({bool all = false}) async {
  final out = await _tool(['windows', '$pid', if (all) 'all']);
  return [
    for (final line in out.split('\n'))
      if (line.trim().isNotEmpty) line.trim().split(' ').first,
  ];
}

/// "x y width height" of the window, in points.
Future<String> macRect(String number, {bool all = false}) async {
  final out = await _tool(['windows', '$pid', if (all) 'all']);
  for (final line in out.split('\n')) {
    final p = line.trim().split(' ');
    if (p.first == number) return p.skip(1).join(' ');
  }
  throw StateError('no window $number in: $out');
}

/// The main screen's size in points.
Future<(int, int)> macScreen() async {
  final p = (await _tool(['screen'])).split(' ');
  return (int.parse(p[0]), int.parse(p[1]));
}

/// A click at [x], [y] in the window's own view, which is [viewHeight] high.
Future<String> macClick(
  String number,
  double x,
  double y,
  double viewHeight, {
  int button = 1,
}) => _tool(['click', number, '$x', '$y', '$viewHeight', if (button == 3) '3']);

/// The red close button of the window at [rect] ("x y width height"), found
/// through the accessibility tree where the window's own buttons are, and
/// clicked with a real mouse click at its centre.
Future<String> macClickClose(String rect) async {
  final p = rect.split(' ').map(int.parse).toList();
  final script =
      '''
tell application "System Events" to tell process "Jeansh"
  repeat with w in windows
    set q to position of w
    if (item 1 of q) is ${p[0]} and (item 2 of q) is ${p[1]} then
      set b to first button of w whose subrole is "AXCloseButton"
      set bp to position of b
      set bs to size of b
      return ((item 1 of bp) + (item 1 of bs) / 2) & " " & ((item 2 of bp) + (item 2 of bs) / 2)
    end if
  end repeat
  return "none"
end tell
''';
  final found = await Process.run('osascript', ['-e', script]);
  final out = '${found.stdout}'.trim();
  if (found.exitCode != 0 || out == 'none' || out.isEmpty) {
    throw StateError('no close button for $rect: $out ${found.stderr}');
  }
  final at = out.split(RegExp(r'[ ,]+')).map(double.parse).toList();
  return _tool(['clickat', '${at[0]}', '${at[1]}']);
}

/// A chord such as `cmd+shift+n`, pressed and released.
Future<void> macKey(String chord) async {
  await _tool(['key', chord]);
}

/// Every window line of this process, the off-screen ones too, as the tool
/// prints them; for a failure's trace.
Future<String> macDump() async {
  final on = await _tool(['windows', '$pid']);
  final all = await _tool(['dump', '$pid']);
  final screen = await _tool(['screen']);
  return 'on screen: ${on.replaceAll('\n', ' | ')}; screen $screen; '
      'all: ${all.replaceAll(RegExp(r'\s+'), ' ').replaceAll('# ', '| #')}';
}
