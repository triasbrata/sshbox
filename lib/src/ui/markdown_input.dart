import 'package:flutter/material.dart';

/// A text field's controller that draws its Markdown as it is typed, the way
/// Discord's message box does: bold bold, code in the monospace on a panel,
/// a heading larger — and every character still there, its markers dimmed.
///
/// Only the drawing changes. [text] is what was typed, character for
/// character, so the caret, a selection, a paste, undo and what is sent all
/// work on exactly what they did; an IME's composing region keeps its
/// underline on top of whatever style is under it.
class MarkdownEditingController extends TextEditingController {
  MarkdownEditingController({
    required this.mono,
    required this.dim,
    required this.accent,
    required this.panel,
  });

  /// The monospace family code is drawn in, and the colours of a marker, of
  /// a list's bullet and a link, and behind code.
  String mono;
  Color dim;
  Color accent;
  Color panel;

  /// Past this many characters the box is plain text: styling runs at every
  /// keystroke, and a paste this big is not being read as it is typed.
  static const plainPast = 20 * 1024;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (text.length > plainPast || text.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final runs = markdownRuns(text, this);
    final composing = withComposing && value.isComposingRangeValid
        ? value.composing
        : null;
    return TextSpan(
      style: style,
      children: [
        for (final (start, end, runStyle) in _split(runs, composing))
          TextSpan(text: text.substring(start, end), style: runStyle),
      ],
    );
  }

  /// [runs] cut at the composing region's two ends, the part inside it
  /// underlined as Flutter underlines it in a plain field.
  static Iterable<(int, int, TextStyle?)> _split(
    List<(int, int, TextStyle?)> runs,
    TextRange? composing,
  ) sync* {
    for (final (start, end, style) in runs) {
      if (composing == null ||
          composing.end <= start ||
          composing.start >= end) {
        yield (start, end, style);
        continue;
      }
      final from = composing.start.clamp(start, end);
      final to = composing.end.clamp(start, end);
      if (from > start) yield (start, from, style);
      yield (
        from,
        to,
        (style ?? const TextStyle()).merge(
          const TextStyle(decoration: TextDecoration.underline),
        ),
      );
      if (to < end) yield (to, end, style);
    }
  }
}

final _fence = RegExp(r'^ {0,3}(`{3,}|~{3,})');
final _heading = RegExp(r'^ {0,3}(#{1,6})( +|$)');
final _quote = RegExp(r'^ {0,3}(>+ ?)');
final _bullet = RegExp(r'^( *)([-*+]|\d{1,9}[.)]) +');

/// Inline Markdown, earliest match first: code spans before anything, since
/// nothing inside one is Markdown; then links, bold, strike and italic. An
/// opener must be followed, and a closer preceded, by something not a space,
/// and `_` must not sit inside a word, so `2 * 3 * 4` and `snake_case` read
/// as written, as CommonMark reads them.
final _inline = RegExp(
  r'(`+)(.+?)\1' // 1, 2: code
  r'|\[([^\]\n]+)\]\(([^)\s]*)\)' // 3, 4: link
  r'|(\*\*|__)(?=\S)(.+?)(?<=\S)\5' // 5, 6: bold
  r'|~~(?=\S)(.+?)(?<=\S)~~' // 7: strike
  r'|\*(?=[^\s*])(.+?)(?<=[^\s*])\*' // 8: italic
  r'|(?<![\w_])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![\w_])', // 9: italic
);

/// [text] as runs of (start, end, style) that cover it end to end, in order.
@visibleForTesting
List<(int, int, TextStyle?)> markdownRuns(
  String text,
  MarkdownEditingController c,
) {
  final runs = <(int, int, TextStyle?)>[];
  final marker = TextStyle(color: c.dim);
  final code = TextStyle(fontFamily: c.mono, backgroundColor: c.panel);
  void add(int start, int end, TextStyle? style) {
    if (end > start) runs.add((start, end, style));
  }

  String? fence;
  var at = 0;
  for (final line in text.split('\n')) {
    final end = at + line.length;
    final open = _fence.firstMatch(line);
    if (fence != null) {
      // Inside a fenced block, every line is code; a fence like the one that
      // opened it closes it.
      final closes =
          open != null &&
          open[1]![0] == fence[0] &&
          open[1]!.length >= fence.length &&
          line.substring(open.end).trim().isEmpty;
      add(at, end, closes ? code.merge(marker) : code);
      if (closes) fence = null;
    } else if (open != null) {
      fence = open[1];
      add(at, end, code.merge(marker));
    } else {
      _line(line, at, c, marker, code, add);
    }
    // The line break belongs to no style.
    if (end < text.length) add(end, end + 1, null);
    at = end + 1;
  }
  return runs;
}

void _line(
  String line,
  int at,
  MarkdownEditingController c,
  TextStyle marker,
  TextStyle code,
  void Function(int, int, TextStyle?) add,
) {
  TextStyle? base;
  var from = 0;
  if (_heading.firstMatch(line) case final m?) {
    add(at, at + m.end, marker);
    from = m.end;
    base = const TextStyle(fontWeight: FontWeight.bold);
  } else if (_quote.firstMatch(line) case final m?) {
    add(at, at + m.end, marker);
    from = m.end;
    base = TextStyle(color: c.dim, fontStyle: FontStyle.italic);
  } else if (_bullet.firstMatch(line) case final m?) {
    final indent = m[1]!.length;
    add(at, at + indent, null);
    add(at + indent, at + m.end, TextStyle(color: c.accent));
    from = m.end;
  }
  _spans(line, from, line.length, at, base, c, marker, code, add);
}

/// The inline Markdown in [line] between [from] and [to], over [base]; bold,
/// strike and italic style what they hold, and what they hold may hold more.
void _spans(
  String line,
  int from,
  int to,
  int at,
  TextStyle? base,
  MarkdownEditingController c,
  TextStyle marker,
  TextStyle code,
  void Function(int, int, TextStyle?) add,
) {
  TextStyle over(TextStyle style) => (base ?? const TextStyle()).merge(style);
  var i = from;
  for (final m in _inline.allMatches(line.substring(0, to), from)) {
    add(at + i, at + m.start, base);
    final s = at + m.start;
    final e = at + m.end;
    if (m[1] != null) {
      final n = m[1]!.length;
      add(s, s + n, over(code).merge(marker));
      add(s + n, e - n, over(code));
      add(e - n, e, over(code).merge(marker));
    } else if (m[3] != null) {
      // Drawn as a link and not tappable: it is being typed, not read.
      final label = s + 1 + m[3]!.length;
      add(s, s + 1, over(marker));
      add(
        s + 1,
        label,
        over(
          TextStyle(
            color: c.accent,
            decoration: TextDecoration.underline,
            decorationColor: c.accent,
          ),
        ),
      );
      add(label, e, over(marker));
    } else {
      final (n, style) = m[5] != null
          ? (2, const TextStyle(fontWeight: FontWeight.bold))
          : m[7] != null
          ? (2, const TextStyle(decoration: TextDecoration.lineThrough))
          : (1, const TextStyle(fontStyle: FontStyle.italic));
      add(s, s + n, over(marker));
      _spans(
        line,
        m.start + n,
        m.end - n,
        at,
        over(style),
        c,
        marker,
        code,
        add,
      );
      add(e - n, e, over(marker));
    }
    i = m.end;
  }
  add(at + i, at + to, base);
}
