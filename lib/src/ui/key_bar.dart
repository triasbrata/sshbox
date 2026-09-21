import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart' show CodeLineEditingController;
import 'package:xterm2/xterm.dart';

import 'ctrl_click.dart' show hyperlinkIn;
import 'toast.dart';

/// Applications that request DECCKM (vim, less, many TUIs) expect the SS3
/// form; sending CSI there produces stray characters instead of movement.
String cursorKey(Terminal terminal, String finalChar) =>
    terminal.cursorKeysMode ? '\x1bO$finalChar' : '\x1b[$finalChar';

/// How far a drag must travel before it counts as a direction rather than a
/// wobble during a tap.
const _swipeDeadzone = 20.0;

/// The cursor key a drag of [offset] from where the finger landed stands for,
/// or null while it is still inside the deadzone.
String? swipeArrow(Offset offset) {
  if (offset.distance < _swipeDeadzone) return null;
  if (offset.dx.abs() > offset.dy.abs()) return offset.dx > 0 ? 'C' : 'D';
  return offset.dy > 0 ? 'B' : 'A';
}

/// Reach this far and holding still starts repeating; short of it the drag is
/// a single press however long you hold it, which is what you want when you
/// only meant to step one line.
const _swipeRepeatFrom = 60.0;

/// Reach this far and the repeat is as fast as it gets.
const _swipeFullSpeedFrom = 200.0;

/// Milliseconds between repeats while a drag of [distance] is held, or null
/// when the drag is still short enough to mean one press and no more.
///
/// The far end is deliberately unhurried: a held finger that runs away at
/// keyboard speed overshoots the line you were aiming for, and on a terminal
/// an overshoot costs you a trip back.
int? swipeRepeatMs(double distance) {
  if (distance < _swipeRepeatFrom) return null;

  final reach =
      ((distance - _swipeRepeatFrom) / (_swipeFullSpeedFrom - _swipeRepeatFrom))
          .clamp(0.0, 1.0);
  return (2000 - reach * 1700).round();
}

/// How many chevrons the readout shows for a drag of [distance]: one for the
/// nudge that will not repeat, then one more for each step up in speed.
int swipeSpeedLevel(double distance) {
  final interval = swipeRepeatMs(distance);
  if (interval == null) return 1;
  return interval > 1000 ? 2 : 3;
}

/// The idle arms of the readout, and the chevrons the live one is drawn with.
const _swipeArmIcons = <String, IconData>{
  'A': Icons.arrow_upward,
  'B': Icons.arrow_downward,
  'C': Icons.arrow_forward,
  'D': Icons.arrow_back,
};

const _swipeChevronIcons = <String, IconData>{
  'A': Icons.keyboard_arrow_up,
  'B': Icons.keyboard_arrow_down,
  'C': Icons.keyboard_arrow_right,
  'D': Icons.keyboard_arrow_left,
};

/// Holds the sticky modifier state shared by the key bar and the terminal's
/// outgoing data path.
class KeyBarController extends ChangeNotifier {
  bool _ctrl = false;
  bool _alt = false;

  bool get ctrl => _ctrl;
  bool get alt => _alt;

  void toggleCtrl() {
    _ctrl = !_ctrl;
    notifyListeners();
  }

  void toggleAlt() {
    _alt = !_alt;
    notifyListeners();
  }

  void _disarm() {
    if (!_ctrl && !_alt) return;
    _ctrl = false;
    _alt = false;
    notifyListeners();
  }

  /// Folds any armed modifier into text the soft keyboard just produced.
  ///
  /// This is the whole trick behind a usable phone terminal. A touch keyboard
  /// has no Ctrl key, so the bar arms one and we apply it to the next
  /// character on its way out — tap CTRL, then `c`, and the remote end sees
  /// a real `0x03`.
  String applyModifiers(String data) {
    if (data.isEmpty || (!_ctrl && !_alt)) return data;

    final result = withModifiers(data, ctrl: _ctrl, alt: _alt);
    _disarm();
    return result;
  }

  /// The same for a key the bar, the pad or the magic key sends, which is how
  /// ALT and the magic key's Enter make a new line: a key of one character
  /// takes the armed modifiers, `\r` becoming ESC CR, while anything longer is
  /// a ready-made sequence — a cursor key, ESC f, a custom key's own
  /// combination — that carries its modifiers already and would only be
  /// mangled by another layer.
  String applyToKey(String data) =>
      data.length == 1 ? applyModifiers(data) : data;
}

/// [data] as a keyboard sends it with Ctrl or Alt held. Ctrl turns a lone
/// character into the C0 code a hardware chord sends; text longer than that
/// keeps it, since autocomplete and paste arrive as a run of characters and
/// mangling the first would corrupt them. Alt goes out the way every terminal
/// sends it: ESC, then the key.
String withModifiers(String data, {bool ctrl = false, bool alt = false}) {
  var result = data;
  if (ctrl && data.length == 1) {
    final control = _controlCode(data.codeUnitAt(0));
    if (control != null) result = String.fromCharCode(control);
  }
  return alt ? '\x1b$result' : result;
}

/// Maps a printable character to the C0 code a hardware Ctrl chord sends.
int? _controlCode(int code) {
  if (code >= 0x61 && code <= 0x7a) return code - 0x60; // a-z
  if (code >= 0x40 && code <= 0x5f) return code - 0x40; // @ A-Z [ \ ] ^ _
  if (code == 0x20) return 0x00; // Ctrl-Space sends NUL
  if (code == 0x3f) return 0x7f; // Ctrl-? sends DEL
  return null;
}

/// Turns a drag into cursor-key steps.
///
/// Holding the space bar on iOS and Android turns the on-screen keyboard into
/// a trackpad for moving the caret. The OS runs that gesture against its own
/// text field and reports it as a floating cursor, which never reaches us —
/// so the key bar grows a space key that behaves the same way.
class CursorPad {
  CursorPad({this.stepX = 20, this.stepY = 28});

  /// Distance to travel per cursor key. Vertical is deliberately coarser: in a
  /// shell an accidental up is a recalled command, not just a moved caret.
  final double stepX;
  final double stepY;

  int _x = 0;
  int _y = 0;

  void reset() {
    _x = 0;
    _y = 0;
  }

  /// [offset] is measured from where the drag began, so what comes back is
  /// whatever movement the distance travelled so far still owes — nothing if
  /// the finger has not crossed the next threshold, and the reverse key if it
  /// has come back.
  List<String> advance(Offset offset) {
    final steps = <String>[];
    final x = offset.dx ~/ stepX;
    final y = offset.dy ~/ stepY;

    while (_x < x) {
      _x++;
      steps.add('C');
    }
    while (_x > x) {
      _x--;
      steps.add('D');
    }
    while (_y < y) {
      _y++;
      steps.add('B');
    }
    while (_y > y) {
      _y--;
      steps.add('A');
    }

    return steps;
  }
}

