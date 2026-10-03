import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app_log.dart';

/// The keys and pastes the app log records, and nothing a keylogger would.
///
/// **Only a key that types nothing is a line**: Home, End, the arrows and the
/// other named keys, and a Ctrl or ⌘ chord. A key whose event carries a
/// printable character is never recorded, which keeps AltGr and Option
/// combinations out (they make a character), and so does anything an IME is
/// composing, which arrives as no named key at all. While an obscured field
/// has the focus nothing is recorded, not even Backspace.
///
/// A paste is recorded by where, its kind and its amount, never its content or
/// a file's name.
class InputLog {
  InputLog(this.log, {this.settle = const Duration(milliseconds: 400)});

  final AppLog log;

  /// How long a key may be quiet before its line is written, so a held key or
  /// a run of the same one is a single line with a count.
  final Duration settle;

  String? _label;
  var _count = 0;
  Timer? _timer;

  static final _named = <LogicalKeyboardKey, String>{
    LogicalKeyboardKey.home: 'Home',
    LogicalKeyboardKey.end: 'End',
    LogicalKeyboardKey.pageUp: 'PageUp',
    LogicalKeyboardKey.pageDown: 'PageDown',
    LogicalKeyboardKey.arrowUp: 'Up',
    LogicalKeyboardKey.arrowDown: 'Down',
    LogicalKeyboardKey.arrowLeft: 'Left',
    LogicalKeyboardKey.arrowRight: 'Right',
    LogicalKeyboardKey.escape: 'Escape',
    LogicalKeyboardKey.tab: 'Tab',
    LogicalKeyboardKey.enter: 'Enter',
    LogicalKeyboardKey.numpadEnter: 'Enter',
    LogicalKeyboardKey.backspace: 'Backspace',
    LogicalKeyboardKey.delete: 'Delete',
    LogicalKeyboardKey.insert: 'Insert',
    LogicalKeyboardKey.f1: 'F1',
    LogicalKeyboardKey.f2: 'F2',
    LogicalKeyboardKey.f3: 'F3',
    LogicalKeyboardKey.f4: 'F4',
    LogicalKeyboardKey.f5: 'F5',
    LogicalKeyboardKey.f6: 'F6',
    LogicalKeyboardKey.f7: 'F7',
    LogicalKeyboardKey.f8: 'F8',
    LogicalKeyboardKey.f9: 'F9',
    LogicalKeyboardKey.f10: 'F10',
    LogicalKeyboardKey.f11: 'F11',
    LogicalKeyboardKey.f12: 'F12',
  };

  /// The line a key event would be, or null when it must not be recorded.
  /// Pure, so the tests drive it without a keyboard.
  static String? labelOf(
    KeyEvent event, {
    required bool ctrl,
    required bool alt,
    required bool meta,
    required bool shift,
  }) {
    if (event is KeyUpEvent) return null;
    // A key that made a character is typing, AltGr and Option included. The
    // control characters a named key or a chord makes are not, and a Ctrl or
    // ⌘ chord without Alt types nothing even where the platform names the
    // letter as its character, as GTK does for Ctrl+V.
    final char = event.character;
    final types =
        char != null && char.codeUnits.any((u) => u >= 0x20 && u != 0x7f);
    // mutation
    final name = _named[event.logicalKey];
    final chord = ctrl || meta;
    // Ctrl with Alt is how Windows and Linux spell AltGr, and Option alone on
    // a Mac makes dead keys that carry no character: only a named key is
    // safe with Alt.
    if (alt && name == null && (!chord || ctrl)) return null;
    // mutation
    final key = name ?? _chordKey(event.logicalKey);
    if (key == null) return null;
    return [
      if (ctrl) 'Ctrl',
      if (alt) 'Alt',
      if (meta) 'Meta',
      if (shift) 'Shift',
      key,
    ].join('+');
  }

  /// A chord's key: a letter or digit by its label, a modifier alone never.
  static String? _chordKey(LogicalKeyboardKey key) {
    final label = key.keyLabel;
    return label.length == 1 ? label.toUpperCase() : null;
  }

