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

/// The shorter way round between two angles, in radians.
double _angleBetween(double a, double b) {
  final d = (a - b).abs() % (2 * math.pi);
  return math.min(d, 2 * math.pi - d);
}

/// The widest run of directions — clockwise from north, in radians — in which
/// a petal [radius] out from [centre] stays at least [inset] inside [bounds].
///
/// A full turn when every direction fits, and a zero sweep when none does.
({double start, double sweep}) freeArc(
  Offset centre,
  Size bounds,
  double radius,
  double inset,
) {
  const steps = 360;
  bool fits(int i) {
    final a = 2 * math.pi * i / steps;
    final x = centre.dx + radius * math.sin(a);
    final y = centre.dy - radius * math.cos(a);
    return x >= inset &&
        x <= bounds.width - inset &&
        y >= inset &&
        y <= bounds.height - inset;
  }

  final ok = [for (var i = 0; i < steps; i++) fits(i)];
  if (!ok.contains(false)) return (start: 0, sweep: 2 * math.pi);
  if (!ok.contains(true)) return (start: 0, sweep: 0);

  // Scanned from just past a blocked direction, so a run that crosses north
  // is counted whole rather than as two halves.
  final blocked = ok.indexOf(false);
  var bestStart = 0, bestLength = 0, runStart = 0, runLength = 0;
  for (var k = 1; k <= steps; k++) {
    final i = (blocked + k) % steps;
    if (!ok[i]) {
      runLength = 0;
      continue;
    }
    if (runLength == 0) runStart = i;
    runLength++;
    if (runLength > bestLength) {
      bestLength = runLength;
      bestStart = runStart;
    }
  }
  return (
    start: 2 * math.pi * bestStart / steps,
    sweep: 2 * math.pi * (bestLength - 1) / steps,
  );
}

/// Where the ring's petals sit around a button at [centre] inside [bounds]:
/// an angle per key, clockwise from north in radians, and the one radius they
/// all sit at.
///
/// With room all round they take the compass points in [magicKeys] order, so
/// the arrows sit where they point. Against an edge there is no room on that
/// side, so rather than hang off the screen or shove the ring off-centre they
/// fan over the arc that is left — each key as near its own compass point as
/// the arc allows, arrows first — pushed out as far as it takes for them not
/// to overlap.
({List<double> angles, double radius}) ringLayout({
  required Offset centre,
  required Size bounds,
  int count = 8,
  double radius = 80,
  double petal = 40,
  double gap = 6,
  double maxRadius = 200,
}) {
  final compass = [for (var i = 0; i < count; i++) 2 * math.pi * i / count];
  final inset = petal / 2 + 4;

  var r = radius;
  var arc = freeArc(centre, bounds, r, inset);
  // A shorter arc needs a longer radius to fit every petal without overlap,
  // and a longer radius can shorten the arc again. A few rounds settle it.
  for (var round = 0; round < 4; round++) {
    if (arc.sweep <= 0 || arc.sweep >= 2 * math.pi) break;
    final needed = (petal + gap) * (count - 1) / arc.sweep;
    if (needed <= r || r >= maxRadius) break;
    r = math.min(needed, maxRadius);
    arc = freeArc(centre, bounds, r, inset);
  }

  // Room all round — or, on a screen too small for any of it, no better idea
  // than the plain ring.
  if (arc.sweep <= 0 || arc.sweep >= 2 * math.pi) {
    return (angles: compass, radius: r);
  }

  final slots = [
    for (var j = 0; j < count; j++) arc.start + arc.sweep * j / (count - 1),
  ];
  // A key whose own direction is still on screen has a right answer, so it
  // outranks every key whose direction the edge has taken away — otherwise →
  // gets parked at the top of a corner fan because that is "only" 86° wrong
  // for it, and sliding up sends → instead of ↑. Among the keys that do have
  // their direction, the arrows count four times over: an arrow in the wrong
  // place is the mistake a thumb makes without looking.
  final tolerance = arc.sweep / (count - 1) / 2;
  bool onArc(double a) {
    final along = (a - arc.start) % (2 * math.pi);
    return along <= arc.sweep + tolerance || along >= 2 * math.pi - tolerance;
  }

  final weight = [
    for (final a in compass)
      !onArc(a)
          ? 1.0
          : (a % (math.pi / 2)).abs() < 1e-9
          ? 400.0
          : 100.0,
  ];
  final slotOf = _closestAssignment(slots, compass, weight);
  return (
    angles: [for (final j in slotOf) slots[j] % (2 * math.pi)],
    radius: r,
  );
}

