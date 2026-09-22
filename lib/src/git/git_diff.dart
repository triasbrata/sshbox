import 'dart:convert';
import 'dart:typed_data';

/// A diff open in a tab of its own.
///
/// What `git diff` or `git show` printed is not a file on the host, so the tab
/// cannot read it over SFTP: it holds the command instead and runs it again
/// whenever the tab asks, which is what Reload from host does here.
class GitDiff {
  const GitDiff({
    required this.key,
    required this.title,
    required this.subtitle,
    required this.read,
    this.blob,
  });

  /// Identifies the tab: the repository and what is being diffed. The same
  /// diff asked for twice goes back to the tab already open, while a file's
  /// staged and unstaged diffs are two of them.
  final String key;

  /// What the tab and the page's header say it is.
  final String title;

  /// The line under the title: where the file is, or what the commit did.
  final String subtitle;

  /// Runs the git command again and gives back what it printed.
  final Future<String> Function() read;

  /// Reads one blob of the repository by the id a diff's `index` line gives
  /// it, which is how the lines around a hunk are shown: see
  /// [DiffFile.oldBlob]. Null where there is no repository to ask, and then
  /// a hunk shows only the context git printed.
  final Future<String> Function(String id)? blob;
}

/// What a line of a hunk is.
enum DiffLineKind { context, added, removed }

/// One line of a hunk, with its number in the old file, the new one, or both.
class DiffLine {
  DiffLine(this.kind, this.text, {this.oldNo, this.newNo});

  final DiffLineKind kind;

  /// The line itself, without the sign git put in front of it.
  final String text;

  final int? oldNo;
  final int? newNo;

  /// Git said `\ No newline at end of file` after this line.
  bool noNewline = false;
}

/// One `@@` section of a file's diff.
class DiffHunk {
  DiffHunk({
    required this.header,
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
  });

  /// The `@@ -60,7 +60,9 @@ class MainActivity …` line as git printed it,
  /// the function it is in included.
  final String header;

  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;

  final lines = <DiffLine>[];

  /// The first old line at or after the hunk. A hunk that removes nothing
  /// names the line *before* where it goes — `-0,0` is the top of the file —
  /// so its first line is one further on.
  int get oldFrom => oldCount == 0 ? oldStart + 1 : oldStart;

  /// The first old line after the hunk.
  int get oldEnd => oldFrom + oldCount;

  int get newFrom => newCount == 0 ? newStart + 1 : newStart;
  int get newEnd => newFrom + newCount;
}

/// One file's part of a diff.
class DiffFile {
  /// Where the file was, and where it is: null for the side a new or a
  /// deleted file does not have.
  String? oldPath;
  String? newPath;

  bool isNew = false;
  bool isDeleted = false;

  /// Moved, or copied, from [oldPath]: git names both.
  bool renamed = false;
  bool copied = false;

  String? oldMode;
  String? newMode;

  /// "Binary files a/x and b/x differ": there are no lines to show.
  bool binary = false;

  /// A merge's combined diff, `diff --cc`, whose lines have a column per
  /// parent and so no one old side to set beside the new one. Shown as git
  /// printed it, in [raw].
  bool combined = false;

  /// The id of the old side's blob, from the `index` line. The lines between
  /// and around the hunks are the same on both sides, so this one blob is all
  /// that showing more of them needs, and it is always in the repository —
  /// the index for an unstaged diff, HEAD for a staged one, the parent for a
  /// commit — where the new side of an unstaged diff is only a file in the
  /// working tree.
  String? oldBlob;

  final hunks = <DiffHunk>[];

  /// This file's part of the diff, exactly as git printed it.
  String raw = '';

  String get path => newPath ?? oldPath ?? '';

  int get added => _count(DiffLineKind.added);
  int get removed => _count(DiffLineKind.removed);

  int _count(DiffLineKind kind) => hunks.fold(
    0,
    (sum, hunk) => sum + hunk.lines.where((line) => line.kind == kind).length,
  );

  /// Whether there is an old version to read more lines from: a new file has
  /// none, and a deleted one is shown whole already.
  bool get expandable =>
      !binary &&
      !combined &&
      !isNew &&
      !isDeleted &&
      hunks.isNotEmpty &&
      (oldBlob?.replaceAll('0', '').isNotEmpty ?? false);
}

/// A diff as git printed it, read into files, hunks and lines.
class ParsedDiff {
  const ParsedDiff({required this.preamble, required this.files});

  /// Whatever came before the first file: a commit's subject and author and
  /// its `--stat`. Empty for a plain `git diff`.
  final String preamble;

  final List<DiffFile> files;
}

