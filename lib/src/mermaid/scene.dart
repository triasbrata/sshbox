/// What a Mermaid diagram is drawn as: boxes, lines and text at places
/// worked out in Dart, painted by `MermaidCanvas` with the app's own fonts
/// and palette. Nothing here knows about Flutter's widgets, so a layout can
/// be tested, and kept in a golden, as plain geometry.
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

/// The kinds of text a diagram holds, each with a face of its own.
enum MText {
  node,
  edgeLabel,
  cluster,
  actor,
  message,
  note,
  frameKind,
  frameTitle,
  number,
}

/// Measures [text] in [kind]'s face, wrapping at [maxWidth]. A line break in
/// the text is a line break.
typedef MermaidMeasure = Size Function(
  String text,
  MText kind,
  double maxWidth,
);

enum MShape {
  rect,
  round,
  stadium,
  subroutine,
  cylinder,
  circle,
  doubleCircle,
  asymmetric,
  rhombus,
  hexagon,
  parallelogram,
  parallelogramAlt,
  trapezoid,
  trapezoidAlt,

  /// A subgraph.
  cluster,
  note,

  /// A sequence diagram's participant.
  actorBox,

  /// A sequence diagram's actor: a stick figure in its rect.
  actorFigure,

  /// A sequence diagram's loop, alt, opt and the rest.
  frame,

  /// The tab in a frame's corner naming its kind.
  frameTab,
  activation,

  /// Autonumber's numbered circle.
  badge,
}

enum MStroke { solid, thick, dotted, dashed }

enum MHead { none, arrow, open, circle, cross }

enum MLineRole { edge, lifeline, separator }

sealed class MItem {
  const MItem();

  Rect get bounds;

  MItem shifted(Offset by);

  /// One line of the golden file.
  String dump();
}

String _n(double v) {
  final r = (v * 10).round() / 10;
  return r == r.roundToDouble() ? r.toInt().toString() : r.toString();
}

String _rect(Rect r) =>
    '${_n(r.left)},${_n(r.top)} ${_n(r.width)}x${_n(r.height)}';

class MBox extends MItem {
  const MBox(this.shape, this.rect);

  final MShape shape;
  final Rect rect;

  @override
  Rect get bounds => rect;

  @override
  MBox shifted(Offset by) => MBox(shape, rect.shift(by));

  @override
  String dump() => 'box ${shape.name} ${_rect(rect)}';
}

class MLine extends MItem {
  const MLine(
    this.points, {
    this.stroke = MStroke.solid,
    this.start = MHead.none,
    this.end = MHead.none,
    this.curved = false,
    this.role = MLineRole.edge,
  });

  final List<Offset> points;
  final MStroke stroke;
  final MHead start;
  final MHead end;

  /// Drawn as a smooth curve through [points] rather than straight between
  /// them.
  final bool curved;
  final MLineRole role;

  @override
  Rect get bounds {
    var l = double.infinity, t = double.infinity;
    var r = -double.infinity, b = -double.infinity;
    for (final p in points) {
      l = math.min(l, p.dx);
      t = math.min(t, p.dy);
      r = math.max(r, p.dx);
      b = math.max(b, p.dy);
    }
    // An arrowhead reaches a little past its line's end.
    return Rect.fromLTRB(l, t, r, b).inflate(6);
  }

  @override
  MLine shifted(Offset by) => MLine(
    [for (final p in points) p + by],
    stroke: stroke,
    start: start,
    end: end,
    curved: curved,
    role: role,
  );

  @override
  String dump() =>
      'line ${role.name} ${stroke.name} ${start.name}-${end.name}'
      '${curved ? ' curved' : ''} '
      '${points.map((p) => '(${_n(p.dx)},${_n(p.dy)})').join(' ')}';
}

class MLabel extends MItem {
  const MLabel(
    this.text,
    this.kind,
    this.rect, {
    this.background = false,
    this.center = true,
  });

  final String text;
  final MText kind;

  /// Where the text sits, as measured: it is laid out to this width again
  /// when painted.
  final Rect rect;

  /// Painted on the diagram's background colour, so a line under it does
  /// not run through the words.
  final bool background;
  final bool center;

  @override
  Rect get bounds => rect;

  @override
  MLabel shifted(Offset by) => MLabel(
    text,
    kind,
    rect.shift(by),
    background: background,
    center: center,
  );

  @override
  String dump() =>
      'text ${kind.name} ${_rect(rect)} '
      '"${text.replaceAll('\n', r'\n')}"';
}

/// One diagram, laid out.
class MermaidScene {
  MermaidScene._(this.items, this.size, this.description);

  /// Moves [items] so the leftmost and topmost of them sit [margin] from the
  /// edge, and sizes the scene to hold them all.
  factory MermaidScene(
    List<MItem> items, {
    required String description,
    double margin = 8,
  }) {
    if (items.isEmpty) return MermaidScene._(const [], Size.zero, description);
    var bounds = items.first.bounds;
    for (final item in items.skip(1)) {
      bounds = bounds.expandToInclude(item.bounds);
    }
    final by = Offset(margin - bounds.left, margin - bounds.top);
    return MermaidScene._(
      [for (final item in items) item.shifted(by)],
      Size(bounds.width + margin * 2, bounds.height + margin * 2),
      description,
    );
  }

  /// In the order they are painted, back to front.
  final List<MItem> items;
  final Size size;

  /// What a screen reader says for the whole diagram.
  final String description;

  String dump() =>
      'size ${_n(size.width)}x${_n(size.height)}\n'
      '${items.map((i) => i.dump()).join('\n')}\n';
}

/// Where a line from [center] towards [toward] leaves [shape] in [rect].
Offset clipToShape(MShape shape, Rect rect, Offset toward) {
  final c = rect.center;
  final d = toward - c;
  if (d.dx == 0 && d.dy == 0) return c;
  final hw = rect.width / 2, hh = rect.height / 2;
  switch (shape) {
    case MShape.rhombus:
      final t = 1 / (d.dx.abs() / hw + d.dy.abs() / hh);
      return c + d * t;
    case MShape.circle || MShape.doubleCircle:
      return c + d / d.distance * math.min(hw, hh);
    default:
      final tx = d.dx == 0 ? double.infinity : hw / d.dx.abs();
      final ty = d.dy == 0 ? double.infinity : hh / d.dy.abs();
      final t = math.min(tx, ty);
      return t >= 1 ? toward : c + d * t;
  }
}

/// Makes the label text Mermaid's way: `<br>` and `<br/>` are line breaks,
/// a Markdown string's backticks go, and the entity codes Mermaid knows for
/// characters its grammar would otherwise read are the characters.
String mermaidText(String raw) {
  var s = raw.trim();
  if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
    s = s.substring(1, s.length - 1);
  }
  if (s.length >= 2 && s.startsWith('`') && s.endsWith('`')) {
    s = s.substring(1, s.length - 1);
  }
  s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  s = s.replaceAllMapped(RegExp(r'#(\d+|quot|amp|lt|gt|nbsp);'), (m) {
    final code = m[1]!;
    return switch (code) {
      'quot' => '"',
      'amp' => '&',
      'lt' => '<',
      'gt' => '>',
      'nbsp' => ' ',
      _ => String.fromCharCode(int.parse(code)),
    };
  });
  return s;
}

/// A diagram's source that could not be read: [line] is 1-based.
class MermaidError implements Exception {
  const MermaidError(this.message, {this.line});

  final String message;
  final int? line;

  @override
  String toString() => line == null ? message : 'line $line: $message';
}
