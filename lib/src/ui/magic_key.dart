import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm2/xterm.dart';

import 'key_bar.dart';

/// One slot on the magic key's ring. [send] is resolved at emit time because
/// what a cursor key has to send depends on the mode the remote application
/// has put the terminal in.
typedef MagicKeyAction = ({String label, String Function(Terminal) send});

/// The ring, clockwise from north.
///
/// The arrows sit where the finger points, so the dpad needs no learning; the
/// diagonals hold the keys a shell wants most and a touch keyboard lacks.
final List<MagicKeyAction> magicKeys = [
  (label: '↑', send: (t) => cursorKey(t, 'A')),
  (label: 'ESC', send: (_) => '\x1b'),
  (label: '→', send: (t) => cursorKey(t, 'C')),
  (label: 'TAB', send: (_) => '\t'),
  (label: '↓', send: (t) => cursorKey(t, 'B')),
  (label: '^C', send: (_) => '\x03'),
  (label: '←', send: (t) => cursorKey(t, 'D')),
  (label: '^D', send: (_) => '\x04'),
];

/// Which of [count] sectors a drag of [offset] points at, or null while the
/// finger is still inside the dead zone — a wobble during a tap must not send
/// a key.
///
/// Sector 0 is north and they run clockwise, matching the order of [magicKeys].
int? sectorFor(Offset offset, int count, {double deadZone = 18}) {
  if (offset.distance < deadZone) return null;
  // atan2 is measured from east, counter-clockwise; swapping and negating its
  // arguments turns it into north, clockwise.
  final turn = math.atan2(offset.dx, -offset.dy) / (2 * math.pi) % 1.0;
  return (turn * count).round() % count;
}

/// A floating Enter key that doubles as a radial key picker and can be parked
/// anywhere over the terminal.
///
/// Enter is the one key you reach for with the keyboard down — reading output,
/// answering a prompt, waking a dozing shell. Dragging out of it picks from
/// [magicKeys] by direction, which puts the keys that matter one gesture away
/// without spending any of the screen on them. Holding it picks the button up,
/// because wherever it sits by default is over the thing someone wants to read.
///
/// Give it the whole terminal area with [Positioned.fill]: it is a layer, and
/// only the button inside it takes touches.
class MagicKey extends StatefulWidget {
  const MagicKey({super.key, required this.terminal, required this.onEmit});

  final Terminal terminal;
  final void Function(String data) onEmit;

  @override
  State<MagicKey> createState() => _MagicKeyState();
}

class _MagicKeyState extends State<MagicKey> {
  static const _prefsX = 'sshbox.magickey.x';
  static const _prefsY = 'sshbox.magickey.y';

  static const _size = 52.0;
  static const _ring = 80.0;
  static const _petal = 40.0;

  /// Where the button sits, as a fraction of the room it has to move in, so it
  /// keeps its corner across a rotation and when the keyboard resizes the page.
  Offset _spot = const Offset(0.95, 0.92);

  /// [_spot] when the current move began. The gesture reports its offset from
  /// where the finger landed, which is drift-free where summing deltas is not.
  Offset _anchor = Offset.zero;

