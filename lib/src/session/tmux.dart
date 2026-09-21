import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:xterm2/xterm.dart';

import 'pane_record.dart';
import 'terminal_session.dart';

/// tmux turned a command down, or went away before answering it.
class TmuxException implements Exception {
  const TmuxException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// How tmux has split a window, as a tree of cells.
///
/// tmux sends it as a string: `d67e,80x24,0,0{40x24,0,0,0,39x24,41,0,1}` is a
/// checksum, then the window's size and corner, then `{…}` for children laid
/// side by side or `[…]` for children stacked, down to leaves that end in
/// their pane's number. Every node carries its own absolute position, so a
/// pane can be put on screen straight from its leaf; the tree is only needed
/// for where the dividers go.
class TmuxLayout {
  const TmuxLayout({
    required this.width,
    required this.height,
    required this.x,
    required this.y,
    this.pane,
    this.sideBySide = false,
    this.children = const [],
  });

  final int width;
  final int height;
  final int x;
  final int y;

  /// The N of `%N`, on a leaf. null on a split.
  final int? pane;

  /// On a split, whether [children] sit left to right (`{}`) rather than top
  /// to bottom (`[]`). tmux leaves one cell between each pair for its border.
  final bool sideBySide;

  final List<TmuxLayout> children;

  /// The leaves, left to right and top to bottom.
  Iterable<TmuxLayout> get panes sync* {
    if (pane != null) yield this;
    for (final child in children) {
      yield* child.panes;
    }
  }

  /// Throws [FormatException] on anything tmux would not have written.
  static TmuxLayout parse(String layout) {
    final reader = _LayoutReader(layout);
    // The checksum is tmux's own business: it only checks layouts typed in.
    reader.at = layout.indexOf(',') + 1;
    final root = reader.node();
    if (reader.at != layout.length) {
      throw FormatException('Trailing text in layout', layout, reader.at);
    }
    return root;
  }
}

class _LayoutReader {
  _LayoutReader(this.text);

  final String text;
  var at = 0;

  String? get _next => at < text.length ? text[at] : null;

  int _number() {
    final start = at;
    while (at < text.length && '0123456789'.contains(text[at])) {
      at++;
    }
    if (at == start) throw FormatException('Expected a number', text, at);
    return int.parse(text.substring(start, at));
  }

  void _expect(String char) {
    if (_next != char) throw FormatException('Expected "$char"', text, at);
    at++;
  }

  TmuxLayout node() {
    final width = _number();
    _expect('x');
    final height = _number();
    _expect(',');
    final x = _number();
    _expect(',');
    final y = _number();

    final open = _next;
    if (open != '{' && open != '[') {
      _expect(',');
      return TmuxLayout(
        width: width,
        height: height,
        x: x,
        y: y,
        pane: _number(),
      );
    }
    at++;
    final children = [node()];
    while (_next == ',') {
      at++;
      children.add(node());
    }
    _expect(open == '{' ? '}' : ']');
    return TmuxLayout(
      width: width,
      height: height,
      x: x,
      y: y,
      sideBySide: open == '{',
      children: children,
    );
  }
}

/// Speaks tmux's control mode (`tmux -C`): writes commands, matches each
/// reply to the command that asked for it, and hands on everything else as
/// it arrives.
///
/// Read as bytes, never as decoded text. `%output` carries what a pane wrote,
/// and a UTF-8 character a pane wrote across two reads arrives split over two
/// `%output` lines, with a newline and the next line's header between the
/// halves — decoding the stream whole would turn both into replacement
/// characters. Each pane decodes its own bytes instead.
class TmuxClient {
  TmuxClient({
    required this.write,
    required this.onOutput,
    required this.onNotification,
  });

  final void Function(Uint8List data) write;

  /// A pane's output, already unescaped: the bytes as the pane wrote them.
  final void Function(int pane, Uint8List data) onOutput;

  /// Every other line outside a reply — `%layout-change …`, `%exit` — and
  /// anything that is not tmux at all, which is how a host says it has none.
  final void Function(String line) onNotification;

  /// Waiting for their replies, in the order they were written. tmux answers
  /// in order, and numbers its replies server-wide rather than per client,
  /// so the order is the only thing to match on.
  final _waiting = Queue<Completer<List<String>>>();

  final _line = BytesBuilder();

  /// The reply being read: the arguments its `%begin` gave, which its `%end`
  /// or `%error` repeats, and whether it answers one of ours.
  String? _reply;
  bool _replyIsOurs = false;
  final _replyLines = <String>[];

