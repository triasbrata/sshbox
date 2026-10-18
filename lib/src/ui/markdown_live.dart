/// A Markdown file read for live preview: what each piece of its source
/// looks like, and which markers hide while the caret is elsewhere.
///
/// Nothing here ever writes the source. The editor's text is the file itself,
/// byte for byte, and this only says how to draw it, the way Obsidian's live
/// preview does: `**`, `_`, `` ` ``, `#`, `[..](..)`, a list's bullet and a
/// quote's `>` hide away from the caret and show where it is; a table, a code
/// fence, a rule and a picture draw rendered until the caret goes into them.
/// So a reading that is wrong costs only a look, never a byte.
///
/// The reading is deliberately lenient, as an editor's highlighter is, rather
/// than the markdown package's exact one: it has to be right about where a
/// span starts and ends in the source, which a parser's tree does not say.
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// A range of the source, [start] inclusive and [end] exclusive.
@immutable
class MdRange {
  const MdRange(this.start, this.end);

  final int start;
  final int end;

  bool contains(int offset) => offset >= start && offset < end;

  /// Whether a caret at [offset] touches this range, either edge counting.
  bool touches(int offset) => offset >= start && offset <= end;

  @override
  bool operator ==(Object other) =>
      other is MdRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => '[$start, $end)';
}

/// A link's target, as written.
@immutable
class MdLink {
  const MdLink(this.href, {this.title});

  final String href;
  final String? title;

  @override
  bool operator ==(Object other) =>
      other is MdLink && other.href == href && other.title == title;

  @override
  int get hashCode => Object.hash(href, title);

  @override
  String toString() => 'MdLink($href)';
}

/// What a character of the source is, as bits of [MdLive.marks].
abstract final class MdMark {
  static const bold = 1 << 0;
  static const italic = 1 << 1;
  static const code = 1 << 2;
  static const strike = 1 << 3;
  static const link = 1 << 4;

  /// Syntax drawn quietly where it shows: a revealed marker, front matter,
  /// HTML, a definition's label.
  static const dim = 1 << 5;

  /// A fenced or indented code block's lines.
  static const codeBlock = 1 << 6;
  static const quote = 1 << 7;

  /// A blank line between blocks, drawn shorter than a line of text.
  static const gap = 1 << 8;

  /// A list item's indent, widened so nesting reads as nesting.
  static const indent = 1 << 9;

  /// A finished task's text.
  static const done = 1 << 10;

  /// The heading level, 1 to 6, in three bits from [headingShift].
  static const headingShift = 12;
  static const headingMask = 7 << headingShift;

  static int heading(int marks) => (marks & headingMask) >> headingShift;
}

/// Markup that hides unless the caret or a selection's end is in [reveal].
@immutable
class MdHide {
  const MdHide(this.range, this.reveal);

  final MdRange range;
  final MdRange reveal;
}

enum MdSwapKind { bullet, task, quoteBar, rule, table, fence, image }

/// Source drawn as something else until the caret goes into [reveal]: its
/// first character becomes the widget and the rest hides, so the text and
/// what is drawn stay the same length and every offset means the same thing.
@immutable
class MdSwap {
  const MdSwap(this.kind, this.range, this.reveal, {this.checked = false});

  final MdSwapKind kind;
  final MdRange range;
  final MdRange reveal;

  /// For a task: whether its box is ticked.
  final bool checked;
}

/// A link, by where its text is.
@immutable
class MdLinkSpan {
  const MdLinkSpan(this.range, this.link, {this.target, this.all});

  final MdRange range;
  final MdLink link;

  /// For `[text](url)`: where the url is written, and the whole link.
  final MdRange? target;
  final MdRange? all;
}

/// The kind of block a line belongs to, for the formatting bar and Enter.
enum MdLineKind {
  blank,
  paragraph,
  heading,
  setextUnderline,
  listItem,
  fence,
  code,
  table,
  html,
  frontMatter,
  rule,
  definition,
}

/// One line of the source, without its line break.
@immutable
class MdLine {
  const MdLine({
    required this.start,
    required this.end,
    required this.kind,
    this.level = 0,
    this.quote,
    this.marker,
    this.content = 0,
  });

  final int start;
  final int end;
  final MdLineKind kind;

  /// A heading's level.
  final int level;

  /// The `> ` markers before it, as one range.
  final MdRange? quote;