/// For each key, which of [slots] it takes: the assignment that leaves the
/// keys as near their [compass] points as possible, each key's miss counted
/// [weight] times over.
///
/// Eight keys is 40320 orderings at worst; cutting off any branch already
/// dearer than the best found keeps it to a handful.
List<int> _closestAssignment(
  List<double> slots,
  List<double> compass,
  List<double> weight,
) {
  final n = slots.length;
  final best = List<int>.filled(n, 0);
  final current = List<int>.filled(n, 0);
  final used = List<bool>.filled(n, false);
  var bestCost = double.infinity;

  void place(int key, double cost) {
    if (cost >= bestCost) return;
    if (key == n) {
      bestCost = cost;
      best.setAll(0, current);
      return;
    }
    for (var j = 0; j < n; j++) {
      if (used[j]) continue;
      used[j] = true;
      current[key] = j;
      place(
        key + 1,
        cost + weight[key] * _angleBetween(slots[j], compass[key]),
      );
      used[j] = false;
    }
  }

  place(0, 0);
  return best;
}

/// Which petal a drag of [offset] from where the finger landed points at.
///
/// Null inside the dead zone, where a wobble must not send a key, and when it
/// points further than half a spacing from every petal — into the gap a fan
/// leaves against an edge, where any guess would be the wrong key.
int? petalFor(Offset offset, List<double> angles, {double deadZone = 18}) {
  if (offset.distance < deadZone) return null;
  // atan2 is measured from east, counter-clockwise; swapping and negating its
  // arguments turns it into north, clockwise — the frame [angles] is in.
  final pointing = math.atan2(offset.dx, -offset.dy);

  var nearest = 0;
  var nearestGap = double.infinity;
  for (var i = 0; i < angles.length; i++) {
    final gap = _angleBetween(pointing, angles[i]);
    if (gap < nearestGap) {
      nearestGap = gap;
      nearest = i;
    }
  }

  final sorted = [...angles]..sort();
  var spacing = 2 * math.pi - sorted.last + sorted.first;
  for (var i = 1; i < sorted.length; i++) {
    spacing = math.min(spacing, sorted[i] - sorted[i - 1]);
  }
  return nearestGap <= spacing / 2 + 1e-6 ? nearest : null;
}