  bool _closed = false;

  /// How many commands this client has written, and how many of them tmux
  /// has answered, counted as each answer is read rather than when whoever
  /// waits for it hears: a pane's `%output` read once the Nth answer has been
  /// is what the pane wrote after the Nth command ran.
  int get sent => _sent;
  int get answered => _answered;
  int _sent = 0;
  int _answered = 0;

  /// Runs [command] and hands back what it printed, a line at a time. Throws
  /// [TmuxException] with tmux's own words when tmux refuses it.
  ///
  /// A command must fit on one line, and must not be empty: an empty line is
  /// how a control client asks to detach.
  Future<List<String>> command(String command) {
    assert(command.isNotEmpty && !command.contains('\n'));
    final reply = Completer<List<String>>();
    if (_closed) {
      reply.completeError(const TmuxException('tmux is not running.'));
    } else {
      _waiting.add(reply);
      _sent++;
      write(utf8.encode('$command\n'));
    }
    return reply.future;
  }

  /// Feeds what tmux wrote, in whatever pieces it arrived in.
  void add(List<int> bytes) {
    var start = 0;
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] != 0x0a) continue;
      _line.add(bytes.sublist(start, i));
      _read(_line.takeBytes());
      start = i + 1;
    }
    if (start < bytes.length) _line.add(bytes.sublist(start));
  }

  /// tmux has gone: nothing still waiting will be answered.
  void close() {
    _closed = true;
    while (_waiting.isNotEmpty) {
      _waiting.removeFirst().completeError(
        const TmuxException('tmux is not running.'),
      );
    }
  }

  static final _outputPrefix = ascii.encode('%output %');

  void _read(Uint8List line) {
    // Replies are never interrupted by a notification, so inside one a line
    // starting with `%` is output like any other — `list-panes` prints `%0`.
    if (_reply == null && _startsWith(line, _outputPrefix)) {
      final space = line.indexOf(0x20, _outputPrefix.length);
      final pane = space < 0
          ? null
          : int.tryParse(
              String.fromCharCodes(line, _outputPrefix.length, space),
            );
      if (pane != null) {
        onOutput(pane, unescape(Uint8List.sublistView(line, space + 1)));
      }
      return;
    }

    final text = utf8.decode(line, allowMalformed: true);
    final reply = _reply;
    if (reply == null) {
      if (text.startsWith('%begin ')) {
        _reply = text.substring('%begin '.length);
        // The last argument is 1 for a command this client wrote and 0 for
        // anything else run on its behalf — the `new-session` it was started
        // with, a hook — which has nobody here waiting for it.
        _replyIsOurs = _reply!.endsWith(' 1');
        _replyLines.clear();
      } else {
        onNotification(text);
      }
      return;
    }

    final ok = text == '%end $reply';
    if (!ok && text != '%error $reply') {
      _replyLines.add(text);
      return;
    }
    _reply = null;
    if (!_replyIsOurs || _waiting.isEmpty) return;
    final waiting = _waiting.removeFirst();
    _answered++;
    if (ok) {
      waiting.complete(List.of(_replyLines));
    } else {
      waiting.completeError(TmuxException(_replyLines.join('\n')));
    }
  }

  static bool _startsWith(List<int> line, List<int> prefix) {
    if (line.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (line[i] != prefix[i]) return false;
    }
    return true;
  }

  /// `%output`'s value as the bytes the pane wrote. tmux writes every byte
  /// below a space, and the backslash itself, as a three-digit octal escape
  /// (`\033`, `\134`); everything else, UTF-8 included, is sent as it was.
  static Uint8List unescape(List<int> value) {
    final bytes = Uint8List(value.length);
    var length = 0;
    for (var i = 0; i < value.length; i++) {
      final byte = value[i];
      if (byte == 0x5c && i + 3 < value.length) {
        bytes[length++] =
            (value[i + 1] - 0x30) * 64 +
            (value[i + 2] - 0x30) * 8 +
            (value[i + 3] - 0x30);
        i += 3;
      } else {
        bytes[length++] = byte;
      }
    }
    return Uint8List.sublistView(bytes, 0, length);
  }
}

/// One tmux pane, drawn by a terminal of its own.
class TmuxPane {
  TmuxPane._(this.id, this.terminal);

  /// The N of `%N`.
  final int id;

  final Terminal terminal;

