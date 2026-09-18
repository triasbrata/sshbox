import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../session/terminal_session.dart';

/// How much of a tool's result is kept for the transcript. A `cat` of a large
/// file comes back whole, and every byte of it would sit in memory for as
/// long as the tab is open; what is shown is the head of it, and the rest is
/// counted rather than kept.
const _resultLimit = 4000;

/// One line of the transcript.
sealed class ChatEntry {}

/// What the user typed, or what Claude answered.
class ChatSaid extends ChatEntry {
  ChatSaid(this.text, {required this.mine});

  final String text;

  /// Whose turn it was: the user's, or Claude's.
  final bool mine;
}

/// A tool Claude asked for, and what came back — one entry rather than two,
/// so the result folds into the call that asked for it, as the VS Code
/// plugin shows it.
class ChatToolRun extends ChatEntry {
  ChatToolRun({required this.id, required this.name, required this.input});

  /// The `tool_use_id` a result arrives under.
  final String id;
  final String name;
  final Map<String, dynamic> input;

  String? result;
  bool failed = false;

  /// False while the tool is still running, which is how the row draws a
  /// spinner rather than a result.
  bool get done => result != null;

  /// The one line the row shows beside the tool's name: the command, the
  /// file, the pattern — whatever this tool is chiefly about. Everything
  /// else is behind the row's own expansion.
  String get summary {
    for (final key in const [
      'command',
      'file_path',
      'path',
      'pattern',
      'url',
      'query',
      'prompt',
      'description',
    ]) {
      final value = input[key];
      if (value is String && value.trim().isNotEmpty) {
        return value.trim().replaceAll('\n', ' ');
      }
    }
    return input.isEmpty ? '' : jsonEncode(input);
  }
}

/// Something the run itself has to say: it started, it ended, it was refused.
/// Not part of the conversation, so it draws quietly.
class ChatNotice extends ChatEntry {
  ChatNotice(this.text, {this.failed = false});

  final String text;
  final bool failed;
}

/// What Claude may do on the host without being asked.
///
/// Nothing here can prompt: a prompt needs an SDK host on the other end of
/// the pipe to answer it, which this is not, so anything that would ask is
/// refused and Claude says so in its reply. The mode is what decides
/// everything that does not ask.
enum ChatPermission {
  /// Reads and plans, changes nothing.
  plan('plan', 'Plan only'),

  /// Edits files without asking; the default.
  acceptEdits('acceptEdits', 'Accept edits'),

  /// Everything, including commands. For a host the user already trusts
  /// Claude on.
  bypass('bypassPermissions', 'Allow everything');

  const ChatPermission(this.flag, this.label);

  /// What `--permission-mode` is given.
  final String flag;

  /// What the picker calls it.
  final String label;
}

/// A conversation with Claude Code running on the host, driven over one
/// command channel on the session's own SSH connection.
///
/// `claude -p` with JSON in and JSON out is the same doorway the VS Code
/// plugin uses: one long-lived process, a JSON line per message in, a JSON
/// line per event out, and the whole conversation in the process rather than
/// here — so nothing has to be replayed, and a turn's tool calls arrive as
/// they happen instead of as terminal drawing to be unpicked.
class ClaudeChat extends ChangeNotifier {
  ClaudeChat({required this.open, this.cwd});

  /// Starts a command on the host and hands back its pipes — the session's
  /// own [ChannelCapable.open], looked up at the moment it is called so a
  /// restart after a reconnect goes down the new connection.
  final Future<CommandChannel> Function(String command) open;

  /// Where Claude runs on the host — the host's file-tree root, so the files
  /// it reads are the ones the drawer shows. Null starts it in the login
  /// directory.
  final String? cwd;

  ChatPermission _permission = ChatPermission.acceptEdits;

  /// What Claude may do without being asked. Fixed when the process starts,
  /// so changing it goes through [restart].
  ChatPermission get permission => _permission;

  final List<ChatEntry> _entries = [];

  List<ChatEntry> get entries => List.unmodifiable(_entries);

  CommandChannel? _channel;
  StreamSubscription<String>? _lines;

  /// Claude's own id for this conversation, from its first event. What a
  /// restart resumes, so changing the permission mode, or coming back after
  /// the connection dropped, keeps everything said so far.
  String? _sessionId;

  String? get sessionId => _sessionId;

  bool _starting = false;
  bool _ready = false;
  bool _busy = false;
  bool _ended = false;

