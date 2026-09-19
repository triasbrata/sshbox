import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:xterm2/core.dart';

import '../files/file_browser.dart';
import 'tmux.dart';

/// A pane's record: everything a pane of the app's tmux sessions writes,
/// piped by tmux itself into a file on the host with `pipe-pane`, so what
/// `clear`, a redraw or the scrollback cap takes from the pane — and what
/// happened while the phone was locked — is still there to read.
///
/// tmux runs the pipe, not the app: once a pane has one it records whether
/// or not anything is attached, and hooks on the app's own session give each
/// pane split or opened later its own, again with nobody attached. Nothing
/// is set on the server as a whole; the user's other sessions are theirs.
///
/// A pane's record is two files in [dir]: `<server pid>-%<pane>`, being
/// written, and the same name with `.1`, the one before it. The server's pid
/// keeps a pane from reusing an earlier server's record of the same number.
abstract final class PaneRecord {
  /// Where a session's records are kept, from the login home.
  static String dir(String session) => '.local/state/jeansh/records/$session';

  /// The hooks that give a pane made later a pipe of its own.
  static const hooks = ['after-split-window', 'after-new-window'];

  // ponytail: 8 MB a file, two files a pane, so 16 MB a pane at most — 32 MB
  // where sh counts `ulimit -f` in KB rather than 512-byte blocks. Up to one
  // pipe read, a few hundred bytes as a rule, is lost at each turn from one
  // file to the next, the write that crossed the limit having failed. A
  // rolling cap with no loss wants a program on the host; sh and tmux are
  // all this has.
  static const _blocks = 16384;

  /// What tmux runs as a pane's pipe, quoted as a tmux argument: `#{pid}`
  /// and `#{pane_id}` are left for `pipe-pane` to fill in.
  ///
  /// Written under umask 077, so the directories come out 0700 and the files
  /// 0600. None of the app's own directories may be a link, and a file is
  /// only ever made new (`set -C`, an exclusive create), so nothing is
  /// written through a link planted in the way. When the file reaches its
  /// size, `ulimit -f` stops `cat`, the file becomes `.1`, and a new one
  /// starts; `cat` ending by itself means the pane or the pipe has, and so
  /// does this. Any other failure — a full disk — stops recording rather
  /// than spinning.
  ///
  /// No `%` and no `#` of its own: `pipe-pane` reads the command as a
  /// strftime format and a tmux format both.
  static String pipe(String session, {int blocks = _blocks}) => quote(
    r'umask 077; trap "" XFSZ; d=$HOME/.local/state; mkdir -p "$d" || exit; '
    'for c in jeansh records $session; do '
    r'd=$d/$c; [ -L "$d" ] && exit; [ -d "$d" ] || mkdir "$d" || exit; done; '
    r'f=$d/#{pid}-#{pane_id}; while :; do '
    r'if [ -e "$f" ]; then mv -f "$f" "$f.1" || exit; fi; '
    '(set -C && ulimit -f $blocks && exec cat > "\$f") && exit; '
    '[ \$(wc -c < "\$f") -ge ${blocks * 512} ] || exit; done',
  );

  /// [text] as one tmux argument in double quotes, where tmux itself would
  /// otherwise read `$` as one of its own variables.
  static String quote(String text) =>
      '"${text.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll(r'$', r'\$')}"';

  /// What the attach script runs before tmux, to prune records by age: a
  /// record untouched for a week whose pane is gone. A pane still there
  /// keeps its record however quiet it has been, since its pipe still has
  /// the file open. Needs `$t`, the tmux the script found.
  static const prune =
      r'r=$HOME/.local/state/jeansh/records; '
      r'if [ -d "$r" ] && [ ! -L "$r" ]; then '
      r'l=" $("$t" list-panes -a -F "#{pid}-#{pane_id}" 2>/dev/null '
      r'| tr "\n" " ")"; '
      r'find "$r" -type f -mtime +7 2>/dev/null | while IFS= read -r f; do '
      r'b=${f##*/}; case "$l" in *" ${b%.1} "*) ;; *) rm -f "$f";; esac; '
      r'done; for s in "$r"/*; do rmdir "$s" 2>/dev/null; done; fi; ';
}