  /// Where tmux has put it, in cells: its leaf of [TmuxSession.layout].
  TmuxLayout cells = const TmuxLayout(width: 0, height: 0, x: 0, y: 0);

  late final _decoder = const Utf8Decoder(allowMalformed: true)
      .startChunkedConversion(PaneSink(_write));

  /// True while tmux's output is being written into [terminal].
  bool _feeding = false;

  /// What the pane writes while [TmuxSession._fill] asks tmux what it already
  /// holds, each piece with how many answers had been read when it came.
  List<(int, Uint8List)>? _held;

  void _write(String text) {
    _feeding = true;
    try {
      terminal.write(text);
    } finally {
      _feeding = false;
    }
  }
}

/// Feeds a pane's decoded output to its terminal, with screen's title
/// sequence made harmless on the way.
///
/// A program told its terminal is `screen` or `tmux` — what tmux tells the
/// programs in its panes — may name the window with `ESC k title ESC \`.
/// tmux takes that for itself, but `%output` hands it on raw, and xterm2 does
/// not know it: it would print the title at every prompt. Turned into APC
/// (`ESC _`), it is read to its end and dropped. A pane's record, being the
/// same bytes, is replayed through it too.
class PaneSink implements Sink<String> {
  PaneSink(this.write);

  final void Function(String text) write;

  /// An ESC that ended the last piece, held until the next says whether it
  /// began one.
  bool _escape = false;

  @override
  void add(String data) {
    var text = _escape ? '\x1b$data' : data;
    _escape = text.endsWith('\x1b');
    if (_escape) text = text.substring(0, text.length - 1);
    write(text.replaceAll('\x1bk', '\x1b_'));
  }

  @override
  void close() {}
}

/// One tmux session on a host, as `list-sessions` describes it: a row of the
/// Attach picker.
class TmuxSessionInfo {
  const TmuxSessionInfo({
    required this.name,
    required this.windows,
    required this.attached,
    required this.created,
    required this.activity,
  });

  /// What tmux calls it, which is what attaching asks for. The host's own
  /// text, whatever the user called it: shown as text and never as anything
  /// a shell or tmux reads.
  final String name;

  final int windows;

  /// How many clients are attached to it — another phone, or a terminal
  /// somebody is sitting at. tmux lets several share a session.
  final int attached;

  final DateTime created;

  /// When the session's current window last wrote anything. Its other
  /// windows are not asked about: that would be a command per session, and
  /// this one comes free with the listing.
  final DateTime activity;

  bool get inUse => attached > 0;
}

/// A tab's tmux session, spoken to in control mode: the panes of its window,
/// how tmux has laid them out, and which one has focus.
///
/// One tmux session per tab, named for it (`sshbox-<id>`), so a dropped
/// connection reattaches to the same panes with their programs still running,
/// and closing the tab is what ends them.
///
/// Only the session's current window is shown. Others can exist — made from
/// another terminal attached to the same session — and are left alone.
class TmuxSession {
  TmuxSession({
    required this.name,
    required this._channel,
    required this._newTerminal,
    required this._transform,
    required this.onChanged,
    required this.onEnded,
    this._size,
    this.record = false,
  }) {
    _client = TmuxClient(
      write: _channel.write,
      onOutput: _onOutput,
      onNotification: _onNotification,
    );
    _subscription = _channel.output.listen(
      _client.add,
      onError: (Object _) => _onDone(),
      onDone: _onDone,
    );
  }

  /// What the host runs for a tab in tmux mode, attaching to [name] or
  /// creating it. Through `sh` because the login shell may be fish, and with
  /// stderr folded in so that whatever stops tmux from starting — not being
  /// installed, most likely — is what the channel says instead.
  ///
  /// `-u` because a control client that tmux does not believe speaks UTF-8
  /// gets `_` in place of every other character in what `capture-pane`
  /// prints, and an SSH exec channel usually arrives with no locale at all.
  ///
  /// The device's variables (see `LiveSession.connect`) reach the client with
  /// the channel, but a pane gets the tmux server's environment: what it
  /// started with, perhaps nothing, or a key since replaced. Listed in
  /// `update-environment`, tmux copies them from the client into the session
  /// when it makes it and at every attach, so the first pane, and any split
  /// off after a reconnect, has this connection's; a pane already running
  /// keeps its own, as any process does: the direct way's URL and secret
  /// too, which die with the connection that gave them. Not
  /// `new-session -e`, which tmux before 3.0 refuses and which would show
  /// the values in `ps`. Added once per server, since the list holds at most
  /// 1000 names, and looked for by the newest name, so a server that
  /// listed an earlier version's names gets the new ones; a name listed
  /// twice is harmless.
  ///
  /// tmux is found once, as an absolute path `$t`, and every tmux here runs
  /// from it. An exec channel's shell is not a login shell, so its PATH
  /// lacks what a profile adds: on a Mac it is `/usr/bin:/bin:/usr/sbin:/sbin`
  /// and Homebrew's tmux is not on it. So after PATH come the places package
  /// managers put tmux, then the login shell's own PATH — asked with nothing
  /// on stdin, its errors dropped and only its last line kept, so whatever a
  /// profile prints never reaches the channel, let alone control mode.
  ///
  /// Pane records gone stale are pruned on the way: see [PaneRecord.prune].
  static String command(String name) => _attach('new-session -A -s "\$n"', name);

