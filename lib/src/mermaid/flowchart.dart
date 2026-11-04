/// Mermaid's flowchart (and its older name, graph): read, and laid out as a
/// [MermaidScene].
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'layered.dart';
import 'scene.dart';

class FlowNode {
  FlowNode(this.id, this.order) : label = id;

  final String id;
  final int order;
  String label;
  MShape shape = MShape.rect;

  /// The subgraph it is drawn in, null for the top.
  String? group;
}

class FlowEdge {
  FlowEdge(
    this.from,
    this.to, {
    this.label,
    this.stroke = MStroke.solid,
    this.start = MHead.none,
    this.end = MHead.arrow,
    this.length = 1,
  });

  final String from;
  final String to;
  final String? label;
  final MStroke stroke;
  final MHead start;
  final MHead end;
  final int length;
}

class FlowGroup {
  FlowGroup(this.id, this.label, this.parent, this.order);

  final String id;
  final String label;
  final String? parent;
  final int order;
}

class Flowchart {
  Flowchart(this.direction);

  LayerDirection direction;
  final nodes = <String, FlowNode>{};
  final groups = <String, FlowGroup>{};
  final edges = <FlowEdge>[];

  int _order = 0;

  FlowNode node(String id, String? group) {
    final known = nodes[id];
    if (known != null) {
      // A node first met at the top and then inside a subgraph is drawn in
      // the subgraph, as Mermaid draws it.
      if (known.group == null && group != null && !groups.containsKey(id)) {
        known.group = group;
      }
      return known;
    }
    return nodes[id] = FlowNode(id, _order++)..group = group;
  }

  // ------------------------------------------------------------ reading

  static final _header = RegExp(
    r'^(graph|flowchart)\b(?:\s+(TB|TD|BT|RL|LR)\b)?\s*;?\s*(.*)$',
  );

  /// Reads [source], from its `graph` or `flowchart` line on; anything it
  /// does not know throws [MermaidError], naming the line.
  static Flowchart parse(String source) {
    final lines = source.split('\n');
    var i = _skipPreamble(lines);
    if (i == lines.length) throw const MermaidError('no diagram');
    final head = _header.firstMatch(lines[i].trim());
    if (head == null) throw MermaidError('not a flowchart', line: i + 1);
    final chart = Flowchart(switch (head[2]) {
      'BT' => LayerDirection.bt,
      'LR' => LayerDirection.lr,
      'RL' => LayerDirection.rl,
      _ => LayerDirection.tb,
    });
    final stack = <String>[];
    void statement(String text, int line) {
      final s = text.trim();
      if (s.isEmpty || s.startsWith('%%')) return;
      final word = s.split(RegExp(r'\s')).first;
      if (_ignored.contains(word)) return;
      if (word == 'subgraph') {
        final g = _subgraph(s.substring(8).trim(), line);
        final id = chart.groups.containsKey(g.$1)
            ? '${g.$1}#${chart._order}'
            : g.$1;
        chart.groups[id] = FlowGroup(
          id,
          g.$2,
          stack.isEmpty ? null : stack.last,
          chart._order++,
        );
        stack.add(id);
        return;
      }
      if (s == 'end') {
        if (stack.isEmpty) {
          throw MermaidError('end with no subgraph', line: line);
        }
        stack.removeLast();
        return;
      }
      if (word == 'direction') return;
      _Chain(chart, s, stack.isEmpty ? null : stack.last, line).read();
    }

    final rest = head[3]!;
    if (rest.isNotEmpty) {
      for (final part in _split(rest)) {
        statement(part, i + 1);
      }
    }
    for (i++; i < lines.length; i++) {
      for (final part in _split(lines[i])) {
        statement(part, i + 1);
      }
    }
    if (stack.isNotEmpty) {
      throw MermaidError('subgraph ${stack.last} is never ended');
    }
    // A subgraph named in an edge is that subgraph, not a node.
    for (final id in chart.groups.keys) {
      chart.nodes.remove(id);
    }
    return chart;
  }