  /// True from the moment a message is sent until Claude's turn ends, which
  /// is what the send button and the spinner follow.
  bool get busy => _busy;

  /// True once the process is up and a message may be sent.
  bool get ready => _ready;

  /// True once the process has gone: the host said Claude is not installed,
  /// it crashed, or the connection went.
  bool get ended => _ended;

  /// The tool calls still waiting for their result, by `tool_use_id`.
  final Map<String, ChatToolRun> _running = {};

  /// Starts Claude on the host. Safe to call again: a chat already up, or on
  /// its way up, stays as it is.
  Future<void> start() async {
    if (_starting || _ready) return;
    _starting = true;
    _ended = false;
    notifyListeners();
    try {
      final channel = await open(
        command(cwd: cwd, permission: _permission, resume: _sessionId),
      );
      _channel = channel;
      _ready = true;
      _lines = utf8.decoder
          .bind(channel.output)
          .transform(const LineSplitter())
          .listen(_onLine, onDone: _onDone, onError: (Object error) {
            _say(ChatNotice('$error', failed: true));
            _onDone();
          });
    } catch (error) {
      _say(ChatNotice('$error', failed: true));
      _ended = true;
    } finally {
      _starting = false;
      notifyListeners();
    }
  }

  /// Sends a message and waits for the turn it starts.
  void send(String text) {
    final message = text.trim();
    if (message.isEmpty || !_ready || _busy) return;
    _write({
      'type': 'user',
      'message': {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': message},
        ],
      },
    });
    _entries.add(ChatSaid(message, mine: true));
    _busy = true;
    notifyListeners();
  }

  /// Starts Claude again, resuming the same conversation when it got far
  /// enough to have one. What a changed permission mode needs, since the
  /// mode is fixed when the process starts, and what a dropped connection
  /// needs once the session is back.
  Future<void> restart({ChatPermission? permission}) async {
    if (permission != null) _permission = permission;
    await _stop();
    _busy = false;
    _ended = false;
    await start();
  }

  void _write(Map<String, dynamic> message) {
    final channel = _channel;
    if (channel == null) return;
    channel.write(Uint8List.fromList(utf8.encode('${jsonEncode(message)}\n')));
  }

  void _say(ChatEntry entry) {
    _entries.add(entry);
    notifyListeners();
  }

  /// One event, or one line the host wrote that is not an event at all —
  /// `claude: not found`, or whatever a profile printed. Those show as they
  /// came rather than being dropped, because they are usually the reason
  /// nothing else is happening.
  void _onLine(String line) {
    final text = line.trim();
    if (text.isEmpty) return;
    if (!text.startsWith('{')) {
      _say(ChatNotice(text, failed: true));
      return;
    }
    final Object? event;
    try {
      event = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (event is! Map<String, dynamic>) return;
    switch (event['type']) {
      case 'system' when event['subtype'] == 'init':
        _sessionId = event['session_id'] as String?;
        notifyListeners();
      case 'assistant':
        _onAssistant(event['message']);
      case 'user':
        _onToolResults(event['message']);
      case 'result':
        _busy = false;
        final subtype = event['subtype'];
        if (subtype is String && subtype != 'success') {
          _entries.add(ChatNotice(_resultReason(subtype), failed: true));
        }
        notifyListeners();
    }
  }

  static String _resultReason(String subtype) => switch (subtype) {
    'error_max_turns' => 'Claude stopped: it hit its limit on tool calls.',
    'error_during_execution' => 'Claude stopped: something went wrong.',
    _ => 'Claude stopped: $subtype.',
  };

  void _onAssistant(Object? message) {
    if (message is! Map<String, dynamic>) return;
    final content = message['content'];
    if (content is! List) return;
    var changed = false;
    for (final block in content) {
      if (block is! Map<String, dynamic>) continue;
      switch (block['type']) {
        // Thinking is left out: it is Claude's working, not its answer, and
        // it arrives with the signature blob that carries it.
        case 'text':
          final text = (block['text'] as String? ?? '').trim();
          if (text.isEmpty) break;
          _entries.add(ChatSaid(text, mine: false));
          changed = true;
        case 'tool_use':
          final run = ChatToolRun(
            id: block['id'] as String? ?? '',
            name: block['name'] as String? ?? 'tool',
            input: switch (block['input']) {
              final Map<String, dynamic> input => input,
              _ => const {},
            },
          );
          _entries.add(run);
          _running[run.id] = run;
          changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// A `user` event is not the user: it is what the tools Claude ran gave
  /// back, which folds into the call that asked for it.
  void _onToolResults(Object? message) {
    if (message is! Map<String, dynamic>) return;
    final content = message['content'];
    if (content is! List) return;
    var changed = false;
    for (final block in content) {
      if (block is! Map<String, dynamic>) continue;
      if (block['type'] != 'tool_result') continue;
      final run = _running.remove(block['tool_use_id']);
      if (run == null) continue;
      run
        ..result = _resultText(block['content'])
        ..failed = block['is_error'] == true;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// A result is a string, or the blocks a tool answered with. Either way
  /// what the row shows is text, cut to [_resultLimit].
  static String _resultText(Object? content) {
    final text = switch (content) {
      final String value => value,
      final List blocks => blocks
          .whereType<Map<String, dynamic>>()
          .map(
            (block) => switch (block['type']) {
              'text' => block['text'] as String? ?? '',
              'tool_reference' => block['tool_name'] as String? ?? '',
              final other => '[$other]',
            },
          )
          .join('\n'),
      _ => '',
    };
    if (text.length <= _resultLimit) return text;
    final rest = text.length - _resultLimit;
    return '${text.substring(0, _resultLimit)}\n… $rest more characters';
  }

  void _onDone() {
    // An error on the stream is followed by its close, and the run has only
    // ended once.
    if (_ended) return;
    _ready = false;
    _busy = false;
    _ended = true;
    for (final run in _running.values) {
      run
        ..result = 'Claude went away before this finished.'
        ..failed = true;
    }
    _running.clear();
    _entries.add(ChatNotice('Claude is no longer running on this host.'));
    notifyListeners();
  }

  Future<void> _stop() async {
    final lines = _lines;
    final channel = _channel;
    _lines = null;
    _channel = null;
    _ready = false;
    // Cancelled first: closing the channel ends the stream, and _onDone has
    // nothing to say about a chat that was stopped on purpose.
    await lines?.cancel();
    channel?.close();
  }

  @override
  void dispose() {
    unawaited(_stop());
    super.dispose();
  }

  /// What the host runs.
  ///
  /// An exec channel's shell is not a login shell, so its PATH lacks what a
  /// profile adds — the same trouble tmux had, and the same answer: PATH,
  /// then where Claude Code's own installer puts it, then the login shell's
  /// PATH, asked with nothing on stdin so whatever a profile prints never
  /// reaches the protocol.
  ///
  /// stderr is folded into stdout because [ChannelCapable.open] carries only
  /// stdout, and without it the host saying Claude is not installed would be
  /// silence. A line that is not an event shows as a notice.
  static String command({
    String? cwd,
    ChatPermission permission = ChatPermission.acceptEdits,
    String? resume,
  }) {
    final start = cwd == null || cwd.trim().isEmpty
        ? ''
        : 'cd ${_shellQuote(cwd)} || exit 1; ';
    final again = resume == null ? '' : ' --resume ${_shellQuote(resume)}';
    // Quoted once for each shell it passes through: the directory and the
    // session for sh, then the whole script for the login shell that runs sh.
    // Splicing a quoted value into an outer '…' closes that quote instead, so
    // the value reached sh bare: a space split the directory, and a $( ) ran.
    final script = '$_findClaude$start'
        r'exec "$c" -p --input-format stream-json --output-format stream-json '
        '--verbose --permission-mode ${permission.flag} '
        '--permission-prompts none$again 2>&1';
    return 'sh -c ${_shellQuote(script)}';
  }

  /// Finds Claude Code into `$c`, or says it is not there and stops.
  static const _findClaude =
      r'ok() { case $1 in /*) [ -x "$1" ];; *) return 1;; esac; }; '
      r'c=$(command -v claude 2>/dev/null); '
      r'ok "$c" || for c in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" '
      r'/opt/homebrew/bin/claude /usr/local/bin/claude "$HOME/.bun/bin/claude"; '
      r'do ok "$c" && break; c=; done; '
      r'ok "$c" || c=$("$SHELL" -lc "command -v claude" </dev/null 2>/dev/null '
      r'| tail -n 1); '
      r'ok "$c" || { echo "Claude Code is not installed on this host (looked on '
      r'PATH, in ~/.local/bin, ~/.claude/local and the usual package managers)"; '
      r'exit 1; }; ';

  /// Wraps a value so the remote shell sees exactly these bytes.
  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", r"'\''")}'";
}
