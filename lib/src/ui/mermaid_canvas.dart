import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../mermaid/mermaid.dart';
import 'termul/termul_palette.dart';
import 'termul/termul_theme.dart';

/// A Mermaid diagram laid out and painted by Jeansh itself, in the app's
/// fonts and the termul palette: no web view, so it is the right size from
/// its first frame, follows the theme at once and draws on every platform.
class MermaidCanvas extends StatelessWidget {
  const MermaidCanvas({
    super.key,
    required this.diagram,
    required this.source,
    required this.background,
  });

  final MermaidDrawable diagram;

  /// What [diagram] was read from: the key its layout is kept under.
  final String source;

  /// What the diagram sits on, which a label over a line is filled with.
  final Color background;

  /// Layouts by source and face, so a rebuild — every key in the rich text —
  /// does not lay a diagram out again.
  ///
  /// ponytail: 48 entries, a few KB each.
  static final _scenes = <(String, String, double), MermaidScene>{};

  static TextStyle styleOf(TextStyle base, MText kind) => base.copyWith(
    fontSize: switch (kind) {
      MText.node || MText.actor => 14,
      MText.edgeLabel || MText.frameTitle => 12,
      MText.frameKind => 11,
      MText.number => 10,
      _ => 13,
    },
    fontWeight: switch (kind) {
      MText.cluster || MText.frameKind || MText.number => FontWeight.w600,
      _ => FontWeight.w400,
    },
    height: 1.3,
    fontStyle: FontStyle.normal,
    decoration: TextDecoration.none,
    letterSpacing: 0,
  );

  static TextPainter _painter(
    String text,
    TextStyle style,
    TextScaler scaler,
    TextAlign align,
  ) => TextPainter(
    text: TextSpan(text: text, style: style),
    textAlign: align,
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    textWidthBasis: TextWidthBasis.longestLine,
  );

  /// Lays [diagram] out in [base]'s face at [scaler].
  static MermaidScene sceneOf(
    MermaidDrawable diagram,
    String source,
    TextStyle base,
    TextScaler scaler,
  ) {
    final key = (
      source,
      '${base.fontFamily}/${base.fontFamilyFallback}',
      scaler.scale(14),
    );
    final known = _scenes.remove(key);
    if (known != null) return _scenes[key] = known;
    final scene = diagram.layout((text, kind, maxWidth) {
      final tp = _painter(text, styleOf(base, kind), scaler, TextAlign.center)
        ..layout(maxWidth: maxWidth);
      final size = Size(tp.width.ceilToDouble(), tp.height.ceilToDouble());
      tp.dispose();
      return size;
    });
    _scenes[key] = scene;
    if (_scenes.length > 48) _scenes.remove(_scenes.keys.first);
    return scene;
  }

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);
    final scene = sceneOf(diagram, source, base, scaler);
    final palette = TermulThemeData.of(context).palette;
    return Semantics(
      container: true,
      image: true,
      label: scene.description,
      child: CustomPaint(
        size: scene.size,
        painter: MermaidPainter(
          scene,
          MermaidColors.of(palette, background),
          base,
          scaler,
        ),
      ),
    );
  }
}

/// The colours a diagram is painted in, from the termul palette.
@immutable
class MermaidColors {
  const MermaidColors({
    required this.background,
    required this.text,
    required this.line,
    required this.nodeFill,
    required this.nodeStroke,
    required this.clusterFill,
    required this.clusterStroke,
    required this.noteFill,
    required this.noteStroke,
    required this.tabFill,
    required this.badgeFill,
    required this.badgeText,
  });

  factory MermaidColors.of(TermulPalette p, Color background) {
    Color tint(Color c, double a) =>
        Color.alphaBlend(c.withValues(alpha: a), background);
    return MermaidColors(
      background: background,
      text: p.text,
      line: p.muted,
      nodeFill: tint(p.accent, 0.12),
      nodeStroke: p.accent,
      clusterFill: tint(p.text, 0.04),
      clusterStroke: p.border,
      noteFill: tint(p.yellow, 0.18),
      noteStroke: p.yellow,
      tabFill: tint(p.muted, 0.18),
      badgeFill: p.accent,
      badgeText: p.bg,
    );
  }

  final Color background;
  final Color text;
  final Color line;
  final Color nodeFill;
  final Color nodeStroke;
  final Color clusterFill;
  final Color clusterStroke;
  final Color noteFill;
  final Color noteStroke;
  final Color tabFill;
  final Color badgeFill;
  final Color badgeText;

  @override
  bool operator ==(Object other) =>
      other is MermaidColors &&
      other.background == background &&
      other.text == text &&
      other.line == line &&
      other.nodeFill == nodeFill &&
      other.nodeStroke == nodeStroke &&
      other.clusterFill == clusterFill &&
      other.clusterStroke == clusterStroke &&
      other.noteFill == noteFill &&
      other.noteStroke == noteStroke &&
      other.tabFill == tabFill &&
      other.badgeFill == badgeFill &&
      other.badgeText == badgeText;

