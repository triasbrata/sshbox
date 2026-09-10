import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
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

/// What resting on a petal opens: a second ring round it, keyed by the label
/// of the petal it hangs off. A petal with nothing here only ever sends.
///
/// Each is a key that goes with its parent — further the same way, or the same
/// key for another job — so the hand is already nearly there. ESC ESC is
/// Claude Code's double Esc, and Shift+Tab cycles its modes.
final Map<String, List<MagicKeyAction>> magicSubKeys = {
  '↑': [(label: 'PGUP', send: (_) => '\x1b[5~'), _home],
  'ESC': [(label: 'ESC²', send: (_) => '\x1b\x1b')],
  '→': [_end, (label: 'W→', send: (_) => '\x1bf')],
  'TAB': [(label: '⇧TAB', send: (_) => '\x1b[Z')],
  '↓': [(label: 'PGDN', send: (_) => '\x1b[6~'), _end],
  '^C': [
    (label: '^Z', send: (_) => '\x1a'),
    (label: '^\\', send: (_) => '\x1c'),
  ],
  '←': [_home, (label: 'W←', send: (_) => '\x1bb')],
  '^D': [
    (label: '^L', send: (_) => '\x0c'),
    (label: '^R', send: (_) => '\x12'),
  ],
};

/// Home and End follow DECCKM the way the arrows do: xterm sends them as
/// `ESC O H` / `ESC O F` in application mode and `ESC [ H` / `ESC [ F` outside
/// it.
final MagicKeyAction _home = (label: 'HOME', send: (t) => cursorKey(t, 'H'));
final MagicKeyAction _end = (label: 'END', send: (t) => cursorKey(t, 'F'));

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

const _deadZone = 18.0;