final _hunkHeader = RegExp(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@');
final _index = RegExp(r'^index ([0-9a-f]+)\.\.[0-9a-f]+');

bool _startsFile(String line) =>
    line.startsWith('diff --git ') ||
    line.startsWith('diff --cc ') ||
    line.startsWith('diff --combined ');

/// Reads what `git diff`, `git show` or `git diff --no-index` printed.
///
/// Every hunk is read by the counts in its header rather than by what its
/// lines look like, so a line of a file that happens to start `diff --git`
/// or `@@` is still a line of that file. Nothing it cannot place is thrown
/// away: text before the first file is the [ParsedDiff.preamble], and a file
/// it cannot draw side by side keeps its [DiffFile.raw] lines.
ParsedDiff parseDiff(String text) {
  // Carriage returns go: a file with CRLF endings is still the same lines.
  final lines = [
    for (final line in text.split('\n'))
      line.endsWith('\r') ? line.substring(0, line.length - 1) : line,
  ];
  var i = 0;
  final preamble = <String>[];
  while (i < lines.length && !_startsFile(lines[i])) {
    preamble.add(lines[i++]);
  }

  final files = <DiffFile>[];
  while (i < lines.length) {
    final start = i;
    final file = DiffFile();
    final header = lines[i++];
    if (!header.startsWith('diff --git ')) {
      file
        ..combined = true
        ..newPath = _unquote(header.substring(header.indexOf(' ', 5) + 1));
      while (i < lines.length && !_startsFile(lines[i])) {
        i++;
      }
      file.raw = lines.sublist(start, i).join('\n');
      files.add(file);
      continue;
    }
    _pathsFromHeader(file, header.substring('diff --git '.length));

    // The extended header: modes, renames, the blob ids, and the two names.
    while (i < lines.length) {
      final line = lines[i];
      if (_startsFile(line) || line.startsWith('@@')) break;
      i++;
      if (line.startsWith('--- ')) {
        file.oldPath = _side(line.substring(4));
      } else if (line.startsWith('+++ ')) {
        file.newPath = _side(line.substring(4));
      } else if (line.startsWith('new file mode ')) {
        file
          ..isNew = true
          ..oldPath = null
          ..newMode = line.substring('new file mode '.length);
      } else if (line.startsWith('deleted file mode ')) {
        file
          ..isDeleted = true
          ..newPath = null
          ..oldMode = line.substring('deleted file mode '.length);
      } else if (line.startsWith('old mode ')) {
        file.oldMode = line.substring('old mode '.length);
      } else if (line.startsWith('new mode ')) {
        file.newMode = line.substring('new mode '.length);
      } else if (line.startsWith('rename from ')) {
        file
          ..renamed = true
          ..oldPath = _unquote(line.substring('rename from '.length));
      } else if (line.startsWith('rename to ')) {
        file.newPath = _unquote(line.substring('rename to '.length));
      } else if (line.startsWith('copy from ')) {
        file
          ..copied = true
          ..oldPath = _unquote(line.substring('copy from '.length));
      } else if (line.startsWith('copy to ')) {
        file.newPath = _unquote(line.substring('copy to '.length));
      } else if (_index.firstMatch(line) case final match?) {
        file.oldBlob = match.group(1);
      } else if (line.startsWith('Binary files ') ||
          line == 'GIT binary patch') {
        file.binary = true;
      }
    }

    while (i < lines.length && !_startsFile(lines[i])) {
      final match = _hunkHeader.firstMatch(lines[i]);
      if (match == null || file.binary) {
        i++;
        continue;
      }
      final hunk = DiffHunk(
        header: lines[i++],
        oldStart: int.parse(match.group(1)!),
        oldCount: int.tryParse(match.group(2) ?? '') ?? 1,
        newStart: int.parse(match.group(3)!),
        newCount: int.tryParse(match.group(4) ?? '') ?? 1,
      );
      var oldLeft = hunk.oldCount;
      var newLeft = hunk.newCount;
      var oldNo = hunk.oldFrom;
      var newNo = hunk.newFrom;
      while (i < lines.length &&
          (oldLeft > 0 || newLeft > 0 || lines[i].startsWith(r'\'))) {
        final line = lines[i++];
        final sign = line.isEmpty ? ' ' : line[0];
        final body = line.isEmpty ? '' : line.substring(1);
        if (sign == r'\') {
          hunk.lines.lastOrNull?.noNewline = true;
        } else if (sign == '+' && newLeft > 0) {
          hunk.lines.add(DiffLine(DiffLineKind.added, body, newNo: newNo++));
          newLeft--;
        } else if (sign == '-' && oldLeft > 0) {
          hunk.lines.add(DiffLine(DiffLineKind.removed, body, oldNo: oldNo++));
          oldLeft--;
        } else if (sign == ' ' && oldLeft > 0 && newLeft > 0) {
          hunk.lines.add(
            DiffLine(
              DiffLineKind.context,
              body,
              oldNo: oldNo++,
              newNo: newNo++,
            ),
          );
          oldLeft--;
          newLeft--;
        } else if (hunk.lines.lastOrNull case final last?) {
          // A line the counts do not expect: what splitting the output into
          // lines made of a lone carriage return inside one. It is the rest
          // of the line before.
          hunk.lines.last = DiffLine(
            last.kind,
            '${last.text}$line',
            oldNo: last.oldNo,
            newNo: last.newNo,
          )..noNewline = last.noNewline;
        }
      }
      // The output reaches here with its trailing whitespace trimmed, which
      // takes blank context lines at the very end with it. Only those can
      // go, so as many as both sides are still owed are put back.
      if (i >= lines.length && oldLeft == newLeft) {
        for (var n = 0; n < oldLeft; n++) {
          hunk.lines.add(
            DiffLine(DiffLineKind.context, '', oldNo: oldNo++, newNo: newNo++),
          );
        }
      }
      file.hunks.add(hunk);
    }
    file.raw = lines.sublist(start, i).join('\n');
    files.add(file);
  }
  return ParsedDiff(preamble: preamble.join('\n').trim(), files: files);
}

/// One row of a split view: the old line on the left, the new one on the
/// right, and null where that side has nothing to set against the other.
typedef SplitRow = ({DiffLine? left, DiffLine? right});

/// Pairs a hunk's lines the way a split view shows them: a context line on
/// both sides, and a run of removed lines beside the added run that follows
/// it, one to one, the shorter run padded with nulls so what comes after
/// still lines up.
List<SplitRow> splitRows(List<DiffLine> lines) {
  final rows = <SplitRow>[];
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    if (line.kind == DiffLineKind.context) {
      rows.add((left: line, right: line));
      i++;
      continue;
    }
    final removed = <DiffLine>[];
    while (i < lines.length && lines[i].kind == DiffLineKind.removed) {
      removed.add(lines[i++]);
    }
    final added = <DiffLine>[];
    while (i < lines.length && lines[i].kind == DiffLineKind.added) {
      added.add(lines[i++]);
    }
    final count = removed.length > added.length ? removed.length : added.length;
    for (var n = 0; n < count; n++) {
      rows.add((
        left: n < removed.length ? removed[n] : null,
        right: n < added.length ? added[n] : null,
      ));
    }
  }
  return rows;
}

/// `a/lib/main.dart b/lib/main.dart`, for a file with no `---` and `+++`
/// lines to name it — a binary one, or a change of mode alone.
void _pathsFromHeader(DiffFile file, String rest) {
  String a;
  String b;
  if (rest.startsWith('"')) {
    final (value, end) = _readQuoted(rest, 0);
    a = value;
    b = _unquote(rest.substring(end).trimLeft());
  } else {
    // Both halves are the same name when nothing was renamed, which is the
    // only way to tell where the first ends when a name holds a space.
    final half = (rest.length - 1) ~/ 2;
    if (rest.length.isOdd &&
        rest[half] == ' ' &&
        rest.substring(2, half) == rest.substring(half + 3)) {
      a = rest.substring(0, half);
      b = rest.substring(half + 1);
    } else {
      final cut = rest.lastIndexOf(' b/');
      a = cut == -1 ? rest : rest.substring(0, cut);
      b = cut == -1 ? rest : _unquote(rest.substring(cut + 1));
    }
  }
  file
    ..oldPath = _strip(a)
    ..newPath = _strip(b);
}

/// The name on a `---` or `+++` line, or null for `/dev/null`. Git ends the
/// line with a tab when the name holds a space.
String? _side(String value) {
  final name = value.endsWith('\t')
      ? value.substring(0, value.length - 1)
      : value;
  if (name == '/dev/null') return null;
  return _strip(_unquote(name));
}

/// Takes off the `a/` or `b/` git puts in front of every name.
String _strip(String name) =>
    name.startsWith('a/') || name.startsWith('b/') ? name.substring(2) : name;

/// A name as git writes one that holds a quote, a backslash, a control
/// character or anything past ASCII: in double quotes, C-escaped, with each
/// byte of UTF-8 as three octal digits.
String _unquote(String value) =>
    value.startsWith('"') ? _readQuoted(value, 0).$1 : value;

(String, int) _readQuoted(String s, int from) {
  final out = BytesBuilder();
  const escapes = {
    'a': 7,
    'b': 8,
    't': 9,
    'n': 10,
    'v': 11,
    'f': 12,
    'r': 13,
    '"': 34,
    r'\': 92,
  };
  var i = from + 1;
  while (i < s.length && s[i] != '"') {
    if (s[i] == r'\' && i + 1 < s.length) {
      var end = i + 1;
      while (end < s.length && end < i + 4 && '01234567'.contains(s[end])) {
        end++;
      }
      if (end > i + 1) {
        out.addByte(int.parse(s.substring(i + 1, end), radix: 8) & 0xff);
        i = end;
      } else {
        out.addByte(escapes[s[i + 1]] ?? s.codeUnitAt(i + 1));
        i += 2;
      }
    } else {
      // One code unit, or two where it is half of a pair.
      final end = (s.codeUnitAt(i) & 0xFC00) == 0xD800 && i + 1 < s.length
          ? i + 2
          : i + 1;
      out.add(utf8.encode(s.substring(i, end)));
      i = end;
    }
  }
  return (utf8.decode(out.takeBytes(), allowMalformed: true), i + 1);
}
