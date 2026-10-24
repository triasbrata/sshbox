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

  @override
  bool operator ==(Object other) =>
      other is MdHide && other.range == range && other.reveal == reveal;

  @override
  int get hashCode => Object.hash(range, reveal);

  @override
  String toString() => 'MdHide($range, $reveal)';
}

enum MdSwapKind {
  bullet,
  task,
  quoteBar,
  rule,
  table,
  fence,
  image,

  /// Front matter, drawn as a quiet block of its keys and values.
  frontMatter,

  /// `<details>` with its `<summary>`, or the `</details>` that ends it.
  details,

  /// `<br>`: the rest of the paragraph on a line of its own.
  lineBreak,
}

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

  @override
  bool operator ==(Object other) =>
      other is MdSwap &&
      other.kind == kind &&
      other.range == range &&
      other.reveal == reveal &&
      other.checked == checked;

  @override
  int get hashCode => Object.hash(kind, range, reveal, checked);

  @override
  String toString() => 'MdSwap(${kind.name}, $range, $reveal)';
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

  @override
  bool operator ==(Object other) =>
      other is MdLinkSpan &&
      other.range == range &&
      other.link == link &&
      other.target == target &&
      other.all == all;

  @override
  int get hashCode => Object.hash(range, link, target, all);

  @override
  String toString() => 'MdLinkSpan($range, $link)';
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

  @override
  bool operator ==(Object other) =>
      other is MdLine &&
      other.start == start &&
      other.end == end &&
      other.kind == kind &&
      other.level == level &&
      other.quote == quote &&
      other.marker == marker &&
      other.content == content;

  @override
  int get hashCode =>
      Object.hash(start, end, kind, level, quote, marker, content);

  @override
  String toString() => 'MdLine(${kind.name}, $start-$end)';
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
    this._refs,
  );

  final String text;

  /// The reference definitions, as links read them.
  final Map<String, MdLink> _refs;

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

  /// The reading of [text], an edit of [old]'s: only the sections the edit
  /// touched are read again, the rest moved over from [old]. It reads the
  /// whole text when the edit reaches past them — a fence or front matter
  /// opened or closed, a setext underline or a table row joining the block
  /// before, a list going on over a blank line, a reference definition — so
  /// it is always what [parse] would make.
  static MdLive update(MdLive old, String text) {
    if (identical(old.text, text)) return old;
    final read = _update(old, text);
    if (read != null) return read;
    fullReads++;
    return parse(text);
  }

  /// How many updates read the whole text, for tests.
  @visibleForTesting
  static int fullReads = 0;

  /// Turns the incremental path off, for a test showing what it guards.
  @visibleForTesting
  static bool incremental = true;

  static MdLive? _update(MdLive old, String text) {
    if (!incremental) return null;
    final o = old.text;
    var a = 0;
    final shorter = o.length < text.length ? o.length : text.length;
    while (a < shorter && o.codeUnitAt(a) == text.codeUnitAt(a)) {
      a++;
    }
    var s = 0;
    while (s < shorter - a &&
        o.codeUnitAt(o.length - 1 - s) ==
            text.codeUnitAt(text.length - 1 - s)) {
      s++;
    }
    final oldEnd = o.length - s;
    final delta = text.length - o.length;

    final reader = _Reader(text);
    // Front matter only begins on the first line, but may close anywhere.
    final front = old.lines.first.kind == MdLineKind.frontMatter;
    if (!front && reader.n > 1 && reader.line(0) == '---') return null;

    final sections = old.sections;
    var lo = 0;
    while (lo < sections.length - 1 && sections[lo].end < a) {
      lo++;
    }
    var hi = lo;
    while (hi + 1 < sections.length && sections[hi + 1].start <= oldEnd) {
      hi++;
    }
    for (var tries = 0; tries < 4; tries++) {
      final rs = sections[lo].start;
      final re = sections[hi].end;
      final last = hi == sections.length - 1;
      final newRe = re + delta;
      final k0 = reader.lineStartingAt(rs);
      final stop = last ? reader.n : reader.lineStartingAt(newRe);
      // The region starts on a blank line in the new text too, with no
      // indented code before it that could run on into it.
      final startOk =
          rs == 0 ||
          (k0 >= 0 &&
              reader.blank(k0) &&
              old.lineAt(rs - 1).kind != MdLineKind.code);
      if (!startOk) {
        if (lo == 0) return null;
        lo--;
        continue;
      }
      if (stop < 0 || stop <= k0 || (!last && !reader.blank(stop))) {
        if (last) return null;
        hi++;
        continue;
      }
      final lines = old.lines;
      final before = _firstAt(lines, rs, (l) => l.start);
      final after = last ? lines.length : _firstAt(lines, re, (l) => l.start);
      // The same definitions, or links elsewhere would read differently.
      final oldReader = _Reader(o);
      final defsOld = oldReader.definitions(
        oldReader.lineStartingAt(rs),
        last ? oldReader.n : oldReader.lineStartingAt(re),
      );
      final defsNew = reader.definitions(k0, stop);
      if (!listEquals(defsOld, defsNew)) return null;

      final r = _Reader(text, refs: old._refs);
      r.lines.addAll(lines.take(before));
      final reached = r._blocks(k0, stop);
      if (reached != stop && false) { // MUTANT: no fallback
        if (last) return null;
        hi++;
        continue;
      }
      // What follows reads an indented line by whether a list came last.
      if (!last &&
          _Reader._listBefore(r.lines, r.lines.length) !=
              _Reader._listBefore(lines, after)) {
        return null;
      }
      // Whatever comes after moves by the edit's length.
      int at(int k) => k + delta;
      MdRange mv(MdRange x) => MdRange(at(x.start), at(x.end));
      MdRange? mvn(MdRange? x) => x == null ? null : mv(x);
      bool moves(MdRange x) => !last && x.start >= re;

      final marks = r.marks;
      marks.setRange(0, rs, old.marks);
      if (!last) marks.setRange(newRe, text.length, old.marks, re);
      for (final l in lines.skip(after)) {
        if (last) break;
        r.lines.add(
          MdLine(
            start: at(l.start),
            end: at(l.end),
            kind: l.kind,
            level: l.level,
            quote: mvn(l.quote),
            marker: mvn(l.marker),
            content: at(l.content),
          ),
        );
      }
      List<T> join<T>(
        List<T> was,
        List<T> region,
        MdRange Function(T) range,
        T Function(T) move,
      ) => [
        for (final x in was)
          if (range(x).start < rs) x,
        ...region,
        for (final x in was)
          if (moves(range(x))) move(x),
      ];
      final hides = join(
        old.hides,
        r.hides,
        (h) => h.range,
        (h) => MdHide(mv(h.range), mv(h.reveal)),
      );
      final swaps = join(
        old.swaps,
        r.swaps,
        (w) => w.range,
        (w) => MdSwap(w.kind, mv(w.range), mv(w.reveal), checked: w.checked),
      );
      final links = join(
        old.links,
        r.links,
        (l) => l.range,
        (l) => MdLinkSpan(
          mv(l.range),
          l.link,
          target: mvn(l.target),
          all: mvn(l.all),
        ),
      );
      return MdLive._(
        text,
        marks,
        hides,
        swaps,
        links,
        r.lines,
        _Reader._sections(r.lines, text.length),
        old._refs,
      );
    }
    return null;
  }

  /// The index of the first of [items], sorted by [key], whose key is at
  /// least [offset].
  static int _firstAt<T>(List<T> items, int offset, int Function(T) key) {
    var lo = 0;
    var hi = items.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (key(items[mid]) < offset) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
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

/// An HTML block that is a `<details>` opening, with its `<summary>`, or the
/// `</details>` that closes one.
final _details = RegExp(
  r'^\s*(<details(\s+open)?\s*>\s*(<summary>[^<\n]*</summary>)?|</details>)\s*$',
  caseSensitive: false,
);

/// The HTML drawn rather than shown as source: these tags, and no others.
const _drawnTags = {'b', 'strong', 'i', 'em', 'a', 'br', 'img'};
final _anyTag = RegExp(r'<(/?)([a-zA-Z][a-zA-Z0-9]*)\b[^<>]*>');

/// Whether [source] holds only tags drawn as such, and no comment.
bool _simpleHtml(String source) {
  if (source.contains('<!')) return false;
  final tags = _anyTag.allMatches(source).toList();
  return tags.isNotEmpty &&
      tags.every((m) => _drawnTags.contains(m[2]!.toLowerCase()));
}

/// How many lines a section takes before it may end: smaller sections shape
/// less on each key, larger ones make fewer runs in the page.
const _sectionLines = 8;

final _refLine = RegExp(r'^ {0,3}\[([^\]^][^\]]*)\]:[ \t]*<?([^\s>]+)>?');

class _Reader {
  _Reader(this.text, {Map<String, MdLink>? refs})
    : marks = Uint32List(text.length),
      refs = refs ?? <String, MdLink>{} {
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0A) starts.add(i + 1);
    }
  }

  final String text;
  final Uint32List marks;
  final hides = <MdHide>[];
  final swaps = <MdSwap>[];
  final links = <MdLinkSpan>[];
  final lines = <MdLine>[];

  /// Where each line starts.
  final starts = <int>[0];

  /// `[label]: url`, for reference links, by lowercased label.
  final Map<String, MdLink> refs;

  void mark(int start, int end, int bits) {
    for (var i = start; i < end; i++) {
      marks[i] |= bits;
    }
  }

  int get n => starts.length;
  int lineEnd(int k) => k + 1 < starts.length ? starts[k + 1] - 1 : text.length;
  String line(int k) => text.substring(starts[k], lineEnd(k));
  bool blank(int k) => k < n && line(k).trim().isEmpty;

  /// The line starting at [offset], or -1 when none does.
  int lineStartingAt(int offset) {
    var lo = 0;
    var hi = starts.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final s = starts[mid];
      if (s == offset) return mid;
      if (s < offset) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return -1;
  }

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

  /// The reference definitions written on lines [from] to [to], in order.
  List<(String, MdLink)> definitions(int from, int to) => [
    for (var k = from; k < to; k++)
      if (_refLine.firstMatch(line(k)) case final m?)
        (m[1]!.toLowerCase(), MdLink(m[2]!)),
  ];

  MdLive read() {
    // Reference definitions first: a link can come before its target.
    for (final (label, link) in definitions(0, n)) {
      refs[label] = link;
    }
    _blocks(0, n);
    if (lines.isEmpty) {
      lines.add(const MdLine(start: 0, end: 0, kind: MdLineKind.blank));
    }
    return MdLive._(
      text,
      marks,
      hides,
      swaps,
      links,
      lines,
      _sections(lines, text.length),
      refs,
    );
  }

  /// The blocks from line [k], until one ends at or past line [stop]: the
  /// line it got to, which is past [stop] when a block ran on over it.
  int _blocks(int k, int stop) {
    var prevKind = MdLineKind.blank;

    // Front matter: `---` on the very first line, closed by `---` or `...`.
    if (k == 0 && n > 1 && line(0) == '---') {
      var e = 1;
      while (e < n && line(e) != '---' && line(e) != '...') {
        e++;
      }
      if (e < n) {
        for (var j = 0; j <= e; j++) {
          add(j, MdLineKind.frontMatter);
        }
        mark(0, lineEnd(e), MdMark.dim | MdMark.codeBlock);
        final all = MdRange(0, lineEnd(e));
        swaps.add(MdSwap(MdSwapKind.frontMatter, all, all));
        k = e + 1;
        prevKind = MdLineKind.frontMatter;
      }
    }

    while (k < stop) {
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
        final end = lineEnd(e);
        final source = text.substring(b, end);
        if (_details.hasMatch(source)) {
          // Drawn as the summary it opens with, or as nothing for its end.
          final r = MdRange(b, end);
          mark(b, end, MdMark.dim | MdMark.code);
          swaps.add(MdSwap(MdSwapKind.details, r, r));
        } else if (_simpleHtml(source)) {
          // Only tags drawn as Preview drew them: read as a paragraph's text.
          for (var j = k; j <= e; j++) {
            _inline(starts[j] + (j == k ? at : 0), lineEnd(j));
          }
        } else {
          mark(b, end, MdMark.dim | MdMark.code);
        }
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
    return k;
  }

  /// The document cut into runs of whole blocks of about [_sectionLines]
  /// lines, each starting with the blank lines before its first block and
  /// ending with the line break of its last: never inside a fence, a table
  /// or any other block, since a cut only falls where a blank line ends.
  static List<MdRange> _sections(List<MdLine> lines, int length) {
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
    if (start < length || out.isEmpty) {
      out.add(MdRange(start, length));
    }
    return out;
  }

  bool _lastWasList() => _listBefore(lines, lines.length);

  /// Whether the last block that is not blank, of the first [count] of
  /// [lines], is a list: an indented line after it is then not code.
  static bool _listBefore(List<MdLine> lines, int count) {
    for (var i = count - 1; i >= 0; i--) {
      final kind = lines[i].kind;
      if (kind == MdLineKind.blank) continue;
      return kind == MdLineKind.listItem ||
          (kind == MdLineKind.paragraph && i > 0 && _continuesList(lines, i));
    }
    return false;
  }

  static bool _continuesList(List<MdLine> lines, int i) {
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
        final html = _inlineHtml(i, end, bits);
        if (html > i) {
          i = html;
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

  /// A tag at [i]: where what it covers ends, or [i] when it is none. `<br>`
  /// and `<img>` are drawn, `<b>`, `<strong>`, `<i>`, `<em>` and `<a href>`
  /// hide their tags and style what is between, as Preview drew them; any
  /// other tag is quiet source.
  int _inlineHtml(int i, int end, int bits) {
    final open = _anyTag.matchAsPrefix(text.substring(i, end));
    if (open == null) return i;
    final tag = MdRange(i, i + open[0]!.length);
    final name = open[2]!.toLowerCase();
    if (open[1]!.isNotEmpty || !_drawnTags.contains(name)) {
      mark(tag.start, tag.end, MdMark.dim | MdMark.code);
      return tag.end;
    }
    if (name == 'br') {
      mark(tag.start, tag.end, MdMark.dim);
      swaps.add(MdSwap(MdSwapKind.lineBreak, tag, tag));
      return tag.end;
    }
    if (name == 'img') {
      mark(tag.start, tag.end, MdMark.dim);
      swaps.add(MdSwap(MdSwapKind.image, tag, tag));
      return tag.end;
    }
    final close = RegExp('</$name\\s*>', caseSensitive: false);
    final m = close.firstMatch(text.substring(tag.end, end));
    if (m == null) {
      mark(tag.start, tag.end, MdMark.dim | MdMark.code);
      return tag.end;
    }
    final inner = MdRange(tag.end, tag.end + m.start);
    final shut = MdRange(inner.end, tag.end + m.end);
    final all = MdRange(tag.start, shut.end);
    final style = switch (name) {
      'b' || 'strong' => MdMark.bold,
      'i' || 'em' => MdMark.italic,
      _ => 0,
    };
    if (name == 'a') {
      final href = RegExp(
        r'''\bhref\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))''',
        caseSensitive: false,
      ).firstMatch(open[0]!);
      final url = href?[2] ?? href?[3] ?? href?[4];
      if (url != null) {
        links.add(MdLinkSpan(inner, MdLink(url), all: all));
        mark(inner.start, inner.end, MdMark.link);
      }
    }
    mark(inner.start, inner.end, style);
    mark(tag.start, tag.end, MdMark.dim | style);
    mark(shut.start, shut.end, MdMark.dim | style);
    hides.add(MdHide(tag, all));
    hides.add(MdHide(shut, all));
    _span(inner.start, inner.end, bits | style);
    return all.end;
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