/// Which petal a drag of [offset] from where the finger landed points at.
///
/// Null inside the dead zone, where a wobble must not send a key, and when it
/// points further than half a spacing from every petal — into the gap a fan
/// leaves against an edge, where any guess would be the wrong key.
int? petalFor(
  Offset offset,
  List<double> angles, {
  double deadZone = _deadZone,
}) {
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
/// Rest on a petal as long as it took to open the ring and, if [magicSubKeys]
/// has anything behind it, a second ring opens round that petal the same way:
/// slide to one of those and lift, or lift where you are for the petal itself.
///
/// Drag it straight away, without holding first, to move it: wherever it sits
/// by default is over the thing someone wants to read. Throw it at a side, or
/// push it flat against one, and it tucks in there half off the screen; a tap
/// on what is left brings it back out, a little clear of the edge.
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
  static const _prefsDocked = 'sshbox.magickey.docked';

  static const _size = 52.0;
  static const _petal = 40.0;

  /// Sideways speed, in logical pixels a second, at which letting go counts as
  /// a throw rather than a move that happened to end moving. Tuned by thumb.
  static const _throwSpeed = 700.0;

  /// How far short of the edge a button coming out of its side stops.
  static const _inset = 16.0;

  static const _glideTime = Duration(milliseconds: 220);

  /// Where the button sits, as a fraction of the room it has to move in, so it
  /// keeps its corner across a rotation and when the keyboard resizes the page.
  Offset _spot = const Offset(0.95, 0.92);

  /// Tucked into a side, half off the screen. The side is whichever edge
  /// [_spot] is against.
  bool _docked = false;

  bool get _onLeft => _spot.dx < 0.5;

  /// Zero whenever a finger is moving the button, so it stays under the
  /// finger; set only when it tucks in or comes back out, so those glide.
  Duration _glide = Duration.zero;

  /// [_spot] and the finger's position when the current move began. Measuring
  /// from where the finger landed is drift-free where summing deltas is not.
  Offset _anchor = Offset.zero;
  Offset _grab = Offset.zero;

  int? _aim;

  /// Ring 2's aim, into the keys behind [_parent]. While it is set [_aim] is
  /// not, so there is only ever one thing that lifting would send.
  int? _child;

  /// The petal ring 2 is open round, or null while only ring 1 is.
  int? _parent;

  /// Ring 2, and the drag at which it opened. It is aimed from where the finger
  /// rested to open it, as ring 1 is from where the finger landed: the finger
  /// is rarely on the petal itself, only pointing at it.
  late ({List<double> angles, double radius}) _subRing;
  Offset _subOrigin = Offset.zero;

  /// The finger's drag from where it landed, as of its last move.
  Offset _drag = Offset.zero;

  /// Runs while the finger rests on a petal with keys behind it.
  Timer? _dwell;

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

  @override
  void dispose() {
    _dwell?.cancel();
    super.dispose();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final x = prefs.getDouble(_prefsX);
    final y = prefs.getDouble(_prefsY);
    if (!mounted || x == null || y == null) return;
    setState(() {
      _spot = Offset(x, y);
      _docked = prefs.getBool(_prefsDocked) ?? false;
    });
  }

  Future<void> _remember() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_prefsX, _spot.dx);
    await prefs.setDouble(_prefsY, _spot.dy);
    await prefs.setBool(_prefsDocked, _docked);
  }

  void _aimAt(Offset drag) {
    _drag = drag;
    final parent = _parent;
    int? aim, child;
    if (parent == null) {
      aim = petalFor(drag, _ring.angles);
    } else if (drag.distance >= _deadZone) {
      // Pointing at no child is still the parent. Only the middle of ring 1
      // lets go of it, so backing all the way out cancels here as it does
      // there.
      child = petalFor(drag - _subOrigin, _subRing.angles);
      if (child == null) aim = parent;
    }
    if (aim == _aim && child == _child) return;
    // The finger is covering the button, so this is the only signal that the
    // selection moved.
    if (aim != null || child != null) HapticFeedback.selectionClick();
    setState(() {
      _aim = aim;
      _child = child;
    });

    // Resting on a petal with keys behind it opens them, the way resting on
    // the button opened this ring. The clock starts when the finger arrives,
    // so a slide that passes over a petal, or lifts off it, opens nothing.
    _dwell?.cancel();
    if (parent == null && aim != null && _subKeysOf(aim).isNotEmpty) {
      _dwell = Timer(kLongPressTimeout, () => _openSubRing(aim!));
    }
  }

  List<MagicKeyAction> _subKeysOf(int index) =>
      magicSubKeys[magicKeys[index].label] ?? const [];

  /// Ring 2 is fitted like ring 1: a full compass round the parent petal,
  /// fanned against an edge. Its keys take the slots either side of the
  /// parent's own compass point, so they open outward, clear of ring 1 and the
  /// button; a lone key takes the parent's point itself.
  void _openSubRing(int parent) {
    final keys = _subKeysOf(parent);
    final ring = ringLayout(
      centre: _out(_centre, _ring.angles[parent], _ring.radius),
      bounds: _bounds,
      count: magicKeys.length,
      radius: 56,
      petal: _petal,
    );
    _subRing = (
      angles: [
        for (var j = 0; j < keys.length; j++)
          ring.angles[(parent + 2 * j - keys.length + 1) % magicKeys.length],
      ],
      radius: ring.radius,
    );
    _subOrigin = _drag;
    HapticFeedback.mediumImpact();
    setState(() => _parent = parent);
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
    final aim = _aim, child = _child, parent = _parent;
    _closeRing();
    if (child != null) {
      widget.onEmit(_subKeysOf(parent!)[child].send(widget.terminal));
    } else if (aim != null) {
      widget.onEmit(magicKeys[aim].send(widget.terminal));
    }
  }

  void _closeRing() {
    _dwell?.cancel();
    if (!_picking && _aim == null) return;
    setState(() {
      _picking = false;
      _aim = null;
      _child = null;
      _parent = null;
    });
  }

  void _startMoving(DragStartDetails details) {
    _anchor = _spot;
    _grab = details.globalPosition;
    setState(() {
      _moving = true;
      _docked = false;
      _glide = Duration.zero;
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

  /// Let go while moving fast sideways, or pushed flat against a side, and the
  /// button tucks into that side — out of the way of the output, and still one
  /// tap from coming back.
  void _stopMoving([Velocity velocity = Velocity.zero]) {
    if (!_moving) return;
    final v = velocity.pixelsPerSecond;
    final thrown = v.dx.abs() > _throwSpeed && v.dx.abs() > v.dy.abs();
    final againstSide = _spot.dx <= 0 || _spot.dx >= 1;
    setState(() {
      _moving = false;
      if (thrown || againstSide) {
        _docked = true;
        _glide = _glideTime;
        if (thrown) _spot = Offset(v.dx > 0 ? 1 : 0, _spot.dy);
      }
    });
    unawaited(_remember());
  }

  /// Out of its side, stopping [_inset] short of the edge it was tucked into.
  void _reveal(Size room) {
    final inset = (_inset / room.width).clamp(0.0, 1.0);
    setState(() {
      _docked = false;
      _glide = _glideTime;
      _spot = Offset(_onLeft ? inset : 1 - inset, _spot.dy);
    });
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
        final origin = Offset(
          // Tucked in, its middle sits on the edge: half on screen, half off.
          _docked
              ? (_onLeft ? 0 : constraints.maxWidth) - _size / 2
              : _spot.dx * room.width,
          _spot.dy * room.height,
        );
        _centre = origin + const Offset(_size / 2, _size / 2);
        _bounds = constraints.biggest;
        final parent = _parent;

        return Stack(
          children: [
            if (_picking)
              for (var i = 0; i < magicKeys.length; i++)
                _petalAt(
                  _out(_centre, _ring.angles[i], _ring.radius),
                  magicKeys[i].label,
                  aimed: i == _aim,
                  // Ring 1 recedes behind ring 2, all but the petal ring 2
                  // hangs off, so it is plain which ring the finger is in.
                  dimmed: parent != null && i != parent,
                ),
            if (_picking && parent != null)
              for (var j = 0; j < _subRing.angles.length; j++)
                _petalAt(
                  _out(
                    _out(_centre, _ring.angles[parent], _ring.radius),
                    _subRing.angles[j],
                    _subRing.radius,
                  ),
                  _subKeysOf(parent)[j].label,
                  aimed: j == _child,
                ),
            AnimatedPositioned(
              // Keyed because the ring is inserted ahead of it mid-gesture.
              // Unkeyed, Flutter would reuse this element for the first petal
              // and throw away the detector holding the finger, so the hold
              // that opened the ring could never end.
              key: const ValueKey('magic-key-button'),
              duration: _glide,
              curve: Curves.easeOutCubic,
              left: origin.dx,
              top: origin.dy,
              width: _size,
              height: _size,
              child: Semantics(
                // Named for what a tap does. Screen readers need it, and so
                // does anything driving the app by its accessibility tree.
                label: _docked ? 'Show Enter key' : 'Send Enter',
                button: true,
                child: GestureDetector(
                  // A tucked-away key is out of the way on purpose; the first
                  // tap only fetches it, and never lands in the shell.
                  onTap: _docked
                      ? () => _reveal(room)
                      : () => widget.onEmit('\r'),
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
                  onPanEnd: (details) => _stopMoving(details.velocity),
                  onPanCancel: _stopMoving,
                  child: _Button(
                    picking: _picking,
                    moving: _moving,
                    tuckedLeft: _docked ? _onLeft : null,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// [distance] out from [from] at [angle], clockwise from north.
  static Offset _out(Offset from, double angle, double distance) =>
      from + Offset(math.sin(angle), -math.cos(angle)) * distance;

  Widget _petalAt(
    Offset at,
    String label, {
    required bool aimed,
    bool dimmed = false,
  }) {
    return Positioned(
      left: at.dx - _petal / 2,
      top: at.dy - _petal / 2,
      width: _petal,
      height: _petal,
      // A picture of what the finger is aiming at, not a set of buttons: the
      // ring is gone the moment that finger lifts.
      child: IgnorePointer(
        child: Opacity(
          opacity: dimmed ? 0.3 : 1,
          child: _Petal(label: label, aimed: aimed),
        ),
      ),
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({
    required this.picking,
    required this.moving,
    this.tuckedLeft,
  });

  final bool picking;
  final bool moving;

  /// Which side it is tucked into, or null while it floats free.
  final bool? tuckedLeft;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tucked = tuckedLeft;

    return Material(
      // Lifted while it is loose, so it reads as picked up rather than stuck.
      elevation: moving ? 12 : 6,
      shape: const CircleBorder(),
      color: moving
          ? theme.colorScheme.tertiaryContainer
          : theme.colorScheme.primaryContainer,
      // Tucked in, only half of it is on screen: the icon moves into that half
      // and points the way the button comes out, where a centred Enter would
      // be cut down the middle.
      child: Align(
        alignment: tucked == null
            ? Alignment.center
            : Alignment(tucked ? 0.8 : -0.8, 0),
        child: Icon(
          moving
              ? Icons.open_with
              : tucked != null
              ? (tucked ? Icons.chevron_right : Icons.chevron_left)
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