/// A pane's record on the host, read from its end a page at a time through
/// the session's own file browser: a record can be 16 MB, and what is
/// wanted is nearly always the end of it.
class PaneRecordReader {
  PaneRecordReader(
    this._browser, {
    required this.session,
    required this.name,
    this.page = 512 * 1024,
  });

  final FileBrowser _browser;

  /// The tmux session, whose [PaneRecord.dir] holds the record.
  final String session;

  /// The record's name, from `TmuxSession.recordName`.
  final String name;

  // ponytail: 512 KB a page — some 7,000 lines of a build log, about a third
  // of a second to replay on a desktop — and each page back replayed on its
  // own, so a program's screen across a page's edge is seen twice.
  final int page;

  late String _dir;

  /// The size of the record's earlier file, where the one being written
  /// takes over: the record is read as the two end to end.
  var _older = 0;

  /// Where what has been read so far begins in the record. 0 once it is all.
  int start = 0;

  /// The record's last page, read afresh. null when the pane has no record.
  Future<Uint8List?> tail() async {
    _dir = RemotePath.join(
      await _browser.resolveHome(),
      PaneRecord.dir(session),
    );
    final List<RemoteEntry> entries;
    try {
      entries = await _browser.list(_dir);
    } on FileBrowserException catch (error) {
      if (error.fault == FileBrowserFault.notFound) return null;
      rethrow;
    }
    // Links are not followed: no record is one.
    int? size(String file) => entries
        .where((e) => e.name == file && e.kind == RemoteEntryKind.file)
        .firstOrNull
        ?.size;
    final older = size('$name.1');
    final current = size(name);
    if (older == null && current == null) return null;
    _older = older ?? 0;
    final end = _older + (current ?? 0);
    return _read(math.max(0, end - page), end);
  }

  /// The page before what has been read so far. Call only while [start] is
  /// past 0.
  Future<Uint8List> earlier() => _read(math.max(0, start - page), start);

  Future<Uint8List> _read(int from, int to) async {
    final temp = Directory.systemTemp.createTempSync('record');
    try {
      final bytes = BytesBuilder(copy: false);
      Future<void> part(String file, int offset, int length) async {
        if (length <= 0) return;
        final copy = '${temp.path}/${bytes.length}';
        await _browser.download(
          RemotePath.join(_dir, file),
          copy,
          offset: offset,
          length: length,
        );
        bytes.add(File(copy).readAsBytesSync());
      }

      await part('$name.1', from, math.min(to, _older) - from);
      await part(name, math.max(from - _older, 0), to - math.max(from, _older));
      var read = bytes.takeBytes();
      if (from > 0) {
        // Part way through the record is part way through a line, perhaps
        // through an escape sequence or a character: from the next line, or
        // the next escape sequence if that comes first.
        var skip = read.indexOf(0x0a) + 1;
        final escape = read.indexOf(0x1b);
        if (escape >= 0 && (skip == 0 || escape < skip)) skip = escape;
        read = Uint8List.sublistView(read, skip);
        from += skip;
      }
      start = from;
      return read;
    } finally {
      temp.deleteSync(recursive: true);
    }
  }
}

/// What a person would have read in [bytes], a pane's output as the pane
/// wrote it, as lines of text, oldest first.
///
/// The bytes are replayed into a terminal of the pane's size, [columns] by
/// [rows], and every line that leaves its top is kept. What would take text
/// away is made to keep it instead: a clear scrolls the screen up rather
/// than wiping it, the scrollback is never erased, and a full-screen program
/// draws where the rest does — the screen before it scrolls up when it
/// starts, and its last screen when it ends, as does a screen it clears. What
/// such a program shows in between, it only ever showed.
List<String> renderRecord(
  Uint8List bytes, {
  required int columns,
  required int rows,
}) {
  final replay = _Replay(math.max(columns, 2), math.max(rows, 2));
  final sink = const Utf8Decoder(allowMalformed: true)
      .startChunkedConversion(PaneSink(replay.feed));
  for (var at = 0; at < bytes.length; at += _piece) {
    sink.add(
      Uint8List.sublistView(bytes, at, math.min(at + _piece, bytes.length)),
    );
  }
  sink.close();
  return replay.finish();
}