/// Every item the terminal's key bar can show, by the id Settings saves its
/// place under, so an id never changes once shipped.
///
/// [send] is read at tap time, so cursor keys follow the mode the application
/// has put the terminal in. CTRL, ALT, SPACE and the divider do more than
/// send, or nothing at all, and the bar builds them itself.
final Map<String, ({String label, String Function(Terminal)? send})>
terminalKeys = {
  'esc': (label: 'ESC', send: (_) => '\x1b'),
  'tab': (label: 'TAB', send: (_) => '\t'),
  'ctrl': (label: 'CTRL', send: null),
  'alt': (label: 'ALT', send: null),
  'left': (label: '←', send: (t) => cursorKey(t, 'D')),
  'down': (label: '↓', send: (t) => cursorKey(t, 'B')),
  'up': (label: '↑', send: (t) => cursorKey(t, 'A')),
  'right': (label: '→', send: (t) => cursorKey(t, 'C')),
  'space': (label: 'SPACE', send: null),
  'ctrl-c': (label: '^C', send: (_) => '\x03'),
  'ctrl-d': (label: '^D', send: (_) => '\x04'),
  'ctrl-z': (label: '^Z', send: (_) => '\x1a'),
  'home': (label: 'HOME', send: (t) => cursorKey(t, 'H')),
  'end': (label: 'END', send: (t) => cursorKey(t, 'F')),
  'pgup': (label: 'PGUP', send: (_) => '\x1b[5~'),
  'pgdn': (label: 'PGDN', send: (_) => '\x1b[6~'),
  // Symbols the stock keyboard buries two layers deep, each its own id.
  for (final symbol in const ['-', '/', '|', '~', ':', '*'])
    symbol: (label: symbol, send: (_) => symbol),
  keyBarDivider: (label: 'Divider', send: null),
};

/// The one item that may appear more than once.
const keyBarDivider = 'divider';

/// The bar as it has always been, and as it stays until Settings rearranges
/// it: modifiers, then movement, then job control, then paging, then symbols.
const terminalKeyBarDefault = [
  'esc', 'tab', 'ctrl', 'alt', keyBarDivider, //
  'left', 'down', 'up', 'right', 'space', keyBarDivider,
  'ctrl-c', 'ctrl-d', 'ctrl-z', keyBarDivider,
  'home', 'end', 'pgup', 'pgdn', keyBarDivider,
  '-', '/', '|', '~', ':', '*',
];

/// A key the user made in Settings: the [label] it shows, the [combo] it
/// stands for, and [send], the same as text, escapes and all, for
/// [decodeKeyText]. That text is all an earlier version of the app reads, and
/// all a key made before there was a picker has: its [combo] is null, and it
/// types its text.
typedef CustomKey = ({String label, String send, KeyCombo? combo});

/// The longest label a key of the user's own may have: twice PGUP, the widest
/// built-in key.
const customKeyLabelMax = 8;

/// A key and the modifiers held with it, as the custom key picker builds it.
/// [key] is the key's cap, from [keyComboRows]. [superKey] is Super on a PC
/// and Command on a Mac. [mac] is the layout it was picked on: macOS names
/// the modifiers ⌃ ⌥ ⇧ ⌘, and a few of its text-editing combinations send
/// what a shell's line editor takes for them, [macTextEditing].
typedef KeyCombo = ({
  String key,
  bool ctrl,
  bool alt,
  bool shift,
  bool superKey,
  bool mac,
});

/// On the macOS layout, what these send in place of xterm's sequence, as
/// iTerm2's Natural Text Editing has them: line start and end, a word back
/// and forward, and deleting the line or the word before the cursor. By
/// [keyComboName].
const macTextEditing = {
  'Super+←': '\x01',
  'Super+→': '\x05',
  'Alt+←': '\x1bb',
  'Alt+→': '\x1bf',
  'Super+BKSP': '\x15',
  'Alt+BKSP': '\x17',
};

/// The keys a Mac marks with a symbol rather than a name.
const _macCaps = {'BKSP': '⌫', 'DEL': '⌦'};

/// The keys that type a character, by cap, row by row as a US keyboard has
/// them, and what each types with Shift.
const _typingRows = [
  '1234567890', 'QWERTYUIOP', 'ASDFGHJKL;', 'ZXCVBNM,./', "`-=[]\\'", //
];
const _typingRowsShifted = [
  r'!@#$%^&*()', 'QWERTYUIOP', 'ASDFGHJKL:', 'ZXCVBNM<>?', '~_+{}|"', //
];

/// What each typing key types with Shift, by cap.
final _shifted = {
  for (final (row, caps) in _typingRows.indexed)
    for (var i = 0; i < caps.length; i++) caps[i]: _typingRowsShifted[row][i],
};

/// Keys that type a character with no cap of its own.
const _charKeys = {
  'ESC': '\x1b',
  'TAB': '\t',
  'ENTER': '\r',
  'BKSP': '\x7f',
  'SPACE': ' ',
};

/// The rest: what xterm sends after CSI for each, `~` and all.
const _csiKeys = {
  'INS': '2~', 'DEL': '3~', 'HOME': 'H', 'END': 'F', 'PGUP': '5~', 'PGDN': '6~',
  '←': 'D', '↓': 'B', '↑': 'A', '→': 'C', //
  'F1': 'P', 'F2': 'Q', 'F3': 'R', 'F4': 'S', 'F5': '15~', 'F6': '17~',
  'F7': '18~', 'F8': '19~', 'F9': '20~', 'F10': '21~', 'F11': '23~',
  'F12': '24~',
};

/// Every key a custom key can be, by cap, row by row as the picker lays them
/// out: the typing keys as a US keyboard has them, then the rest.
final keyComboRows = [
  for (final caps in _typingRows) caps.split(''),
  _charKeys.keys.toList(),
  ['INS', 'DEL', 'HOME', 'END', 'PGUP', 'PGDN'],
  ['←', '↓', '↑', '→'],
  ['F1', 'F2', 'F3', 'F4', 'F5', 'F6'],
  ['F7', 'F8', 'F9', 'F10', 'F11', 'F12'],
];

/// What the cap of [key] shows: the character a typing key types, the one
/// above it with Shift, or the name of any other key, or on a [mac] its
/// symbol.
String keyCapOf(String key, {bool shift = false, bool mac = false}) =>
    switch (_shifted[key]) {
      final upper? => shift ? upper : key.toLowerCase(),
      null => mac ? _macCaps[key] ?? key : key,
    };