  /// A list item's marker with its indent and the space after it, a task's
  /// box included: `  - [ ] `.
  final MdRange? marker;

  /// Where the text proper starts, past every marker.
  final int content;
}

/// The whole reading of one source text.
class MdLive {
  MdLive._(
    this.text,
    this.marks,
    this.hides,
    this.swaps,
    this.links,
    this.lines,
    this.sections,
  );

  final String text;

  /// The document in runs of whole blocks that draw on their own while no
  /// caret is in them: see the editor.
  final List<MdRange> sections;
  final Uint32List marks;
  final List<MdHide> hides;
  final List<MdSwap> swaps;
  final List<MdLinkSpan> links;
  final List<MdLine> lines;

  /// The line holding [offset].
  MdLine lineAt(int offset) {
    var lo = 0;
    var hi = lines.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (lines[mid].start <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lines[lo];
  }

  /// The link written over [offset], its text or its markup, if any.
  MdLink? linkAt(int offset) {
    for (final l in links) {
      if ((l.all ?? l.range).contains(offset)) return l.link;
    }
    return null;
  }

  static MdLive parse(String text) => _Reader(text).read();
}

final _fenceOpen = RegExp(r'^( {0,3})(`{3,}|~{3,})(.*)$');
final _heading = RegExp(r'^( {0,3})(#{1,6})([ \t]+|$)');
final _list = RegExp(r'^([ \t]*)([-*+]|\d{1,9}[.)])([ \t]+|$)');
final _task = RegExp(r'^\[([ xX])\]([ \t]|$)');
final _rule = RegExp(r'^ {0,3}([-*_])([ \t]*\1){2,}[ \t]*$');
final _setext = RegExp(r'^ {0,3}(=+|-+)[ \t]*$');
final _tableDelim = RegExp(
  r'^[ \t]*\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$',
);
final _definition = RegExp(r'^ {0,3}\[(\^?)[^\]]+\]:');
final _htmlStart = RegExp(
  r'^ {0,3}<(!--|/?(address|article|aside|blockquote|body|caption|center|col|'
  r'colgroup|dd|details|dialog|div|dl|dt|fieldset|figcaption|figure|footer|'
  r'form|h[1-6]|head|header|hr|html|iframe|legend|li|link|main|menu|nav|ol|p|'
  r'picture|pre|script|section|source|style|summary|table|tbody|td|tfoot|th|'
  r'thead|title|tr|ul|video|img|br|a|span)\b)',
  caseSensitive: false,
);

/// How many lines a section takes before it may end: smaller sections shape
/// less on each key, larger ones make fewer runs in the page.
const _sectionLines = 8;

class _Reader {
  _Reader(this.text) : marks = Uint32List(text.length);

  final String text;
  final Uint32List marks;
  final hides = <MdHide>[];
  final swaps = <MdSwap>[];
  final links = <MdLinkSpan>[];
  final lines = <MdLine>[];

  /// `[label]: url`, for reference links, by lowercased label.
  final refs = <String, MdLink>{};

  void mark(int start, int end, int bits) {
    for (var i = start; i < end; i++) {
      marks[i] |= bits;
    }
  }

  MdLive read() {
    final starts = <int>[0];
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0A) starts.add(i + 1);
    }
    int lineEnd(int k) =>
        k + 1 < starts.length ? starts[k + 1] - 1 : text.length;
    String line(int k) => text.substring(starts[k], lineEnd(k));
    final n = starts.length;
    bool blank(int k) => k < n && line(k).trim().isEmpty;

    // Reference definitions first: a link can come before its target.
    final refLine = RegExp(r'^ {0,3}\[([^\]^][^\]]*)\]:[ \t]*<?([^\s>]+)>?');
    for (var k = 0; k < n; k++) {
      final m = refLine.firstMatch(line(k));
      if (m != null) refs[m[1]!.toLowerCase()] = MdLink(m[2]!);
    }

    var k = 0;
    var prevKind = MdLineKind.blank;

    void add(
      int k,
      MdLineKind kind, {
      int level = 0,
      MdRange? quote,
      MdRange? marker,
      int? content,
    }) {
      lines.add(
        MdLine(
          start: starts[k],
          end: lineEnd(k),
          kind: kind,
          level: level,
          quote: quote,
          marker: marker,
          content: content ?? starts[k],
        ),
      );
    }