  Offset _drag = Offset.zero;
  int? _aim;
  bool _picking = false;
  bool _moving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final x = prefs.getDouble(_prefsX);
    final y = prefs.getDouble(_prefsY);
    if (!mounted || x == null || y == null) return;
    setState(() => _spot = Offset(x, y));
  }

  Future<void> _remember() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_prefsX, _spot.dx);
    await prefs.setDouble(_prefsY, _spot.dy);
  }

  void _aimAt(Offset drag) {
    final aim = sectorFor(drag, magicKeys.length);
    if (aim == _aim) return;
    // The finger is covering the button, so this is the only signal that the
    // selection moved.
    if (aim != null) HapticFeedback.selectionClick();
    setState(() => _aim = aim);
  }

  void _startPicking(DragStartDetails _) {
    _drag = Offset.zero;
    setState(() {
      _picking = true;
      _aim = null;
    });
  }

  void _endPicking() {
    final aim = _aim;
    if (aim != null) widget.onEmit(magicKeys[aim].send(widget.terminal));
    setState(() {
      _picking = false;
      _aim = null;
    });
  }

  void _startMoving(LongPressStartDetails _) {
    _anchor = _spot;
    HapticFeedback.selectionClick();
    setState(() => _moving = true);
  }

  void _keepMoving(LongPressMoveUpdateDetails details, Size room) {
    final moved = details.offsetFromOrigin;
    setState(() {
      _spot = Offset(
        (_anchor.dx + moved.dx / room.width).clamp(0.0, 1.0),
        (_anchor.dy + moved.dy / room.height).clamp(0.0, 1.0),
      );
    });
  }

  void _stopMoving() {
    if (!_moving) return;
    setState(() => _moving = false);
    unawaited(_remember());
  }

  /// Keeps the ring on screen when the button is parked in a corner. The drag
  /// angle is what selects, not which petal the finger reached, so sliding the
  /// ring over changes nothing but what the user can see.
  double _ringCentre(double value, double extent) {
    final margin = _ring + _petal / 2;
    if (extent < margin * 2) return extent / 2;
    return value.clamp(margin, extent - margin);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final room = Size(
          math.max(1, constraints.maxWidth - _size),
          math.max(1, constraints.maxHeight - _size),
        );
        final origin = Offset(_spot.dx * room.width, _spot.dy * room.height);
        final centre = Offset(
          _ringCentre(origin.dx + _size / 2, constraints.maxWidth),
          _ringCentre(origin.dy + _size / 2, constraints.maxHeight),
        );

        return Stack(
          children: [
            if (_picking)
              for (var i = 0; i < magicKeys.length; i++) _petalAt(centre, i),
            Positioned(
              left: origin.dx,
              top: origin.dy,
              width: _size,
              height: _size,
              child: GestureDetector(
                onTap: () => widget.onEmit('\r'),
                // Pan and long press share the gesture arena: move the finger
                // and the ring opens, hold it still and the button comes
                // loose. The same bargain the space key strikes, so the habit
                // carries over.
                onPanStart: _startPicking,
                onPanUpdate: (details) => _aimAt(_drag += details.delta),
                onPanEnd: (_) => _endPicking(),
                onPanCancel: _endPicking,
                onLongPressStart: _startMoving,
                onLongPressMoveUpdate: (details) => _keepMoving(details, room),
                onLongPressEnd: (_) => _stopMoving(),
                onLongPressCancel: _stopMoving,
                child: _Button(picking: _picking, moving: _moving),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _petalAt(Offset centre, int index) {
    final angle = 2 * math.pi * index / magicKeys.length;
    return Positioned(
      left: centre.dx + _ring * math.sin(angle) - _petal / 2,
      top: centre.dy - _ring * math.cos(angle) - _petal / 2,
      width: _petal,
      height: _petal,
      child: IgnorePointer(
        child: _Petal(label: magicKeys[index].label, aimed: index == _aim),
      ),
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({required this.picking, required this.moving});

  final bool picking;
  final bool moving;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      // Lifted while it is loose, so it reads as picked up rather than stuck.
      elevation: moving ? 12 : 6,
      shape: const CircleBorder(),
      color: moving
          ? theme.colorScheme.tertiaryContainer
          : theme.colorScheme.primaryContainer,
      child: Center(
        child: Icon(
          moving
              ? Icons.open_with
              : picking
                  ? Icons.radio_button_unchecked
                  : Icons.keyboard_return,
          size: 22,
          color: moving
              ? theme.colorScheme.onTertiaryContainer
              : theme.colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

class _Petal extends StatelessWidget {
  const _Petal({required this.label, required this.aimed});

  final String label;
  final bool aimed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      elevation: aimed ? 8 : 3,
      shape: const CircleBorder(),
      color: aimed ? theme.colorScheme.primary : theme.colorScheme.surface,
      child: Center(
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: aimed
                ? theme.colorScheme.onPrimary
                : theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}