  /// What the host runs to join a session that is already there, rather than
  /// make one: the Attach picker's, for a session somebody left running.
  ///
  /// `attach-session` rather than `new-session -A`, so a session that has
  /// gone since it was listed is an error the tab can say out loud instead of
  /// an empty session of the same name — and `=` makes the name exact, where
  /// tmux would otherwise take a session whose name only starts with it.
  static String attachExisting(String name) =>
      _attach('attach-session -t "=\$n"', name);

  /// [command] and [attachExisting], which differ only in the tmux command
  /// they end with — given here with the name as `$n`.
  ///
  /// The name is the host's own text: a session somebody made can hold a
  /// space, a quote, a `$( )`, a backtick or a semicolon (tmux takes all of
  /// them; it turns `:` and `.` into `_` and writes control characters out as
  /// escapes). So it never goes into the script: it is passed to `sh` as an
  /// argument, quoted once for the shell that reads this command line, and
  /// read back out of `$1` before `set --` can take the place. Inside the
  /// script it is only ever `"$n"`, which no shell looks at twice.
  ///
  /// The `shift` matters: what follows puts tmux's own arguments in `$@` and
  /// runs `"$@"` whether it set them or not, so the name left sitting in `$1`
  /// would be handed to tmux as a command of its own.
  static String _attach(String tmuxCommand, String name) =>
      "sh -c '"
      r'n=$1; shift; '
      '$_findTmux'
      r'"$t" show -gv update-environment 2>/dev/null | '
      'grep -q LC_SSHBOX_KEY || '
      r'set -- set -ga update-environment " LC_SSHBOX_KEY LC_SSHBOX_HOST_ID '
      r'LC_SSHBOX_NOTIFY_URL LC_SSHBOX_NOTIFY_SECRET" '
      '\\;; ${PaneRecord.prune}'
      r'exec "$t" -u -C "$@" '
      "$tmuxCommand 2>&1' sh ${quoteArgument(name)}";

  /// What the host runs to say whether the session called [name] is still
  /// there, as its last line: `yes` or `no`. `=` makes the name exact, where
  /// tmux would otherwise take a session whose name only starts with it.
  static String exists(String name) =>
      "sh -c '$_findTmux"
      r'"$t" has-session -t "=$1" 2>/dev/null && echo yes || echo no'
      "' sh ${quoteArgument(name)}";

  /// What the host runs to list every tmux session it has, a line each, for
  /// the Attach picker: see [parseList].
  ///
  /// Fields apart by spaces, the name last: everything before it is a
  /// number, so a name full of spaces cannot pass for another field. Not a
  /// tab, which would have been the obvious choice: tmux 3.2a prints any
  /// control character in a format's output as `_`, tab included.
  ///
  /// `#{window_activity}` rather than `#{session_activity}`, which sounds
  /// like the one to ask for and does not move when a pane writes — measured
  /// on tmux 3.2a, where a session printing for five seconds kept the
  /// activity time it was made with while its window's went up.
  static const list =
      "sh -c '$_findTmux"
      r'exec "$t" list-sessions -F '
      '"#{session_attached} #{session_windows} #{session_created} '
      '#{window_activity} #{session_name}" 2>/dev/null\'';

  /// [value] as one argument to `sh`: in single quotes, with any single quote
  /// of its own closed, escaped and opened again.
  static String quoteArgument(String value) =>
      "'${value.replaceAll("'", r"'\''")}'";