  static const _ignored = {
    'classDef',
    'class',
    'style',
    'linkStyle',
    'click',
    'accTitle',
    'accDescr',
    'accTitle:',
    'accDescr:',
  };

  static (String, String) _subgraph(String rest, int line) {
    if (rest.isEmpty) throw MermaidError('subgraph with no name', line: line);
    final m = RegExp(r'^([^\s\[]+)\s*\[(.*)\]$').firstMatch(rest);
    if (m != null) return (m[1]!, mermaidText(m[2]!));
    final label = mermaidText(rest);
    return (label, label);
  }

  /// [line] cut at each `;` that is not inside quotes or a shape.
  static List<String> _split(String line) {
    final parts = <String>[];
    var depth = 0;
    var quoted = false;
    var from = 0;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        quoted = !quoted;
      } else if (!quoted && '[({'.contains(ch)) {
        depth++;
      } else if (!quoted && '])}'.contains(ch)) {
        depth = math.max(0, depth - 1);
      } else if (!quoted && depth == 0 && ch == ';') {
        parts.add(line.substring(from, i));
        from = i + 1;
      }
    }
    parts.add(line.substring(from));
    return parts;
  }

  // ------------------------------------------------------------- layout

  Size _nodeSize(FlowNode node, MermaidMeasure measure) {
    final t = measure(node.label, MText.node, 200);
    final w = t.width, h = t.height;
    return switch (node.shape) {
      MShape.rhombus => Size.square(w / 2 + h / 2 + 16) * 2,
      MShape.circle => Size.square(math.sqrt(w * w + h * h) + 16),
      MShape.doubleCircle => Size.square(math.sqrt(w * w + h * h) + 26),
      MShape.stadium => Size(w + h + 24, h + 20),
      MShape.cylinder => Size(w + 30, h + 34),
      MShape.subroutine => Size(w + 46, h + 20),
      MShape.hexagon ||
      MShape.parallelogram ||
      MShape.parallelogramAlt ||
      MShape.trapezoid ||
      MShape.trapezoidAlt => Size(w + 30 + h, h + 20),
      MShape.asymmetric => Size(w + 30 + h / 2, h + 20),
      _ => Size(w + 30, h + 20),
    };
  }

  MermaidScene layout(MermaidMeasure measure) {
    const pad = 16.0;
    final sizes = <String, Size>{
      for (final n in nodes.values) n.id: _nodeSize(n, measure),
    };
    final titles = <String, Size>{
      for (final g in groups.values) g.id: measure(g.label, MText.cluster, 240),
    };
    String? parentOf(String id) => nodes[id]?.group ?? groups[id]?.parent;
    List<String?> path(String id) {
      final p = <String?>[id];
      for (var at = parentOf(id); at != null; at = parentOf(at)) {
        p.insert(0, at);
      }
      return [null, ...p];
    }

    // Every edge is laid out in the subgraph that holds both its ends.
    final at = <String?, List<(int, String, String)>>{};
    for (var e = 0; e < edges.length; e++) {
      final edge = edges[e];
      if (edge.from == edge.to) continue;
      final a = path(edge.from), b = path(edge.to);
      var k = 0;
      while (k < a.length && k < b.length && a[k] == b[k]) {
        k++;
      }
      // One end inside the other: a subgraph linked to its own node.
      if (k >= a.length || k >= b.length) continue;
      (at[a[k - 1]] ??= []).add((e, a[k]!, b[k]!));
    }

    final local = <String, Offset>{}; // a child's centre in its parent
    final boxes = <String, Size>{}; // each subgraph's size
    final inset = <String?, Offset>{}; // where a parent's children start
    final routes = <int, List<Offset>>{};
    final labels = <int, Offset>{};
    final routeOwner = <int, String?>{};

    void place(String? group) {
      final children = <String>[
        ...nodes.values.where((n) => n.group == group).map((n) => n.id),
        ...groups.values.where((g) => g.parent == group).map((g) => g.id),
      ]..sort((x, y) => _orderOf(x).compareTo(_orderOf(y)));
      for (final child in children) {
        if (groups.containsKey(child)) place(child);
      }
      final index = {for (var i = 0; i < children.length; i++) children[i]: i};
      final mine = at[group] ?? const [];
      final result = layered(
        sizes: [for (final c in children) sizes[c] ?? boxes[c]!],
        edges: [
          for (final (e, a, b) in mine)
            LayerEdge(
              index[a]!,
              index[b]!,
              minLength: edges[e].length,
              label: edges[e].label == null
                  ? null
                  : measure(edges[e].label!, MText.edgeLabel, 200) +
                        const Offset(8, 4),
            ),
        ],
        direction: direction,
        nodeSep: 40,
        rankSep: 60,
      );
      for (var i = 0; i < children.length; i++) {
        local[children[i]] = result.centers[i];
      }
      for (var k = 0; k < mine.length; k++) {
        final e = mine[k].$1;
        routes[e] = result.routes[k];
        routeOwner[e] = group;
        final l = result.labels[k];
        if (l != null) labels[e] = l;
      }
      if (group != null) {
        final title = titles[group]!;
        final width = math.max(result.size.width, title.width) + pad * 2;
        final height = result.size.height + title.height + pad * 2 + 4;
        boxes[group] = Size(width, height);
        inset[group] = Offset(
          (width - result.size.width) / 2,
          pad + title.height + 4,
        );
      } else {
        inset[null] = Offset.zero;
      }
    }

    place(null);

    // Where everything is, from the top down.
    final origin = <String?, Offset>{null: Offset.zero};
    final rects = <String, Rect>{};
    Rect rectOf(String id) {
      final known = rects[id];
      if (known != null) return known;
      final size = sizes[id] ?? boxes[id]!;
      var o = Offset.zero;
      for (var at = parentOf(id); at != null; at = parentOf(at)) {
        o += inset[at]!;
        final p = sizes[at] ?? boxes[at]!;
        o += local[at]! - Offset(p.width / 2, p.height / 2);
      }
      return rects[id] = Rect.fromCenter(
        center: o + local[id]!,
        width: size.width,
        height: size.height,
      );
    }

    Offset originOf(String? group) =>
        origin[group] ??= rectOf(group!).topLeft + inset[group]!;

    MShape shapeOf(String id) => nodes[id]?.shape ?? MShape.cluster;

    final items = <MItem>[];
    final sortedGroups = groups.values.toList()
      ..sort((a, b) => path(a.id).length.compareTo(path(b.id).length));
    for (final g in sortedGroups) {
      final r = rectOf(g.id);
      items.add(MBox(MShape.cluster, r));
      final t = titles[g.id]!;
      items.add(
        MLabel(
          g.label,
          MText.cluster,
          Rect.fromLTWH(
            r.center.dx - t.width / 2,
            r.top + pad / 2,
            t.width,
            t.height,
          ),
        ),
      );
    }
    final texts = <MItem>[];
    for (var e = 0; e < edges.length; e++) {
      final edge = edges[e];
      if (edge.from == edge.to) {
        final r = rectOf(edge.from);
        final y = r.center.dy;
        items.add(
          MLine(
            [
              Offset(r.right, y - 8),
              Offset(r.right + 24, y - 14),
              Offset(r.right + 24, y + 14),
              Offset(r.right, y + 8),
            ],
            stroke: edge.stroke,
            start: edge.start,
            end: edge.end,
            curved: true,
          ),
        );
        if (edge.label != null) {
          final s = measure(edge.label!, MText.edgeLabel, 200);
          texts.add(
            MLabel(
              edge.label!,
              MText.edgeLabel,
              Rect.fromLTWH(r.right + 30, y - s.height / 2, s.width, s.height),
              background: true,
            ),
          );
        }
        continue;
      }
      final route = routes[e];
      if (route == null) continue;
      final o = originOf(routeOwner[e]);
      final bends = [for (final p in route) p + o];
      final a = rectOf(edge.from), b = rectOf(edge.to);
      final first = bends.isEmpty ? b.center : bends.first;
      final last = bends.isEmpty ? a.center : bends.last;
      final points = [
        clipToShape(shapeOf(edge.from), a, first),
        ...bends,
        clipToShape(shapeOf(edge.to), b, last),
      ];
      items.add(
        MLine(
          points,
          stroke: edge.stroke,
          start: edge.start,
          end: edge.end,
          curved: points.length > 2,
        ),
      );
      final l = labels[e];
      if (edge.label != null && l != null) {
        final s = measure(edge.label!, MText.edgeLabel, 200);
        texts.add(
          MLabel(
            edge.label!,
            MText.edgeLabel,
            Rect.fromCenter(center: l + o, width: s.width, height: s.height),
            background: true,
          ),
        );
      }
    }
    final sortedNodes = nodes.values.toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    for (final n in sortedNodes) {
      final r = rectOf(n.id);
      items.add(MBox(n.shape, r));
      final t = measure(n.label, MText.node, 200);
      texts.add(
        MLabel(
          n.label,
          MText.node,
          Rect.fromCenter(
            center:
                r.center +
                (n.shape == MShape.cylinder ? const Offset(0, 5) : Offset.zero),
            width: t.width,
            height: t.height,
          ),
        ),
      );
    }
    items.addAll(texts);
    return MermaidScene(
      items,
      description:
          'Flowchart: '
          '${sortedNodes.map((n) => n.label.replaceAll('\n', ' ')).join(', ')}',
    );
  }

  int _orderOf(String id) => nodes[id]?.order ?? groups[id]!.order;
}