  @override
  int get hashCode => Object.hash(
    background,
    text,
    line,
    nodeFill,
    nodeStroke,
    clusterFill,
    clusterStroke,
    noteFill,
    noteStroke,
    tabFill,
    badgeFill,
    badgeText,
  );
}

class MermaidPainter extends CustomPainter {
  MermaidPainter(this.scene, this.colors, this.base, this.scaler);

  final MermaidScene scene;
  final MermaidColors colors;
  final TextStyle base;
  final TextScaler scaler;

  @override
  void paint(Canvas canvas, Size size) {
    for (final item in scene.items) {
      switch (item) {
        case MBox():
          _box(canvas, item);
        case MLine():
          _line(canvas, item);
        case MLabel():
          _label(canvas, item);
      }
    }
  }

  Paint _stroke(Color c, [double w = 1.4]) => Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..isAntiAlias = true;

  Paint _fill(Color c) => Paint()
    ..color = c
    ..style = PaintingStyle.fill;

  void _box(Canvas canvas, MBox box) {
    final r = box.rect;
    final l = r.left, t = r.top, rr = r.right, b = r.bottom;
    final cy = r.center.dy;
    Path poly(List<Offset> pts) => Path()..addPolygon(pts, true);
    void shape(Path path, Color fill, Color stroke) {
      canvas
        ..drawPath(path, _fill(fill))
        ..drawPath(path, _stroke(stroke));
    }

    final node = colors.nodeFill, edge = colors.nodeStroke;
    final o = r.height / 2;
    switch (box.shape) {
      case MShape.rect || MShape.actorBox:
        shape(
          Path()
            ..addRRect(RRect.fromRectAndRadius(r, const Radius.circular(3))),
          node,
          edge,
        );
      case MShape.round:
        shape(
          Path()
            ..addRRect(RRect.fromRectAndRadius(r, const Radius.circular(10))),
          node,
          edge,
        );
      case MShape.stadium:
        shape(
          Path()..addRRect(RRect.fromRectAndRadius(r, Radius.circular(o))),
          node,
          edge,
        );
      case MShape.subroutine:
        shape(Path()..addRect(r), node, edge);
        canvas
          ..drawLine(Offset(l + 8, t), Offset(l + 8, b), _stroke(edge))
          ..drawLine(Offset(rr - 8, t), Offset(rr - 8, b), _stroke(edge));
      case MShape.cylinder:
        final ry = math.min(8.0, r.height / 6);
        final top = Rect.fromLTWH(l, t, r.width, ry * 2);
        final body = Path()
          ..moveTo(l, t + ry)
          ..lineTo(l, b - ry)
          ..arcTo(
            Rect.fromLTWH(l, b - ry * 2, r.width, ry * 2),
            math.pi,
            -math.pi,
            false,
          )
          ..lineTo(rr, t + ry)
          ..arcTo(top, 0, -math.pi, false)
          ..close();
        shape(body, node, edge);
        canvas.drawArc(top, 0, math.pi, false, _stroke(edge));
      case MShape.circle:
        shape(Path()..addOval(r), node, edge);
      case MShape.doubleCircle:
        shape(Path()..addOval(r), node, edge);
        canvas.drawOval(r.deflate(4), _stroke(edge));
      case MShape.asymmetric:
        shape(
          poly([
            Offset(l, t),
            Offset(rr, t),
            Offset(rr, b),
            Offset(l, b),
            Offset(l + o / 2, cy),
          ]),
          node,
          edge,
        );
      case MShape.rhombus:
        shape(
          poly([r.topCenter, r.centerRight, r.bottomCenter, r.centerLeft]),
          node,
          edge,
        );
      case MShape.hexagon:
        final k = o / 2;
        shape(
          poly([
            Offset(l + k, t),
            Offset(rr - k, t),
            Offset(rr, cy),
            Offset(rr - k, b),
            Offset(l + k, b),
            Offset(l, cy),
          ]),
          node,
          edge,
        );
      case MShape.parallelogram:
        shape(
          poly([
            Offset(l + o, t),
            Offset(rr, t),
            Offset(rr - o, b),
            Offset(l, b),
          ]),
          node,
          edge,
        );
      case MShape.parallelogramAlt:
        shape(
          poly([
            Offset(l, t),
            Offset(rr - o, t),
            Offset(rr, b),
            Offset(l + o, b),
          ]),
          node,
          edge,
        );
      case MShape.trapezoid:
        shape(
          poly([
            Offset(l + o, t),
            Offset(rr - o, t),
            Offset(rr, b),
            Offset(l, b),
          ]),
          node,
          edge,
        );
      case MShape.trapezoidAlt:
        shape(
          poly([
            Offset(l, t),
            Offset(rr, t),
            Offset(rr - o, b),
            Offset(l + o, b),
          ]),
          node,
          edge,
        );
      case MShape.cluster:
        shape(
          Path()
            ..addRRect(RRect.fromRectAndRadius(r, const Radius.circular(6))),
          colors.clusterFill,
          colors.clusterStroke,
        );
      case MShape.note:
        shape(Path()..addRect(r), colors.noteFill, colors.noteStroke);
      case MShape.actorFigure:
        final p = _stroke(edge, 1.6);
        final cx = r.center.dx;
        canvas
          ..drawCircle(Offset(cx, t + 6), 6, p)
          ..drawLine(Offset(cx, t + 12), Offset(cx, t + 24), p)
          ..drawLine(Offset(l + 2, t + 16), Offset(rr - 2, t + 16), p)
          ..drawLine(Offset(cx, t + 24), Offset(l + 3, b), p)
          ..drawLine(Offset(cx, t + 24), Offset(rr - 3, b), p);
      case MShape.frame:
        canvas.drawRect(r, _stroke(colors.line, 1));
      case MShape.frameTab:
        shape(
          poly([
            Offset(l, t),
            Offset(rr, t),
            Offset(rr, b - 6),
            Offset(rr - 6, b),
            Offset(l, b),
          ]),
          colors.tabFill,
          colors.line,
        );
      case MShape.activation:
        shape(Path()..addRect(r), colors.tabFill, colors.line);
      case MShape.badge:
        canvas.drawOval(r, _fill(colors.badgeFill));
    }
  }

