// What xdotool is on Linux, for the Windows job: windows found, focused, moved
// and clicked in, and keys pressed, by Win32 calls made from inside the app's
// own process. The windows are the app's own, so nothing here needs another
// process or a session helper; the keys and clicks are the real input queue's
// (keybd_event and mouse_event), so a window gets them as it gets a hand's.
//
// Only Windows loads this: every function is behind `Platform.isWindows`.

import 'dart:ffi';

import 'package:ffi/ffi.dart';

final _user32 = DynamicLibrary.open('user32.dll');

final _findWindowEx = _user32
    .lookupFunction<
      IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
      int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)
    >('FindWindowExW');
final _isWindowVisible = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'IsWindowVisible',
    );
final _getWindowRect = _user32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Int32>),
      int Function(int, Pointer<Int32>)
    >('GetWindowRect');
final _clientToScreen = _user32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Int32>),
      int Function(int, Pointer<Int32>)
    >('ClientToScreen');
final _setForegroundWindow = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'SetForegroundWindow',
    );
final _showWindow = _user32
    .lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>(
      'ShowWindow',
    );
final _setCursorPos = _user32
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
      'SetCursorPos',
    );
final _mouseEvent = _user32
    .lookupFunction<
      Void Function(Uint32, Uint32, Uint32, Uint32, UintPtr),
      void Function(int, int, int, int, int)
    >('mouse_event');
final _keybdEvent = _user32
    .lookupFunction<
      Void Function(Uint8, Uint8, Uint32, UintPtr),
      void Function(int, int, int, int)
    >('keybd_event');
final _getCursorPos = _user32
    .lookupFunction<
      Int32 Function(Pointer<Int32>),
      int Function(Pointer<Int32>)
    >('GetCursorPos');
final _getForegroundWindow = _user32
    .lookupFunction<IntPtr Function(), int Function()>('GetForegroundWindow');
final _mapVirtualKey = _user32
    .lookupFunction<Uint32 Function(Uint32, Uint32), int Function(int, int)>(
      'MapVirtualKeyW',
    );
final _moveWindow = _user32
    .lookupFunction<
      Int32 Function(IntPtr, Int32, Int32, Int32, Int32, Int32),
      int Function(int, int, int, int, int, int)
    >('MoveWindow');

/// Jeansh's visible top-level windows, oldest handle first.
List<String> winWindows() {
  final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  final title = 'Jeansh'.toNativeUtf16();
  try {
    final found = <int>[];
    var at = 0;
    for (var i = 0; i < 64; i++) {
      at = _findWindowEx(0, at, cls, title);
      if (at == 0) break;
      if (_isWindowVisible(at) != 0) found.add(at);
    }
    found.sort();
    return [for (final h in found) '$h'];
  } finally {
    calloc.free(cls);
    calloc.free(title);
  }
}

/// "x y width height" of the window, in physical pixels on the screen.
String winRect(String id) {
  final r = calloc<Int32>(4);
  try {
    _getWindowRect(int.parse(id), r);
    return '${r[0]} ${r[1]} ${r[2] - r[0]} ${r[3] - r[1]}';
  } finally {
    calloc.free(r);
  }
}

/// The window brought to the front and given the keys: Windows lets a process
/// take the foreground when it has just seen an Alt press, which is why one
/// is made first.
bool winFocus(String id) {
  final h = int.parse(id);
  _showWindow(h, 9);
  _keybdEvent(0x12, _mapVirtualKey(0x12, 0), 0, 0);
  _setForegroundWindow(h);
  _keybdEvent(0x12, _mapVirtualKey(0x12, 0), 2, 0);
  return _getForegroundWindow() == h;
}

/// The window that has the keyboard now.
String winForeground() => '${_getForegroundWindow()}';

/// A click at [x], [y] in the window's own client area, in physical pixels:
/// the pointer put there, a move made so the window sees it arrive, and then
/// the button down and up.
Future<void> winClick(String id, int x, int y, {int button = 1}) async {
  final h = int.parse(id);
  final p = calloc<Int32>(2);
  try {
    _clientToScreen(h, p);
    _setCursorPos(p[0] + x, p[1] + y);
  } finally {
    calloc.free(p);
  }
  _mouseEvent(0x0001, 0, 0, 0, 0);
  await Future<void>.delayed(const Duration(milliseconds: 150));
  final (down, up) = button == 3 ? (0x08, 0x10) : (0x02, 0x04);
  _mouseEvent(down, 0, 0, 0, 0);
  await Future<void>.delayed(const Duration(milliseconds: 60));
  _mouseEvent(up, 0, 0, 0, 0);
}

/// Moves and sizes the window, `null` keeping what it has.
void winPlace(String id, {int? x, int? y, int? width, int? height}) {
  final h = int.parse(id);
  final r = winRect(id).split(' ').map(int.parse).toList();
  _moveWindow(h, x ?? r[0], y ?? r[1], width ?? r[2], height ?? r[3], 1);
}

const _keys = {
  'ctrl': 0x11,
  'shift': 0x10,
  'alt': 0x12,
  'return': 0x0D,
  'equal': 0xBB,
  'f4': 0x73,
};

/// A chord as xdotool names it, `ctrl+shift+n`, pressed and released.
void winKey(String chord) {
  final parts = chord.split('+');
  final codes = <int>[];
  for (final part in parts) {
    final name = part.toLowerCase();
    final known = _keys[name];
    if (known != null) {
      codes.add(known);
    } else if (name.length == 1) {
      codes.add(name.toUpperCase().codeUnitAt(0));
    } else {
      throw ArgumentError('no key called $part');
    }
  }
  // With scan codes, as a keyboard sends them: Flutter's embedder names the
  // physical key from the scan code.
  for (final code in codes) {
    _keybdEvent(code, _mapVirtualKey(code, 0), 0, 0);
  }
  for (final code in codes.reversed) {
    _keybdEvent(code, _mapVirtualKey(code, 0), 2, 0);
  }
}

/// Where the pointer is, in screen pixels.
String winCursor() {
  final p = calloc<Int32>(2);
  try {
    _getCursorPos(p);
    return '${p[0]},${p[1]}';
  } finally {
    calloc.free(p);
  }
}