/// Past a front matter block, `%%` comments and `%%{init}%%` lines: the
/// index of the line naming the diagram, or the length when there is none.
int _skipPreamble(List<String> lines) {
  var i = 0;
  while (i < lines.length && lines[i].trim().isEmpty) {
    i++;
  }
  if (i < lines.length && lines[i].trim() == '---') {
    final close = lines.indexWhere((l) => l.trim() == '---', i + 1);
    i = close < 0 ? lines.length : close + 1;
  }
  while (i < lines.length &&
      (lines[i].trim().isEmpty || lines[i].trim().startsWith('%%'))) {
    i++;
  }
  return i;
}

int skipMermaidPreamble(List<String> lines) => _skipPreamble(lines);

/// One statement of nodes and the links between them:
/// `A & B -->|yes| C[Label] --- D`.
class _Chain {
  _Chain(this.chart, this.s, this.group, this.line);

  final Flowchart chart;
  final String s;
  final String? group;
  final int line;
  int i = 0;

  Never _fail(String what) => throw MermaidError(
    '$what at "${s.substring(math.min(i, s.length)).trim()}"',
    line: line,
  );

  void _space() {
    while (i < s.length && (s[i] == ' ' || s[i] == '\t')) {
      i++;
    }
  }

  void read() {
    var left = _group();
    while (true) {
      _space();
      if (i >= s.length) return;
      final link = _link() ?? _fail('expected a link');
      final right = _group();
      for (final a in left) {
        for (final b in right) {
          chart.edges.add(
            FlowEdge(
              a,
              b,
              label: link.label,
              stroke: link.stroke,
              start: link.start,
              end: link.end,
              length: link.length,
            ),
          );
        }
      }
      left = right;
    }
  }