  void _line(Canvas canvas, MLine line) {
    final pts = line.points;
    if (pts.length < 2) return;
    final color = switch (line.role) {
      MLineRole.lifeline => colors.clusterStroke,
      _ => colors.line,
    };
    final width = switch (line.stroke) {
      MStroke.thick => 3.0,
      _ => 1.4,
    };
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    // A smooth curve through the bends, Catmull-Rom's, as cubic segments.
    var endFrom = pts[pts.length - 2];
    var startTo = pts[1];
    if (line.curved && pts.length > 2) {
      for (var i = 0; i + 1 < pts.length; i++) {
        final p0 = pts[math.max(0, i - 1)];
        final p1 = pts[i];
        final p2 = pts[i + 1];
        final p3 = pts[math.min(pts.length - 1, i + 2)];
        final c1 = p1 + (p2 - p0) / 6;
        final c2 = p2 - (p3 - p1) / 6;
        path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
        if (i == 0 && c1 != p1) startTo = c1;
        if (i + 2 == pts.length && c2 != p2) endFrom = c2;
      }
    } else {
      for (final p in pts.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
    }
    final dash = switch (line.stroke) {
      MStroke.dotted => const [2.0, 4.0],
      MStroke.dashed => const [6.0, 4.0],
      _ => null,
    };
    final paint = _stroke(color, width);
    canvas.drawPath(dash == null ? path : _dashed(path, dash), paint);
    _head(canvas, line.end, pts.last, endFrom, color, width);
    _head(canvas, line.start, pts.first, startTo, color, width);
  }

  static Path _dashed(Path path, List<double> dash) {
    final out = Path();
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      var on = true;
      var k = 0;
      while (d < metric.length) {
        final len = dash[k % dash.length];
        if (on) {
          out.addPath(
            metric.extractPath(d, math.min(d + len, metric.length)),
            Offset.zero,
          );
        }
        d += len;
        on = !on;
        k++;
      }
    }
    return out;
  }

  void _head(
    Canvas canvas,
    MHead head,
    Offset tip,
    Offset from,
    Color color,
    double width,
  ) {
    final d = tip - from;
    if (d.distance == 0) return;
    final u = d / d.distance;
    final n = Offset(-u.dy, u.dx);
    final len = 9.0 + width;
    switch (head) {
      case MHead.none:
        return;
      case MHead.arrow:
        final back = tip - u * len;
        canvas.drawPath(
          Path()..addPolygon([
            tip,
            back + n * (len * 0.45),
            back - n * (len * 0.45),
          ], true),
          _fill(color),
        );
      case MHead.open:
        final back = tip - u * len;
        final p = _stroke(color, width);
        canvas
          ..drawLine(tip, back + n * (len * 0.45), p)
          ..drawLine(tip, back - n * (len * 0.45), p);
      case MHead.circle:
        canvas
          ..drawCircle(tip - u * 4, 4, _fill(colors.background))
          ..drawCircle(tip - u * 4, 4, _stroke(color, width));
      case MHead.cross:
        final c = tip - u * 5;
        final p = _stroke(color, width);
        canvas
          ..drawLine(c + (u + n) * 4, c - (u + n) * 4, p)
          ..drawLine(c + (u - n) * 4, c - (u - n) * 4, p);
    }
  }

  void _label(Canvas canvas, MLabel label) {
    if (label.background) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          label.rect.inflate(2),
          const Radius.circular(3),
        ),
        _fill(colors.background),
      );
    }
    final style = MermaidCanvas.styleOf(base, label.kind).copyWith(
      color: label.kind == MText.number ? colors.badgeText : colors.text,
    );
    final tp = MermaidCanvas._painter(
      label.text,
      style,
      scaler,
      label.center ? TextAlign.center : TextAlign.left,
    )..layout(minWidth: label.rect.width, maxWidth: label.rect.width + 1);
    tp.paint(canvas, label.rect.topLeft);
    tp.dispose();
  }

  @override
  bool shouldRepaint(MermaidPainter old) =>
      old.scene != scene ||
      old.colors != colors ||
      old.base != base ||
      old.scaler != scaler;
}