  /// What [list] printed, as sessions, the ones that wrote something most
  /// recently first — which is the question somebody coming back to a host
  /// is really asking.
  ///
  /// A line that is not a row is dropped rather than guessed at: the script's
  /// own "tmux is not installed", a greeting a profile printed, a `%` line.
  ///
  /// Only the first four spaces split the row; the rest of it, spaces and
  /// all, is the name. And a row is always one line: tmux stores a name
  /// through `session_check_name`, which writes every control character out
  /// as an escape — a newline is kept as the two characters `\n` — so no
  /// name can carry a row break.
  static List<TmuxSessionInfo> parseList(Iterable<String> lines) {
    final sessions = <TmuxSessionInfo>[];
    for (final line in lines) {
      final fields = <String>[];
      var rest = line;
      while (fields.length < 4) {
        final space = rest.indexOf(' ');
        if (space < 0) break;
        fields.add(rest.substring(0, space));
        rest = rest.substring(space + 1);
      }
      if (fields.length < 4) continue;
      final attached = int.tryParse(fields[0]);
      final windows = int.tryParse(fields[1]);
      final created = int.tryParse(fields[2]);
      final activity = int.tryParse(fields[3]);
      final name = rest;
      if (attached == null ||
          windows == null ||
          created == null ||
          activity == null ||
          name.isEmpty) {
        continue;
      }
      sessions.add(
        TmuxSessionInfo(
          name: name,
          windows: windows,
          attached: attached,
          created: DateTime.fromMillisecondsSinceEpoch(created * 1000),
          activity: DateTime.fromMillisecondsSinceEpoch(activity * 1000),
        ),
      );
    }
    sessions.sort((a, b) => b.activity.compareTo(a.activity));
    return sessions;
  }

  /// Finds tmux as [command] says, into `$t`, or says it is not installed and
  /// stops.
  static const _findTmux =
      r'ok() { case $1 in /*) [ -f "$1" ] && [ -x "$1" ];; *) return 1;; esac; }; '
      r't=$(command -v tmux); '
      r'ok "$t" || for t in /opt/homebrew/bin/tmux /usr/local/bin/tmux '
      r'/opt/local/bin/tmux /home/linuxbrew/.linuxbrew/bin/tmux '
      r'"$HOME/.nix-profile/bin/tmux" /run/current-system/sw/bin/tmux '
      r'"$HOME/.local/bin/tmux" /snap/bin/tmux; do ok "$t" && break; t=; done; '
      r'ok "$t" || t=$("$SHELL" -lc "command -v tmux" </dev/null 2>/dev/null '
      '| tail -n 1); '
      r'ok "$t" || { echo "tmux is not installed on this host (looked on PATH, '
      'in Homebrew and the other usual places)"; exit 1; }; ';

  /// How far back a pane's history reaches when it is filled in on attach.
  // ponytail: a fixed 2000 lines, a fifth of the plain terminal's 10k,
  // because it crosses the connection at every attach; follow tmux's
  // history-limit if that proves short.
  static const _history = 2000;

  /// Longest run of keystrokes put in one `send-keys`, so a large paste is
  /// several reasonable lines rather than one enormous one.
  static const _sendChunk = 256;

  final String name;
  final CommandChannel _channel;
  final Terminal Function() _newTerminal;
  final String Function(String data) _transform;
  late final TmuxClient _client;
  late final StreamSubscription<Uint8List> _subscription;

  final void Function() onChanged;

  /// tmux ended after attaching: the last pane exited, the session was killed
  /// elsewhere, or the connection went.
  final void Function() onEnded;

  /// Whether the session's panes are recorded on the host — see
  /// [PaneRecord]. Set up, or taken down, at every attach, so a switch
  /// changed since reaches a session that is already there.
  ///
  /// Null for a session the app did not make — what Attach joins — which is
  /// left exactly as whoever made it set it up, recorded or not. Two reasons,
  /// and either is enough: a record is kept in a directory named after the
  /// session and piped to by a command tmux reads as a format string, and a
  /// name from the host can hold a space, a `#` or a `%`; and the hooks are
  /// set on the session, so taking them down would take down the user's own.
  final bool? record;

  final _panes = <int, TmuxPane>{};
  final _attached = Completer<bool>();

  /// The room on screen, in cells, as last reported.
  (int columns, int rows)? _size;
  String? _window;
  int? _focused;
  bool _disposed = false;

  /// The current window's layout, once tmux has said what it is.
  TmuxLayout? layout;