    // Front matter: `---` on the very first line, closed by `---` or `...`.
    if (n > 1 && line(0) == '---') {
      var e = 1;
      while (e < n && line(e) != '---' && line(e) != '...') {
        e++;
      }
      if (e < n) {
        for (var j = 0; j <= e; j++) {
          add(j, MdLineKind.frontMatter);
        }
        mark(0, lineEnd(e), MdMark.dim | MdMark.codeBlock);
        k = e + 1;
        prevKind = MdLineKind.frontMatter;
      }
    }

    while (k < n) {
      final s = starts[k];
      final raw = line(k);

      if (raw.trim().isEmpty) {
        add(k, MdLineKind.blank);
        // The line break of a blank line, drawn as a gap rather than a line.
        if (lineEnd(k) < text.length) {
          mark(s, lineEnd(k) + 1, MdMark.gap);
        }
        prevKind = MdLineKind.blank;
        k++;
        continue;
      }

      // Quote markers: each `>` becomes a bar, its text read as any other.
      var at = 0;
      var quoteEnd = 0;
      var depth = 0;
      while (true) {
        var q = at;
        while (q < raw.length && q - at < 3 && raw[q] == ' ') {
          q++;
        }
        if (q < raw.length && raw[q] == '>') {
          swaps.add(
            MdSwap(
              MdSwapKind.quoteBar,
              MdRange(s + q, s + q + 1),
              MdRange(s + q, s + q + 1),
            ),
          );
          q++;
          if (q < raw.length && raw[q] == ' ') q++;
          at = q;
          quoteEnd = q;
          depth++;
          continue;
        }
        break;
      }
      final quote = depth > 0 ? MdRange(s, s + quoteEnd) : null;
      if (depth > 0) mark(s, lineEnd(k), MdMark.quote);
      final body = raw.substring(at);
      final b = s + at;

      // A fence runs to its closing fence, or to the end when there is none.
      final fence = _fenceOpen.firstMatch(body);
      if (fence != null &&
          !(fence[2]!.startsWith('`') && fence[3]!.contains('`'))) {
        final open = fence[2]!;
        var e = k + 1;
        final close = RegExp(
          '^ {0,3}${RegExp.escape(open[0])}{${open.length},}[ \\t]*\$',
        );
        while (e < n) {
          final l = line(e);
          final inner = depth > 0
              ? l.replaceFirst(RegExp(r'^( {0,3}> ?)+'), '')
              : l;
          if (close.hasMatch(inner)) break;
          e++;
        }
        final last = e < n ? e : n - 1;
        for (var j = k; j <= last; j++) {
          add(j, MdLineKind.fence, quote: quote);
        }
        final end = lineEnd(last);
        mark(b, end, MdMark.codeBlock);
        mark(b, b + body.length, MdMark.dim);
        if (e < n) mark(starts[e], end, MdMark.dim);
        swaps.add(MdSwap(MdSwapKind.fence, MdRange(b, end), MdRange(b, end)));
        prevKind = MdLineKind.fence;
        k = last + 1;
        continue;
      }

      // A table: a row with a pipe, then the delimiter row.
      if (body.contains('|') &&
          k + 1 < n &&
          _tableDelim.hasMatch(line(k + 1)) &&
          line(k + 1).contains('-')) {
        var e = k + 1;
        while (e + 1 < n && !blank(e + 1) && line(e + 1).contains('|')) {
          e++;
        }
        for (var j = k; j <= e; j++) {
          add(j, MdLineKind.table, quote: quote);
        }
        final end = lineEnd(e);
        for (var j = k; j <= e; j++) {
          final l = line(j);
          for (var c = 0; c < l.length; c++) {
            if (l[c] == '|') mark(starts[j] + c, starts[j] + c + 1, MdMark.dim);
          }
          if (j != k + 1) _inline(starts[j], lineEnd(j));
        }
        mark(starts[k + 1], lineEnd(k + 1), MdMark.dim);
        swaps.add(MdSwap(MdSwapKind.table, MdRange(b, end), MdRange(b, end)));
        prevKind = MdLineKind.table;
        k = e + 1;
        continue;
      }

      // An HTML block runs to a blank line, as CommonMark's sixth kind does.
      if (_htmlStart.hasMatch(body) && prevKind != MdLineKind.paragraph) {
        var e = k;
        while (e + 1 < n && !blank(e + 1)) {
          e++;
        }
        for (var j = k; j <= e; j++) {
          add(j, MdLineKind.html, quote: quote);
        }
        mark(b, lineEnd(e), MdMark.dim | MdMark.code);
        prevKind = MdLineKind.html;
        k = e + 1;
        continue;
      }

      // Setext: a paragraph line with `===` or `---` under it.
      if (k + 1 < n &&
          depth == 0 &&
          prevKind != MdLineKind.paragraph &&
          !_list.hasMatch(body) &&
          !_heading.hasMatch(body) &&
          _setext.hasMatch(line(k + 1)) &&
          !_rule.hasMatch(body)) {
        final level = line(k + 1).trim().startsWith('=') ? 1 : 2;
        add(k, MdLineKind.heading, level: level, content: b);
        add(k + 1, MdLineKind.setextUnderline, level: level);
        mark(b, lineEnd(k), level << MdMark.headingShift);
        _inline(b, lineEnd(k));
        final under = MdRange(starts[k + 1], lineEnd(k + 1));
        mark(under.start, under.end, MdMark.dim);
        // The underline line and the break before it hide together.
        hides.add(
          MdHide(MdRange(lineEnd(k), under.end), MdRange(s, under.end)),
        );
        prevKind = MdLineKind.heading;
        k += 2;
        continue;
      }

      if (_rule.hasMatch(body) &&
          !(prevKind == MdLineKind.paragraph && body.trim().startsWith('-'))) {
        add(k, MdLineKind.rule, quote: quote);
        final r = MdRange(b, lineEnd(k));
        mark(r.start, r.end, MdMark.dim);
        swaps.add(MdSwap(MdSwapKind.rule, r, r));
        prevKind = MdLineKind.rule;
        k++;
        continue;
      }

      final heading = _heading.firstMatch(body);
      if (heading != null) {
        final level = heading[2]!.length;
        final content = b + heading[0]!.length;
        add(
          k,
          MdLineKind.heading,
          level: level,
          quote: quote,
          content: content,
        );
        final e = lineEnd(k);
        mark(b, e, level << MdMark.headingShift);
        // A closing run of hashes hides with the opening one.
        var ce = e;
        var trail = raw.length;
        while (trail > 0 && (raw[trail - 1] == ' ' || raw[trail - 1] == '\t')) {
          trail--;
        }
        var h = trail;
        while (h > 0 && raw[h - 1] == '#') {
          h--;
        }
        if (h < trail &&
            h > 0 &&
            s + h > content &&
            (raw[h - 1] == ' ' || raw[h - 1] == '\t')) {
          var sp = h;
          while (sp > 0 && (raw[sp - 1] == ' ' || raw[sp - 1] == '\t')) {
            sp--;
          }
          ce = s + sp;
          mark(ce, e, MdMark.dim);
          hides.add(MdHide(MdRange(ce, e), MdRange(s, e)));
        }
        mark(b, content, MdMark.dim);
        hides.add(MdHide(MdRange(b, content), MdRange(s, e)));
        _inline(content, ce);
        prevKind = MdLineKind.heading;
        k++;
        continue;
      }

      final list = _list.firstMatch(body);
      if (list != null &&
          (list[3]!.isNotEmpty || body.length == list[0]!.length) &&
          !(list[2]!.length > 1 &&
              prevKind == MdLineKind.paragraph &&
              !list[2]!.startsWith('1'))) {
        final indent = list[1]!.length;
        final ms = b + indent;
        final bullet = list[2]!;
        var content = b + list[0]!.length;
        final e = lineEnd(k);
        if (indent > 0) mark(b, ms, MdMark.indent);
        final task = _task.firstMatch(text.substring(content, e));
        if (task != null && !bullet.contains(RegExp(r'\d'))) {
          final box = MdRange(content, content + 3);
          final checked = task[1] != ' ';
          // The bullet hides behind the box, which ticks with a tap.
          hides.add(MdHide(MdRange(ms, box.start), MdRange(s, box.end)));
          swaps.add(
            MdSwap(MdSwapKind.task, box, MdRange(s, box.end), checked: checked),
          );
          content = box.end + (task[2]!.isEmpty ? 0 : 1);
          if (checked) mark(content, e, MdMark.done);
        } else if (!bullet.contains(RegExp(r'\d'))) {
          swaps.add(
            MdSwap(MdSwapKind.bullet, MdRange(ms, ms + 1), MdRange(s, ms + 1)),
          );
        } else {
          mark(ms, ms + bullet.length, MdMark.dim);
        }
        add(
          k,
          MdLineKind.listItem,
          quote: quote,
          marker: MdRange(b, content),
          content: content,
        );
        _inline(content, e);
        prevKind = MdLineKind.listItem;
        k++;
        continue;
      }

      if (_definition.hasMatch(body)) {
        add(k, MdLineKind.definition, quote: quote, content: b);
        final close = body.indexOf(']:');
        mark(b, b + close + 2, MdMark.dim);
        _inline(b + close + 2, lineEnd(k));
        prevKind = MdLineKind.definition;
        k++;
        continue;
      }

      // Indented code: four spaces after a blank line, outside a list.
      if (depth == 0 &&
          (raw.startsWith('    ') || raw.startsWith('\t')) &&
          prevKind == MdLineKind.blank &&
          !_lastWasList()) {
        var e = k;
        while (e + 1 < n &&
            (line(e + 1).startsWith('    ') ||
                line(e + 1).startsWith('\t') ||
                (blank(e + 1) &&
                    e + 2 < n &&
                    (line(e + 2).startsWith('    ') ||
                        line(e + 2).startsWith('\t'))))) {
          e++;
        }
        for (var j = k; j <= e; j++) {
          add(j, MdLineKind.code);
        }
        mark(s, lineEnd(e), MdMark.codeBlock);
        prevKind = MdLineKind.code;
        k = e + 1;
        continue;
      }

      add(k, MdLineKind.paragraph, quote: quote, content: b);
      _inline(b, lineEnd(k));
      prevKind = MdLineKind.paragraph;
      k++;
    }
    if (lines.isEmpty) {
      lines.add(const MdLine(start: 0, end: 0, kind: MdLineKind.blank));
    }
    return MdLive._(text, marks, hides, swaps, links, lines, _sections());
  }

  /// The document cut into runs of whole blocks of about [_sectionLines]
  /// lines, each starting with the blank lines before its first block and
  /// ending with the line break of its last: never inside a fence, a table
  /// or any other block, since a cut only falls where a blank line ends.
  List<MdRange> _sections() {
    final out = <MdRange>[];
    var start = 0;
    var count = 0;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      count++;
      final next = i + 1 < lines.length ? lines[i + 1] : null;
      if (next == null) break;
      // A cut after a block's last line, where blank lines follow.
      if (count >= _sectionLines &&
          line.kind != MdLineKind.blank &&
          next.kind == MdLineKind.blank) {
        out.add(MdRange(start, line.end + 1));
        start = line.end + 1;
        count = 0;
      }
    }
    if (start < text.length || out.isEmpty) {
      out.add(MdRange(start, text.length));
    }
    return out;
  }

  bool _lastWasList() {
    for (var i = lines.length - 1; i >= 0; i--) {
      final kind = lines[i].kind;
      if (kind == MdLineKind.blank) continue;
      return kind == MdLineKind.listItem ||
          (kind == MdLineKind.paragraph && i > 0 && _continuesList(i));
    }
    return false;
  }

  bool _continuesList(int i) {
    for (var j = i; j >= 0; j--) {
      final kind = lines[j].kind;
      if (kind == MdLineKind.listItem) return true;
      if (kind != MdLineKind.paragraph) return false;
    }
    return false;
  }

  /// Inline markup between [start] and [end].
  void _inline(int start, int end) => _span(start, end, 0);

  static bool _space(String c) => c == ' ' || c == '\t' || c == '\n';
  static bool _punct(String c) => RegExp(r'''[!-/:-@\[-`{-~]''').hasMatch(c);

  void _span(int start, int end, int bits) {
    var i = start;
    while (i < end) {
      final c = text[i];
      // An escape: the backslash hides, the character after it is text.
      if (c == '\\' && i + 1 < end && _punct(text[i + 1])) {
        mark(i, i + 1, MdMark.dim);
        hides.add(MdHide(MdRange(i, i + 1), MdRange(i, i + 2)));
        i += 2;
        continue;
      }
      if (c == '`') {
        var run = i;
        while (run < end && text[run] == '`') {
          run++;
        }
        final len = run - i;
        final close = _closingTicks(run, end, len);
        if (close < 0) {
          i = run;
          continue;
        }
        final all = MdRange(i, close + len);
        mark(i, close + len, bits | MdMark.code);
        mark(i, run, MdMark.dim);
        mark(close, close + len, MdMark.dim);
        hides.add(MdHide(MdRange(i, run), all));
        hides.add(MdHide(MdRange(close, close + len), all));
        i = close + len;
        continue;
      }
      if (c == '!' && i + 1 < end && text[i + 1] == '[') {
        final img = _link(i + 1, end);
        if (img != null) {
          final r = MdRange(i, img.end);
          mark(r.start, r.end, MdMark.dim);
          swaps.add(MdSwap(MdSwapKind.image, r, r));
          i = img.end;
          continue;
        }
      }
      if (c == '[') {
        final l = _link(i, end);
        if (l != null) {
          final all = MdRange(i, l.end);
          final label = MdRange(i + 1, l.textEnd);
          if (l.link != null) {
            links.add(MdLinkSpan(label, l.link!, target: l.target, all: all));
            mark(label.start, label.end, MdMark.link);
          } else {
            // A footnote reference, drawn as a quiet label.
            mark(label.start, label.end, MdMark.dim);
          }
          mark(i, i + 1, MdMark.dim);
          mark(l.textEnd, l.end, MdMark.dim);
          hides.add(MdHide(MdRange(i, i + 1), all));
          hides.add(MdHide(MdRange(l.textEnd, l.end), all));
          _span(label.start, label.end, bits);
          i = l.end;
          continue;
        }
      }
      if (c == '<') {
        final m = RegExp(r'<(https?://[^\s>]+|[^\s@>]+@[^\s@>]+)>')
            .matchAsPrefix(text.substring(i, end));
        if (m != null) {
          final label = MdRange(i + 1, i + m[0]!.length - 1);
          final href = m[1]!.contains('://') ? m[1]! : 'mailto:${m[1]}';
          links.add(MdLinkSpan(label, MdLink(href)));
          mark(label.start, label.end, MdMark.link);
          final all = MdRange(i, label.end + 1);
          hides.add(MdHide(MdRange(i, i + 1), all));
          hides.add(MdHide(MdRange(label.end, label.end + 1), all));
          i = all.end;
          continue;
        }
      }
      if ((c == 'h') &&
          (i == start || !RegExp(r'[A-Za-z0-9]').hasMatch(text[i - 1]))) {
        final m = RegExp(r'https?://[^\s<>()]+[^\s<>().,;:!?*_~]')
            .matchAsPrefix(text.substring(i, end));
        if (m != null) {
          final r = MdRange(i, i + m[0]!.length);
          links.add(MdLinkSpan(r, MdLink(m[0]!)));
          mark(r.start, r.end, MdMark.link);
          i = r.end;
          continue;
        }
      }
      if (c == '*' || c == '_' || c == '~') {
        final closed = _emphasis(i, end, bits);
        if (closed > i) {
          i = closed;
          continue;
        }
        var run = i;
        while (run < end && text[run] == c) {
          run++;
        }
        i = run;
        continue;
      }
      i++;
    }
  }

  int _closingTicks(int from, int end, int len) {
    var i = from;
    while (i < end) {
      if (text[i] != '`') {
        i++;
        continue;
      }
      var run = i;
      while (run < end && text[run] == '`') {
        run++;
      }
      if (run - i == len) return i;
      i = run;
    }
    return -1;
  }

  /// An emphasis run opening at [i]: where it ends, or [i] when it does not
  /// close on this line.
  int _emphasis(int i, int end, int bits) {
    final c = text[i];
    var run = i;
    while (run < end && text[run] == c) {
      run++;
    }
    final len = run - i;
    if (c == '~' && len != 2) return i;
    if (len > 3) return i;
    // Left-flanking: not followed by a space; `_` not inside a word.
    if (run >= end || _space(text[run])) return i;
    if (c == '_' && i > 0 && RegExp(r'[A-Za-z0-9]').hasMatch(text[i - 1])) {
      return i;
    }
    // The nearest closing run of the same length, right-flanking.
    var j = run;
    while (j < end) {
      final t = text[j];
      if (t == '`') {
        var r = j;
        while (r < end && text[r] == '`') {
          r++;
        }
        final close = _closingTicks(r, end, r - j);
        j = close < 0 ? r : close + (r - j);
        continue;
      }
      if (t == '\\') {
        j += 2;
        continue;
      }
      if (t != c) {
        j++;
        continue;
      }
      var r = j;
      while (r < end && text[r] == c) {
        r++;
      }
      final closeLen = r - j;
      final flanking =
          !_space(text[j - 1]) &&
          (c != '_' || r >= end || !RegExp(r'[A-Za-z0-9]').hasMatch(text[r]));
      if (flanking && closeLen == len && j > run) {
        final style = switch ((c, len)) {
          ('~', _) => MdMark.strike,
          (_, 1) => MdMark.italic,
          (_, 2) => MdMark.bold,
          _ => MdMark.bold | MdMark.italic,
        };
        final all = MdRange(i, r);
        mark(run, j, style);
        mark(i, run, MdMark.dim | style);
        mark(j, r, MdMark.dim | style);
        hides.add(MdHide(MdRange(i, run), all));
        hides.add(MdHide(MdRange(j, r), all));
        _span(run, j, bits | style);
        return r;
      }
      // A longer or shorter run inside: `**a *b* c**` reads *b* first.
      if (flanking && closeLen != len) {
        // Skip a nested run of another length that closes on its own.
        final inner = _emphasis(j, end, bits);
        if (inner > j) {
          j = inner;
          continue;
        }
      }
      j = r;
    }
    return i;
  }

  /// `[text](url "title")`, `[text][ref]`, `[text]` naming a reference, or a
  /// footnote `[^1]`, starting at the `[` at [i].
  ({int textEnd, int end, MdLink? link, MdRange? target})? _link(
    int i,
    int end,
  ) {
    var depth = 0;
    var j = i;
    for (; j < end; j++) {
      final t = text[j];
      if (t == '\\') {
        j++;
        continue;
      }
      if (t == '`') {
        var r = j;
        while (r < end && text[r] == '`') {
          r++;
        }
        final close = _closingTicks(r, end, r - j);
        if (close >= 0) j = close + (r - j) - 1;
        continue;
      }
      if (t == '[') depth++;
      if (t == ']') {
        depth--;
        if (depth == 0) break;
      }
    }
    if (j >= end) return null;
    final textEnd = j;
    if (textEnd == i + 1) return null;
    final label = text.substring(i + 1, textEnd);
    if (j + 1 < end && text[j + 1] == '(') {
      var p = j + 2;
      var parens = 1;
      var angle = p < end && text[p] == '<';
      while (p < end) {
        final t = text[p];
        if (t == '\\') {
          p += 2;
          continue;
        }
        if (angle) {
          if (t == '>') angle = false;
        } else if (t == '(') {
          parens++;
        } else if (t == ')') {
          parens--;
          if (parens == 0) break;
        }
        p++;
      }
      if (p >= end) return null;
      final written = text.substring(j + 2, p);
      final inside = written.trim();
      final lead = written.length - written.trimLeft().length;
      final m = RegExp(r'^(<[^>]*>|\S+)(?:\s+"([^"]*)")?$').firstMatch(inside);
      var href = m?[1] ?? inside;
      final from = j + 2 + lead;
      final target = MdRange(from, from + href.length);
      if (href.startsWith('<') && href.endsWith('>')) {
        href = href.substring(1, href.length - 1);
      }
      return (
        textEnd: textEnd,
        end: p + 1,
        link: MdLink(href, title: m?[2]),
        target: target,
      );
    }
    if (label.startsWith('^')) {
      return (textEnd: textEnd, end: textEnd + 1, link: null, target: null);
    }
    if (j + 1 < end && text[j + 1] == '[') {
      final close = text.indexOf(']', j + 2);
      if (close < 0 || close >= end) return null;
      final name = close == j + 2 ? label : text.substring(j + 2, close);
      final ref = refs[name.toLowerCase()];
      if (ref == null) return null;
      return (textEnd: textEnd, end: close + 1, link: ref, target: null);
    }
    final ref = refs[label.toLowerCase()];
    if (ref == null) return null;
    // Not a definition's own label.
    if (j + 1 < end && text[j + 1] == ':') return null;
    return (textEnd: textEnd, end: textEnd + 1, link: ref, target: null);
  }
}
