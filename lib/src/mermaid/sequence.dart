/// Mermaid's sequenceDiagram: read, and laid out as a [MermaidScene].
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'flowchart.dart' show skipMermaidPreamble;
import 'scene.dart';

class SeqParticipant {
  SeqParticipant(this.id, this.label, {this.actor = false});

  final String id;
  String label;
  bool actor;
}

sealed class SeqEvent {
  const SeqEvent();
}

class SeqMessage extends SeqEvent {
  const SeqMessage(
    this.from,
    this.to,
    this.text, {
    required this.stroke,
    required this.start,
    required this.end,
    this.activate = false,
    this.deactivate = false,
  });

  final String from;
  final String to;
  final String text;
  final MStroke stroke;
  final MHead start;
  final MHead end;
  final bool activate;
  final bool deactivate;
}

enum NoteSide { left, right, over }

class SeqNote extends SeqEvent {
  const SeqNote(this.side, this.over, this.text);

  final NoteSide side;
  final List<String> over;
  final String text;
}

class SeqOpen extends SeqEvent {
  const SeqOpen(this.kind, this.title);

  final String kind;
  final String title;
}

class SeqElse extends SeqEvent {
  const SeqElse(this.kind, this.title);

  final String kind;
  final String title;
}

class SeqEnd extends SeqEvent {
  const SeqEnd();
}

class SeqActivation extends SeqEvent {
  const SeqActivation(this.who, {required this.on});

  final String who;
  final bool on;
}

class SequenceDiagram {
  final participants = <String, SeqParticipant>{};
  final events = <SeqEvent>[];
  bool autonumber = false;
  int numberFrom = 1;
  int numberStep = 1;

  SeqParticipant _who(String id) => participants[id] ??= SeqParticipant(id, id);

  static final _participant = RegExp(
    r'^(?:create\s+)?(participant|actor)\s+(.+?)(?:\s+as\s+(.+))?$',
  );
  static final _message = RegExp(
    r'^([^\s:;<>+-][^\s:;<>]*?)\s*(<<-->>|<<->>|-->>|->>|--x|-x|--\)|-\)|-->|->)\s*([+-]?)\s*([^\s:;]+)\s*(?::(.*))?$',
  );
  static final _note = RegExp(
    r'^note\s+(left of|right of|over)\s+([^:]+?)\s*:(.*)$',
    caseSensitive: false,
  );
  static final _open = RegExp(
    r'^(loop|alt|opt|par|critical|break|rect)\b\s*(.*)$',
  );
  static final _else = RegExp(r'^(else|and|option)\b\s*(.*)$');

  static SequenceDiagram parse(String source) {
    final lines = source.split('\n');
    var i = skipMermaidPreamble(lines);
    if (i == lines.length ||
        lines[i].trim().split(RegExp(r'\s')).first != 'sequenceDiagram') {
      throw MermaidError('not a sequence diagram', line: i + 1);
    }
    final d = SequenceDiagram();
    var depth = 0;
    for (i++; i < lines.length; i++) {
      var s = lines[i].trim();
      final line = i + 1;
      if (s.endsWith(';')) s = s.substring(0, s.length - 1).trim();
      if (s.isEmpty || s.startsWith('%%')) continue;
      final word = s.split(RegExp(r'\s')).first;
      if (const {
        'title',
        'accTitle',
        'accDescr',
        'accTitle:',
        'accDescr:',
        'destroy',
      }.contains(word)) {
        continue;
      }
      if (word == 'autonumber') {
        d.autonumber = true;
        final nums = s.split(RegExp(r'\s+')).skip(1).map(int.tryParse).toList();
        if (nums.isNotEmpty && nums[0] != null) d.numberFrom = nums[0]!;
        if (nums.length > 1 && nums[1] != null) d.numberStep = nums[1]!;
        if (nums.length == 1 && s.endsWith('off')) d.autonumber = false;
        continue;
      }
      if (word == 'box') {
        throw MermaidError('box is not drawn natively', line: line);
      }
      var m = _participant.firstMatch(s);
      if (m != null) {
        final id = mermaidText(m[2]!);
        final p = d._who(id)
          ..actor = m[1] == 'actor'
          ..label = m[3] == null ? id : mermaidText(m[3]!);
        p.label = p.label;
        continue;
      }
      if (word == 'activate' || word == 'deactivate') {
        final who = s.substring(word.length).trim();
        if (who.isEmpty) throw MermaidError('$word whom?', line: line);
        d._who(who);
        d.events.add(SeqActivation(who, on: word == 'activate'));
        continue;
      }
      m = _note.firstMatch(s);
      if (m != null) {
        final over = [for (final w in m[2]!.split(',')) w.trim()];
        if (over.length > 2 || over.any((w) => w.isEmpty)) {
          throw MermaidError(
            'a note is over one or two participants',
            line: line,
          );
        }
        over.forEach(d._who);
        d.events.add(
          SeqNote(
            switch (m[1]!.toLowerCase()) {
              'left of' => NoteSide.left,
              'right of' => NoteSide.right,
              _ => NoteSide.over,
            },
            over,
            mermaidText(m[3]!),
          ),
        );
        continue;
      }
      m = _open.firstMatch(s);
      if (m != null) {
        depth++;
        d.events.add(SeqOpen(m[1]!, mermaidText(m[2]!)));
        continue;
      }
      m = _else.firstMatch(s);
      if (m != null) {
        if (depth == 0) {
          throw MermaidError('${m[1]} outside a block', line: line);
        }
        d.events.add(SeqElse(m[1]!, mermaidText(m[2]!)));
        continue;
      }
      if (s == 'end') {
        if (depth == 0) throw MermaidError('end with no block', line: line);
        depth--;
        d.events.add(const SeqEnd());
        continue;
      }
      m = _message.firstMatch(s);
      if (m != null) {
        final arrow = m[2]!;
        final from = m[1]!, to = m[4]!;
        d._who(from);
        d._who(to);
        d.events.add(
          SeqMessage(
            from,
            to,
            mermaidText(m[5] ?? ''),
            stroke: arrow.startsWith('--') || arrow.startsWith('<<--')
                ? MStroke.dashed
                : MStroke.solid,
            start: arrow.startsWith('<<') ? MHead.arrow : MHead.none,
            end: arrow.endsWith('>>')
                ? MHead.arrow
                : arrow.endsWith('x')
                ? MHead.cross
                : arrow.endsWith(')')
                ? MHead.open
                : MHead.none,
            activate: m[3] == '+',
            deactivate: m[3] == '-',
          ),
        );
        continue;
      }
      throw MermaidError('not read: "$s"', line: line);
    }
    if (depth > 0) throw const MermaidError('a block is never ended');
    return d;
  }