  /// Where focus is: the part of the app a key went to.
  static String whereOf(BuildContext? focus) {
    if (focus == null) return 'app';
    var where = 'app';
    var editable = false;
    void see(Widget w) {
      if (w is EditableText) editable = true;
      if (where != 'app') return;
      where = switch (w.runtimeType.toString()) {
        'TerminalView' => 'terminal',
        'ChatPage' => 'chat',
        'FileEditorPage' || 'TuiCodeEditor' => 'editor',
        _ => 'app',
      };
    }

    see(focus.widget);
    focus.visitAncestorElements((e) {
      see(e.widget);
      return true;
    });
    return where == 'app' && editable ? 'field' : where;
  }

  /// Whether the focus is on an obscured field.
  static bool obscured(BuildContext? focus) {
    if (focus == null) return false;
    if (focus.widget case EditableText(obscureText: true)) return true;
    var found = false;
    focus.visitAncestorElements((e) {
      if (e.widget case EditableText(obscureText: true)) found = true;
      return !found;
    });
    return found;
  }

  /// A handler for [HardwareKeyboard]; never consumes the event.
  bool onKey(KeyEvent event) {
    final focus = FocusManager.instance.primaryFocus?.context;
    if (obscured(focus)) return false;
    final keys = HardwareKeyboard.instance;
    final label = labelOf(
      event,
      ctrl: keys.isControlPressed,
      alt: keys.isAltPressed,
      meta: keys.isMetaPressed,
      shift: keys.isShiftPressed,
    );
    if (label == null) return false;
    final where = whereOf(focus);
    if (_pasteChord(event, keys) && (where == 'field' || where == 'editor')) {
      paste(where, 'text');
    }
    _note('$label ($where)');
    return false;
  }

  bool _pasteChord(KeyEvent event, HardwareKeyboard keys) =>
      event is KeyDownEvent &&
      ((event.logicalKey == LogicalKeyboardKey.keyV &&
              (keys.isControlPressed || keys.isMetaPressed)) ||
          (event.logicalKey == LogicalKeyboardKey.insert &&
              keys.isShiftPressed));

  void _note(String label) {
    if (label != _label) flush();
    _label = label;
    _count++;
    _timer?.cancel();
    _timer = Timer(settle, flush);
  }

  /// Writes the key being held, with how many times it came.
  void flush() {
    _timer?.cancel();
    final label = _label;
    if (label == null) return;
    log.add('key $label${_count > 1 ? ' ×$_count' : ''}');
    _label = null;
    _count = 0;
  }

  /// A paste: where it went, what kind and how much. [amount] is characters
  /// for text and a count for pictures and files. A paste the app does not do
  /// itself has none: the clipboard is never read for the log.
  void paste(String where, String kind, [int? amount]) {
    flush();
    log.add('paste $kind${amount == null ? '' : ' $amount'} ($where)');
  }
}

/// The app's one.
final inputLog = InputLog(appLog);

var _muted = 0;

/// Records a paste, unless inside [mutePasteLog].
void logPaste(String where, String kind, [int? amount]) {
  if (_muted == 0) inputLog.paste(where, kind, amount);
}

/// Runs [body] with [logPaste] silent: a paste recorded once already under
/// its true kind (a dropped path goes through the terminal's text paste).
T mutePasteLog<T>(T Function() body) {
  _muted++;
  try {
    return body();
  } finally {
    _muted--;
  }
}

/// Starts the key log. Safe to call again: a test binding drops the
/// keyboard's handlers between tests, and `main` runs once in each.
void watchKeys() {
  HardwareKeyboard.instance
    ..removeHandler(inputLog.onKey)
    ..addHandler(inputLog.onKey);
}

/// Logs the route a dialog, menu or sheet opens as, never what it shows.
class LogRoutes extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _note('open', route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _note('close', route);

  void _note(String what, Route<dynamic> route) {
    final kind = route is PopupRoute ? 'popup' : 'page';
    appLog.add('route $what $kind ${route.runtimeType}');
  }
}
