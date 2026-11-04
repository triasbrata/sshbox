/// A layered graph layout in the manner of Sugiyama's, as dagre, which
/// Mermaid uses, does it: cycles broken, ranks by longest path, a dummy node
/// for every rank a long edge crosses, ordering by barycentres, and
/// coordinates pulled towards the neighbours within each rank's order.
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

enum LayerDirection { tb, bt, lr, rl }

class LayerEdge {
  const LayerEdge(this.from, this.to, {this.minLength = 1, this.label});

  final int from;
  final int to;

  /// How many ranks apart at least: Mermaid's `--->` is two.
  final int minLength;

  /// The label's size, which takes a place in the middle of the edge.
  final Size? label;
}

class LayerResult {
  const LayerResult(this.centers, this.routes, this.labels, this.size);

  /// Each node's centre.
  final List<Offset> centers;

  /// The bends of each edge between its two ends, in its own direction,
  /// from [LayerEdge.from] to [LayerEdge.to]; the ends themselves are left
  /// to the caller, which knows the shapes.
  final List<List<Offset>> routes;

  /// Each edge's label centre, or null for an edge with none.
  final List<Offset?> labels;
  final Size size;
}

class _V {
  _V(this.cross, this.along, {this.dummy = false});

  final double cross;
  final double along;
  final bool dummy;
  int rank = 0;
  double order = 0;
  double c = 0;
  final up = <int>[];
  final down = <int>[];
}