  /// Why tmux never attached, in the host's words when it gave any.
  String? problem;

  /// True once tmux is attached, false if the channel ended first.
  Future<bool> get attached => _attached.future;

  /// Every pane on screen, in layout order.
  List<TmuxPane> get panes => [
    for (final leaf in layout?.panes ?? const <TmuxLayout>[])
      ?_panes[leaf.pane],
  ];

  /// The pane keystrokes go to: the one tmux calls active, or the one last
  /// tapped while tmux catches up.
  TmuxPane? get focused => _panes[_focused] ?? panes.firstOrNull;

  void focus(TmuxPane pane) {
    if (_focused == pane.id) return;
    _focused = pane.id;
    _client.command('select-pane -t %${pane.id}').ignore();
    onChanged();
  }

  /// Keeps tmux's idea of the window's size in step with the room on screen,
  /// in cells. tmux answers with a new layout.
  void resize(int columns, int rows) {
    if (columns <= 0 || rows <= 0 || _size == (columns, rows)) return;
    _size = (columns, rows);
    if (_attached.isCompleted) {
      _client.command('refresh-client -C ${columns}x$rows').ignore();
    }
  }

  /// Keystrokes for the focused pane, as they would reach a plain shell.
  void send(String data) {
    final pane = focused;
    if (pane != null) _sendTo(pane, data);
  }

  /// As hex, so no byte is ever read as tmux syntax: `send-keys -H` writes
  /// each one to the pane as it is, rather than as a key tmux looks up.
  void _sendTo(TmuxPane pane, String data) {
    final bytes = utf8.encode(data);
    for (var start = 0; start < bytes.length; start += _sendChunk) {
      final hex = bytes
          .sublist(start, math.min(start + _sendChunk, bytes.length))
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      _client.command('send-keys -t %${pane.id} -H $hex').ignore();
    }
  }

  /// Splits the focused pane in two, the new one starting in the folder the
  /// focused one is in. tmux focuses the new pane itself. Throws
  /// [TmuxException] when tmux will not, as with no room for another pane.
  Future<void> split({required bool sideBySide}) async {
    final pane = focused;
    if (pane == null) return;
    await _client.command(
      'split-window ${sideBySide ? '-h' : '-v'} -t %${pane.id} '
      '-c "#{pane_current_path}"',
    );
  }

  Future<void> closePane() async {
    final pane = focused;
    if (pane != null) await _client.command('kill-pane -t %${pane.id}');
  }

  /// What the focused pane is running and where, as tmux sees it — the
  /// shape of `LiveSession.foreground`. null when tmux cannot say.
  ///
  /// The shell is in the foreground when the program is the host's default
  /// shell, which is what every pane here starts, or a shell by another name.
  Future<({bool shellInForeground, String program, String cwd})?>
  foreground() async {
    final pane = focused;
    if (pane == null) return null;
    try {
      final reply = await _client.command(
        'display -p -t %${pane.id} '
        '"#{default-shell}\t#{pane_current_command}\t#{pane_current_path}"',
      );
      final fields = (reply.firstOrNull ?? '').split('\t');
      if (fields.length < 3) return null;
      final program = fields[1];
      return (
        shellInForeground:
            program == fields[0].split('/').last || _shells.contains(program),
        program: program,
        // A folder may hold a tab; nothing else here can.
        cwd: fields.skip(2).join('\t'),
      );
    } on TmuxException {
      return null;
    }
  }

  static const _shells = {'sh', 'bash', 'zsh', 'fish', 'dash', 'ksh', 'tcsh'};

  /// The name [pane]'s record has on the host, in [PaneRecord.dir]: the tmux
  /// server's pid and the pane, as `pipe-pane` named it. null when tmux
  /// cannot say.
  Future<String?> recordName(TmuxPane pane) async {
    try {
      final reply = await _client.command(
        'display -p -t %${pane.id} "#{pid}-#{pane_id}"',
      );
      final name = reply.firstOrNull ?? '';
      return RegExp(r'^\d+-%\d+$').hasMatch(name) ? name : null;
    } on TmuxException {
      return null;
    }
  }