/// A floating Enter key that doubles as a radial key picker and can be parked
/// anywhere over the terminal.
///
/// Enter is the one key you reach for with the keyboard down — reading output,
/// answering a prompt, waking a dozing shell. Tap it for Enter.
///
/// Hold it and [magicKeys] open as a ring around it. Still holding, slide to
/// one and lift to send it. Lifting always closes the ring — on a key or not —
/// so the ring only ever exists while the finger that asked for it is down.
///
/// Drag it straight away, without holding first, to move it: wherever it sits
/// by default is over the thing someone wants to read.
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
  static const _petal = 40.0;

  /// Where the button sits, as a fraction of the room it has to move in, so it
  /// keeps its corner across a rotation and when the keyboard resizes the page.
  Offset _spot = const Offset(0.95, 0.92);

  /// [_spot] and the finger's position when the current move began. Measuring
  /// from where the finger landed is drift-free where summing deltas is not.
  Offset _anchor = Offset.zero;
  Offset _grab = Offset.zero;

  int? _aim;

  /// The ring is up, and only for as long as the finger that opened it is.
  bool _picking = false;

  bool _moving = false;

  /// Where the button's centre is and how much room it has, as of the last
  /// layout — what the ring is fitted into when it opens.
  Offset _centre = Offset.zero;
  Size _bounds = Size.zero;

  /// Worked out once, when the ring opens, so the petals cannot shift under a
  /// finger that is already aiming at one.
  ({List<double> angles, double radius}) _ring = (
    angles: [for (var i = 0; i < magicKeys.length; i++) 0.0],
    radius: 80.0,
  );

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
    final aim = petalFor(drag, _ring.angles);
    if (aim == _aim) return;
    // The finger is covering the button, so this is the only signal that the
    // selection moved.
    if (aim != null) HapticFeedback.selectionClick();
    setState(() => _aim = aim);
  }

  void _openRing(LongPressStartDetails _) {
    _ring = ringLayout(
      centre: _centre,
      bounds: _bounds,
      count: magicKeys.length,
      petal: _petal,
    );
    HapticFeedback.mediumImpact();
    setState(() {
      _picking = true;
      _aim = null;
    });
  }

  /// Lifting sends whatever is aimed at, and closes the ring either way.
  void _releaseRing() {
    final aim = _aim;
    _closeRing();
    if (aim != null) widget.onEmit(magicKeys[aim].send(widget.terminal));
  }

  void _closeRing() {
    if (!_picking && _aim == null) return;
    setState(() {
      _picking = false;
      _aim = null;
    });
  }

  void _startMoving(DragStartDetails details) {
    _anchor = _spot;
    _grab = details.globalPosition;
    setState(() {
      _moving = true;
      _picking = false;
      _aim = null;
    });
  }

  void _keepMoving(DragUpdateDetails details, Size room) {
    final moved = details.globalPosition - _grab;
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

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final room = Size(
          math.max(1, constraints.maxWidth - _size),
          math.max(1, constraints.maxHeight - _size),
        );
        final origin = Offset(_spot.dx * room.width, _spot.dy * room.height);
        _centre = origin + const Offset(_size / 2, _size / 2);
        _bounds = constraints.biggest;

        return Stack(
          children: [
            if (_picking)
              for (var i = 0; i < magicKeys.length; i++) _petalAt(i),
            Positioned(
              // Keyed because the ring is inserted ahead of it mid-gesture.
              // Unkeyed, Flutter would reuse this element for the first petal
              // and throw away the detector holding the finger, so the hold
              // that opened the ring could never end.
              key: const ValueKey('magic-key-button'),
              left: origin.dx,
              top: origin.dy,
              width: _size,
              height: _size,
              child: Semantics(
                // Named for what a tap does. Screen readers need it, and so
                // does anything driving the app by its accessibility tree.
                label: 'Send Enter',
                button: true,
                child: GestureDetector(
                  onTap: () => widget.onEmit('\r'),
                  // Pan and long press share the gesture arena, which is what
                  // splits the two: hold still until the long press fires and
                  // the ring opens, move first and the button comes loose.
                  onLongPressStart: _openRing,
                  onLongPressMoveUpdate: (details) =>
                      _aimAt(details.offsetFromOrigin),
                  onLongPressEnd: (_) => _releaseRing(),
                  onLongPressCancel: _closeRing,
                  onPanStart: _startMoving,
                  onPanUpdate: (details) => _keepMoving(details, room),
                  onPanEnd: (_) => _stopMoving(),
                  onPanCancel: _stopMoving,
                  child: _Button(picking: _picking, moving: _moving),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _petalAt(int index) {
    final angle = _ring.angles[index];
    return Positioned(
      left: _centre.dx + _ring.radius * math.sin(angle) - _petal / 2,
      top: _centre.dy - _ring.radius * math.cos(angle) - _petal / 2,
      width: _petal,
      height: _petal,
      // A picture of what the finger is aiming at, not a set of buttons: the
      // ring is gone the moment that finger lifts.
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
