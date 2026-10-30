import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/mermaid/flowchart.dart';
import 'package:sshbox/src/mermaid/layered.dart';
import 'package:sshbox/src/mermaid/mermaid.dart';
import 'package:sshbox/src/mermaid/sequence.dart';
import 'package:sshbox/src/ui/mermaid_canvas.dart';
import 'package:sshbox/src/ui/mermaid_view.dart';
import 'package:sshbox/src/ui/termul/termul_palette.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'fake_web_view.dart';

/// A face every character of which is 7 wide and every line 16 high,
/// wrapped at spaces: the layout's goldens do not depend on a font.
Size _measure(String text, MText kind, double maxWidth) {
  const w = 7.0, h = 16.0;
  final perLine = (maxWidth / w).floor().clamp(1, 1 << 20);
  var lines = 0;
  var widest = 0;
  for (final para in text.split('\n')) {
    var line = 0;
    for (final word in para.split(' ')) {
      final len = word.length;
      if (line == 0) {
        line = len;
      } else if (line + 1 + len <= perLine) {
        line += 1 + len;
      } else {
        widest = widest < line ? line : widest;
        lines++;
        line = len;
      }
    }
    widest = widest < line ? line : widest;
    lines++;
  }
  return Size(widest * w, lines * h);
}

List<String> _docDiagrams() {
  final doc = File('docs/notification-architecture.md').readAsStringSync();
  return RegExp(r'```mermaid\n([\s\S]*?)```')
      .allMatches(doc)
      .map((m) => m[1]!)
      .toList();
}

MermaidScene _scene(String source) =>
    (readMermaid(source) as MermaidDrawable).layout(_measure);