/// What [combo] sends, as xterm sends it. Shift picks a typing key's upper
/// character, and Ctrl and Alt fold into a character the way the key bar's
/// own sticky CTRL and ALT do. Any other key with a modifier gets xterm's
/// modifier parameter: 1, plus 1 for Shift, 2 for Alt, 4 for Ctrl and 8 for
/// Super, so Ctrl+→ is `ESC [1;5C`. Without one, the arrows, HOME and END
/// follow the terminal's cursor-keys mode, read now, as the bar's own arrows
/// do. Super has no character to fold into, so a key that types one goes out
/// in the CSI u form, `ESC [115;9u` for Super+S: the key's own character and
/// the same parameter. On the macOS layout, [macTextEditing] comes first.
String encodeKeyCombo(Terminal terminal, KeyCombo combo) {
  final (:key, :ctrl, :alt, :shift, :superKey, :mac) = combo;
  if (mac) {
    if (macTextEditing[keyComboName(combo)] case final edit?) return edit;
  }
  final modifier =
      1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0) + (superKey ? 8 : 0);
  final csi = _csiKeys[key];
  if (csi == null && superKey) {
    final code = (_charKeys[key] ?? keyCapOf(key)).codeUnitAt(0);
    return '\x1b[$code;${modifier}u';
  }
  if (csi == null) {
    // Shift+Tab is its own key to a terminal, the back tab.
    final typed = key == 'TAB' && shift
        ? '\x1b[Z'
        : _charKeys[key] ?? keyCapOf(key, shift: shift);
    return withModifiers(typed, ctrl: ctrl, alt: alt);
  }

  if (csi.endsWith('~')) {
    return modifier == 1
        ? '\x1b[$csi'
        : '\x1b[${csi.substring(0, csi.length - 1)};$modifier~';
  }
  if (modifier > 1) return '\x1b[1;$modifier$csi';
  return 'PQRS'.contains(csi) ? '\x1bO$csi' : cursorKey(terminal, csi);
}

/// How [combo] reads on a PC, `Ctrl+Alt+R`, whatever its layout: how a custom
/// key saves it for [parseKeyCombo], and what [macTextEditing] goes by.
String keyComboName(KeyCombo combo) => [
  if (combo.ctrl) 'Ctrl',
  if (combo.alt) 'Alt',
  if (combo.shift) 'Shift',
  if (combo.superKey) 'Super',
  combo.key,
].join('+');

/// How [combo] reads in its own layout: [keyComboName] on a PC, and on a Mac
/// the symbols in the Mac's order, `⌃⌥⇧⌘`, then the key, `⌘→`.
String keyComboText(KeyCombo combo) => combo.mac
    ? [
        if (combo.ctrl) '⌃',
        if (combo.alt) '⌥',
        if (combo.shift) '⇧',
        if (combo.superKey) '⌘',
        _macCaps[combo.key] ?? combo.key,
      ].join()
    : keyComboName(combo);

/// The combination [saved] names, as [keyComboName] wrote it, on the [mac]
/// layout or a PC's, or null for one with a key or a modifier this build does
/// not have.
KeyCombo? parseKeyCombo(String saved, {bool mac = false}) {
  final parts = saved.split('+');
  final key = parts.removeLast();
  final modifiers = parts.toSet();
  final known =
      _shifted.containsKey(key) ||
      _charKeys.containsKey(key) ||
      _csiKeys.containsKey(key);
  if (!known ||
      !const {'Ctrl', 'Alt', 'Shift', 'Super'}.containsAll(modifiers)) {
    return null;
  }
  return (
    key: key,
    ctrl: modifiers.contains('Ctrl'),
    alt: modifiers.contains('Alt'),
    shift: modifiers.contains('Shift'),
    superKey: modifiers.contains('Super'),
    mac: mac,
  );
}

/// A label for [combo]'s button, no longer than [customKeyLabelMax]. On a Mac
/// it is [keyComboText], `⌥B`. On a PC it is in the style of the built-in
/// keys: the character it types, a Ctrl chord in the caret form a terminal
/// shows it in, `^R`, or the cap, `PGUP`, behind Emacs's `C-` for Ctrl, `M-`
/// for Alt, `S-` for Shift and `s-` for Super. With Super held a Ctrl chord is
/// no control character, so it gets `C-` too.
String keyComboLabel(KeyCombo combo) {
  final (:key, :ctrl, :alt, :shift, :superKey, :mac) = combo;
  final typing = _shifted.containsKey(key);
  final cap = keyCapOf(key, shift: shift);
  final control = ctrl && typing && !superKey
      ? _controlCode(cap.codeUnitAt(0))
      : null;
  final label = mac
      ? keyComboText(combo)
      : [
          if (ctrl && control == null) 'C-',
          if (alt) 'M-',
          if (shift && !typing) 'S-',
          if (superKey) 's-',
          control == null ? cap : '^${String.fromCharCode(control ^ 0x40)}',
        ].join();
  return label.length > customKeyLabelMax
      ? label.substring(0, customKeyLabelMax)
      : label;
}