  List<String> _group() {
    final ids = [_node()];
    while (true) {
      _space();
      if (i < s.length && s[i] == '&') {
        i++;
        ids.add(_node());
      } else {
        return ids;
      }
    }
  }

  static final _id = RegExp(r'[\p{L}\p{N}_]+', unicode: true);

  static const _shapes = <(String, String, MShape)>[
    ('(((', ')))', MShape.doubleCircle),
    ('((', '))', MShape.circle),
    ('([', '])', MShape.stadium),
    ('[[', ']]', MShape.subroutine),
    ('[(', ')]', MShape.cylinder),
    ('{{', '}}', MShape.hexagon),
    ('[/', '/]', MShape.parallelogram),
    ('[/', r'\]', MShape.trapezoid),
    (r'[\', r'\]', MShape.parallelogramAlt),
    (r'[\', '/]', MShape.trapezoidAlt),
    ('[', ']', MShape.rect),
    ('(', ')', MShape.round),
    ('{', '}', MShape.rhombus),
    ('>', ']', MShape.asymmetric),
  ];

  String _node() {
    _space();
    final m = _id.matchAsPrefix(s, i);
    if (m == null) _fail('expected a node');
    final id = m[0]!;
    i = m.end;
    final node = chart.node(id, chart.groups.containsKey(id) ? null : group);
    if (s.startsWith('@{', i)) _fail('shape syntax @{…} is not read');
    // The longest opener that closes wins, and of two with the same opener,
    // `[/…/]` and `[/…\]`, the one that closes first.
    (int, int, String, MShape)? best;
    for (final (open, close, shape) in _shapes) {
      if (!s.startsWith(open, i)) continue;
      if (best != null && open.length < best.$1) break;
      final from = i + open.length;
      int end;
      if (from < s.length && s[from] == '"') {
        final q = s.indexOf('"', from + 1);
        if (q < 0) _fail('unclosed quote');
        end = s.startsWith(close, q + 1) ? q + 1 : -1;
      } else {
        end = s.indexOf(close, from);
      }
      if (end < 0 || (best != null && end >= best.$2)) continue;
      best = (open.length, end, close, shape);
    }
    if (best != null) {
      final (open, end, close, shape) = best;
      node
        ..label = mermaidText(s.substring(i + open, end))
        ..shape = shape;
      i = end + close.length;
    }
    final cls = RegExp(r':::[\w-]+').matchAsPrefix(s, i);
    if (cls != null) i = cls.end;
    return id;
  }