  /// Starts every pane of the session recording, and has tmux start each
  /// one made later, with nobody attached — or, with [record] off, stops
  /// them. A pane already recording is left as it is: `-o` opens a pipe only
  /// where there is none.
  ///
  /// The hooks are the session's own. One of the same name set for every
  /// session is the user's, and one here would hide it from this session, so
  /// then there is none, and a pane made while nothing is attached records
  /// from the next attach.
  Future<void> _recordPanes() async {
    final record = this.record;
    // Somebody else's session: nothing of ours goes near it, which also
    // keeps a name the app did not make out of the pipe command and out of
    // the tmux target below, neither of which is quoted for one.
    if (record == null) return;
    final pipe = PaneRecord.pipe(name);
    try {
      final panes = await _client.command(
        'list-panes -s -t "=$name" -F "#{pane_id}"',
      );
      for (final pane in panes) {
        if (!RegExp(r'^%\d+$').hasMatch(pane)) continue;
        _client
            .command(
              record ? 'pipe-pane -o -t $pane $pipe' : 'pipe-pane -t $pane',
            )
            .ignore();
      }
      for (final hook in PaneRecord.hooks) {
        final session = '-t "=$name:" $hook';
        if (!record) {
          _client.command('set-hook -u $session').ignore();
          continue;
        }
        final global = await _client.command('show-hooks -g $hook');
        if (global.any((line) => line.trim() != hook)) continue;
        _client.command("set-hook $session 'pipe-pane -o $pipe'").ignore();
      }
    } on TmuxException {
      // Gone, or a tmux older than hooks: the channel ending says the rest.
    }
  }

  /// Leaves the session and everything running in it on the host, and lets
  /// this client go: Detach, which is the whole point of the feature — walk
  /// away from a build or an agent and find it alive later.
  ///
  /// Nothing else is undone, deliberately. The panes' pipes keep writing
  /// their records, which is the case records were built for, and the hooks
  /// that give a pane made later one stay on the session. tmux ends no
  /// process: a session with no client attached is the ordinary state of a
  /// tmux session.
  ///
  /// `detach-client` with no target is this client, the one that ran it.
  /// tmux answers it and only then says `%exit`, so it completes rather than
  /// hanging; an empty line detaches too but is answered by nothing, which
  /// is why this asks in words. Closing the channel would do it in the end —
  /// tmux's client exits when its input does — and this is the orderly way,
  /// so what the host sees is a detach rather than a hang-up.
  ///
  /// Never [kill]: the two say opposite things to the host and share no code.
  Future<void> detach() async {
    if (!_attached.isCompleted || _disposed) return;
    try {
      await _client
          .command('detach-client')
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // Gone already, or the connection is. Either way the session is not
      // this client's to end, and closing the channel is all that is left.
    }
  }