/// Enter is a carriage return, as the Enter key sends it: a program that reads
/// keys one at a time, such as fzf or vim, takes a line feed for Ctrl+J.
const _keyEscapes = {'n': '\r', 'r': '\r', 't': '\t', 'e': '\x1b', r'\': r'\'};

/// The text a custom key types, from what its form says: the text as written,
/// but for a backslash, which starts an escape for a key with no character of
/// its own. `\n` is Enter, as is `\r`; `\t` is Tab, `\e` is Esc, `\\` is a
/// backslash, and `\xHH` is the character with that hex code, `\x03` being
/// Ctrl+C. Any other backslash throws a [FormatException] that says which.
String decodeKeyText(String typed) =>
    typed.replaceAllMapped(RegExp(r'\\(x[0-9a-fA-F]{2}|.?)'), (match) {
      final escape = match[1]!;
      if (escape.length == 3) {
        return String.fromCharCode(int.parse(escape.substring(1), radix: 16));
      }
      return _keyEscapes[escape] ??
          (throw FormatException(
            'Unknown escape \\$escape: use \\n, \\r, \\t, \\e, \\\\ or \\xHH',
          ));
    });

/// The accessory row that sits directly above the soft keyboard.
///
/// Without this the app cannot send Esc, Tab, Ctrl or arrows at all, which
/// rules out vim, less, tmux and job control — that is to say, most reasons
/// to open a terminal in the first place.
class TerminalKeyBar extends StatelessWidget {
  const TerminalKeyBar({
    super.key,
    required this.controller,
    required this.terminal,
    required this.onEmit,
    this.leading = const [],
    this.showKeys = true,
    this.compact = false,
    this.keys = terminalKeyBarDefault,
    this.customKeys = const {},
  });

  final KeyBarController controller;

  /// Read at tap time so cursor keys follow the application's current mode.
  final Terminal terminal;

  final void Function(String data) onEmit;

  /// The session's own buttons, ahead of ESC. Plain [IconButton]s: the bar
  /// dresses them as keys.
  final List<Widget> leading;

  /// False while there is no shell, when the keys would have nothing to talk
  /// to. [leading] stays either way, the way the header it replaced always
  /// showed its buttons, greyed out until there was something to reach.
  final bool showKeys;

  /// Draws the bar for a pointer rather than a thumb: shorter, with smaller
  /// buttons. A phone's keys are sized to be hit while walking; on a desktop
  /// that same size reads as an enormous toolbar.
  final bool compact;

  /// The ids from [terminalKeys] and [customKeys] to show, in order: the
  /// arrangement picked in Settings. [leading] and the divider after it are
  /// the page's own, and always come first.
  final List<String> keys;

  /// The keys the user made, by the ids [keys] names them with.
  final Map<String, CustomKey> customKeys;

  String _cursor(String finalChar) => cursorKey(terminal, finalChar);

  Widget _key(String id) => switch (id) {
    keyBarDivider => const _KeyDivider(),
    'ctrl' => KeyButton(
      label: 'CTRL',
      active: controller.ctrl,
      onTap: controller.toggleCtrl,
    ),
    'alt' => KeyButton(
      label: 'ALT',
      active: controller.alt,
      onTap: controller.toggleAlt,
    ),
    'space' => _SpacePad(
      onSpace: () => onEmit(' '),
      onCursor: (finalChar) => onEmit(_cursor(finalChar)),
    ),
    // A custom key goes out the way the built-in ones do, through
    // [onEmit], so the page lets go of a selection for it and sends it to
    // the pane in use, and armed modifiers wait for the keyboard.
    _ => KeyButton(
      label: customKeys[id]?.label ?? terminalKeys[id]!.label,
      onTap: () => onEmit(switch (customKeys[id]) {
        final key? => switch (key.combo) {
          final combo? => encodeKeyCombo(terminal, combo),
          null => decodeKeyText(key.send),
        },
        null => terminalKeys[id]!.send!(terminal),
      }),
    ),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A divider only ever between two keys: a group hidden whole leaves no
    // double line, and none trails at the end. The first is [leading]'s own.
    final shown = <String>[];
    for (final id in keys) {
      if (id != keyBarDivider ||
          (shown.isNotEmpty && shown.last != keyBarDivider)) {
        shown.add(id);
      }
    }
    if (shown.lastOrNull == keyBarDivider) shown.removeLast();

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: SizedBox(
          // A thumb's key is 48 tall; a pointer's does not need to be.
          height: compact ? 34 : 48,
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              return ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                children: [
                  for (final button in leading)
                    _IconKey(button, compact: compact),
                  if (showKeys && shown.isNotEmpty) ...[
                    const _KeyDivider(),
                    for (final id in shown) _key(id),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The accessory row under the code editor: the keys a touch keyboard lacks,
/// acting on the editor's own cursor rather than sending bytes to a shell.
///
/// ponytail: no PgUp/PgDn, which re_editor 0.10 leaves unimplemented; the
/// space bar's trackpad and scrolling cover long moves until it has them.
class EditorKeyBar extends StatelessWidget {
  const EditorKeyBar({
    super.key,
    required this.controller,
    this.useTabs = false,
  });

  final CodeLineEditingController controller;

  /// Tab types a real tab instead of spaces: for a Makefile, where a recipe
  /// indented with spaces does not run, and for any file already indented
  /// with tabs.
  final bool useTabs;

  static const _arrows = {
    'A': AxisDirection.up,
    'B': AxisDirection.down,
    'C': AxisDirection.right,
    'D': AxisDirection.left,
  };

  /// What config files and scripts are made of, and the stock keyboard buries
  /// a layer or two down.
  static const _symbols = [
    '{', '}', '[', ']', '(', ')', '<', '>', '"', "'", ';', ':', //
    '/', r'\', '|', r'$', '=', '-', '_', '#', '&', '*', '~',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget arrow(String label, String key) => KeyButton(
      label: label,
      onTap: () => controller.moveCursor(_arrows[key]!),
    );

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 48,
          // Only undo and redo change with the text, but they change on the
          // first keystroke and the last undo, so they are watched.
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              children: [
                _IconKey(
                  IconButton(
                    tooltip: 'Undo',
                    onPressed: controller.canUndo ? controller.undo : null,
                    icon: const Icon(Icons.undo),
                  ),
                ),
                _IconKey(
                  IconButton(
                    tooltip: 'Redo',
                    onPressed: controller.canRedo ? controller.redo : null,
                    icon: const Icon(Icons.redo),
                  ),
                ),
                const _KeyDivider(),
                KeyButton(
                  label: 'TAB',
                  onTap: useTabs
                      ? () => controller.replaceSelection('\t')
                      : controller.applyIndent,
                ),
                KeyButton(label: '⇤', onTap: controller.applyOutdent),
                const _KeyDivider(),
                arrow('←', 'D'),
                arrow('↓', 'B'),
                arrow('↑', 'A'),
                arrow('→', 'C'),
                _SpacePad(
                  onSpace: () => controller.replaceSelection(' '),
                  onCursor: (key) => controller.moveCursor(_arrows[key]!),
                ),
                const _KeyDivider(),
                KeyButton(
                  label: 'HOME',
                  onTap: controller.moveCursorToLineStart,
                ),
                KeyButton(label: 'END', onTap: controller.moveCursorToLineEnd),
                const _KeyDivider(),
                for (final symbol in _symbols)
                  KeyButton(
                    label: symbol,
                    onTap: () => controller.replaceSelection(symbol),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A key of a bar. Public so Settings can offer a key the way it will look on
/// the bar.
class KeyButton extends StatelessWidget {
  const KeyButton({
    super.key,
    required this.label,
    required this.onTap,
    this.active = false,
    this.minWidth = 44,
  });

  final String label;
  final VoidCallback onTap;

  /// Armed sticky modifiers stay lit so the user can see what the next
  /// keystroke will do.
  final bool active;

  final double minWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = active
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 3),
      child: Material(
        color: active
            ? theme.colorScheme.primary
            : theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Container(
            constraints: BoxConstraints(minWidth: minWidth),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: foreground,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A space key that doubles as a cursor trackpad: tap for a space, hold and
/// slide to move.
///
/// Long press is what claims the gesture — the bar scrolls horizontally, and a
/// plain drag belongs to the scroll. Holding first is also the gesture the
/// stock keyboards teach, so the muscle memory carries over.
class _SpacePad extends StatefulWidget {
  const _SpacePad({required this.onSpace, required this.onCursor});

  final VoidCallback onSpace;

  /// Receives the final character of a cursor sequence: A, B, C or D.
  final void Function(String finalChar) onCursor;

  @override
  State<_SpacePad> createState() => _SpacePadState();
}

class _SpacePadState extends State<_SpacePad> {
  final _pad = CursorPad();

  bool _moving = false;

  void _startMoving(LongPressStartDetails _) {
    _pad.reset();
    // The only signal that the key changed meaning, since the finger is
    // covering it.
    HapticFeedback.selectionClick();
    setState(() => _moving = true);
  }

  void _stopMoving() {
    if (_moving) setState(() => _moving = false);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: _startMoving,
      onLongPressMoveUpdate: (details) {
        for (final finalChar in _pad.advance(details.localOffsetFromOrigin)) {
          widget.onCursor(finalChar);
        }
      },
      onLongPressEnd: (_) => _stopMoving(),
      onLongPressCancel: _stopMoving,
      child: KeyButton(
        label: _moving ? '↔ MOVE' : 'SPACE',
        active: _moving,
        minWidth: 96,
        onTap: widget.onSpace,
      ),
    );
  }
}

/// An [IconButton] the page hands in, given the face of the keys around it so
/// the header it came from does not show.
class _IconKey extends StatelessWidget {
  const _IconKey(this.child, {this.compact = false});

  final Widget child;

  /// Sized for a pointer rather than a thumb — see [TerminalKeyBar.compact].
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.symmetric(
        vertical: compact ? 4 : 6,
        horizontal: compact ? 2 : 3,
      ),
      child: IconButtonTheme(
        data: IconButtonThemeData(
          style: IconButton.styleFrom(
            foregroundColor: colors.onSurface,
            backgroundColor: colors.surfaceContainerHigh,
            // Greyed out rather than gone: still a key, just not one to press.
            disabledBackgroundColor: colors.surfaceContainerHigh,
            iconSize: compact ? 15 : 20,
            minimumSize: compact ? const Size(30, 24) : const Size(44, 36),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
        ),
        child: child,
      ),
    );
  }
}

class _KeyDivider extends StatelessWidget {
  const _KeyDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      child: VerticalDivider(
        width: 1,
        thickness: 1,
        color: Theme.of(context).colorScheme.outlineVariant,
      ),
    );
  }
}

/// Wraps the terminal so a long press arms the arrow keys and the drag that
/// follows holds one down: the direction picks the key, and how far the finger
/// has reached sets how fast it repeats for as long as it stays down. A short
/// reach is one press however long you hold it; further out it ticks about
/// once every two seconds, and further still every 300ms. Lifting the finger
/// stops it.
///
/// Holding first is what claims the gesture, the same split the space key
/// makes with the bar's own scroll: a plain drag is left to the terminal, and
/// scrolls the scrollback the way it would in any other app.
///
/// A double tap sends Tab, which is what a shell wants far more often than it
/// wants a word selected, and a single tap still raises the keyboard.
///
/// That long press is also the one xterm2 selects text with on touch, so what
/// a hold means is settled by what is under the finger when it fires. On a
/// character it selects the word, the way xterm2 would, and the drag that
/// follows widens it word by word; on a space, an empty cell or the padding it
/// arms the arrows. Once the finger lifts, the selection wears Flutter's own
/// handles and toolbar, the way selected text does anywhere else on the
/// phone: drag a handle to move that end, drag anywhere else to scroll, tap to
/// let go. A mouse still selects with a drag; xterm2's pan recogniser for that
/// is mouse-only.
class SwipeKeyPad extends StatefulWidget {
  const SwipeKeyPad({
    super.key,
    required this.terminal,
    required this.controller,
    required this.onEmit,
    required this.onPaste,
    required this.child,
  });

  /// Read at emit time so cursor keys follow the application's current mode.
  final Terminal terminal;

  /// The one [child]'s TerminalView was given, so the word picked here is the
  /// one it paints, and whoever clears it — a key sent, xterm2 changing
  /// screens — ends selecting here too.
  final TerminalController controller;

  final void Function(String data) onEmit;

  /// What the toolbar's Paste does. The page owns it, not the pad: an image on
  /// the clipboard goes to the host as a file rather than down the wire, and
  /// only the page can upload.
  final Future<void> Function() onPaste;

  final Widget child;

  @override
  State<SwipeKeyPad> createState() => _SwipeKeyPadState();
}

/// How often the held drag is re-examined. Short enough that reaching further
/// speeds the repeat up under the finger, long enough to be free.
const _swipeTick = Duration(milliseconds: 50);

class _SwipeKeyPadState extends State<SwipeKeyPad> {
  Timer? _repeat;
  Offset _travelled = Offset.zero;
  String? _arrow;

  /// Milliseconds the current key has been held down for since it last
  /// repeated.
  int _held = 0;

  /// Drives the readout: whether it is up, how many chevrons it shows, and
  /// which top corner it sits in.
  bool _swiping = false;
  int _level = 1;
  bool _hudOnRight = true;

  /// On from a hold that lands on a character until the selection goes.
  bool _selecting = false;

  /// Where that hold landed, in the terminal's own coordinates, for as long as
  /// the finger stays down and the drag is still widening the first word.
  Offset? _wordFrom;

  /// The end of the selection a handle drag leaves alone, while one lasts.
  CellOffset? _pinned;

  /// Where the end being dragged has got to, in the terminal's own
  /// coordinates: where its handle pointed, plus however far the finger has
  /// moved since.
  Offset _dragAt = Offset.zero;

  /// The terminal's scroll, while a drag that missed the handles drives it.
  Drag? _scroll;

  /// How the selection sits in this pad, worked out from xterm2's cells each
  /// time it or the text under it moves: the feet its two handles hang from,
  /// null for one out of sight, the height of a row, and where the toolbar
  /// goes. Null while there is no selection to show.
  ({
    Offset? start,
    Offset? end,
    double line,
    TextSelectionToolbarAnchors toolbar,
  })?
  _shown;

  /// Set while a re-placing waits for the frame to be out.
  bool _placing = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onSelectionChanged);
    widget.terminal.addListener(_onOutput);
  }

  @override
  void didUpdateWidget(SwipeKeyPad oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onSelectionChanged);
      widget.controller.addListener(_onSelectionChanged);
    }
    if (oldWidget.terminal != widget.terminal) {
      oldWidget.terminal.removeListener(_onOutput);
      widget.terminal.addListener(_onOutput);
    }
  }

  @override
  void dispose() {
    _repeat?.cancel();
    widget.controller.removeListener(_onSelectionChanged);
    widget.terminal.removeListener(_onOutput);
    super.dispose();
  }

  void _onSelectionChanged() {
    if (!_selecting) return;
    if (widget.controller.selection != null) {
      setState(_place);
      return;
    }

    // The drag recogniser goes with the selection, and would leave the scroll
    // hanging mid-drag.
    _scroll?.cancel();
    setState(() {
      _selecting = false;
      _wordFrom = null;
      _pinned = null;
      _shown = null;
    });
  }

  /// New output can move the selected text, so the handles and the toolbar
  /// are placed again — once the frame is out, because a terminal sitting on
  /// its last line takes the scroll that brings new output up while it lays
  /// out, and tells nobody.
  void _onOutput() {
    if (!_selecting || _placing) return;
    _placing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _placing = false;
      if (mounted && _selecting) setState(_place);
    });
  }

  /// The first [T] inside [SwipeKeyPad.child] — its TerminalView, or the
  /// Scrollable that scrolls it — found rather than handed in so a pad needs
  /// nothing beyond the controller its view was already given.
  T? _find<T extends State>() {
    T? found;
    void look(Element element) {
      if (element is StatefulElement && element.state is T) {
        found ??= element.state as T;
      } else {
        element.visitChildren(look);
      }
    }

    context.visitChildElements(look);
    return found;
  }

  TerminalViewState? _view() => _find<TerminalViewState>();

  /// Whether [global] is on a character rather than a space, an empty cell,
  /// an empty row or the padding round the grid.
  bool _onText(TerminalViewState view, Offset global) {
    final render = view.renderTerminal;
    final at = render.globalToLocal(global);
    final cell = render.getCellOffset(at);
    // getCellOffset pulls a point in the padding onto the nearest cell, so the
    // point has to be inside the cell it came back with.
    if (!(render.getOffset(cell) & render.cellSize).contains(at)) return false;

    final line = widget.terminal.buffer.lines[cell.y];
    var x = cell.x;
    // The right half of a wide character is an empty cell of its own.
    if (x > 0 && line.getWidth(x) == 0 && line.getWidth(x - 1) == 2) x--;
    return x < line.length && line.getCodePoint(x) > 0x20;
  }

  void _select(TerminalViewState view, Offset global) {
    assert(
      identical(view.widget.controller, widget.controller),
      'SwipeKeyPad and its TerminalView need the same TerminalController',
    );
    final render = view.renderTerminal;
    final at = render.globalToLocal(global);
    render.selectWord(at);
    // A separator hemmed in by separators is no word to xterm2, but it is
    // still what the finger is on.
    if (widget.controller.selection == null) render.selectCharacters(at);
    // Lighter than the bump that arms the arrows, so the hand can tell which
    // of the two the hold became.
    HapticFeedback.selectionClick();
    setState(() {
      _selecting = true;
      _wordFrom = at;
      _place();
    });
  }

  /// Works out [_shown] from xterm2's cell geometry: a cell's offset in the
  /// terminal, which already takes the scroll into account, and the cell
  /// size, brought into this pad's coordinates.
  ///
  /// The handles hang from the foot of the first cell and of the gap after
  /// the last, which is the text's baseline as near as a terminal has one.
  /// The toolbar goes over the middle of a selection on one row and over the
  /// middle of the pad for one across rows, above the selection, or below it
  /// when there is no room above — the anchors a text field would give it.
  void _place() {
    final range = widget.controller.selection?.normalized;
    final render = _view()?.renderTerminal;
    final box = context.findRenderObject() as RenderBox?;
    if (range == null || render == null || box == null) {
      _shown = null;
      return;
    }

    final line = render.cellSize.height;
    Offset foot(CellOffset cell) => box.globalToLocal(
      render.localToGlobal(render.getOffset(cell) + Offset(0, line)),
    );
    final start = foot(range.begin);
    final end = foot(range.end);
    final size = box.size;
    // Both kept, clipped, while a handle is held: output pushing the text up
    // can take an end out of sight, even the one whose handle holds the drag
    // (the far one, with the ends crossed), and a handle that leaves the tree
    // takes its drag with it.
    Offset? inSight(Offset foot) =>
        _pinned != null || (foot.dy >= 0 && foot.dy <= size.height)
        ? foot
        : null;
    final x = start.dy == end.dy ? (start.dx + end.dx) / 2 : size.width / 2;
    // Held inside the pad, as a text field holds them inside itself. The
    // lower one is held a toolbar short of the bottom, because this pad clips
    // where an overlay would not, and a selection running off both edges —
    // Select all, say — would otherwise put Copy out of reach.
    final lowest = math.max(
      0.0,
      size.height -
          kMinInteractiveDimension -
          TextSelectionToolbar.kToolbarContentDistanceBelow,
    );
    _shown = (
      start: inSight(start),
      end: inSight(end),
      line: line,
      toolbar: TextSelectionToolbarAnchors(
        primaryAnchor: Offset(x, (start.dy - line).clamp(0.0, size.height)),
        secondaryAnchor: Offset(x, end.dy.clamp(0.0, lowest)),
      ),
    );
  }

  /// A handle is picked up: the other end stays where it is, and this one
  /// follows the finger from where the handle points rather than from where
  /// the finger landed, a line or so lower, so picking it up moves nothing.
  void _grab(bool start) {
    final range = widget.controller.selection?.normalized;
    final render = _view()?.renderTerminal;
    if (range == null || render == null) return;

    setState(() {
      _pinned = start ? range.end : range.begin;
      _dragAt =
          render.getOffset(start ? range.begin : range.end) +
          Offset(0, render.cellSize.height / 2);
    });
  }

  /// Moves the dragged end, a cell at a time, to the gap between cells
  /// nearest the finger, held to the rows in sight: a finger past the edge
  /// takes the end to the row along it, rather than on out of sight with its
  /// handle. The ends may cross: the range is normalised wherever it is
  /// read, so the handles trade places, as they do in a text field.
  ///
  /// ponytail: a handle held at the edge doesn't scroll the terminal; scroll
  /// first, then drag the handle. Tried and dropped by the user after three
  /// UAT rounds. Should it come back, whatever the pad scrolls on its own
  /// must scroll the terminal's scrollback, the innermost Scrollable in its
  /// view, and not the first one [_find] meets: while a program reads the
  /// mouse, or has the alternate screen up, xterm2 wraps that one in a
  /// Scrollable of its own that turns scrolling into wheel events or arrow
  /// keys for the program, and the page lets go of the selection on anything
  /// the terminal sends. A drag that misses the handles is another matter:
  /// that is the finger's own scroll, and goes where xterm2 would send it.
  void _drag(DragUpdateDetails details) {
    final pinned = _pinned;
    final render = _view()?.renderTerminal;
    if (pinned == null || render == null) return;

    _dragAt += details.delta;
    final at = Offset(
      _dragAt.dx,
      _dragAt.dy.clamp(
        0.0,
        math.max(0.0, render.size.height - render.cellSize.height),
      ),
    );
    final cell = render.getCellOffset(at);
    final pastMiddle =
        at.dx - render.getOffset(cell).dx > render.cellSize.width / 2;
    final gap = pastMiddle ? CellOffset(cell.x + 1, cell.y) : cell;
    // Nothing selected is no selection, and the same end twice is no move.
    if (gap == pinned || gap == widget.controller.selection?.end) return;

    final buffer = widget.terminal.buffer;
    widget.controller.setSelection(
      buffer.createAnchorFromOffset(pinned),
      buffer.createAnchorFromOffset(gap),
    );
  }

  /// A finger that was shaping the selection has lifted, so the toolbar can
  /// come back without being under it, and a handle kept while held goes if
  /// it is out of sight.
  void _settle() => setState(() {
    _wordFrom = null;
    _pinned = null;
    if (_selecting) _place();
  });

  /// While a selection is up the pad takes every touch, so a drag that missed
  /// the handles is handed to the scroll position of the terminal's own
  /// Scrollable — the one it would have driven itself, fling and all.
  void _scrollStart(DragStartDetails details) => _scroll =
      _find<ScrollableState>()?.position.drag(details, () => _scroll = null);

  void _copy() {
    final range = widget.controller.selection;
    if (range != null) {
      Clipboard.setData(
        ClipboardData(text: widget.terminal.buffer.getText(range, true)),
      );
      showToast(context, 'Copied', type: ToastificationType.success);
    }
    widget.controller.clearSelection();
  }

  /// The address of an OSC 8 hyperlink under the selection, if there is one:
  /// see [hyperlinkIn].
  String? get _selectedLink {
    final range = widget.controller.selection;
    return range == null ? null : hyperlinkIn(widget.terminal, range);
  }

  /// A hyperlink's label hides its address, and copying the label gives only
  /// the label, so this is how a user finds out where a link goes before a
  /// Ctrl+tap opens it — the toast says it in full, and it can be pasted
  /// anywhere to look at.
  void _copyLink(String address) {
    Clipboard.setData(ClipboardData(text: address));
    showToast(context, 'Copied $address', type: ToastificationType.success);
    widget.controller.clearSelection();
  }

  /// Handed to the page, which pastes text through xterm2's own paste — the
  /// one a hardware Ctrl+V takes, so it arrives bracketed when the shell asked
  /// for that — and sends an image to the host as a file instead.
  ///
  /// ponytail: offered whether or not the clipboard holds anything. A
  /// ClipboardStatusNotifier would hide it when empty, as a text field does.
  void _paste() {
    widget.controller.clearSelection();
    widget.onPaste();
  }

  /// Everything the terminal holds, scrollback and all, as xterm2's own
  /// Ctrl+A takes it.
  void _selectAll() {
    final buffer = widget.terminal.buffer;
    widget.controller.setSelection(
      buffer.createAnchor(0, 0),
      buffer.createAnchor(widget.terminal.viewWidth, buffer.height - 1),
      mode: SelectionMode.line,
    );
  }

  void _onUpdate(LongPressMoveUpdateDetails details) {
    final from = _wordFrom;
    if (from != null) {
      final render = _view()?.renderTerminal;
      render?.selectWord(from, render.globalToLocal(details.globalPosition));
      return;
    }
    // A hold whose selection went while it was down steers nothing.
    if (!_swiping) return;

    // Measured from where the finger landed, not from where the hold was
    // recognised, so a finger that crept a little while holding still is not
    // judged short of where it actually is.
    _travelled = details.localOffsetFromOrigin;

    final arrow = swipeArrow(_travelled);
    final level = swipeSpeedLevel(_travelled.distance);
    // Repaint when the readout would actually differ, not on every pixel the
    // finger crosses — the terminal underneath is expensive to rebuild.
    if (arrow == _arrow && level == _level) return;

    // A new direction is one press straight away, so a short drag does
    // something without being held at all.
    if (arrow != _arrow) {
      _held = 0;
      if (arrow != null) widget.onEmit(cursorKey(widget.terminal, arrow));
    }

    setState(() {
      _arrow = arrow;
      _level = level;
    });
  }

  /// Reads the reach afresh every tick rather than scheduling one repeat at a
  /// time, so a finger that reaches further mid-hold speeds up immediately
  /// instead of waiting out the two seconds already in flight.
  void _onTick(Timer _) {
    final arrow = _arrow;
    final interval = arrow == null ? null : swipeRepeatMs(_travelled.distance);

    // Pulled back to a nudge: stop repeating, and do not bank the wait.
    if (interval == null) {
      _held = 0;
      return;
    }

    _held += _swipeTick.inMilliseconds;
    if (_held < interval) return;

    _held = 0;
    widget.onEmit(cursorKey(widget.terminal, arrow!));
  }

  void _start(LongPressStartDetails details) {
    final view = _view();
    if (view != null && _onText(view, details.globalPosition)) {
      _select(view, details.globalPosition);
      return;
    }

    // Never leave an earlier tick running: two of them would race the same
    // key out at twice the rate the reach asked for.
    _repeat?.cancel();
    // The finger is still, and covering the spot; nothing else says the drag
    // that follows will steer instead of scroll. The same bump the magic key
    // gives when its ring opens, since it is the same kind of hold.
    HapticFeedback.mediumImpact();

    final width = context.size?.width;

    setState(() {
      _reset();
      _swiping = true;
      // Sit on the far side from the finger. The hand comes in over the side
      // it started on, and a readout under your own palm tells you nothing.
      _hudOnRight = width == null || details.localPosition.dx < width / 2;
    });

    _repeat = Timer.periodic(_swipeTick, _onTick);
  }

  void _stop() {
    _repeat?.cancel();
    _repeat = null;
    // The recogniser can cancel us on its way out, after we are already gone.
    if (!mounted) return;
    setState(() {
      _reset();
      _swiping = false;
    });
  }

  void _reset() {
    _arrow = null;
    _level = 1;
    _held = 0;
    _travelled = Offset.zero;
  }

  /// One of Flutter's own selection handles, hung by its anchor from [foot]
  /// the way a text field hangs it from the baseline, in a touch target as
  /// big as the one Flutter's own overlay gives it. Keyed by its side, so a
  /// handle keeps its drag while the other one comes and goes.
  Widget _handle(TextSelectionHandleType type, Offset foot, double line) {
    final controls = materialTextSelectionControls;
    final size = controls.getHandleSize(line);
    final at =
        foot -
        controls.getHandleAnchor(type, line) -
        Offset(
          (kMinInteractiveDimension - size.width) / 2,
          (kMinInteractiveDimension - size.height) / 2,
        );

    return Positioned(
      key: ValueKey(type),
      left: at.dx,
      top: at.dy,
      child: GestureDetector(
        // Opaque, and above the pad, so a touch on it goes nowhere else and
        // the drag starts the moment the finger lands.
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => _grab(type == TextSelectionHandleType.left),
        onPanUpdate: _drag,
        onPanEnd: (_) => _settle(),
        child: SizedBox.square(
          dimension: kMinInteractiveDimension,
          child: Center(child: controls.buildHandle(context, type, line)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;

    return Stack(
      children: [
        // The terminal's scrolling, heard on its way up, so the handles and
        // the toolbar go where the text goes.
        NotificationListener<ScrollUpdateNotification>(
          onNotification: (_) {
            if (_selecting) setState(_place);
            return false;
          },
          child: widget.child,
        ),
        // A layer over the terminal rather than a wrapper round it, so it
        // meets every touch before xterm2 does. That order is what decides the
        // long press: xterm2 holds one too, for selecting text, both wait out
        // the same platform timeout, and of two timers due together the one
        // started first fires first and wins. Wrapped, that would be xterm2's,
        // and every hold would select, even on the blank the arrows want.
        // Translucent, so the touch still reaches the terminal underneath for
        // the taps and drags this lets go of — except while a selection is
        // up. xterm2 lets go of a selection once a touch has lasted 100ms,
        // which a slow drag does well before it counts as a scroll, so while
        // one is up the pad keeps every touch and hands a drag on to the
        // terminal's scroll itself.
        Positioned.fill(
          child: RawGestureDetector(
            behavior: _selecting
                ? HitTestBehavior.opaque
                : HitTestBehavior.translucent,
            excludeFromSemantics: true,
            gestures: {
              // ponytail: the one cell under the finger decides, so a hold on
              // the space between two words steers rather than selects. Look
              // a cell either side too if people keep missing the letter.
              LongPressGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    LongPressGestureRecognizer
                  >(
                    () => LongPressGestureRecognizer(
                      debugOwner: this,
                      supportedDevices: const {PointerDeviceKind.touch},
                    ),
                    (instance) {
                      instance
                        ..onLongPressStart = _start
                        ..onLongPressMoveUpdate = _onUpdate
                        ..onLongPressEnd = (_) {
                          _swiping ? _stop() : _settle();
                        }
                        ..onLongPressCancel = _stop;
                    },
                  ),
              // ponytail: this holds the arena for kDoubleTapTimeout, so a
              // single tap raises the keyboard ~300ms later than it used to.
              // Detect the second tap from a plain Listener instead if that
              // lag ever grates — at the cost of xterm2 also selecting a word
              // under the double tap.
              if (!_selecting)
                DoubleTapGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      DoubleTapGestureRecognizer
                    >(
                      () => DoubleTapGestureRecognizer(debugOwner: this),
                      (instance) =>
                          instance.onDoubleTap = () => widget.onEmit('\t'),
                    ),
              if (_selecting) ...{
                VerticalDragGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      VerticalDragGestureRecognizer
                    >(() => VerticalDragGestureRecognizer(debugOwner: this), (
                      instance,
                    ) {
                      instance
                        ..onStart = _scrollStart
                        ..onUpdate = (details) {
                          _scroll?.update(details);
                        }
                        ..onEnd = (details) {
                          _scroll?.end(details);
                        };
                    }),
                TapGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                      () => TapGestureRecognizer(debugOwner: this),
                      (instance) =>
                          instance.onTap = widget.controller.clearSelection,
                    ),
              },
            },
          ),
        ),
        if (_swiping)
          Positioned(
            top: 12,
            left: _hudOnRight ? null : 12,
            right: _hudOnRight ? 12 : null,
            // Never in the way of the drag it is reporting on.
            child: IgnorePointer(
              child: _SwipeReadout(arrow: _arrow, level: _level),
            ),
          ),
        if (shown != null) ...[
          if (shown.start case final foot?)
            _handle(TextSelectionHandleType.left, foot, shown.line),
          if (shown.end case final foot?)
            _handle(TextSelectionHandleType.right, foot, shown.line),
          // Over the handles, where Flutter's own overlay puts it, and gone
          // whenever a finger is shaping the selection, so it is never under
          // one.
          if (_wordFrom == null && _pinned == null)
            Positioned.fill(
              child: AdaptiveTextSelectionToolbar.buttonItems(
                anchors: shown.toolbar,
                buttonItems: [
                  ContextMenuButtonItem(
                    type: ContextMenuButtonType.copy,
                    onPressed: _copy,
                  ),
                  ContextMenuButtonItem(
                    type: ContextMenuButtonType.paste,
                    onPressed: _paste,
                  ),
                  ContextMenuButtonItem(
                    type: ContextMenuButtonType.selectAll,
                    onPressed: _selectAll,
                  ),
                  if (_selectedLink case final address?)
                    ContextMenuButtonItem(
                      label: 'Copy link address',
                      onPressed: () => _copyLink(address),
                    ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

/// The compass that comes up under a swipe: four idle arms, and the one being
/// held drawn as a stack of chevrons — one for a nudge, three when the cursor
/// is running as fast as the gesture goes.
class _SwipeReadout extends StatelessWidget {
  const _SwipeReadout({required this.arrow, required this.level});

  final String? arrow;
  final int level;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 108,
      height: 108,
      decoration: BoxDecoration(
        // Lifted off the background rather than frosted: a BackdropFilter over
        // a terminal repaints the blur on every line of output, which is a lot
        // to pay for a hint. Opaque enough to knock back whatever it lands on —
        // it sits in a corner where the prompt usually is, and a bright line of
        // shell output showing through drowns the arms out.
        color: const Color(0xD8262626),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
      ),
      child: Stack(
        children: [
          _arm('A', Alignment.topCenter),
          _arm('D', Alignment.centerLeft),
          _arm('C', Alignment.centerRight),
          _arm('B', Alignment.bottomCenter),
        ],
      ),
    );
  }

  Widget _arm(String direction, Alignment at) {
    final live = direction == arrow;

    return Align(
      alignment: at,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: live
            ? _chevrons(direction)
            : Icon(
                _swipeArmIcons[direction],
                size: 22,
                color: Colors.white.withValues(alpha: 0.45),
              ),
      ),
    );
  }

  /// Overlapped rather than spaced out, so three of them still fit the arm.
  Widget _chevrons(String direction) {
    const icon = 24.0;
    const step = 9.0;
    final sideways = direction == 'C' || direction == 'D';
    final run = icon + step * (level - 1);

    return SizedBox(
      width: sideways ? run : icon,
      height: sideways ? icon : run,
      child: Stack(
        children: [
          for (var i = 0; i < level; i++)
            Positioned(
              left: sideways ? i * step : 0,
              top: sideways ? 0 : i * step,
              child: Icon(
                _swipeChevronIcons[direction],
                size: icon,
                color: Colors.white,
              ),
            ),
        ],
      ),
    );
  }
}