  // ------------------------------------------------------------- layout

  MermaidScene layout(MermaidMeasure measure) {
    const wrap = 260.0;
    const boxPadX = 14.0, boxPadY = 10.0;
    const loopWidth = 34.0;
    final ps = participants.values.toList();
    final index = {for (var i = 0; i < ps.length; i++) ps[i].id: i};
    final labelSize = [for (final p in ps) measure(p.label, MText.actor, 200)];
    final boxW = [
      for (final s in labelSize) math.max(s.width + boxPadX * 2, 90.0),
    ];
    final boxH = [
      for (var i = 0; i < ps.length; i++)
        labelSize[i].height + boxPadY * 2 + (ps[i].actor ? 34 : 0),
    ];
    final headH = boxH.isEmpty ? 0.0 : boxH.reduce(math.max);

    // Across: the gaps between neighbours, widened for what lies between.
    final gaps = [
      for (var i = 0; i + 1 < ps.length; i++) (boxW[i] + boxW[i + 1]) / 2 + 40,
    ];
    final needs = <(int, int, double)>[];
    Size noteSize(String t) {
      final s = measure(t, MText.note, wrap);
      return Size(s.width + 20, s.height + 14);
    }

    for (final e in events) {
      switch (e) {
        case SeqMessage(:final from, :final to, :final text):
          final a = index[from]!, b = index[to]!;
          final w = text.isEmpty
              ? 0.0
              : measure(text, MText.message, wrap).width;
          if (a == b) {
            if (a + 1 < ps.length) {
              needs.add((a, a + 1, math.max(loopWidth, w + 12) + 24));
            }
          } else {
            needs.add((math.min(a, b), math.max(a, b), w + 40));
          }
        case SeqNote(:final side, :final over, :final text):
          final w = noteSize(text).width;
          final a = index[over.first]!;
          final b = index[over.last]!;
          switch (side) {
            case NoteSide.left:
              if (a > 0) needs.add((a - 1, a, w + 24));
            case NoteSide.right:
              if (a + 1 < ps.length) needs.add((a, a + 1, w + 24));
            case NoteSide.over when a == b:
              if (a > 0) needs.add((a - 1, a, w / 2 + boxW[a - 1] / 2 + 12));
              if (a + 1 < ps.length) {
                needs.add((a, a + 1, w / 2 + boxW[a + 1] / 2 + 12));
              }
            case NoteSide.over:
              needs.add((math.min(a, b), math.max(a, b), w - 40));
          }
        default:
      }
    }
    needs.sort((x, y) => (x.$2 - x.$1).compareTo(y.$2 - y.$1));
    for (final (a, b, need) in needs) {
      var have = 0.0;
      for (var k = a; k < b; k++) {
        have += gaps[k];
      }
      if (have >= need) continue;
      final more = (need - have) / (b - a);
      for (var k = a; k < b; k++) {
        gaps[k] += more;
      }
    }
    final x = <double>[];
    for (var i = 0; i < ps.length; i++) {
      x.add(i == 0 ? boxW[0] / 2 : x[i - 1] + gaps[i - 1]);
    }

    final back = <MItem>[];
    final front = <MItem>[];
    void participantBox(int i, double top) {
      final p = ps[i];
      final r = Rect.fromLTWH(x[i] - boxW[i] / 2, top, boxW[i], boxH[i]);
      final s = labelSize[i];
      if (p.actor) {
        front.add(
          MBox(
            MShape.actorFigure,
            Rect.fromCenter(
              center: Offset(x[i], top + 18),
              width: 24,
              height: 34,
            ),
          ),
        );
        front.add(
          MLabel(
            p.label,
            MText.actor,
            Rect.fromLTWH(
              x[i] - s.width / 2,
              top + 38 + boxPadY / 2,
              s.width,
              s.height,
            ),
          ),
        );
      } else {
        front.add(MBox(MShape.actorBox, r));
        front.add(
          MLabel(
            p.label,
            MText.actor,
            Rect.fromCenter(center: r.center, width: s.width, height: s.height),
          ),
        );
      }
    }

    for (var i = 0; i < ps.length; i++) {
      participantBox(i, headH - boxH[i]);
    }

    // Down: one event at a time.
    var y = headH + 24;
    var number = numberFrom;
    final active = {for (final p in ps) p.id: <double>[]};
    double edgeOf(String id, bool fromLeft) {
      final depth = active[id]!.length;
      final cx = x[index[id]!];
      if (depth == 0) return cx;
      return cx + (fromLeft ? -5.0 : 5.0) + (depth - 1) * 5;
    }

    void activationOff(String id) {
      final stack = active[id]!;
      if (stack.isEmpty) return;
      final from = stack.removeLast();
      final depth = stack.length;
      back.add(
        MBox(
          MShape.activation,
          Rect.fromLTRB(
            x[index[id]!] - 5 + depth * 5,
            from,
            x[index[id]!] + 5 + depth * 5,
            math.max(y, from + 8),
          ),
        ),
      );
    }

    final frames = <_Frame>[];
    void reach(double l, double r) {
      if (frames.isEmpty) return;
      frames.last.left = math.min(frames.last.left, l);
      frames.last.right = math.max(frames.last.right, r);
    }

    for (final e in events) {
      switch (e) {
        case SeqMessage():
          final a = index[e.from]!, b = index[e.to]!;
          final s = e.text.isEmpty
              ? Size.zero
              : measure(e.text, MText.message, wrap);
          if (a == b) {
            final cx = edgeOf(e.from, false);
            if (s != Size.zero) {
              front.add(
                MLabel(
                  e.text,
                  MText.message,
                  Rect.fromLTWH(cx + 10, y, s.width, s.height),
                  center: false,
                ),
              );
            }
            y += s.height + 6;
            front.add(
              MLine(
                [
                  Offset(cx, y),
                  Offset(cx + loopWidth, y),
                  Offset(cx + loopWidth, y + 18),
                  Offset(cx, y + 18),
                ],
                stroke: e.stroke,
                start: e.start,
                end: e.end,
              ),
            );
            if (autonumber) _badge(front, measure, Offset(cx, y), number);
            reach(cx - 10, math.max(cx + loopWidth, cx + 10 + s.width) + 4);
            y += 18;
          } else {
            final ltr = a < b;
            final x1 = edgeOf(e.from, !ltr);
            if (e.activate) active[e.to]!.add(y + s.height + 6);
            final x2 = edgeOf(e.to, ltr);
            final mid = (x1 + x2) / 2;
            if (s != Size.zero) {
              front.add(
                MLabel(
                  e.text,
                  MText.message,
                  Rect.fromLTWH(mid - s.width / 2, y, s.width, s.height),
                ),
              );
            }
            y += s.height + 6;
            front.add(
              MLine(
                [Offset(x1, y), Offset(x2, y)],
                stroke: e.stroke,
                start: e.start,
                end: e.end,
              ),
            );
            if (autonumber) _badge(front, measure, Offset(x1, y), number);
            reach(math.min(x1, x2) - 10, math.max(x1, x2) + 10);
            reach(mid - s.width / 2, mid + s.width / 2);
          }
          if (autonumber) number += numberStep;
          if (e.activate && a == b) active[e.to]!.add(y);
          y += 22;
          if (e.deactivate) activationOff(e.from);
        case SeqNote():
          final s = noteSize(e.text);
          final a = x[index[e.over.first]!], b = x[index[e.over.last]!];
          final Rect r;
          switch (e.side) {
            case NoteSide.left:
              r = Rect.fromLTWH(a - 12 - s.width, y, s.width, s.height);
            case NoteSide.right:
              r = Rect.fromLTWH(a + 12, y, s.width, s.height);
            case NoteSide.over:
              final l = math.min(a, b), rr = math.max(a, b);
              final w = math.max(s.width, rr - l + 40);
              r = Rect.fromLTWH((l + rr) / 2 - w / 2, y, w, s.height);
          }
          front.add(MBox(MShape.note, r));
          final t = measure(e.text, MText.note, wrap);
          front.add(
            MLabel(
              e.text,
              MText.note,
              Rect.fromCenter(
                center: r.center,
                width: t.width,
                height: t.height,
              ),
            ),
          );
          reach(r.left, r.right);
          y += s.height + 14;
        case SeqOpen():
          final kind = measure(e.kind, MText.frameKind, 200);
          final title = e.title.isEmpty
              ? Size.zero
              : measure('[${e.title}]', MText.frameTitle, wrap);
          frames.add(_Frame(y, kind, e)..titleSize = title);
          y += math.max(kind.height + 8, title.height + 6) + 10;
        case SeqElse():
          final f = frames.last;
          final t = e.title.isEmpty
              ? Size.zero
              : measure('[${e.title}]', MText.frameTitle, wrap);
          f.sections.add((y, e.title, t));
          y += t.height + 16;
        case SeqEnd():
          final f = frames.removeLast();
          var l = f.left, r = f.right;
          if (l == double.infinity) {
            l = x.first - 20;
            r = x.last + 20;
          }
          l -= 10;
          r += 10;
          final kindW = f.kind.width + 16;
          r = math.max(r, l + kindW + f.titleSize.width + 24);
          for (final (_, _, t) in f.sections) {
            r = math.max(r, l + t.width + 24);
          }
          final rect = Rect.fromLTRB(l, f.top, r, y);
          final tab = Rect.fromLTWH(l, f.top, kindW, f.kind.height + 8);
          back.add(MBox(MShape.frame, rect));
          back.add(MBox(MShape.frameTab, tab));
          front.add(
            MLabel(
              f.open.kind,
              MText.frameKind,
              Rect.fromCenter(
                center: tab.center,
                width: f.kind.width,
                height: f.kind.height,
              ),
            ),
          );
          if (f.open.title.isNotEmpty) {
            final mid = (tab.right + r) / 2;
            front.add(
              MLabel(
                '[${f.open.title}]',
                MText.frameTitle,
                Rect.fromLTWH(
                  mid - f.titleSize.width / 2,
                  f.top + 4,
                  f.titleSize.width,
                  f.titleSize.height,
                ),
              ),
            );
          }
          for (final (sy, title, t) in f.sections) {
            back.add(
              MLine(
                [Offset(l, sy), Offset(r, sy)],
                stroke: MStroke.dashed,
                role: MLineRole.separator,
              ),
            );
            if (title.isNotEmpty) {
              front.add(
                MLabel(
                  '[$title]',
                  MText.frameTitle,
                  Rect.fromLTWH(
                    (l + r) / 2 - t.width / 2,
                    sy + 4,
                    t.width,
                    t.height,
                  ),
                ),
              );
            }
          }
          y += 12;
          reach(l, r);
        case SeqActivation(:final who, :final on):
          if (on) {
            active[who]!.add(y - 10);
          } else {
            activationOff(who);
          }
      }
    }
    for (final p in ps) {
      while (active[p.id]!.isNotEmpty) {
        activationOff(p.id);
      }
    }
    y += 8;
    final lifelines = <MItem>[
      for (var i = 0; i < ps.length; i++)
        MLine(
          [Offset(x[i], headH), Offset(x[i], y)],
          stroke: MStroke.dashed,
          role: MLineRole.lifeline,
        ),
    ];
    for (var i = 0; i < ps.length; i++) {
      participantBox(i, y);
    }
    return MermaidScene(
      [...lifelines, ...back, ...front],
      description:
          'Sequence diagram between ${ps.map((p) => p.label).join(', ')}, '
          '${events.whereType<SeqMessage>().length} messages',
    );
  }

  void _badge(List<MItem> into, MermaidMeasure measure, Offset at, int n) {
    final t = measure('$n', MText.number, 40);
    final d = math.max(18.0, t.width + 8);
    final r = Rect.fromCenter(center: at, width: d, height: d);
    into.add(MBox(MShape.badge, r));
    into.add(
      MLabel(
        '$n',
        MText.number,
        Rect.fromCenter(center: at, width: t.width, height: t.height),
      ),
    );
  }
}

class _Frame {
  _Frame(this.top, this.kind, this.open);

  final double top;
  final Size kind;
  final SeqOpen open;
  Size titleSize = Size.zero;
  double left = double.infinity;
  double right = -double.infinity;
  final sections = <(double, String, Size)>[];
}