void main() {
  group('the eight diagrams in notification-architecture.md', () {
    final diagrams = _docDiagrams();

    test('are all drawn natively', () {
      expect(diagrams, hasLength(8));
      for (final (i, d) in diagrams.indexed) {
        expect(readMermaid(d), isA<MermaidDrawable>(), reason: 'diagram $i');
      }
    });

    test('lay out as their goldens', () {
      for (final (i, d) in diagrams.indexed) {
        final file = File('test/goldens/mermaid/notification_${i + 1}.txt');
        final dump = _scene(d).dump();
        if (autoUpdateGoldenFiles || !file.existsSync()) {
          file
            ..createSync(recursive: true)
            ..writeAsStringSync(dump);
        }
        expect(dump, file.readAsStringSync(), reason: file.path);
      }
    });

    test('the flowchart keeps every node apart and inside its subgraph', () {
      final chart = Flowchart.parse(diagrams.first);
      expect(chart.direction, LayerDirection.lr);
      expect(chart.groups.keys, ['Tablet', 'Server', 'Cloudflare', 'Google']);
      expect(chart.groups['Server']!.label, 'SSH server');
      expect(chart.nodes['Store']!.shape, MShape.cylinder);
      expect(chart.nodes['Store']!.label, contains('\nsshbox.notify.keys'));
      expect(chart.nodes['SSHD']!.group, 'Server');
      // SSHD --> Shell --> Notify is two edges.
      expect(chart.edges.where((e) => e.from == 'Shell'), hasLength(1));

      final scene = chart.layout(_measure);
      final nodes = scene.items
          .whereType<MBox>()
          .where((b) => b.shape != MShape.cluster)
          .toList();
      final clusters = scene.items
          .whereType<MBox>()
          .where((b) => b.shape == MShape.cluster)
          .toList();
      expect(nodes, hasLength(chart.nodes.length));
      expect(clusters, hasLength(4));
      for (var i = 0; i < nodes.length; i++) {
        for (var j = i + 1; j < nodes.length; j++) {
          expect(
            nodes[i].rect.overlaps(nodes[j].rect),
            isFalse,
            reason: '${nodes[i].dump()} / ${nodes[j].dump()}',
          );
        }
      }
      for (var i = 0; i < clusters.length; i++) {
        for (var j = i + 1; j < clusters.length; j++) {
          expect(clusters[i].rect.overlaps(clusters[j].rect), isFalse);
        }
      }
      // Each node lies inside exactly one cluster here.
      for (final n in nodes) {
        expect(
          clusters.where(
            (c) =>
                c.rect.inflate(0.5).contains(n.rect.topLeft) &&
                c.rect.inflate(0.5).contains(n.rect.bottomRight),
          ),
          hasLength(1),
          reason: n.dump(),
        );
      }
      // Every edge starts and ends on a node's edge, not inside it.
      for (final line in scene.items.whereType<MLine>()) {
        for (final end in [line.points.first, line.points.last]) {
          expect(
            nodes.any(
              (n) =>
                  n.rect.inflate(0.6).contains(end) &&
                  !n.rect.deflate(0.6).contains(end),
            ),
            isTrue,
            reason: '$end of ${line.dump()}',
          );
        }
      }
    });

    test(
      'the sequence diagrams go down in order, with no words over others',
      () {
        for (final d in diagrams.skip(1)) {
          final scene = _scene(d);
          final arrows = scene.items
              .whereType<MLine>()
              .where((l) => l.role == MLineRole.edge)
              .toList();
          final numbers = scene.items
              .whereType<MLabel>()
              .where((l) => l.kind == MText.number)
              .map((l) => int.parse(l.text))
              .toList();
          expect(numbers, [for (var i = 1; i <= arrows.length; i++) i]);
          for (var i = 1; i < arrows.length; i++) {
            expect(
              arrows[i].points.first.dy,
              greaterThan(arrows[i - 1].points.first.dy),
            );
          }
          final words = scene.items
              .whereType<MLabel>()
              .where((l) => l.kind != MText.number && l.kind != MText.actor)
              .toList();
          for (var i = 0; i < words.length; i++) {
            for (var j = i + 1; j < words.length; j++) {
              expect(
                words[i].rect.deflate(1).overlaps(words[j].rect.deflate(1)),
                isFalse,
                reason: '${words[i].dump()} / ${words[j].dump()}',
              );
            }
          }
        }
      },
    );
  });

  group('readMermaid', () {
    test('draws flowcharts, graphs and sequence diagrams natively', () {
      for (final s in [
        'graph TD\nA-->B',
        'flowchart LR\nA-->B',
        '---\ntitle: x\n---\n%%{init: {}}%%\n%% c\nflowchart\nA',
        'sequenceDiagram\nA->>B: hi',
      ]) {
        expect(readMermaid(s), isA<MermaidDrawable>(), reason: s);
      }
    });

    test('names a kind it does not draw, and a line it could not read', () {
      final pie = readMermaid('pie\n "a": 1') as MermaidNotDrawn;
      expect(pie.kind, 'pie');
      expect(pie.reason, 'pie is not drawn natively');
      expect((readMermaid('\n') as MermaidNotDrawn).reason, 'no diagram');
      final bad =
          readMermaid('graph TD\n  A --> B\n  A ?? B') as MermaidNotDrawn;
      expect(bad.reason, startsWith('not drawn natively: line 3:'));
      expect(
        (readMermaid('sequenceDiagram\n  wat') as MermaidNotDrawn).reason,
        'not drawn natively: line 2: not read: "wat"',
      );
    });
  });

  group('flowchart reading', () {
    test('every shape', () {
      final chart = Flowchart.parse('''
flowchart TD
  a[rect] --- b(round) --- c([stadium]) --- d[[sub]] --- e[(db)]
  f((circle)) --- g(((double))) --- h>flag] --- i{rhombus} --- j{{hex}}
  k[/para/] --- l[\\alt\\] --- m[/trap\\] --- n[\\trapAlt/] --- o
  p["quoted [with] brackets"]:::cls
''');
      expect(
        {for (final n in chart.nodes.values) n.id: n.shape},
        {
          'a': MShape.rect,
          'b': MShape.round,
          'c': MShape.stadium,
          'd': MShape.subroutine,
          'e': MShape.cylinder,
          'f': MShape.circle,
          'g': MShape.doubleCircle,
          'h': MShape.asymmetric,
          'i': MShape.rhombus,
          'j': MShape.hexagon,
          'k': MShape.parallelogram,
          'l': MShape.parallelogramAlt,
          'm': MShape.trapezoid,
          'n': MShape.trapezoidAlt,
          'o': MShape.rect,
          'p': MShape.rect,
        },
      );
      expect(chart.nodes['o']!.label, 'o');
      expect(chart.nodes['p']!.label, 'quoted [with] brackets');
      // Every shape lays out and paints.
      expect(chart.layout(_measure).items, isNotEmpty);
    });

    test('every kind of link, its heads, its length and its label', () {
      final chart = Flowchart.parse('''
graph LR
  a --> b
  a --- c
  a -.-> d
  a ==> e
  a <--> f
  a --o g
  a --x h
  a o--o i
  a ----> j
  a -..-> k
  a -->|bar label| l
  a -- text label --> m
  a -. dotted text .-> n
  a == thick text ==> o
  a ---- p
''');
      String d(FlowEdge e) =>
          '${e.to} ${e.stroke.name} ${e.start.name}-${e.end.name} '
          '${e.length}${e.label == null ? '' : ' "${e.label}"'}';
      expect(chart.edges.map(d), [
        'b solid none-arrow 1',
        'c solid none-none 1',
        'd dotted none-arrow 1',
        'e thick none-arrow 1',
        'f solid arrow-arrow 1',
        'g solid none-circle 1',
        'h solid none-cross 1',
        'i solid circle-circle 1',
        'j solid none-arrow 3',
        'k dotted none-arrow 2',
        'l solid none-arrow 1 "bar label"',
        'm solid none-arrow 1 "text label"',
        'n dotted none-arrow 1 "dotted text"',
        'o thick none-arrow 1 "thick text"',
        'p solid none-none 2',
      ]);
    });

    test('&, ; and the statements it does not draw', () {
      final chart = Flowchart.parse('''
graph TD; a & b --> c & d; c --> d
  classDef x fill:#f00
  class a x
  style b fill:#0f0
  linkStyle 0 stroke:#00f
  click a callback
  %% a comment
  accTitle: hi
''');
      expect(chart.edges.map((e) => '${e.from}${e.to}'), [
        'ac',
        'ad',
        'bc',
        'bd',
        'cd',
      ]);
    });

    test('subgraphs: by id and title, by title alone, nested, and a node '
        'first named outside', () {
      final chart = Flowchart.parse('''
flowchart TB
  x --> y
  subgraph one [The first]
    direction LR
    y
    subgraph two
      z
    end
  end
  subgraph "Quoted title"
    w
  end
  w --> one
''');
      expect(chart.groups['one']!.label, 'The first');
      expect(chart.groups['two']!.parent, 'one');
      expect(chart.groups['Quoted title']!.label, 'Quoted title');
      expect(chart.nodes['x']!.group, isNull);
      expect(chart.nodes['y']!.group, 'one');
      expect(chart.nodes['z']!.group, 'two');
      // A subgraph named in a link is the subgraph.
      expect(chart.nodes.containsKey('one'), isFalse);
      final scene = chart.layout(_measure);
      expect(
        scene.items.whereType<MBox>().where((b) => b.shape == MShape.cluster),
        hasLength(3),
      );
      expect(scene.items.whereType<MLine>(), hasLength(2));
    });

    test('a link to itself is a loop beside the node', () {
      final scene = Flowchart.parse('graph TD\n  a -->|again| a')
          .layout(_measure);
      final loop = scene.items.whereType<MLine>().single;
      expect(loop.points, hasLength(4));
      expect(loop.curved, isTrue);
      expect(
        scene.items.whereType<MLabel>().map((l) => l.text),
        contains('again'),
      );
    });

    test('each direction lays the ranks out its way', () {
      Offset at(String dir, String id) {
        final scene = Flowchart.parse('flowchart $dir\n  a --> b')
            .layout(_measure);
        final boxes = scene.items.whereType<MBox>().toList();
        return boxes[id == 'a' ? 0 : 1].rect.center;
      }

      expect(at('TD', 'b').dy, greaterThan(at('TD', 'a').dy));
      expect(at('BT', 'b').dy, lessThan(at('BT', 'a').dy));
      expect(at('LR', 'b').dx, greaterThan(at('LR', 'a').dx));
      expect(at('RL', 'b').dx, lessThan(at('RL', 'a').dx));
    });

    test('a cycle is drawn the right way round', () {
      final scene = Flowchart.parse('graph TD\n  a --> b --> c --> a')
          .layout(_measure);
      final boxes = scene.items.whereType<MBox>().toList();
      final back = scene.items.whereType<MLine>().last;
      // c → a: starts at c, ends at a.
      expect(boxes[2].rect.inflate(1).contains(back.points.first), isTrue);
      expect(boxes[0].rect.inflate(1).contains(back.points.last), isTrue);
    });

    test('what it cannot read, it says, with the line', () {
      for (final (src, says) in [
        ('graph TD\n  end', 'line 2: end with no subgraph'),
        ('graph TD\n  subgraph a\n  b', 'subgraph a is never ended'),
        (
          'graph TD\n  a@{ shape: rect }',
          'line 2: shape syntax @{…} is not read at "@{ shape: rect }"',
        ),
        ('graph TD\n  a -- open', 'line 2: unclosed link text'),
        ('graph TD\n  a b', 'line 2: expected a link'),
        ('graph TD\n  a --> ', 'line 2: expected a node'),
        ('graph TD\n  subgraph', 'line 2: subgraph with no name'),
        ('pie', 'line 1: not a flowchart'),
        ('', 'no diagram'),
      ]) {
        expect(
          () => Flowchart.parse(src),
          throwsA(
            isA<MermaidError>().having((e) => '$e', 'says', startsWith(says)),
          ),
          reason: src,
        );
      }
    });
  });

  group('sequence reading', () {
    test('participants, actors, aliases, and those met in a message', () {
      final d = SequenceDiagram.parse('''
sequenceDiagram
  title Ignored
  participant A as Alice
  actor B
  create participant C
  destroy C
  A->>D: hi;
''');
      expect(d.participants.keys, ['A', 'B', 'C', 'D']);
      expect(d.participants['A']!.label, 'Alice');
      expect(d.participants['B']!.actor, isTrue);
      expect(d.participants['D']!.label, 'D');
    });

    test('every arrow', () {
      final d = SequenceDiagram.parse('''
sequenceDiagram
  A->>B: a
  A-->>B: b
  A->B: c
  A-->B: d
  A-xB: e
  A--xB: f
  A-)B: g
  A--)B: h
  A<<->>B: i
  A<<-->>B: j
  A->>B
''');
      expect(
        d.events.cast<SeqMessage>().map(
          (m) => '${m.text} ${m.stroke.name} ${m.start.name}-${m.end.name}',
        ),
        [
          'a solid none-arrow',
          'b dashed none-arrow',
          'c solid none-none',
          'd dashed none-none',
          'e solid none-cross',
          'f dashed none-cross',
          'g solid none-open',
          'h dashed none-open',
          'i solid arrow-arrow',
          'j dashed arrow-arrow',
          ' solid none-arrow',
        ],
      );
    });

    test('notes, blocks, activations and autonumber lay out', () {
      final d = SequenceDiagram.parse('''
sequenceDiagram
  autonumber 10 5
  participant A
  participant B
  actor C
  Note left of A: left
  Note right of C: right
  Note over B: over one
  Note over A,C: over two
  loop every second
    A->>+B: start
    critical
      B->>B: self
    option other
      B-xC: no
    end
    B-->>-A: done
  end
  alt yes
    activate C
    C->>A: on
    deactivate C
  else
    A->>C: no
  end
  par
    A->>B: one
  and
    A->>C: two
  end
  rect rgb(0,0,0)
  end
  opt
  end
  break
  end
  activate A
''');
      expect(d.autonumber, isTrue);
      expect(d.numberFrom, 10);
      expect(d.numberStep, 5);
      final scene = d.layout(_measure);
      final numbers = scene.items
          .whereType<MLabel>()
          .where((l) => l.kind == MText.number)
          .map((l) => l.text);
      expect(numbers, ['10', '15', '20', '25', '30', '35', '40', '45']);
      final boxes = scene.items.whereType<MBox>().map((b) => b.shape).toList();
      expect(boxes.where((s) => s == MShape.frame), hasLength(7));
      expect(boxes.where((s) => s == MShape.note), hasLength(4));
      expect(boxes.where((s) => s == MShape.activation), hasLength(3));
      expect(boxes.where((s) => s == MShape.actorFigure), hasLength(2));
      expect(boxes.where((s) => s == MShape.actorBox), hasLength(4));
      expect(
        scene.items.whereType<MLine>().where(
          (l) => l.role == MLineRole.separator,
        ),
        hasLength(3),
      );
      final self = scene.items.whereType<MLine>().firstWhere(
        (l) => l.points.length == 4,
      );
      expect(self.points.first.dx, self.points.last.dx);
    });

    test('autonumber off', () {
      final d = SequenceDiagram.parse(
        'sequenceDiagram\n  autonumber off\n  A->>B: x',
      );
      expect(d.autonumber, isFalse);
    });

    test('what it cannot read, it says, with the line', () {
      for (final (src, says) in [
        (
          'sequenceDiagram\n  box Aqua Group\n  end',
          'line 2: box is not drawn natively',
        ),
        ('sequenceDiagram\n  end', 'line 2: end with no block'),
        ('sequenceDiagram\n  else x', 'line 2: else outside a block'),
        ('sequenceDiagram\n  loop x', 'a block is never ended'),
        ('sequenceDiagram\n  activate', 'line 2: activate whom?'),
        (
          'sequenceDiagram\n  Note over A,B,C: x',
          'line 2: a note is over one or two participants',
        ),
        ('graph TD', 'line 1: not a sequence diagram'),
      ]) {
        expect(
          () => SequenceDiagram.parse(src),
          throwsA(
            isA<MermaidError>().having((e) => '$e', 'says', startsWith(says)),
          ),
          reason: src,
        );
      }
    });
  });

  group('the pieces', () {
    test('mermaidText', () {
      expect(mermaidText(' "a<br>b<br/>c<BR />d" '), 'a\nb\nc\nd');
      expect(mermaidText('"`**md**`"'), '**md**');
      expect(mermaidText('#quot;#amp;#lt;#gt;#nbsp;#35;'), '"&<> #');
    });

    test('clipToShape', () {
      const r = Rect.fromLTWH(0, 0, 100, 50);
      expect(
        clipToShape(MShape.rect, r, const Offset(200, 25)),
        const Offset(100, 25),
      );
      expect(
        clipToShape(MShape.rect, r, const Offset(50, 25)),
        const Offset(50, 25),
      );
      expect(
        clipToShape(MShape.rect, r, const Offset(60, 30)),
        const Offset(60, 30),
      );
      expect(
        clipToShape(MShape.rhombus, r, const Offset(200, 25)),
        const Offset(100, 25),
      );
      expect(
        clipToShape(MShape.circle, r, const Offset(50, 125)),
        const Offset(50, 50),
      );
      expect(
        clipToShape(MShape.rect, r, const Offset(50, 125)),
        const Offset(50, 50),
      );
    });

    test('an empty scene, and its dump', () {
      final scene = MermaidScene(const [], description: 'none');
      expect(scene.size, Size.zero);
      expect(
        MermaidScene([
          const MBox(MShape.rect, Rect.fromLTWH(5, 5, 10.25, 10)),
        ], description: '').dump(),
        'size 26.3x26\nbox rect 8,8 10.3x10\n',
      );
    });

    test('layered: nothing, and edges that cross are uncrossed', () {
      expect(layered(sizes: const [], edges: const []).size, Size.zero);
      final r = layered(
        sizes: List.filled(4, const Size(20, 20)),
        edges: const [LayerEdge(0, 3), LayerEdge(1, 2)],
      );
      // 0 → 3 and 1 → 2: the lower rank orders 3 and 2 as their parents.
      expect(
        r.centers[3].dx < r.centers[2].dx,
        r.centers[0].dx < r.centers[1].dx,
      );
    });

    test('layered: a graph that must cross is reordered to cross less', () {
      // a, b, c over d, e, f, each to two: crossings are unavoidable, and
      // the order written has more of them than the best.
      final r = layered(
        // And a seventh linked to nothing, which keeps its place.
        sizes: List.filled(7, const Size(20, 20)),
        edges: const [
          LayerEdge(0, 5),
          LayerEdge(0, 3),
          LayerEdge(1, 4),
          LayerEdge(1, 5),
          LayerEdge(2, 3),
          LayerEdge(2, 4),
        ],
      );
      final xs = [for (final c in r.centers.take(6)) c.dx];
      expect(xs.every((x) => x.isFinite), isTrue);
      // Nothing in a rank sits on anything else.
      for (final rank in [xs.sublist(0, 3), xs.sublist(3)]) {
        final sorted = [...rank]..sort();
        for (var i = 1; i < sorted.length; i++) {
          expect(sorted[i] - sorted[i - 1], greaterThanOrEqualTo(20));
        }
      }
    });
  });

  group('MermaidBlock', () {
    Widget host(String source, {bool copyable = false}) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: MermaidBlock(source: source, copyable: copyable),
        ),
      ),
    );

    testWidgets('draws a flowchart natively, at its size, painted', (
      tester,
    ) async {
      await tester.pumpWidget(host('graph LR\n  A --> B\n'));
      expect(find.byType(MermaidCanvas), findsOneWidget);
      final size = tester.getSize(find.byType(MermaidCanvas));
      expect(size.width, greaterThan(100));
      expect(size.height, greaterThan(30));
      expect(
        tester.getSemantics(find.byType(MermaidCanvas)).label,
        'Flowchart: A, B',
      );
      // A change of source reads it again.
      await tester.pumpWidget(host('sequenceDiagram\n  A->>B: hi\n'));
      expect(
        tester.getSemantics(find.byType(MermaidCanvas)).label,
        'Sequence diagram between A, B, 1 messages',
      );
    });

    testWidgets('copies its source when asked to', (tester) async {
      final copied = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') copied.add(call.arguments);
          return null;
        },
      );
      await tester.pumpWidget(host('graph LR\n  A --> B\n', copyable: true));
      await tester.tap(find.byTooltip('Copy diagram source'));
      await tester.pump();
      expect(copied, [
        {'text': 'graph LR\n  A --> B\n'},
      ]);
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });

    testWidgets('a kind not drawn natively opens in Mermaid where there is a '
        'web view', (tester) async {
      WebViewPlatform.instance = FakeWebViewPlatform();
      await tester.pumpWidget(host('pie\n  "a": 1\n'));
      expect(find.text('pie is not drawn natively'), findsOneWidget);
      expect(find.text('pie\n  "a": 1'), findsOneWidget);
      await tester.tap(find.text('OPEN IN MERMAID'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<MermaidView>(find.byType(MermaidView)).source,
        'pie\n  "a": 1\n',
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('…and has no such button where there is none', (tester) async {
      // With no line break at its end, as a terminal selection can be.
      await tester.pumpWidget(host('pie\n  "a": 1'));
      expect(find.text('pie\n  "a": 1'), findsOneWidget);
      expect(find.text('pie is not drawn natively'), findsOneWidget);
      expect(find.text('OPEN IN MERMAID'), findsNothing);
      expect(find.text('Open in Mermaid'), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    test('canShowMermaid', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(canShowMermaid('graph TD\n A-->B'), isTrue);
      expect(canShowMermaid('pie\n "a": 1'), isFalse);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(canShowMermaid('pie\n "a": 1'), isTrue);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('MermaidPainter', () {
    // Every shape, stroke, head and kind of text, painted for real.
    const everything = '''
flowchart TD
  a[rect] --> b(round) --- c([stadium]) -.-> d[[sub]] ==> e[(db)]
  f((circle)) --o g(((double))) --x h>flag] <--> i{rhombus} --> j{{hex}}
  k[/para/] -->|label| l[\\alt\\] --> m[/trap\\] --> n[\\trapAlt/]
  n --> n
  subgraph s [Cluster]
    o
  end
''';
    const sequence = '''
sequenceDiagram
  autonumber
  actor A
  A->>B: arrow
  A-)B: open
  A-xB: cross
  Note over A: note
  loop l
    activate B
    B-->>A: back
  end
''';

    Future<void> paint(
      WidgetTester tester,
      String source,
      TermulPalette p,
    ) async {
      final read = readMermaid(source) as MermaidDrawable;
      const base = TextStyle(fontSize: 14);
      final scene = MermaidCanvas.sceneOf(
        read,
        source,
        base,
        TextScaler.noScaling,
      );
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      final painter = MermaidPainter(
        scene,
        MermaidColors.of(p, p.bg),
        base,
        TextScaler.noScaling,
      );
      painter.paint(canvas, scene.size);
      rec.endRecording().dispose();
      expect(painter.shouldRepaint(painter), isFalse);
      expect(
        painter.shouldRepaint(
          MermaidPainter(
            scene,
            MermaidColors.of(p, p.panel),
            base,
            TextScaler.noScaling,
          ),
        ),
        isTrue,
      );
    }

    testWidgets('paints every shape and head', (tester) async {
      await paint(tester, everything, TermulPalette.mocha);
      await paint(tester, sequence, TermulPalette.paper);
      // A layout is kept, and found again.
      const base = TextStyle(fontSize: 14);
      final read = readMermaid(everything) as MermaidDrawable;
      expect(
        identical(
          MermaidCanvas.sceneOf(read, everything, base, TextScaler.noScaling),
          MermaidCanvas.sceneOf(read, everything, base, TextScaler.noScaling),
        ),
        isTrue,
      );
      // And only so many are kept.
      for (var i = 0; i < 60; i++) {
        final s = 'graph TD\n  n$i';
        MermaidCanvas.sceneOf(
          readMermaid(s) as MermaidDrawable,
          s,
          base,
          TextScaler.noScaling,
        );
      }
    });

    test('colours compare by value', () {
      final a = MermaidColors.of(TermulPalette.mocha, const Color(0xff000000));
      final b = MermaidColors.of(TermulPalette.mocha, const Color(0xff000000));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        a == MermaidColors.of(TermulPalette.paper, const Color(0xff000000)),
        isFalse,
      );
    });
  });
}