  /// Ends the tmux session and everything running in it — closing the tab,
  /// as opposed to losing the connection.
  Future<void> kill() async {
    if (!_attached.isCompleted || _disposed) return;
    try {
      await _client.command('kill-session').timeout(const Duration(seconds: 2));
    } catch (_) {
      // Gone already, or the connection is: either way there is nothing
      // left to wait for.
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _subscription.cancel();
    _channel.close();
    _client.close();
    for (final pane in _panes.values) {
      pane.terminal.dispose();
    }
    _panes.clear();
  }

  void _onDone() {
    _client.close();
    if (_disposed) return;
    if (!_attached.isCompleted) {
      problem ??= 'tmux did not start on this host.';
      _attached.complete(false);
    } else {
      onEnded();
    }
  }

  void _onOutput(int id, Uint8List data) {
    final pane = _panes[id];
    if (pane == null) return;
    final held = pane._held;
    if (held != null) {
      held.add((_client.answered, data));
    } else {
      pane._decoder.add(data);
    }
  }

  void _onNotification(String line) {
    final words = line.split(' ');
    switch (words.first) {
      case '%session-changed':
        unawaited(_sync());
        if (!_attached.isCompleted) {
          _attached.complete(true);
          unawaited(_recordPanes());
        }
      case '%session-window-changed':
        unawaited(_sync());
      // The visible layout rather than the whole one: a pane zoomed from
      // another client is all there is to see.
      case '%layout-change' when words.length > 3 && words[1] == _window:
        _applyLayout(words[3]);
      case '%window-pane-changed' when words.length > 2 && words[1] == _window:
        _focused = _paneId(words[2]);
        onChanged();
      case '%exit':
        if (words.length > 1) problem = words.skip(1).join(' ');
      default:
        // Before tmux is up, whatever the host says instead is the reason
        // it never came — the script's "not installed", or tmux's own error.
        if (!line.startsWith('%') && line.trim().isNotEmpty) {
          problem = line.trim();
        }
    }
  }

  static int? _paneId(String word) =>
      word.startsWith('%') ? int.tryParse(word.substring(1)) : null;

  /// Asks where things stand — which window, laid out how, which pane has
  /// focus — on attaching and whenever the window changes under us. tmux
  /// only reports a layout when one changes, and on attach nothing has.
  Future<void> _sync() async {
    final size = _size;
    if (size != null) {
      _client.command('refresh-client -C ${size.$1}x${size.$2}').ignore();
    }
    try {
      final reply = await _client.command(
        'display -p "#{window_id}\t#{window_visible_layout}\t#{pane_id}"',
      );
      final fields = (reply.firstOrNull ?? '').split('\t');
      if (fields.length < 3 || _disposed) return;
      _window = fields[0];
      _focused = _paneId(fields[2]);
      _applyLayout(fields[1]);
    } on TmuxException {
      // tmux went while we asked; the channel ending says the rest.
    }
  }

  void _applyLayout(String text) {
    final TmuxLayout parsed;
    try {
      parsed = TmuxLayout.parse(text);
    } on FormatException {
      return;
    }
    layout = parsed;

    final added = <TmuxPane>[];
    final shown = <int>{};
    for (final leaf in parsed.panes) {
      final id = leaf.pane!;
      shown.add(id);
      final pane = _panes[id] ??= _newPane(id, added);
      pane.cells = leaf;
      pane.terminal.resize(leaf.width, leaf.height);
    }
    for (final id in _panes.keys.toList()) {
      if (!shown.contains(id)) _panes.remove(id)!.terminal.dispose();
    }
    // After sizing: history that is filled in wraps at the pane's width.
    added.forEach(_fill);
    onChanged();
  }

  TmuxPane _newPane(int id, List<TmuxPane> added) {
    final pane = TmuxPane._(id, _newTerminal());
    // Keystrokes only. Whatever the terminal says back to the program on
    // its own — answers to "what are you", "where is the cursor" — tmux has
    // already said, being the program's real terminal; sent again, they
    // would arrive as typing.
    pane.terminal.onOutput = (data) {
      if (!pane._feeding) _sendTo(pane, _transform(data));
    };
    added.add(pane);
    return pane;
  }

  /// Draws what the pane already holds, for a pane that existed before we
  /// saw it: after attaching, or one split off since.
  ///
  /// The terminal starts over from the capture. What the pane writes in the
  /// meantime is held rather than drawn: what came before tmux answered the
  /// capture is in it, and what came after is drawn on top once it is. Drawn
  /// as it came, the latter would be wiped by the capture, since tmux can
  /// answer and go straight on to more output in one read, all of it handled
  /// before whoever awaits the answer hears it — which is how a command typed
  /// just after attaching lost its output. The cursor and the modes a
  /// program would have set on its way in are put back too — vim is on the
  /// alternate screen, and wants its arrow keys in application form.
  Future<void> _fill(TmuxPane pane) async {
    final target = '-t %${pane.id}';
    final held = pane._held = [];
    // Held output read before this many answers is in the capture.
    var drawnUpTo = 0;
    try {
      final replies = [
        _client.command(
          'display -p $target "#{cursor_x}\t#{cursor_y}\t#{alternate_on}\t'
          '#{keypad_cursor_flag}\t#{cursor_flag}"',
        ),
        _client.command('capture-pane -p -e -J $target -S -$_history'),
      ];
      final captured = _client.sent;
      final [state, lines] = await Future.wait(replies);
      if (_panes[pane.id] != pane) return;
      final flags = (state.firstOrNull ?? '').split('\t');
      if (flags.length < 5) return;
      final x = int.tryParse(flags[0]) ?? 0;
      final y = int.tryParse(flags[1]) ?? 0;
      pane._write(
        '\x1bc'
        '${flags[2] == '1' ? '\x1b[?1049h' : ''}'
        '${lines.join('\r\n')}'
        '\x1b[${y + 1};${x + 1}H'
        '${flags[3] == '1' ? '\x1b[?1h' : ''}'
        '${flags[4] == '0' ? '\x1b[?25l' : ''}',
      );
      drawnUpTo = captured;
    } on TmuxException {
      // The pane closed between asking and answering.
    } finally {
      pane._held = null;
      if (_panes[pane.id] == pane) {
        for (final (answered, data) in held) {
          if (answered >= drawnUpTo) pane._decoder.add(data);
        }
      }
    }
  }
}