LayerResult layered({
  required List<Size> sizes,
  required List<LayerEdge> edges,
  LayerDirection direction = LayerDirection.tb,
  double nodeSep = 40,
  double rankSep = 50,
}) {
  final across =
      direction == LayerDirection.tb || direction == LayerDirection.bt;
  double crossOf(Size s) => across ? s.width : s.height;
  double alongOf(Size s) => across ? s.height : s.width;

  final n = sizes.length;
  final vs = [for (final s in sizes) _V(crossOf(s), alongOf(s))];

  // Cycles: an edge back to a node still on the depth-first stack is turned
  // round for the layout and drawn the right way afterwards.
  final reversed = List.filled(edges.length, false);
  final out = List.generate(n, (_) => <int>[]);
  for (var e = 0; e < edges.length; e++) {
    out[edges[e].from].add(e);
  }
  final state = List.filled(n, 0); // 0 unseen, 1 on the stack, 2 done
  for (var root = 0; root < n; root++) {
    if (state[root] != 0) continue;
    final stack = <(int, int)>[(root, 0)];
    state[root] = 1;
    while (stack.isNotEmpty) {
      final (v, i) = stack.removeLast();
      if (i < out[v].length) {
        stack.add((v, i + 1));
        final e = out[v][i];
        final w = edges[e].to;
        if (state[w] == 1) {
          reversed[e] = true;
        } else if (state[w] == 0) {
          state[w] = 1;
          stack.add((w, 0));
        }
      } else {
        state[v] = 2;
      }
    }
  }
  int tail(int e) => reversed[e] ? edges[e].to : edges[e].from;
  int head(int e) => reversed[e] ? edges[e].from : edges[e].to;

  // Ranks, doubled so that every edge has a rank between its ends for its
  // label, as dagre does.
  final indeg = List.filled(n, 0);
  final succ = List.generate(n, (_) => <int>[]);
  final pred = List.generate(n, (_) => <int>[]);
  for (var e = 0; e < edges.length; e++) {
    if (tail(e) == head(e)) continue;
    succ[tail(e)].add(e);
    pred[head(e)].add(e);
    indeg[head(e)]++;
  }
  final topo = <int>[];
  final queue = [
    for (var v = 0; v < n; v++)
      if (indeg[v] == 0) v,
  ];
  while (queue.isNotEmpty) {
    final v = queue.removeAt(0);
    topo.add(v);
    for (final e in succ[v]) {
      final w = head(e);
      vs[w].rank = math.max(vs[w].rank, vs[v].rank + 2 * edges[e].minLength);
      if (--indeg[w] == 0) queue.add(w);
    }
  }
  // A node only edges leave is drawn just before the first node it points
  // to, rather than up at the top with the others.
  for (final v in topo.reversed) {
    if (pred[v].isNotEmpty || succ[v].isEmpty) continue;
    vs[v].rank = succ[v]
        .map((e) => vs[head(e)].rank - 2 * edges[e].minLength)
        .reduce(math.min);
  }
  if (n > 0) {
    final least = vs.map((v) => v.rank).reduce(math.min);
    for (final v in vs) {
      v.rank -= least;
    }
  }

  // Dummies along every edge.
  final chains = List.generate(edges.length, (_) => <int>[]);
  final labelAt = List<int?>.filled(edges.length, null);
  for (var e = 0; e < edges.length; e++) {
    final u = tail(e), w = head(e);
    if (u == w) continue;
    final from = vs[u].rank, to = vs[w].rank;
    final mid = from + (to - from) ~/ 2;
    var last = u;
    for (var r = from + 1; r < to; r++) {
      final label = r == mid ? edges[e].label : null;
      final d = _V(
        label == null ? 0 : crossOf(label),
        label == null ? 0 : alongOf(label),
        dummy: true,
      )..rank = r;
      vs.add(d);
      final id = vs.length - 1;
      if (label != null) labelAt[e] = id;
      chains[e].add(id);
      vs[last].down.add(id);
      d.up.add(last);
      last = id;
    }
    vs[last].down.add(w);
    vs[w].up.add(last);
  }

  final ranks = vs.isEmpty ? 0 : vs.map((v) => v.rank).reduce(math.max) + 1;
  final layers = List.generate(ranks, (_) => <int>[]);

  // First order: breadth first from the nodes nothing points to, in the
  // order they were written.
  final seen = List.filled(vs.length, false);
  final visit = <int>[
    for (var v = 0; v < n; v++)
      if (vs[v].up.isEmpty) v,
  ];
  for (var v = 0; v < vs.length; v++) {
    if (!visit.contains(v) && vs[v].up.isEmpty) visit.add(v);
  }
  var head0 = 0;
  while (head0 < visit.length || seen.contains(false)) {
    if (head0 == visit.length) visit.add(seen.indexOf(false));
    final v = visit[head0++];
    if (seen[v]) continue;
    seen[v] = true;
    layers[vs[v].rank].add(v);
    visit.addAll(vs[v].down.where((w) => !seen[w]));
  }
  void number() {
    for (final layer in layers) {
      for (var i = 0; i < layer.length; i++) {
        vs[layer[i]].order = i.toDouble();
      }
    }
  }

  number();

  int crossings() {
    var count = 0;
    for (var r = 0; r + 1 < ranks; r++) {
      final pairs = <(double, double)>[
        for (final v in layers[r])
          for (final w in vs[v].down) (vs[v].order, vs[w].order),
      ];
      for (var i = 0; i < pairs.length; i++) {
        for (var j = i + 1; j < pairs.length; j++) {
          final (a1, b1) = pairs[i];
          final (a2, b2) = pairs[j];
          if ((a1 - a2) * (b1 - b2) < 0) count++;
        }
      }
    }
    return count;
  }

  var best = [
    for (final l in layers) [...l],
  ];
  var bestCount = crossings();
  for (var iter = 0; iter < 24 && bestCount > 0; iter++) {
    final downward = iter.isEven;
    final range = downward
        ? [for (var r = 1; r < ranks; r++) r]
        : [for (var r = ranks - 2; r >= 0; r--) r];
    for (final r in range) {
      final layer = layers[r];
      final key = <int, double>{};
      for (final v in layer) {
        final nb = downward ? vs[v].up : vs[v].down;
        key[v] = nb.isEmpty
            ? vs[v].order
            : nb.map((w) => vs[w].order).reduce((a, b) => a + b) / nb.length;
      }
      final indexed = [for (var i = 0; i < layer.length; i++) (layer[i], i)]
        ..sort((a, b) {
          final c = key[a.$1]!.compareTo(key[b.$1]!);
          return c != 0 ? c : a.$2.compareTo(b.$2);
        });
      layers[r] = [for (final (v, _) in indexed) v];
      for (var i = 0; i < layers[r].length; i++) {
        vs[layers[r][i]].order = i.toDouble();
      }
    }
    final count = crossings();
    if (count < bestCount) {
      bestCount = count;
      best = [
        for (final l in layers) [...l],
      ];
    }
  }
  for (var r = 0; r < ranks; r++) {
    layers[r] = best[r];
  }
  number();

  // Coordinates across: packed, then pulled towards the neighbours, a long
  // edge's dummies pulled hardest so it runs straight.
  double gap(int a, int b) {
    final va = vs[a], vb = vs[b];
    final sep = va.dummy && vb.dummy
        ? 12.0
        : va.dummy || vb.dummy
        ? nodeSep / 2
        : nodeSep;
    return (va.cross + vb.cross) / 2 + sep;
  }

  for (final layer in layers) {
    for (var i = 0; i < layer.length; i++) {
      vs[layer[i]].c = i == 0
          ? 0
          : vs[layer[i - 1]].c + gap(layer[i - 1], layer[i]);
    }
  }
  double weight(int a, int b) =>
      vs[a].dummy && vs[b].dummy ? 8 : (vs[a].dummy || vs[b].dummy ? 2 : 1);
  void settle(List<int> layer, List<int> Function(int) neighbours) {
    final want = <double>[];
    for (final v in layer) {
      final nb = neighbours(v);
      if (nb.isEmpty) {
        want.add(vs[v].c);
        continue;
      }
      var sum = 0.0, total = 0.0;
      for (final w in nb) {
        final k = weight(v, w);
        sum += vs[w].c * k;
        total += k;
      }
      want.add(sum / total);
    }
    final m = layer.length;
    final left = List.filled(m, 0.0), right = List.filled(m, 0.0);
    for (var i = 0; i < m; i++) {
      left[i] = i == 0
          ? want[i]
          : math.max(want[i], left[i - 1] + gap(layer[i - 1], layer[i]));
    }
    for (var i = m - 1; i >= 0; i--) {
      right[i] = i == m - 1
          ? want[i]
          : math.min(want[i], right[i + 1] - gap(layer[i], layer[i + 1]));
    }
    for (var i = 0; i < m; i++) {
      vs[layer[i]].c = (left[i] + right[i]) / 2;
    }
  }

  for (var iter = 0; iter < 8; iter++) {
    if (iter.isEven) {
      for (var r = 1; r < ranks; r++) {
        settle(layers[r], (v) => vs[v].up);
      }
    } else {
      for (var r = ranks - 2; r >= 0; r--) {
        settle(layers[r], (v) => vs[v].down);
      }
    }
  }
  for (var r = 0; r < ranks; r++) {
    settle(layers[r], (v) => [...vs[v].up, ...vs[v].down]);
  }

  var minC = double.infinity, maxC = -double.infinity;
  for (final v in vs) {
    minC = math.min(minC, v.c - v.cross / 2);
    maxC = math.max(maxC, v.c + v.cross / 2);
  }
  if (vs.isEmpty) minC = maxC = 0;

  // Along: each rank as thick as the thickest thing in it, and everything
  // in a rank lined up at its start, so a node beside a tall subgraph sits
  // level with the subgraph's top rather than halfway down it.
  final thick = List.filled(ranks, 0.0);
  for (final v in vs) {
    thick[v.rank] = math.max(thick[v.rank], v.along);
  }
  final at = List.filled(ranks, 0.0);
  for (var r = 1; r < ranks; r++) {
    at[r] = at[r - 1] + thick[r - 1] + rankSep / 2;
  }
  final alongSize = ranks == 0 ? 0.0 : at[ranks - 1] + thick[ranks - 1];
  final crossSize = maxC - minC;

  Offset place(_V v) {
    final c = v.c - minC, a = at[v.rank] + v.along / 2;
    return switch (direction) {
      LayerDirection.tb => Offset(c, a),
      LayerDirection.bt => Offset(c, alongSize - a),
      LayerDirection.lr => Offset(a, c),
      LayerDirection.rl => Offset(alongSize - a, c),
    };
  }

  return LayerResult(
    [for (var v = 0; v < n; v++) place(vs[v])],
    [
      for (var e = 0; e < edges.length; e++)
        reversed[e]
            ? [for (final d in chains[e].reversed) place(vs[d])]
            : [for (final d in chains[e]) place(vs[d])],
    ],
    [for (final d in labelAt) d == null ? null : place(vs[d])],
    across ? Size(crossSize, alongSize) : Size(alongSize, crossSize),
  );
}