  static final _textStart = RegExp(r'([<ox])?(--|==|-\.)(?=\s)');
  static final _plain = RegExp(r'([<ox])?(-{2,}|={2,}|-\.+-)([>ox])?');
  static final _textEnd = RegExp(r'\s(-{2,}|={2,}|\.+-+)([>ox])?');

  _Link? _link() {
    final open = _textStart.matchAsPrefix(s, i);
    if (open != null) {
      final end = _textEnd.firstMatch(s.substring(open.end));
      if (end == null) _fail('unclosed link text');
      final text = s.substring(open.end, open.end + end.start);
      i = open.end + end.end;
      return _Link.of(open[1], end[1]!, end[2], mermaidText(text));
    }
    final m = _plain.matchAsPrefix(s, i);
    if (m == null) return null;
    i = m.end;
    String? label;
    final bar = RegExp(r'\s*\|([^|]*)\|').matchAsPrefix(s, i);
    if (bar != null) {
      label = mermaidText(bar[1]!);
      i = bar.end;
    }
    return _Link.of(m[1], m[2]!, m[3], label);
  }
}

class _Link {
  const _Link(this.stroke, this.start, this.end, this.length, this.label);

  factory _Link.of(String? start, String body, String? end, String? label) {
    MHead head(String? c, MHead arrow) => switch (c) {
      '>' || '<' => arrow,
      'o' => MHead.circle,
      'x' => MHead.cross,
      _ => MHead.none,
    };
    final stroke = body.contains('=')
        ? MStroke.thick
        : body.contains('.')
        ? MStroke.dotted
        : MStroke.solid;
    final endHead = head(end, MHead.arrow);
    final int length;
    if (stroke == MStroke.dotted) {
      length = '.'.allMatches(body).length;
    } else {
      final count = body.length;
      length = endHead == MHead.none ? count - 2 : count - 1;
    }
    return _Link(
      stroke,
      head(start, MHead.arrow),
      endHead,
      math.max(1, length),
      label == null || label.isEmpty ? null : label,
    );
  }

  final MStroke stroke;
  final MHead start;
  final MHead end;
  final int length;
  final String? label;
}
