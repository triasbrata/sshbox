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

  /// Drives the readout: whether it is up, how many chevrons it shows, and
  /// which top corner it sits in.
  bool _swiping = false;
  int _level = 1;
  bool _hudOnRight = true;

  @override
  void dispose() {
    _repeat?.cancel();
    super.dispose();
  }

  void _onUpdate(DragUpdateDetails details) {
    _travelled += details.delta;

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

  void _start(DragStartDetails details) {
    // Never leave an earlier tick running: two of them would race the same
    // key out at twice the rate the reach asked for.
    _repeat?.cancel();

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
              // Measure the reach from where the finger actually landed. The
              // default hands the slop it took to recognise the drag to
              // onStart and never reports it, which would quietly cost every
              // reach the first ~18 pixels of the distance it is judged on.
              ..dragStartBehavior = DragStartBehavior.down
              ..onStart = _start
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
      child: Stack(
        children: [
          widget.child,
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
        ],
      ),
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
        // to pay for a hint. Tinted light because it has to read over the near
        // black a terminal usually is.
        color: Colors.white.withValues(alpha: 0.13),
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