/// Fed a piece at a time, so the lines a piece pushes up fit in the
/// terminal until they are taken.
const _piece = 4096;

/// A terminal that keeps everything, for [renderRecord].
class _Replay extends Terminal {
  _Replay(int columns, int rows) : super(maxLines: _piece * 4) {
    resize(columns, rows);
  }

  /// Each line kept, and whether it carries on the one before it.
  final _kept = <(String, bool)>[];

  /// Whether a full-screen program's screen is up — drawn here on the one
  /// screen there is.
  var _fullScreen = false;

  /// The cursor put back by leaving a full screen, to be skipped: it would
  /// land in the middle of the screen just scrolled up.
  var _skipRestore = false;

  void feed(String text) {
    _skipRestore = false;
    write(text);
    _keep(buffer.scrollBack);
  }

  List<String> finish() {
    _keep(buffer.scrollBack);
    var last = buffer.viewHeight - 1;
    while (last >= 0 && _text(buffer.lines[last]).trim().isEmpty) {
      last--;
    }
    _keep(last + 1);
    final lines = <String>[];
    for (final (text, continues) in _kept) {
      if (continues && lines.isNotEmpty) {
        lines.last += text;
      } else {
        lines.add(text);
      }
    }
    return [for (final line in lines) line.trimRight()];
  }

  /// Takes the first [count] lines out of the terminal.
  void _keep(int count) {
    final lines = buffer.lines;
    for (var i = 0; i < count; i++) {
      _kept.add((_text(lines[i]), lines[i].isWrapped));
    }
    lines.trimStart(count);
  }

  /// A line as it looked: a cell nothing was written to is a space, where
  /// [BufferLine.getText] leaves it out.
  static String _text(BufferLine line) {
    final text = StringBuffer();
    var run = 0;
    for (var i = 0; i < line.length; i++) {
      if (line.getCodePoint(i) != 0 || (i > 0 && line.getWidth(i - 1) == 2)) {
        continue;
      }
      text
        ..write(line.getText(run, i))
        ..write(' ');
      run = i + 1;
    }
    text.write(line.getText(run, line.length));
    return text.toString();
  }

  /// Scrolls what is on screen up into what is kept, and clears it.
  void _scrollAway() {
    buffer.scrollClear();
    buffer.eraseDisplay();
  }

  @override
  void eraseDisplay() {
    buffer.scrollClear();
    super.eraseDisplay();
  }

  /// `clear` in a tmux pane is `ESC[H ESC[J`: erasing below from the top.
  @override
  void eraseDisplayBelow() {
    if (buffer.cursorX == 0 && buffer.cursorY == 0) buffer.scrollClear();
    super.eraseDisplayBelow();
  }

  @override
  void eraseScrollbackOnly() {}

  @override
  void reset() {
    buffer.scrollClear();
    _keep(buffer.scrollBack);
    _fullScreen = false;
    super.reset();
  }

  @override
  void clearAltBuffer() {}

  @override
  void useAltBuffer() {
    if (_fullScreen) return;
    _fullScreen = true;
    _scrollAway();
  }

  @override
  void useMainBuffer() {
    if (!_fullScreen) return;
    _fullScreen = false;
    _scrollAway();
    buffer.setCursor(0, 0);
    _skipRestore = true;
  }

  @override
  void restoreCursor() {
    if (_skipRestore) {
      _skipRestore = false;
      return;
    }
    super.restoreCursor();
  }
}
