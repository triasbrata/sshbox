// Ported from TUI-Termul/termul at 27d94c6fc16502efd103ba217f9e0b52bb164dc5,
// lib/components/tui_magic_key.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// As upstream.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'termul_theme.dart';

/// One slot on the magic key's ring — label only; host maps to terminal bytes.
typedef TuiMagicKeyAction = ({String label});

/// Tap on the floating button emits this label (Enter / CR).
const tuiMagicEnterLabel = '⏎';

/// The ring, clockwise from north.
///
/// Arrows sit where the finger points; diagonals hold shell keys a soft
/// keyboard often lacks.
const List<TuiMagicKeyAction> tuiMagicKeys = [
  (label: '↑'),
  (label: 'ESC'),
  (label: '→'),
  (label: 'TAB'),
  (label: '↓'),
  (label: '^C'),
  (label: '←'),
  (label: '^D'),
];

/// Ring 2: keys behind each of ring 1's, keyed by label.
const Map<String, List<TuiMagicKeyAction>> tuiMagicSubKeys = {
  '↑': [(label: 'PGUP'), (label: 'HOME')],
  'ESC': [(label: 'ESC²')],
  '→': [(label: 'END'), (label: 'W→')],
  'TAB': [(label: '⇧TAB')],
  '↓': [(label: 'PGDN'), (label: 'END')],
  '^C': [(label: '^Z'), (label: '^\\')],
  '←': [(label: 'HOME'), (label: 'W←')],
  '^D': [(label: '^L'), (label: '^R')],
};

/// Default dead zone before a drag aims at a petal.
const double tuiMagicDeadZone = 18;

double _angleBetween(double a, double b) {
  final d = (a - b).abs() % (2 * math.pi);
  return math.min(d, 2 * math.pi - d);
}

