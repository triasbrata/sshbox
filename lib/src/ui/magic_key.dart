import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm2/xterm.dart';

import 'key_bar.dart';
import 'tui.dart';

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

/// Ring 2: the keys behind each of ring 1's, keyed by its label, reached by
/// sliding past it further the same way. Two at most: the first right behind
/// it, the second one step clockwise of that.
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

/// Where the petals sit around a button at [centre] inside [bounds]: an angle
/// per key, clockwise from north in radians, with ring 1 at [radius] and ring
/// 2 at [outer] — the keys behind each one [spread] apart, the first on its
/// own angle and the next clockwise.
///
/// With room all round they take the compass points in [magicKeys] order, so
/// the arrows sit where they point. Against an edge there is no room on that
/// side, so rather than hang off the screen or shove the rings off-centre they
/// fan over the arc ring 2 has left — each key as near its own compass point
/// as the arc allows, arrows first — pushed out as far as it takes for ring
/// 2's petals not to overlap, with ring 1 the same distance inside it.
///
/// ponytail: capped at [maxRadius], so the fan still fits a phone; in a tight
/// corner ring 2's petals overlap a little instead. Smaller petals out there
/// if that bites.
({List<double> angles, double radius, double outer, double spread}) ringLayout({
  required Offset centre,
  required Size bounds,
  int count = 8,
  double radius = 80,
  double outer = 135,
  double petal = 40,
  double gap = 6,
  double maxRadius = 280,
}) {
  final compass = [for (var i = 0; i < count; i++) 2 * math.pi * i / count];
  final inset = petal / 2 + 4;

  // Ring 2 runs out of room first — it has two petals to each of ring 1's —
  // so it is the one fitted, and ring 1, inside it, has room to spare.
  var r = outer;
  var arc = freeArc(centre, bounds, r, inset);
  // A shorter arc needs a longer radius to fit every petal without overlap,
  // and a longer radius can shorten the arc again. A few rounds settle it.
  for (var round = 0; round < 4; round++) {
    if (arc.sweep <= 0 || arc.sweep >= 2 * math.pi) break;
    final needed = (petal + gap) * (2 * count - 1) / arc.sweep;
    if (needed <= r || r >= maxRadius) break;
    r = math.min(needed, maxRadius);
    arc = freeArc(centre, bounds, r, inset);
  }
  final inner = r - (outer - radius);

  // Room all round — or, on a screen too small for any of it, no better idea
  // than the plain ring.
  if (arc.sweep <= 0 || arc.sweep >= 2 * math.pi) {
    return (angles: compass, radius: inner, outer: r, spread: math.pi / count);
  }

  // The second key behind a key sits half a spacing clockwise of it, so the
  // last slot stops half a spacing short of the end of the arc.
  final spacing = arc.sweep / (count - 0.5);
  final slots = [for (var j = 0; j < count; j++) arc.start + spacing * j];
  // A key whose own direction is still on screen has a right answer, so it
  // outranks every key whose direction the edge has taken away — otherwise →
  // gets parked at the top of a corner fan because that is "only" 86° wrong
  // for it, and sliding up sends → instead of ↑. Among the keys that do have
  // their direction, the arrows count four times over: an arrow in the wrong
  // place is the mistake a thumb makes without looking.
  final tolerance = spacing / 2;
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
    radius: inner,
    outer: r,
    spread: spacing / 2,
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

/// How far a finger has to slide before it aims at anything.
const double _deadZone = 18;

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
/// Hold it and two rings open around it: [magicKeys] close in, and further out
/// [magicSubKeys], each behind the key it goes with. Still holding, slide
/// toward a key and lift to send it; how far you slide picks the ring, so a
/// little way up is ↑ and further up is PgUp — tucked into a side, where the
/// rings fan out far, only a short pull further. Lifting always closes the
/// rings — on a key or not — so they only ever exist while the finger that
/// asked for them is down.
///
/// Drag it straight away, without holding first, to move it: wherever it sits
/// by default is over the thing someone wants to read. Throw it at a side, or
/// push it flat against one, and it tucks in there half off the screen; a tap
/// on what is left brings it back out, a little clear of the edge. Left alone,
/// it fades part way so the output under it shows through; a touch brings it
/// straight back.
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

  /// Tucked into a side, the rings fan out so far that halfway out to ring 2
  /// is a slide across half the screen. There ring 2 takes over this far past
  /// the dead zone instead, wherever it is drawn: a short thumb pull, tuned by
  /// feel.
  static const _tuckedRingStep = 32.0;

  /// How far back inside that a finger in ring 2 has to come before ring 1
  /// has it again, so one resting on the line does not flicker between them.
  static const _tuckedRingSlack = 6.0;

  /// Left alone this long, the button fades to [_idleOpacity] over [_fadeTime]
  /// so it hides less of the output under it.
  static const _idleAfter = Duration(seconds: 3);
  static const _idleOpacity = 0.6;
  static const _fadeTime = Duration(milliseconds: 1800);

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

  /// Out in ring 2's reach, which of the keys behind [_aim] is aimed at; null
  /// while ring 1's [_aim] itself is.
  int? _child;

  /// Faded for want of a touch. The clock starts whenever a finger leaves the
  /// button, and stops when one lands.
  bool _idle = false;
  Timer? _idleClock;

  /// The ring is up, and only for as long as the finger that opened it is.
  bool _picking = false;

  bool _moving = false;

  /// Where the button's centre is and how much room it has, as of the last
  /// layout — what the ring is fitted into when it opens.
  Offset _centre = Offset.zero;
  Size _bounds = Size.zero;

  /// Worked out once, when the rings open, so the petals cannot shift under a
  /// finger that is already aiming at one.
  late ({List<double> angles, double radius, double outer, double spread})
  _ring;

  /// Where the rings' bands meet, halfway between them.
  double get _halfway => (_ring.radius + _ring.outer) / 2;

  /// How far out aiming passes from ring 1 to ring 2: where the bands meet
  /// for a floating key, a short pull for a tucked one — and, once ring 2 has
  /// the finger, [_tuckedRingSlack] short of that, so leaving takes a clear
  /// move back.
  double get _ringTwoFrom => !_docked
      ? _halfway
      : _deadZone + _tuckedRingStep - (_child != null ? _tuckedRingSlack : 0);

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
    _doze();
  }

  @override
  void dispose() {
    _idleClock?.cancel();
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

  /// A finger on the button: it is back at full strength, and stays so while
  /// the finger is down.
  void _wake() {
    _idleClock?.cancel();
    if (_idle) setState(() => _idle = false);
  }

  /// A finger off it: the clock to fade it starts. The rings and a move each
  /// hold a finger down, so they keep it awake anyway; checking again is for a
  /// second finger that lifts while the first is still at it.
  void _doze() {
    _idleClock?.cancel();
    _idleClock = Timer(_idleAfter, () {
      if (!_picking && !_moving) setState(() => _idle = true);
    });
  }

  /// Direction picks the key of ring 1. Past [_ringTwoFrom] it picks ring 2's
  /// petal nearest that direction instead, so straight on is the key right
  /// behind — whichever key of ring 1 that petal hangs off. Where ring 1 has
  /// nothing, the middle or the gap a fan leaves, ring 2 has nothing too.
  ///
  /// Tucked, ring 2 keeps to the keys behind the one ring 1 picked. The fan
  /// there packs ring 2 so tight that its nearest petal is often one hanging
  /// off the next key along, and a pull that lit → must not send `^\`.
  void _aimAt(Offset drag) {
    var aim = petalFor(drag, _ring.angles);
    int? child;
    if (aim != null && drag.distance >= _ringTwoFrom) {
      // North, clockwise, as in [petalFor].
      final pointing = math.atan2(drag.dx, -drag.dy);
      double off(double angle) => _angleBetween(pointing, angle);
      // A key's second key behind sits on the line to the next key of ring 1,
      // so once out in ring 2 the key holds for as long as one of its own
      // keys behind is nearer than that next key is: a lean onto the second
      // keeps it, and only a clear move on to the next key hands over.
      if (_docked && _child != null) {
        final held = _aim!;
        final own = _subAnglesOf(held).map(off).reduce(math.min);
        if (own <= off(_ring.angles[aim])) aim = held;
      }
      final parent = aim;
      var nearest = double.infinity;
      for (var i = 0; i < magicKeys.length; i++) {
        if (_docked && i != parent) continue;
        final angles = _subAnglesOf(i);
        for (var j = 0; j < angles.length; j++) {
          final gap = off(angles[j]);
          if (gap < nearest) {
            nearest = gap;
            aim = i;
            child = j;
          }
        }
      }
    }
    if (aim == _aim && child == _child) return;
    // The finger is covering the button, so this is the only signal that the
    // selection moved.
    if (aim != null) HapticFeedback.selectionClick();
    setState(() {
      _aim = aim;
      _child = child;
    });
  }

  List<MagicKeyAction> _subKeysOf(int index) =>
      magicSubKeys[magicKeys[index].label] ?? const [];

  /// Where ring 2 has the keys behind [index]: the first straight behind it,
  /// so going further the same way reaches it, and the next clockwise.
  List<double> _subAnglesOf(int index) => [
    for (var j = 0; j < _subKeysOf(index).length; j++)
      _ring.angles[index] + j * _ring.spread,
  ];

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

  /// Lifting sends whatever is aimed at, and closes the rings either way.
  void _releaseRing() {
    final aim = _aim, child = _child;
    _closeRing();
    if (child != null) {
      widget.onEmit(_subKeysOf(aim!)[child].send(widget.terminal));
    } else if (aim != null) {
      widget.onEmit(magicKeys[aim].send(widget.terminal));
    }
  }

  void _closeRing() {
    if (!_picking && _aim == null) return;
    setState(() {
      _picking = false;
      _aim = null;
      _child = null;
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
        final scheme = Theme.of(context).colorScheme;

        return Stack(
          children: [
            if (_picking) ...[
              // A band behind each ring, meeting halfway between them, so it
              // shows there are two and, floating, how far out the second one
              // starts.
              _band(2 * _ring.outer - _halfway, scheme.tertiaryContainer),
              _band(_halfway, scheme.secondaryContainer),
              for (var i = 0; i < magicKeys.length; i++) ...[
                _petalAt(
                  _out(_centre, _ring.angles[i], _ring.radius),
                  magicKeys[i].label,
                  aimed: i == _aim && _child == null,
                ),
                for (final (j, angle) in _subAnglesOf(i).indexed)
                  _petalAt(
                    _out(_centre, angle, _ring.outer),
                    _subKeysOf(i)[j].label,
                    aimed: i == _aim && j == _child,
                  ),
              ],
            ],
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
                  // Any touch wakes a faded key, whatever the gesture turns
                  // out to be; a Listener hears it without joining the arena.
                  child: Listener(
                    onPointerDown: (_) => _wake(),
                    onPointerUp: (_) => _doze(),
                    onPointerCancel: (_) => _doze(),
                    child: AnimatedOpacity(
                      opacity: _idle ? _idleOpacity : 1,
                      // Slow to fade, back at once: the touch that wakes it
                      // is already on it.
                      duration: _idle ? _fadeTime : Duration.zero,
                      curve: Curves.easeOut,
                      child: _Button(
                        picking: _picking,
                        moving: _moving,
                        tuckedLeft: _docked ? _onLeft : null,
                      ),
                    ),
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

  /// A disc [radius] round the button, under the petals.
  Widget _band(double radius, Color color) => Positioned(
    left: _centre.dx - radius,
    top: _centre.dy - radius,
    width: 2 * radius,
    height: 2 * radius,
    child: IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.6),
          shape: BoxShape.circle,
        ),
      ),
    ),
  );

  Widget _petalAt(Offset at, String label, {required bool aimed}) {
    return Positioned(
      left: at.dx - _petal / 2,
      top: at.dy - _petal / 2,
      width: _petal,
      height: _petal,
      // A picture of what the finger is aiming at, not a set of buttons: the
      // ring is gone the moment that finger lifts.
      child: IgnorePointer(
        child: _Petal(label: label, aimed: aimed),
      ),
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({required this.picking, required this.moving, this.tuckedLeft});

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
      // Round, since it is the middle of a ring, and edged in the accent as
      // Termul edges a thing to press.
      shape: CircleBorder(side: BorderSide(color: theme.colorScheme.primary)),
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
      shape: CircleBorder(
        side: BorderSide(
          color: aimed
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
        ),
      ),
      color: aimed ? theme.colorScheme.primary : theme.colorScheme.surface,
      child: Center(
        child: Text(
          label,
          style: TextStyle(
            fontFamily: TermulFonts.mono,
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
