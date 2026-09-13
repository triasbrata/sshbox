import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:xterm2/xterm.dart';

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
      .startChunkedConversion(_PaneSink(this));

  /// True while tmux's output is being written into [terminal].
  bool _feeding = false;

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
/// (`ESC _`), it is read to its end and dropped.
class _PaneSink implements Sink<String> {
  _PaneSink(this.pane);

  final TmuxPane pane;

  /// An ESC that ended the last piece, held until the next says whether it
  /// began one.
  bool _escape = false;

  @override
  void add(String data) {
    var text = _escape ? '\x1b$data' : data;
    _escape = text.endsWith('\x1b');
    if (_escape) text = text.substring(0, text.length - 1);
    pane._write(text.replaceAll('\x1bk', '\x1b_'));
  }

  @override
  void close() {}
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
  /// started with, perhaps nothing, or a token since replaced. Listed in
  /// `update-environment`, tmux copies them from the client into the session
  /// when it makes it and at every attach, so the first pane, and any split
  /// off after a reconnect, has this connection's; a pane already running
  /// keeps its own, as any process does: the direct way's URL and secret
  /// too, which die with the connection that gave them. Not
  /// `new-session -e`, which tmux before 3.0 refuses and which would show
  /// the values in `ps`. Added once per server, since the list holds at most
  /// 1000 names, and looked for by the newest name, so a server that
  /// listed only the first two for an earlier version gets the rest; a name
  /// listed twice is harmless.
  static String command(String name) =>
      "sh -c 'command -v tmux >/dev/null || "
      "{ echo tmux is not installed on this host; exit 1; }; "
      'tmux show -gv update-environment 2>/dev/null | '
      'grep -q LC_SSHBOX_NOTIFY_SECRET || '
      r'set -- set -ga update-environment " LC_SSHBOX_TOKEN LC_SSHBOX_HOST_ID '
      r'LC_SSHBOX_NOTIFY_URL LC_SSHBOX_NOTIFY_SECRET" '
      r'\;; exec tmux -u -C "$@" '
      "new-session -A -s $name 2>&1'";

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

  void _onOutput(int id, Uint8List data) => _panes[id]?._decoder.add(data);

  void _onNotification(String line) {
    final words = line.split(' ');
    switch (words.first) {
      case '%session-changed':
        unawaited(_sync());
        if (!_attached.isCompleted) _attached.complete(true);
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
  /// The capture is taken after everything tmux has sent so far, so the
  /// terminal starts over from it rather than adding to what arrived in the
  /// meantime. The cursor and the modes a program would have set on its way
  /// in are put back too — vim is on the alternate screen, and wants its
  /// arrow keys in application form.
  Future<void> _fill(TmuxPane pane) async {
    final target = '-t %${pane.id}';
    try {
      final [state, lines] = await Future.wait([
        _client.command(
          'display -p $target "#{cursor_x}\t#{cursor_y}\t#{alternate_on}\t'
          '#{keypad_cursor_flag}\t#{cursor_flag}"',
        ),
        _client.command('capture-pane -p -e -J $target -S -$_history'),
      ]);
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
    } on TmuxException {
      // The pane closed between asking and answering.
    }
  }
}