/// Widest run of directions where a petal stays inside [bounds].
({double start, double sweep}) tuiMagicFreeArc(
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

/// Petal angles around [centre] inside [bounds] — full compass or edge fan.
({List<double> angles, double radius, double outer, double spread})
tuiMagicRingLayout({
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

  var r = outer;
  var arc = tuiMagicFreeArc(centre, bounds, r, inset);
  for (var round = 0; round < 4; round++) {
    if (arc.sweep <= 0 || arc.sweep >= 2 * math.pi) break;
    final needed = (petal + gap) * (2 * count - 1) / arc.sweep;
    if (needed <= r || r >= maxRadius) break;
    r = math.min(needed, maxRadius);
    arc = tuiMagicFreeArc(centre, bounds, r, inset);
  }
  final inner = r - (outer - radius);

  if (arc.sweep <= 0 || arc.sweep >= 2 * math.pi) {
    return (angles: compass, radius: inner, outer: r, spread: math.pi / count);
  }

  final spacing = arc.sweep / (count - 0.5);
  final slots = [for (var j = 0; j < count; j++) arc.start + spacing * j];
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

/// Which petal a drag from the button centre points at, or null in the gap /
/// dead zone.
int? tuiMagicPetalFor(
  Offset offset,
  List<double> angles, {
  double deadZone = tuiMagicDeadZone,
}) {
  if (offset.distance < deadZone) return null;
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

/// Floating Enter that opens two radial rings on long-press; drag to park /
/// dock against a side. Touch-only affordance — omit on desktop.
///
/// Place with [Positioned.fill] over the terminal; only the button hit-tests.
/// [onEmit] receives key labels (`⏎`, `↑`, `ESC`, `PGUP`, …) — host maps to
/// bytes. Optional [initialSpot] / [onSpotChanged] for persistence.
class TuiMagicKey extends StatefulWidget {
  const TuiMagicKey({
    super.key,
    required this.onEmit,
    this.initialSpot = const Offset(0.95, 0.92),
    this.initialDocked = false,
    this.onSpotChanged,
    this.keys = tuiMagicKeys,
    this.subKeys = tuiMagicSubKeys,
    this.enterLabel = tuiMagicEnterLabel,
  });

  final void Function(String label) onEmit;

  /// Fractional position in the movable room (0–1).
  final Offset initialSpot;
  final bool initialDocked;

  /// `(spot, docked)` whenever the button settles after a move/reveal.
  final void Function(Offset spot, bool docked)? onSpotChanged;

  final List<TuiMagicKeyAction> keys;
  final Map<String, List<TuiMagicKeyAction>> subKeys;
  final String enterLabel;

  @override
  State<TuiMagicKey> createState() => _TuiMagicKeyState();
}

class _TuiMagicKeyState extends State<TuiMagicKey> {
  static const _size = 52.0;
  static const _petal = 40.0;
  static const _throwSpeed = 700.0;
  static const _inset = 16.0;
  static const _glideTime = Duration(milliseconds: 220);
  static const _tuckedRingStep = 32.0;
  static const _tuckedRingSlack = 6.0;
  static const _idleAfter = Duration(seconds: 3);
  static const _idleOpacity = 0.55;
  static const _fadeTime = Duration(milliseconds: 1800);

  late Offset _spot = widget.initialSpot;
  late bool _docked = widget.initialDocked;

  bool get _onLeft => _spot.dx < 0.5;

  Duration _glide = Duration.zero;
  Offset _anchor = Offset.zero;
  Offset _grab = Offset.zero;

  int? _aim;
  int? _child;
  bool _idle = false;
  Timer? _idleClock;
  bool _picking = false;
  bool _moving = false;

  Offset _centre = Offset.zero;
  Size _bounds = Size.zero;

  late ({List<double> angles, double radius, double outer, double spread})
  _ring;

  double get _halfway => (_ring.radius + _ring.outer) / 2;

  double get _ringTwoFrom => !_docked
      ? _halfway
      : tuiMagicDeadZone +
            _tuckedRingStep -
            (_child != null ? _tuckedRingSlack : 0);

  @override
  void initState() {
    super.initState();
    _doze();
  }

  @override
  void dispose() {
    _idleClock?.cancel();
    super.dispose();
  }

  void _remember() => widget.onSpotChanged?.call(_spot, _docked);

  void _wake() {
    _idleClock?.cancel();
    if (_idle) setState(() => _idle = false);
  }

  void _doze() {
    _idleClock?.cancel();
    _idleClock = Timer(_idleAfter, () {
      if (!_picking && !_moving) setState(() => _idle = true);
    });
  }

  List<TuiMagicKeyAction> _subKeysOf(int index) =>
      widget.subKeys[widget.keys[index].label] ?? const [];

  List<double> _subAnglesOf(int index) => [
    for (var j = 0; j < _subKeysOf(index).length; j++)
      _ring.angles[index] + j * _ring.spread,
  ];

  void _aimAt(Offset drag) {
    var aim = tuiMagicPetalFor(drag, _ring.angles);
    int? child;
    if (aim != null && drag.distance >= _ringTwoFrom) {
      final pointing = math.atan2(drag.dx, -drag.dy);
      double off(double angle) => _angleBetween(pointing, angle);
      if (_docked && _child != null) {
        final held = _aim!;
        final own = _subAnglesOf(held).map(off).reduce(math.min);
        if (own <= off(_ring.angles[aim])) aim = held;
      }
      final parent = aim;
      var nearest = double.infinity;
      for (var i = 0; i < widget.keys.length; i++) {
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
    if (aim != null) HapticFeedback.selectionClick();
    setState(() {
      _aim = aim;
      _child = child;
    });
  }

  void _openRing(LongPressStartDetails _) {
    _ring = tuiMagicRingLayout(
      centre: _centre,
      bounds: _bounds,
      count: widget.keys.length,
      petal: _petal,
    );
    HapticFeedback.mediumImpact();
    setState(() {
      _picking = true;
      _aim = null;
    });
  }

  void _releaseRing() {
    final aim = _aim, child = _child;
    _closeRing();
    if (child != null) {
      widget.onEmit(_subKeysOf(aim!)[child].label);
    } else if (aim != null) {
      widget.onEmit(widget.keys[aim].label);
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
    _remember();
  }

  void _reveal(Size room) {
    final inset = (_inset / room.width).clamp(0.0, 1.0);
    setState(() {
      _docked = false;
      _glide = _glideTime;
      _spot = Offset(_onLeft ? inset : 1 - inset, _spot.dy);
    });
    _remember();
  }

  static Offset _out(Offset from, double angle, double distance) =>
      from + Offset(math.sin(angle), -math.cos(angle)) * distance;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;

    return LayoutBuilder(
      builder: (context, constraints) {
        final room = Size(
          math.max(1, constraints.maxWidth - _size),
          math.max(1, constraints.maxHeight - _size),
        );
        final origin = Offset(
          _docked
              ? (_onLeft ? 0 : constraints.maxWidth) - _size / 2
              : _spot.dx * room.width,
          _spot.dy * room.height,
        );
        _centre = origin + const Offset(_size / 2, _size / 2);
        _bounds = constraints.biggest;

        return Stack(
          children: [
            if (_picking) ...[
              _band(2 * _ring.outer - _halfway, p.selection),
              _band(_halfway, p.surface.withValues(alpha: 0.85)),
              for (var i = 0; i < widget.keys.length; i++) ...[
                _petalAt(
                  _out(_centre, _ring.angles[i], _ring.radius),
                  widget.keys[i].label,
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
              key: const ValueKey('tui-magic-key-button'),
              duration: _glide,
              curve: Curves.easeOutCubic,
              left: origin.dx,
              top: origin.dy,
              width: _size,
              height: _size,
              child: Semantics(
                label: _docked ? 'Show Enter key' : 'Send Enter',
                button: true,
                child: GestureDetector(
                  onTap: _docked
                      ? () => _reveal(room)
                      : () => widget.onEmit(widget.enterLabel),
                  onLongPressStart: _openRing,
                  onLongPressMoveUpdate: (details) =>
                      _aimAt(details.offsetFromOrigin),
                  onLongPressEnd: (_) => _releaseRing(),
                  onLongPressCancel: _closeRing,
                  onPanStart: _startMoving,
                  onPanUpdate: (details) => _keepMoving(details, room),
                  onPanEnd: (details) => _stopMoving(details.velocity),
                  onPanCancel: _stopMoving,
                  child: Listener(
                    onPointerDown: (_) => _wake(),
                    onPointerUp: (_) => _doze(),
                    onPointerCancel: (_) => _doze(),
                    child: AnimatedOpacity(
                      opacity: _idle ? _idleOpacity : 1,
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

  Widget _band(double radius, Color color) => Positioned(
    left: _centre.dx - radius,
    top: _centre.dy - radius,
    width: 2 * radius,
    height: 2 * radius,
    child: IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.55),
          shape: BoxShape.circle,
          border: Border.all(color: TermulThemeData.of(context).palette.border),
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
  final bool? tuckedLeft;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final tucked = tuckedLeft;

    final bg = moving
        ? p.deep
        : picking
        ? p.surface
        : p.accent;
    final fg = moving || !picking
        ? (p.isLight && !moving ? p.panel : p.bg)
        : p.text;

    final glyph = moving
        ? '✥'
        : tucked != null
        ? (tucked ? '›' : '‹')
        : picking
        ? '◎'
        : '⏎';

    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
        border: Border.all(color: p.border, width: moving ? 2 : 1),
      ),
      child: Align(
        alignment: tucked == null
            ? Alignment.center
            : Alignment(tucked ? 0.8 : -0.8, 0),
        child: Text(
          glyph,
          style: TextStyle(
            fontFamily: TermulFonts.mono,
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: fg,
            height: 1,
          ),
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
    final p = TermulThemeData.of(context).palette;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: aimed ? p.accent : p.panel,
        shape: BoxShape.circle,
        border: Border.all(
          color: aimed ? p.accent : p.border,
          width: aimed ? 2 : 1,
        ),
      ),
      child: Center(
        child: Text(
          label,
          style: TextStyle(
            fontFamily: TermulFonts.mono,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: aimed ? (p.isLight ? p.panel : p.bg) : p.text,
          ),
        ),
      ),
    );
  }
}
