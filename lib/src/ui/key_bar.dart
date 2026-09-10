import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:xterm2/xterm.dart';

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

  final reach = ((distance - _swipeRepeatFrom) /
          (_swipeFullSpeedFrom - _swipeRepeatFrom))
      .clamp(0.0, 1.0);
  return (2000 - reach * 1700).round();
}

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

    var result = data;

    if (_ctrl && data.length == 1) {
      final control = _toControlCode(data.codeUnitAt(0));
      if (control != null) result = String.fromCharCode(control);
    }

    // Alt is transmitted the way every terminal does it: ESC then the key.
    if (_alt) result = '\x1b$result';

    _disarm();
    return result;
  }

  /// Maps a printable character to the C0 code a hardware Ctrl chord sends.
  int? _toControlCode(int code) {
    if (code >= 0x61 && code <= 0x7a) return code - 0x60; // a-z
    if (code >= 0x40 && code <= 0x5f) return code - 0x40; // @ A-Z [ \ ] ^ _
    if (code == 0x20) return 0x00; // Ctrl-Space sends NUL
    if (code == 0x3f) return 0x7f; // Ctrl-? sends DEL
    return null;
  }
}

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
  });

  final KeyBarController controller;

  /// Read at tap time so cursor keys follow the application's current mode.
  final Terminal terminal;

  final void Function(String data) onEmit;

  String _cursor(String finalChar) => cursorKey(terminal, finalChar);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 48,
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              return ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                children: [
                  _KeyButton(label: 'ESC', onTap: () => onEmit('\x1b')),
                  _KeyButton(label: 'TAB', onTap: () => onEmit('\t')),
                  _KeyButton(
                    label: 'CTRL',
                    active: controller.ctrl,
                    onTap: controller.toggleCtrl,
                  ),
                  _KeyButton(
                    label: 'ALT',
                    active: controller.alt,
                    onTap: controller.toggleAlt,
                  ),
                  const _KeyDivider(),
                  _KeyButton(label: '←', onTap: () => onEmit(_cursor('D'))),
                  _KeyButton(label: '↓', onTap: () => onEmit(_cursor('B'))),
                  _KeyButton(label: '↑', onTap: () => onEmit(_cursor('A'))),
                  _KeyButton(label: '→', onTap: () => onEmit(_cursor('C'))),
                  const _KeyDivider(),
                  _KeyButton(label: '^C', onTap: () => onEmit('\x03')),
                  _KeyButton(label: '^D', onTap: () => onEmit('\x04')),
                  _KeyButton(label: '^Z', onTap: () => onEmit('\x1a')),
                  const _KeyDivider(),
                  _KeyButton(label: 'HOME', onTap: () => onEmit(_cursor('H'))),
                  _KeyButton(label: 'END', onTap: () => onEmit(_cursor('F'))),
                  _KeyButton(label: 'PGUP', onTap: () => onEmit('\x1b[5~')),
                  _KeyButton(label: 'PGDN', onTap: () => onEmit('\x1b[6~')),
                  const _KeyDivider(),
                  // Symbols the stock keyboard buries two layers deep.
                  for (final symbol in const ['-', '/', '|', '~', ':', '*'])
                    _KeyButton(label: symbol, onTap: () => onEmit(symbol)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _KeyButton extends StatelessWidget {
  const _KeyButton({
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final String label;
  final VoidCallback onTap;

  /// Armed sticky modifiers stay lit so the user can see what the next
  /// keystroke will do.
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground =
        active ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;

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
            constraints: const BoxConstraints(minWidth: 44),
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

/// Wraps the terminal so a held drag across it holds down an arrow key: the
/// direction picks the key, and how far the finger has reached sets how fast
/// it repeats for as long as it stays down. A short reach is one press however
/// long you hold it; further out it ticks about once every two seconds, and
/// further still every 300ms. Lifting the finger stops it.
///
/// A double tap sends Tab, which is what a shell wants far more often than it
/// wants a word selected.
///
/// Only touch drags are claimed. xterm2 selects text on touch with a long
/// press — its own pan recogniser is mouse-only — so holding still before you
/// move still selects, and a single tap still raises the keyboard.
class SwipeKeyPad extends StatefulWidget {
  const SwipeKeyPad({
    super.key,
    required this.terminal,
    required this.onEmit,
    required this.child,
  });

  /// Read at emit time so cursor keys follow the application's current mode.
  final Terminal terminal;

  final void Function(String data) onEmit;

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

  @override
  void dispose() {
    _repeat?.cancel();
    super.dispose();
  }

  void _onUpdate(DragUpdateDetails details) {
    _travelled += details.delta;

    final arrow = swipeArrow(_travelled);
    if (arrow == _arrow) return;

    // A new direction is one press straight away, so a short drag does
    // something without being held at all.
    _arrow = arrow;
    _held = 0;
    if (arrow != null) widget.onEmit(cursorKey(widget.terminal, arrow));
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

  void _start() {
    _stop();
    _repeat = Timer.periodic(_swipeTick, _onTick);
  }

  void _stop() {
    _repeat?.cancel();
    _repeat = null;
    _arrow = null;
    _held = 0;
    _travelled = Offset.zero;
  }

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      excludeFromSemantics: true,
      gestures: {
        PanGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
          () => PanGestureRecognizer(
            debugOwner: this,
            supportedDevices: const {PointerDeviceKind.touch},
          ),
          (instance) {
            instance
              ..onStart = (_) {
                _start();
              }
              ..onUpdate = _onUpdate
              ..onEnd = (_) {
                _stop();
              }
              ..onCancel = _stop;
          },
        ),
        // ponytail: this holds the arena for kDoubleTapTimeout, so a single tap
        // raises the keyboard ~300ms later than it used to. Detect the second
        // tap from a plain Listener instead if that lag ever grates — at the
        // cost of xterm2 also selecting a word under the double tap.
        DoubleTapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<DoubleTapGestureRecognizer>(
          () => DoubleTapGestureRecognizer(debugOwner: this),
          (instance) => instance.onDoubleTap = () => widget.onEmit('\t'),
        ),
      },
      child: widget.child,
    );
  }
}
