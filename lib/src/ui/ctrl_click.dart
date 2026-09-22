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

/// The text a selection covers, as every copy out of a terminal takes it:
/// the selection menu's Copy and the keyboard's copy shortcut.
///
/// xterm2's own `Buffer.getText` leaves out every cell nothing was written
/// to, and a program drawing a screen — Claude Code's renderer, most TUIs —
/// moves the cursor over a gap (`CSI n C`) instead of writing spaces
/// into it, so `git push origin` drawn that way copied as `gitpushorigin`.
/// Here a blank cell before the last written one on a line is a space, as in
/// any other terminal; blanks after it are left out rather than padded, so a
/// wide character wrapped past a line's last column does not gain a space.
/// Otherwise it is `getText(range, true)` exactly: rows joined with a
/// newline unless one wrapped onto the next, a block selection's always, and
/// the spaces and tabs ending each line trimmed.
String selectedText(Buffer buffer, BufferRange range) {
  range = range.normalized;
  final lines = <StringBuffer>[];
  for (final segment in range.toSegments()) {
    if (segment.line < 0 || segment.line >= buffer.height) continue;
    final line = buffer.lines[segment.line];
    final joined = range is! BufferRangeBlock && line.isWrapped;
    if (lines.isEmpty ||
        !(segment.line == range.begin.y || segment.line == 0 || joined)) {
      lines.add(StringBuffer());
    }

    // The right half of a wide character is blank too, but its left half
    // wrote it, so it counts as written.
    bool written(int x) =>
        line.getCodePoint(x) != 0 || (x > 0 && line.getWidth(x - 1) == 2);
    final from = (segment.start ?? 0).clamp(0, line.length);
    var last = (segment.end ?? line.length).clamp(0, line.length) - 1;
    while (last >= from && !written(last)) {
      last--;
    }
    // Runs of written cells through getText, which keeps combining marks and
    // a wide character cut by either end, and a space for each gap cell —
    // but for the gap a tab leaves, which xterm2 marks with the tab itself in
    // its first cell and which copies as that one tab, as it always has.
    var run = from;
    var tab = false;
    for (var x = from; x <= last; x++) {
      if (written(x)) {
        tab = line.getCodePoint(x) == 0x09;
        continue;
      }
      lines.last.write(line.getText(run, x));
      if (!tab) lines.last.write(' ');
      run = x + 1;
    }
    if (run <= last) lines.last.write(line.getText(run, last + 1));
  }
  final trailing = RegExp(r'[ \t]+$');
  return lines.map((line) => '$line'.replaceFirst(trailing, '')).join('\n');
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

/// What a Ctrl+tap on an OSC 8 hyperlink opens, given the address the
/// program wrote for it: the link a program draws as `COR-6025` or `the docs`
/// with its address hidden, as Claude Code does once it believes the terminal
/// can show one.
///
/// A `file:` address is a path on the host — `ls --hyperlink`, gcc and Claude
/// Code all write one for a file they name — and opens there, as the same
/// path written out would, whatever host the address names: this app can
/// reach no other. Anything else is a URL, for `openUrl` to allow or refuse,
/// since the program chose it and the label says nothing about it.
LinkCandidate hyperlinkTarget(String address) {
  final url = Uri.tryParse(address);
  final path = url != null && url.isScheme('file') && url.path.startsWith('/')
      ? Uri.decodeFull(url.path)
      : null;
  return (
    kind: path != null ? LinkKind.path : LinkKind.url,
    target: path ?? address,
    line: null,
    start: 0,
    end: 0,
  );
}

/// The address of the OSC 8 hyperlink a selection starts or ends on, for the
/// selection menu's Copy link address: a long press on a link's label
/// selects a word of it, so that word's first cell carries the link, and a
/// selection dragged out to a link ends on it.
///
/// ponytail: only the two ends are looked at, so a link wholly inside a
/// longer selection is not offered; a scan of every cell selected would find
/// it, at the cost of walking the whole scrollback under Select all.
String? hyperlinkIn(Terminal terminal, BufferRange range) {
  final ends = range.normalized;
  return terminal.hyperlinkAt(ends.begin) ??
      terminal.hyperlinkAt(CellOffset(ends.end.x - 1, ends.end.y));
}

/// Underlines every URL, path and OSC 8 hyperlink on buffer rows [from] to
/// [to], and hands the underlines back to be disposed when they are no longer
/// wanted.
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
  // A hyperlink is a run of cells carrying one id, on each row it covers:
  // its label shows nothing of its address, so without the underline it
  // looks like any other word.
  for (var y = from; y <= to && y < buffer.lines.length; y++) {
    final line = buffer.lines[y];
    var x = 0;
    while (x < line.length) {
      final id = line.getHyperlinkId(x);
      final start = x++;
      if (id == 0) continue;
      while (x < line.length && line.getHyperlinkId(x) == id) {
        x++;
      }
      underlines.add(
        controller.underline(
          p1: buffer.createAnchor(start, y),
          p2: buffer.createAnchor(x, y),
          color: color,
        ),
      );
    }
  }
  return underlines;
}
