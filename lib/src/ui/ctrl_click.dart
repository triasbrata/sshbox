import 'dart:ui' show Color;

import 'package:xterm2/xterm.dart';

/// What a Ctrl+tap on the terminal can open.
///
/// A [name] is a lone `name.ext`, which could as easily be a word that
/// happens to hold a dot: it only counts once the host says it exists, so it
/// is never underlined and a miss on it says nothing.
enum LinkKind { url, path, name }

/// One thing a Ctrl+tap can open, found in a line of terminal text.
///
/// [target] is the URL or path with its dressing taken off — quotes, brackets,
/// the full stop of the sentence it ended — and [line] the line number written
/// after a path, `:12` or `:12:3`. [start] and [end] are UTF-16 offsets of what
/// it covers in the text, line number included: what is underlined, and what a
/// tap has to land on.
typedef LinkCandidate = ({
  LinkKind kind,
  String target,
  int? line,
  int start,
  int end,
});

final _word = RegExp(r'\S+');
final _url = RegExp(r'https?://');

/// A path's `:line` or `:line:col`, and whatever grep writes after it when the
/// matched text starts at its first column: `lib/a.dart:3:import …`.
final _lineSuffix = RegExp(r'^(.+?):(\d+)(:\d+)?(:\S*)?$');

/// A word with a dot and a letter after it: `README.md`, `.bashrc`. Not
/// `3.14` or `v1.2.3`, which a Ctrl+tap has no business sending to the host.
final _name = RegExp(r'^[\w.-]*\.[A-Za-z]\w*$');

const _opening = '"\'`([{<';
const _closing = '"\'`)]}>.,;:!?';

/// Every URL and path in [text], left to right.
///
/// Words are split on whitespace, so a path with a space in it is not found:
/// quoting does not help, a terminal shows the quotes and the words the same.
List<LinkCandidate> findLinks(String text) => [
  for (final word in _word.allMatches(text))
    ?_candidate(word.group(0)!, word.start),
];

LinkCandidate? _candidate(String word, int at) {
  final url = _url.firstMatch(word);
  var start = url?.start ?? 0;
  var end = word.length;
  while (start < end && _opening.contains(word[start])) {
    start++;
  }
  while (end > start && _closing.contains(word[end - 1])) {
    end--;
  }
  if (start == end) return null;
  final text = word.substring(start, end);

  if (url != null) {
    return (
      kind: LinkKind.url,
      target: text,
      line: null,
      start: at + start,
      end: at + end,
    );
  }

  final suffix = _lineSuffix.firstMatch(text);
  final target = suffix?.group(1) ?? text;
  final LinkKind kind;
  if (target.contains('/')) {
    // `//` is a comment marker and `ssh://` a scheme this does not open;
    // neither is somewhere on the host.
    if (target.contains('://') || !target.contains(RegExp('[^/]'))) {
      return null;
    }
    kind = LinkKind.path;
  } else if (_name.hasMatch(target)) {
    kind = LinkKind.name;
  } else {
    return null;
  }

  return (
    kind: kind,
    target: target,
    line: suffix == null ? null : int.parse(suffix.group(2)!),
    start: at + start,
    // Up to the line and column, leaving whatever grep printed after them.
    end: at + start + text.length - (suffix?.group(4)?.length ?? 0),
  );
}

/// The logical line holding buffer row [row] — the rows the terminal wrapped
/// it onto, joined back up — as text, with the cell each UTF-16 unit of that
/// text came from.
///
/// Built cell by cell rather than with xterm2's `getText`, which drops the
/// blank cells a program skips over with the cursor and would glue the words
/// either side of them together.
({String text, List<CellOffset> cells}) logicalLine(Buffer buffer, int row) {
  final lines = buffer.lines;
  var y = row;
  while (y > 0 && lines[y].isWrapped) {
    y--;
  }

  final text = StringBuffer();
  final cells = <CellOffset>[];
  do {
    final line = lines[y];
    for (var x = 0; x < line.length; x++) {
      // The right half of a wide character, already written by its left.
      if (x > 0 && line.getWidth(x) == 0 && line.getWidth(x - 1) == 2) continue;
      final code = line.getCodePoint(x);
      final char = code == 0 ? ' ' : String.fromCharCode(code);
      text.write(char);
      for (var i = 0; i < char.length; i++) {
        cells.add(CellOffset(x, y));
      }
    }
    y++;
  } while (y < lines.length && lines[y].isWrapped);

  return (text: text.toString(), cells: cells);
}

/// The link covering [cell], if any.
LinkCandidate? linkAt(Buffer buffer, CellOffset cell) {
  final line = logicalLine(buffer, cell.y);
  for (final link in findLinks(line.text)) {
    if (!cell.isBefore(line.cells[link.start]) &&
        !cell.isAfter(line.cells[link.end - 1])) {
      return link;
    }
  }
  return null;
}

/// Underlines every URL and path on buffer rows [from] to [to], and hands the
/// underlines back to be disposed when they are no longer wanted.
///
/// Drawn by xterm2 itself, from anchors on the lines, so each one sits under
/// its cells however the view has scrolled.
List<TerminalUnderline> underlineLinks(
  TerminalController controller,
  Buffer buffer, {
  required int from,
  required int to,
  required Color color,
}) {
  final underlines = <TerminalUnderline>[];
  var row = from;
  while (row <= to && row < buffer.lines.length) {
    final line = logicalLine(buffer, row);
    for (final link in findLinks(line.text)) {
      if (link.kind == LinkKind.name) continue;
      final first = line.cells[link.start];
      final last = line.cells[link.end - 1];
      underlines.add(
        controller.underline(
          p1: buffer.createAnchorFromOffset(first),
          p2: buffer.createAnchor(last.x + 1, last.y),
          color: color,
        ),
      );
    }
    row = line.cells.isEmpty ? row + 1 : line.cells.last.y + 1;
  }
  return underlines;
}
