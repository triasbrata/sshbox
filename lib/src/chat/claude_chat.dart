import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../session/terminal_session.dart';
import '../session/tmux.dart';
import 'chat_ask.dart';
import 'slash_commands.dart';

export 'chat_ask.dart';
export 'slash_commands.dart';

/// How much of a tool's result is kept for the transcript. A `cat` of a large
/// file comes back whole, and every byte of it would sit in memory for as
/// long as the tab is open; what is shown is the head of it, and the rest is
/// counted rather than kept.
const _resultLimit = 4000;

/// One line of the transcript.
sealed class ChatEntry {}

/// Where a message typed into a watched session has got to. Null once the
/// session has recorded it — which is the only thing that makes it sent.
enum Delivery {
  /// Being typed into the session.
  sending,

  /// Recorded by the session as waiting behind the turn it is running.
  queued,

  /// Not delivered; [ChatSaid.why] says why.
  failed,
}

/// What the user typed, or what Claude answered.
class ChatSaid extends ChatEntry {
  ChatSaid(this.text, {required this.mine});

  final String text;

  /// Whose turn it was: the user's, or Claude's.
  final bool mine;

  /// For a message typed into a session being watched, until that session has
  /// recorded it.
  Delivery? delivery;

  /// Why it was not delivered, when [delivery] is [Delivery.failed].
  String? why;
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

/// A turn in flight, for the line under the chat that says the session is
/// working rather than stuck — what Claude Code's own `✶ Zesting… (33s · ↓
/// 1.4k tokens)` says at a terminal.
class ChatProgress {
  const ChatProgress({
    required this.started,
    required this.tokens,
    this.tool,
    this.waitingFor,
  });

  /// When the turn began: the transcript's own time on the line that
  /// started it, so a session picked up mid-turn shows how long it has
  /// really been at it. The host's clock, not this device's.
  final DateTime started;

  /// Output tokens of the turn's messages so far. A transcript gets a
  /// message's line only once the message is whole — measured on 2.1.286 —
  /// so this moves a message at a time, not a token at a time.
  final int tokens;

  /// The tool running now, if any.
  final ChatToolRun? tool;

  /// What the session waits for at its terminal — `permission prompt` — by
  /// what `claude agents` says of it; null while it is working.
  final String? waitingFor;

  /// Seconds as Claude Code's line writes them: `33s`, `2m 5s`, `1h 4m`.
  static String elapsed(Duration time) {
    final s = math.max(0, time.inSeconds);
    if (s < 60) return '${s}s';
    if (s < 3600) return '${s ~/ 60}m ${s % 60}s';
    return '${s ~/ 3600}h ${s % 3600 ~/ 60}m';
  }

  /// Tokens as Claude Code's line writes them: `87`, `1.4k`, `12k`.
  static String count(int tokens) {
    if (tokens < 1000) return '$tokens';
    final k = tokens / 1000;
    return '${k < 10 ? k.toStringAsFixed(1).replaceFirst('.0', '') : k.round()}k';
  }
}

/// A slash command run in the session, as its transcript records it, and
/// what it printed when it runs in the CLI rather than as a prompt.
class ChatCommand extends ChatEntry {
  ChatCommand(this.name, {this.args = ''});

  final String name;
  final String args;
  String? output;
}

/// A question Claude asked with the AskUserQuestion tool, in the transcript:
/// see [ChatAsk]. What it says is Claude's, so it is only ever drawn.
class ChatQuestion extends ChatEntry {
  ChatQuestion(this.ask);

  final ChatAsk ask;
}

/// One line of the session's checklist, as Claude Code's own view lists it:
/// from TaskCreate and TaskUpdate, or TodoWrite's whole list. Host text, so
/// it is drawn and never run.
class ChatTask {
  ChatTask({
    required this.id,
    required this.subject,
    this.activeForm,
    this.status = 'pending',
  });

  final String id;
  String subject;

  /// What it reads as while in progress — `Fixing the bug` for `Fix the bug`.
  String? activeForm;

  /// `pending`, `in_progress` or `completed`.
  String status;

  bool get done => status == 'completed';
  bool get inProgress => status == 'in_progress';

  /// What a row says: the active form while it is being done.
  String get label =>
      inProgress && (activeForm?.trim().isNotEmpty ?? false)
      ? activeForm!.trim()
      : subject.trim();
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

/// One session `claude agents` knows about on the host: a background one
/// started with `--bg`, or an interactive one somebody is typing into.
///
/// Every field here is data from the host, and the name is free text the user
/// typed when they started it — so it is drawn, never run, and the only piece
/// that ever reaches a command is [sessionId], quoted like any other value.
///
/// The shape is what the CLI actually prints, which is not the same for every
/// row: an interactive session has no `id` and no `state`, and a session whose
/// process has gone has no `pid` and no `status`. So everything but the
/// session id is optional here, and [live] reads the one field that says
/// whether the process is still there.
class ClaudeAgent {
  const ClaudeAgent({
    required this.sessionId,
    required this.name,
    required this.cwd,
    required this.kind,
    this.id,
    this.status,
    this.state,
    this.pid,
    this.startedAt,
    this.waitingFor,
    this.pinned = false,
  });

  /// The transcript, and the only thing `--resume` takes.
  final String sessionId;

  /// The short id `claude attach` and `claude stop` take. Background only:
  /// an interactive session has none, which is why none can be attached.
  final String? id;

  final String name;
  final String cwd;

  /// `background`, `interactive`, or whatever a later CLI adds.
  final String kind;

  /// `idle` or `busy` while the process is there; absent once it has gone.
  final String? status;

  /// What a background session is doing, as the CLI puts it: measured
  /// `working` mid-turn, `done` waiting for its next message, `blocked` at a
  /// dialog. An interactive session has none.
  final String? state;

  /// Pinned in `claude agents` on the host. Only a background session can
  /// be: pins are kept by its short [id].
  final bool pinned;

  final int? pid;
  final DateTime? startedAt;

  /// What a session held at a dialog is waiting on, as the CLI puts it —
  /// measured `permission prompt` while a tool waits to be approved. Absent
  /// when nothing is being asked.
  final String? waitingFor;

  /// Whether it is held at a question of Claude's, not a tool to approve.
  /// Measured on 2.1.287: `waitingFor` reads `input needed` for the
  /// AskUserQuestion tool, and for a dialog a tool of its own puts up, and
  /// `permission prompt` for a tool waiting to be approved.
  bool get asking => waitingFor == 'input needed';

  /// What [waitingFor] says in words, for a sentence like "waiting for …":
  /// the CLI's `input needed` is a question waiting for its answer.
  static String? waitingWords(String? waitingFor) =>
      waitingFor == 'input needed' ? 'an answer' : waitingFor;

  String? get waitingText => waitingWords(waitingFor);

  /// Whether the process is still running. Measured against the CLI: a live
  /// session is the one that refuses `-p --resume`, and a finished one is the
  /// one that takes it.
  bool get live => pid != null;

  bool get busy => status == 'busy';

  /// Whether somebody is typing into this one at a terminal.
  bool get interactive => kind == 'interactive';

  /// One row of `claude agents --json`, or null when it carries no session to
  /// resume — a row from a newer CLI that means nothing here is left out
  /// rather than drawn half empty.
  static ClaudeAgent? fromJson(Object? row, {Set<String> pins = const {}}) {
    if (row is! Map<String, dynamic>) return null;
    final sessionId = row['sessionId'];
    if (sessionId is! String || sessionId.isEmpty) return null;
    final started = row['startedAt'];
    return ClaudeAgent(
      sessionId: sessionId,
      id: row['id'] is String ? row['id'] as String : null,
      name: row['name'] is String && (row['name'] as String).trim().isNotEmpty
          ? (row['name'] as String).trim()
          : sessionId,
      cwd: row['cwd'] is String ? row['cwd'] as String : '',
      kind: row['kind'] is String ? row['kind'] as String : 'background',
      status: row['status'] is String ? row['status'] as String : null,
      state: row['state'] is String ? row['state'] as String : null,
      pid: row['pid'] is int ? row['pid'] as int : null,
      startedAt: started is int && started > 0
          ? DateTime.fromMillisecondsSinceEpoch(started)
          : null,
      waitingFor: row['waitingFor'] is String
          ? row['waitingFor'] as String
          : null,
      pinned: row['id'] is String && pins.contains(row['id']),
    );
  }
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
  ClaudeChat({
    required this.open,
    this.openTerminal,
    this.cwd,
    this.deliveryTimeout = const Duration(seconds: 30),
    this.dropGrace = const Duration(seconds: 10),
  });

  /// Starts a command on the host with a terminal of its own — what typing
  /// into a running session goes through, since `claude attach` will not run
  /// without one. Null where the connection cannot give one.
  final Future<CommandChannel> Function(String command)? openTerminal;

  /// How long a message typed into a watched session has, first for the
  /// session to come up to type into and then for it to record the message,
  /// before the chat says it did not arrive.
  final Duration deliveryTimeout;

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

  /// Not final: [loadEarlier] draws an earlier part into a list of its own,
  /// through the same handlers, before it goes in above.
  List<ChatEntry> _entries = [];

  List<ChatEntry> get entries => List.unmodifiable(_entries);

  /// How many of [entries], from the first, [loadEarlier] put there: drawn
  /// above where the chat opened, so the page can grow them upwards without
  /// moving what is on screen.
  int _earlier = 0;

  int get earlier => _earlier;

  /// Where what is shown of the transcript starts, in bytes: everything
  /// before it is only on the host. Zero when the start has been reached,
  /// or the whole transcript was read at once.
  int _shownFrom = 0;

  /// True while the bytes just before [_shownFrom] belong to one event too
  /// large to show, whose start is further back still.
  bool _skipping = false;

  /// How much of the transcript this chat has read, against
  /// [transcriptBudget].
  int _read = 0;

  bool _loadingEarlier = false;

  bool get loadingEarlier => _loadingEarlier;

  /// Whether the transcript goes back further than what is shown.
  bool get hasEarlier => _shownFrom > 0;

  /// Whether [loadEarlier] may read more of it.
  bool get canLoadEarlier => hasEarlier && _read < transcriptBudget;

  /// Tool results read before the part of the transcript holding their
  /// call, by `tool_use_id`: filled in when [loadEarlier] reaches the call,
  /// rather than the call opening to nothing.
  final Map<String, ({String result, bool failed})> _orphans = {};

  /// The questions Claude asked, by the tool call that asked.
  final Map<String, ChatAsk> _asks = {};

  /// The structured answer of a question read before its call was, as with
  /// [_orphans], for when [loadEarlier] reaches the call.
  final Map<String, Object?> _orphanAnswers = {};

  /// Bumped whenever what is shown is thrown away, so an earlier part still
  /// on its way for the old session is dropped rather than drawn into the new.
  int _shown = 0;

  CommandChannel? _channel;
  StreamSubscription<String>? _lines;

  /// Claude's own id for this conversation, from its first event. What a
  /// restart resumes, so changing the permission mode, or coming back after
  /// the connection dropped, keeps everything said so far.
  String? _sessionId;

  String? get sessionId => _sessionId;

  /// The session this chat was picked up from, for the list of sessions to
  /// mark as the one showing.
  String? _pickedFrom;

  String? get pickedFrom => _pickedFrom;

  /// The running session this chat is watching live, or null. While it is
  /// set there is no Claude of this chat's own: what shows is what that
  /// session writes, followed from its transcript as it writes it.
  ClaudeAgent? _watching;

  ClaudeAgent? get watching => _watching;

  /// Why the session being watched cannot be typed into from here, or null
  /// when it can: an interactive one the tmux the tabs use holds no pane of
  /// — see [paneCommand].
  String? _readOnly;

  String? get readOnly => _watching == null ? null : _readOnly;

  CommandChannel? _follower;
  StreamSubscription<String>? _followed;

  /// Set when the follow says the session's process has gone, as against the
  /// channel simply ending with the connection.
  bool _sessionGone = false;

  /// True while this chat has no conversation of its own yet: what is sent
  /// next starts one, as a background session on the host. Where a new tab
  /// starts, and where [newChat] goes back to.
  bool _composing = true;

  bool get composing => _composing;

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

  /// The tool calls still waiting for their result, by `tool_use_id`. Not
  /// final, for the same reason as [_entries].
  Map<String, ChatToolRun> _running = {};

  /// The session's checklist, in the order its tasks were made, by task id.
  /// Rebuilt from the transcript, which holds every TaskCreate, TaskUpdate and
  /// TodoWrite — measured on 2.1.286: a TaskCreate carries no id, which only
  /// its result gives (`Task #14 created successfully…`), so the call waits in
  /// [_parked] for it. A task made before the part of the transcript read is
  /// not known, and a TaskUpdate naming it is dropped.
  final Map<String, ChatTask> _tasks = {};

  /// Task calls waiting for their result, by `tool_use_id`: Claude Code's own
  /// view changes only when the tool succeeded, so nothing is applied before
  /// its result says so.
  final Map<String, ({String name, Map<String, dynamic> input})> _parked = {};

  /// The tasks still to do or being done, for the list under the working
  /// line, in order. Completed ones are only counted, by [tasksDone].
  List<ChatTask> get openTasks => [
    for (final task in _tasks.values)
      if (!task.done) task,
  ];

  int get tasksDone => _tasks.values.where((task) => task.done).length;

  void _noteTaskCall(String name, Map<String, dynamic> input, String id) {
    if (_pastOnly || !const {'TaskCreate', 'TaskUpdate', 'TodoWrite'}.contains(name)) {
      return;
    }
    _parked[id] = (name: name, input: input);
  }

  /// A tool result: the one that lets a parked task call take effect, and, for
  /// a TaskCreate, tells it its id.
  void _noteTaskResult(Object? toolUseId, String result, bool failed) {
    final call = _parked.remove(toolUseId);
    if (call == null || failed || _pastOnly) return;
    final input = call.input;
    String? text(String key) => input[key] is String ? input[key] as String : null;
    switch (call.name) {
      case 'TaskCreate':
        final subject = text('subject');
        final id = RegExp(r'^Task #(\d+) created').firstMatch(result)?.group(1);
        if (subject == null || id == null) return;
        _tasks[id] = ChatTask(
          id: id,
          subject: subject,
          activeForm: text('activeForm'),
        );
      case 'TaskUpdate':
        final task = _tasks[text('taskId')];
        if (task == null) return;
        switch (text('status')) {
          case 'deleted':
            _tasks.remove(task.id);
            return;
          case final status? when const {
            'pending',
            'in_progress',
            'completed',
          }.contains(status):
            task.status = status;
        }
        task.subject = text('subject') ?? task.subject;
        task.activeForm = text('activeForm') ?? task.activeForm;
      case 'TodoWrite':
        final todos = input['todos'];
        if (todos is! List) return;
        // The whole list every time.
        _tasks.clear();
        for (final (i, todo) in todos.indexed) {
          if (todo is! Map || todo['content'] is! String) continue;
          _tasks['todo-$i'] = ChatTask(
            id: 'todo-$i',
            subject: todo['content'] as String,
            activeForm: todo['activeForm'] is String
                ? todo['activeForm'] as String
                : null,
            status: const {'pending', 'in_progress', 'completed'}.contains(
                  todo['status'],
                )
                ? todo['status'] as String
                : 'pending',
          );
        }
    }
  }

  /// When the turn in flight began, or null between turns.
  DateTime? _turnStart;

  /// Output tokens of the turn in flight, by message id: every content block
  /// of a message gets a transcript line of its own, each repeating the
  /// message's whole usage, so a message is counted once.
  final Map<String, int> _turnTokens = {};

  /// What the watched session waits for, from the listing: see [checkState].
  String? _waitingFor;

  /// Set while [loadEarlier] replays older turns, which are history and say
  /// nothing about the turn in flight.
  bool _pastOnly = false;

  /// The turn in flight, or null when there is none — idle, or not begun.
  ChatProgress? get progress {
    final started = _turnStart;
    if (started == null) return null;
    return ChatProgress(
      started: started,
      tokens: _turnTokens.values.fold(0, (sum, n) => sum + n),
      tool: _running.values.lastOrNull,
      waitingFor: _watching == null ? null : _waitingFor,
    );
  }

  void _startTurn(Object? timestamp) {
    if (_pastOnly || _turnStart != null) return;
    _turnStart =
        (timestamp is String ? DateTime.tryParse(timestamp) : null) ??
        DateTime.now();
    _turnTokens.clear();
    // What the last turn waited for, or was seen idle after, is not this
    // one's.
    _waitingFor = null;
    _seenIdle = false;
  }

  void _endTurn() {
    if (_pastOnly) return;
    _turnStart = null;
    _turnTokens.clear();
    _waitingFor = null;
    _seenIdle = false;
  }

  /// What an assistant line says of the turn: its tokens, and whether it is
  /// the turn's last message. A line read with no turn open — the history cut
  /// into one — opens it at its own time, the nearest there is.
  void _onAssistantTurn(Map<String, dynamic> event) {
    final message = event['message'];
    if (_pastOnly || message is! Map<String, dynamic>) return;
    final stop = message['stop_reason'];
    if (stop is String && stop != 'tool_use') return _endTurn();
    _startTurn(event['timestamp']);
    final usage = message['usage'];
    final id = message['id'];
    final tokens = usage is Map ? usage['output_tokens'] : null;
    if (id is String && tokens is int) _turnTokens[id] = tokens;
  }

  bool _checking = false;

  /// The last look found the session idle: see [checkState].
  bool _seenIdle = false;

  /// Asks the host what the watched session is doing now, for what the
  /// transcript cannot tell: a tool call waiting at a permission prompt
  /// looks, there, just like one still running. The page asks this every
  /// few seconds while a turn is open and the chat is on screen. Anything
  /// going wrong costs only this look.
  Future<void> checkState() async {
    final watching = _watching;
    final turn = _turnStart;
    if (watching == null || turn == null || _checking) return;
    _checking = true;
    try {
      final now = (await agents())
          .where((row) => row.sessionId == watching.sessionId)
          .firstOrNull;
      // The turn looked at may have ended, and another begun, meanwhile.
      if (_watching != watching || _turnStart != turn) return;
      if (now == null || !now.live) return;
      _waitingFor = now.waitingFor;
      // Idle with nothing to wait for, twice running: the turn's end was
      // missed, so it stops spinning rather than spinning for ever. Twice,
      // since a turn just typed into is idle for a moment before the
      // listing catches up.
      final idle = now.status == 'idle' && now.waitingFor == null;
      if (idle && _seenIdle) _endTurn();
      _seenIdle = idle && _turnStart != null;
      notifyListeners();
    } catch (_) {
      // Disconnected, or the host could not list them: the next look.
    } finally {
      _checking = false;
    }
  }

  /// Starts Claude on the host. Safe to call again: a chat already up, or on
  /// its way up, stays as it is.
  Future<void> start() async {
    if (_starting || _ready) return;
    // A Claude of this chat's own: its messages go to it, not into a new
    // session.
    _composing = false;
    _starting = true;
    _ended = false;
    notifyListeners();
    try {
      final channel = await open(
        command(cwd: cwd, permission: _permission, resume: _sessionId),
      );
      // The tab closed while the host answered: nothing is left to hold it.
      if (_disposed) {
        channel.close();
        return;
      }
      _retarget();
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

  /// Sends a message and waits for the turn it starts. Before this chat has
  /// a conversation, the message starts one, and what this returns settles
  /// once it has started, or failed to.
  Future<void> send(String text) async {
    final message = text.trim();
    if (message.isEmpty) return;
    final why = unsendable;
    if (why != null) {
      // Said where the user is looking, with what they wrote, so a message
      // that cannot go is never lost without a word.
      _say(ChatNotice('Not sent: $why What you wrote: “${_excerpt(message)}”',
          failed: true));
      return;
    }
    final watching = _watching;
    if (watching != null) {
      _typeInto(watching, message);
      return;
    }
    if (_composing) {
      await _startInBackground(message);
      return;
    }
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
    _startTurn(null);
    notifyListeners();
  }

  /// Why a message cannot go anywhere now, or null when it can: what
  /// disables the box's Send, and what [send] says when it is called anyway.
  /// A watched session is typed into message by message, each of which says
  /// for itself if it did not arrive.
  String? get unsendable {
    if (_disposed) return 'This chat is closed.';
    if (_watching != null) return null;
    if (_composing) return _busy ? 'A new chat is starting.' : null;
    if (_starting) return 'Claude is starting on the host.';
    if (!_ready) {
      return 'Claude is not running on the host. Restart it from the menu '
          'beside the box.';
    }
    if (_busy) return 'Claude is still answering.';
    return null;
  }

  /// [text] shortened to what a notice can hold.
  static String _excerpt(String text) =>
      text.length > 200 ? '${text.substring(0, 200)}…' : text;

  /// Sends [said], a message that was not delivered, again — to what this
  /// chat writes to now, through [send], which is the one way in, and so
  /// never to a process or session that has been replaced. Null when it was
  /// handed over, and why not otherwise, with the failed message left as it
  /// is.
  String? retry(ChatSaid said) {
    if (said.delivery != Delivery.failed || !_entries.contains(said)) {
      return 'That message is no longer here to send again.';
    }
    final why = unsendable;
    if (why != null) return why;
    _entries.remove(said);
    notifyListeners();
    unawaited(send(said.text));
    return null;
  }

  /// Drops [said], a message that was not delivered, from the chat.
  void remove(ChatSaid said) {
    if (said.delivery != Delivery.failed) return;
    if (_entries.remove(said)) notifyListeners();
  }

  /// Starts Claude again, resuming the same conversation when it got far
  /// enough to have one. What a changed permission mode needs, since the
  /// mode is fixed when the process starts, and what a dropped connection
  /// needs once the session is back.
  Future<void> restart({ChatPermission? permission}) async {
    if (permission != null) _permission = permission;
    // Watching runs no Claude of its own to restart: follow it afresh.
    final watching = _watching;
    if (watching != null) return continueFrom(watching);
    // Nothing is running yet: the mode goes with the first message.
    if (_composing) return notifyListeners();
    await _stop();
    _busy = false;
    _ended = false;
    await start();
  }

  /// What `claude agents` can see on the host: the sessions running there,
  /// background and interactive alike, and with [all] the background ones
  /// that have finished too — which [continueFrom] continues in place, since
  /// the CLI resumes a session once its process has gone.
  ///
  /// In the order the sidebar shows them: pinned ones first, in the order
  /// they were pinned — the order the file keeps them in — then the ones
  /// running, then the finished ones, each newest first. `startedAt` is the
  /// one time every row carries; a finished row says nothing of when it
  /// ended.
  ///
  /// Throws with what the host said when it could not list them — an old
  /// Claude Code with no `agents` command, or none installed at all.
  Future<List<ClaudeAgent>> agents({bool all = false}) async {
    final channel = await open(agentsCommand(all: all));
    final String output;
    try {
      output = await utf8.decoder.bind(channel.output).join();
    } finally {
      channel.close();
    }
    // The listing, then the pins after a line of their own: see
    // [agentsCommand].
    final cut = output.indexOf(_pinsMark);
    final text = cut < 0 ? output : output.substring(0, cut);
    final pins = cut < 0 ? const <String>[] : _pinsIn(output.substring(cut));
    final rows = _arrayIn(text);
    if (rows == null) {
      throw SshSessionException(
        text.trim().isEmpty
            ? 'The host said nothing about its Claude sessions.'
            : text.trim(),
      );
    }
    final agents = [
      for (final row in rows) ?ClaudeAgent.fromJson(row, pins: pins.toSet()),
    ];
    int group(ClaudeAgent agent) => agent.pinned
        ? pins.indexOf(agent.id!)
        : pins.length + (agent.live ? 0 : 1);
    int started(ClaudeAgent agent) =>
        agent.startedAt?.millisecondsSinceEpoch ?? 0;
    // List.sort is not stable, so ties keep the CLI's order by its index.
    final ordered = agents.indexed.toList()
      ..sort((a, b) {
        final byGroup = group(a.$2).compareTo(group(b.$2));
        if (byGroup != 0) return byGroup;
        final byAge = started(b.$2).compareTo(started(a.$2));
        return byAge != 0 ? byAge : a.$1.compareTo(b.$1);
      });
    return [for (final (_, agent) in ordered) agent];
  }

  /// The slash commands a session on the host takes, for the list that
  /// opens at a `/` in the box: see [SlashCommand]. Throws with what the
  /// host said when it gave no list.
  Future<List<SlashCommand>> slashCommands() async {
    final output = const Utf8Decoder(allowMalformed: true).convert(
      await _readAll(
        slashCommandsCommand(cwd: cwd),
        const Duration(seconds: 30),
      ),
    );
    final commands = SlashCommand.parse(output);
    if (commands != null) return commands;
    final said = output.trim();
    throw SshSessionException(
      said.isEmpty ? 'The host listed no slash commands.' : said,
    );
  }

  /// What the host runs to list its slash commands: the SDK's `initialize`
  /// control request on stdin of a `claude -p` that ends when stdin does —
  /// it asks the model nothing and writes no transcript — in [cwd], where a
  /// project's own commands are; only the line answering it is kept, the
  /// hooks' output beside it being no business of this. Then, after a line
  /// of their own, the user's command files, which tell their commands from
  /// skills. Found and quoted as [command] does it.
  static String slashCommandsCommand({String? cwd}) {
    final start = cwd == null || cwd.trim().isEmpty
        ? ''
        : 'cd ${_shellQuote(cwd)} || exit 1; ';
    final request = jsonEncode({
      'type': 'control_request',
      'request_id': 'sshbox-commands',
      'request': {'subtype': 'initialize'},
    });
    return 'sh -c ${_shellQuote('$_findClaude$start'
    'printf "%s\\n" ${_shellQuote(request)} | "\$c" -p '
    '--input-format stream-json --output-format stream-json --verbose '
    '2>/dev/null | grep -F control_response; '
    r'printf "\n--- yours\n"; '
    r'find "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/commands" .claude/commands '
    "-name '*.md' 2>/dev/null")}';
  }

  /// The line between the listing and the pins.
  static const _pinsMark = '\n--- pins\n';

  /// The short ids pinned on the host, from `jobs/pins.json`: a JSON array of
  /// strings. Missing, unreadable or not an array means nothing is pinned —
  /// never an error, since nobody may have pinned anything yet.
  static List<String> _pinsIn(String text) {
    try {
      final parsed = jsonDecode(text.replaceFirst(_pinsMark, '').trim());
      if (parsed is List) return parsed.whereType<String>().toList();
    } catch (_) {
      // No pins file, or not one this can read.
    }
    return const [];
  }

  /// The JSON array in [text], or null when there is none.
  ///
  /// stderr is folded into stdout, so a warning from the host, or a line a
  /// profile printed, can sit beside the array; the array is taken from the
  /// first `[` to the last `]` when the whole text will not parse.
  static List<Object?>? _arrayIn(String text) {
    for (final candidate in [
      text.trim(),
      if (text.contains('[') && text.lastIndexOf(']') > text.indexOf('['))
        text.substring(text.indexOf('['), text.lastIndexOf(']') + 1),
    ]) {
      try {
        final parsed = jsonDecode(candidate);
        if (parsed is List) return parsed;
      } catch (_) {
        // Not this one; try the array inside it.
      }
    }
    return null;
  }

  /// Picks up [agent] in this chat, with what it has already said.
  ///
  /// A session whose process is still running is watched: its transcript is
  /// followed as it grows, so what it goes on to do shows here as it does it,
  /// and nothing is started or branched off — the CLI refuses to resume a
  /// live session, and a copy would be a different conversation from the one
  /// being watched. A session that has finished is continued in place.
  ///
  /// ponytail: never `claude stop`, which would end somebody's session from a
  /// tap on a phone.
  ///
  /// [waitForTranscript] gives a session this chat has just started a few
  /// seconds to write its first line.
  Future<void> continueFrom(
    ClaudeAgent agent, {
    bool waitForTranscript = false,
  }) async {
    await _reset();
    _composing = false;
    _sessionId = agent.sessionId;
    _pickedFrom = agent.sessionId;
    final pid = agent.pid;
    final read = await _loadHistory(
      agent.sessionId,
      keepRunning: pid != null,
      wait: waitForTranscript,
    );
    if (_disposed) return;
    if (pid != null) {
      // Unreadable, it has said why; with nothing to follow from, nothing is
      // started either.
      if (read == null) return;
      final pane = agent.interactive ? await _findPane(agent, pid) : null;
      if (_disposed) return;
      _retarget();
      _watching = agent;
      _waitingFor = agent.waitingFor;
      _say(
        ChatNotice(
          !agent.interactive
              ? 'Watching “${agent.name}” live: what it does on the host '
                    'shows here as it happens, and what you send goes into it.'
              : pane != null
              ? 'Watching “${agent.name}” live: it runs at a terminal on the '
                    'host, in tmux pane $pane, and what you send is typed '
                    'into that pane — only while it is waiting for a '
                    'message, never into a question it is asking there.'
              : 'Watching “${agent.name}” live, read-only: $_readOnly What '
                    'it does shows here as it happens; to type into it, use '
                    'that terminal.',
        ),
      );
      await _follow(agent, pid: pid, from: read.from, carry: read.carry);
      return;
    }
    _say(ChatNotice('Continuing “${agent.name}”.'));
    await start();
  }

  /// Leaves whatever this chat shows for a new conversation, which the next
  /// message starts. Nothing is lost by it: a session being watched carries
  /// on untouched on the host, and one continued here is still listed there
  /// under its own id, with everything said in it.
  Future<void> newChat() async {
    await _reset();
    _sessionId = null;
    _pickedFrom = null;
    _composing = true;
    notifyListeners();
  }

  Future<void> _reset() async {
    // What was typed for the session being left and not recorded yet: its
    // entry goes with the rest of the view, so it is said again, once the
    // view is new, where the user will see it.
    final unsent = [..._pending];
    final leaving = _watching;
    await _stop();
    // Those still in the view as it goes: a message the session recorded in
    // the meantime has been replaced there by its own line, and was sent.
    final gone = [
      for (final said in unsent)
        if (_entries.contains(said)) said,
    ];
    _entries.clear();
    _running.clear();
    _orphans.clear();
    _asks.clear();
    _orphanAnswers.clear();
    _tasks.clear();
    _parked.clear();
    _shown++;
    _earlier = 0;
    _shownFrom = 0;
    _skipping = false;
    _read = 0;
    _loadingEarlier = false;
    _busy = false;
    _ended = false;
    _watching = null;
    _readOnly = null;
    _pending.clear();
    _endTurn();
    for (final said in gone) {
      _toldGone.add(said);
      _say(ChatNotice(
        leaving == null
            ? 'Not sent: you moved to another session before it was '
                  'delivered. What you wrote: “${_excerpt(said.text)}”'
            : 'Not sent to “${leaving.name}”: you moved to another session '
                  'before it was delivered. What you wrote: '
                  '“${_excerpt(said.text)}”',
        failed: true,
      ));
    }
  }

  /// Messages [_reset] has already said were not sent, so [_movedOn] does
  /// not say it twice.
  final Set<ChatSaid> _toldGone = {};

  /// The tmux pane [agent], an interactive session, runs in — or null, with
  /// [_readOnly] saying why it cannot be typed into.
  Future<String?> _findPane(ClaudeAgent agent, int pid) async {
    final String answer;
    try {
      answer = utf8.decode(
        await _readAll(
          paneCommand(agent.sessionId, pid: pid),
          const Duration(seconds: 20),
        ),
        allowMalformed: true,
      );
    } catch (error) {
      _readOnly = 'where it runs could not be found out ($error), so it is '
          'not typed into from here.';
      return null;
    }
    final pane = RegExp(
      r'^sshbox:pane (%\d+)$',
      multiLine: true,
    ).firstMatch(answer)?.group(1);
    if (pane != null) return pane;
    final why = answer.trim();
    _readOnly = why.startsWith('sshbox:no ') || why.isEmpty
        ? 'it runs in a terminal outside tmux, or in a tmux this app does '
              'not use, so there is no way to type into it from here.'
        // The host's own words: tmux not installed, most likely.
        : 'it is in no tmux pane this app can reach — $why — so there is no '
              'way to type into it from here.';
    return null;
  }

  /// Starts a new conversation on the host as a background session, with
  /// [message] as its first, and watches it as any running session is
  /// watched: so it is listed with the others, can be pinned, carries on
  /// when the app closes, and is found again in the list. A chat started
  /// any other way, as a `claude -p` of this app's own, is listed only while
  /// its process lives, and would be lost from here the moment it ended.
  ///
  /// The first message goes on the command line rather than being typed in,
  /// so it arrives in one round trip and is never taken for a paste.
  Future<void> _startInBackground(String message) async {
    final said = ChatSaid(message, mine: true)..delivery = Delivery.sending;
    _busy = true;
    _say(said);
    try {
      final channel = await open(
        backgroundCommand(message, cwd: cwd, permission: _permission),
      );
      final String output;
      try {
        output = await utf8.decoder
            .bind(channel.output)
            .join()
            .timeout(const Duration(seconds: 60));
      } finally {
        channel.close();
      }
      final id = backgroundId(output);
      if (id == null) {
        final why = _plain(output).trim();
        throw SshSessionException(
          why.isEmpty ? 'The host started no session.' : why,
        );
      }
      // The tab closed while `--bg` answered: the session carries on, listed
      // on the host, and nothing more is asked of it from here.
      if (_disposed) return;
      // Listed the moment `--bg` returns, measured; a slow host gets a few
      // more looks.
      ClaudeAgent? agent;
      for (var look = 0; look < 5 && agent == null; look++) {
        if (look > 0) await Future<void>.delayed(const Duration(seconds: 1));
        agent = (await agents()).where((row) => row.id == id).firstOrNull;
      }
      if (agent == null) {
        throw SshSessionException(
          'It started as $id, but `claude agents` does not list it. Open it '
          'in a terminal with `claude attach $id`.',
        );
      }
      // Something else was picked meanwhile, or the tab closed: the new
      // session stays on the host, in the list, and this chat shows what was
      // picked, if anything.
      if (!_composing || _disposed) return;
      _busy = false;
      await continueFrom(agent, waitForTranscript: true);
    } catch (error) {
      said
        ..delivery = Delivery.failed
        ..why = 'Not started: $error';
    } finally {
      if (_composing) _busy = false;
      notifyListeners();
    }
  }

  /// What the page does when the connection comes (back): a watched session
  /// is picked up again — its follow went with the old connection — one
  /// continued here is started again, or restarted if it had ended, and a
  /// chat not yet begun waits for its first message.
  Future<void> resume() async {
    final watching = _watching;
    if (watching != null) return continueFrom(watching);
    if (_composing) return;
    return _ended ? restart() : start();
  }

  /// Follows [agent]'s transcript from byte [from], starting with [carry] —
  /// the start of a line the history read stopped in the middle of, which the
  /// follow's first bytes finish.
  Future<void> _follow(
    ClaudeAgent agent, {
    required int pid,
    required int from,
    required List<int> carry,
  }) async {
    if (_disposed) return;
    final CommandChannel channel;
    try {
      channel = await open(
        followCommand(agent.sessionId, from: from, pid: pid),
      );
    } catch (error) {
      _say(ChatNotice('It could not be followed live: $error', failed: true));
      return;
    }
    // The tab closed while the host answered: the tail is ended at once.
    if (_disposed) {
      channel.close();
      return;
    }
    _follower = channel;
    _sessionGone = false;
    Stream<List<int>> bytes() async* {
      if (carry.isNotEmpty) yield carry;
      yield* channel.output;
    }

    _followed = const Utf8Decoder(allowMalformed: true)
        .bind(bytes())
        .transform(const LineSplitter())
        .listen(_onFollowed, onDone: () => _followDone(agent));
  }

  /// One line the watched session wrote, drawn as a live turn is.
  void _onFollowed(String line) {
    final text = line.trim();
    if (text.isEmpty) return;
    if (text == 'sshbox:ended') {
      _sessionGone = true;
      return;
    }
    // Not a transcript line: the host saying why it cannot follow.
    if (!text.startsWith('{')) {
      _say(ChatNotice(text, failed: true));
      return;
    }
    var consumed = false;
    try {
      final event = jsonDecode(text);
      if (event is Map<String, dynamic>) consumed = _confirm(event);
    } catch (_) {
      // Drawn or not by the replay, which reads it again.
    }
    if (!consumed) _replay(text);
    notifyListeners();
  }

  void _followDone(ClaudeAgent agent) {
    _followed = null;
    _follower = null;
    // Not followed, nothing here can tell how the turn goes on.
    _endTurn();
    if (!_sessionGone) {
      _say(
        ChatNotice(
          'Stopped following “${agent.name}”. It picks up again when the '
          'connection is back, or tap it in the list.',
        ),
      );
      return;
    }
    _sessionGone = false;
    _watching = null;
    _retarget();
    // What was in flight when it stopped is history now, not a spinner.
    for (final run in _running.values) {
      run.result = '';
    }
    _running.clear();
    _say(
      ChatNotice(
        '“${agent.name}” is no longer running on the host. What you send '
        'from here now continues it.',
      ),
    );
    // No longer live, so it resumes in place: the same conversation.
    unawaited(start());
  }

  /// Whether [agent] is safe to type into, by what `claude agents` says of
  /// it, every case measured on throwaway sessions:
  /// - `done`, waiting for its next message: taken as the next turn.
  /// - `working`, mid-turn: queued behind the turn and answered after it.
  /// - `blocked` while `idle`, with nothing in `waitingFor`: its turn ended
  ///   on a question for the user, or it was started with no prompt and
  ///   waits for one. What is typed is the answer.
  ///
  /// A session at a dialog is `blocked` too, but `waiting`, with what it is
  /// waiting on in `waitingFor` — `permission prompt` for a tool to approve.
  /// That, a state a later CLI adds, or none at all is refused, since a
  /// keystroke there could answer a prompt nobody meant to answer.
  static bool _typeable(ClaudeAgent agent) => switch (agent.state) {
    'done' || 'working' => true,
    'blocked' => agent.status == 'idle' && agent.waitingFor == null,
    _ => false,
  };

  /// Messages typed into the watched session that it has not recorded yet.
  final List<ChatSaid> _pending = [];

  /// Settled when the session records the message it is keyed by.
  final Map<ChatSaid, Completer<void>> _recorded = {};

  /// One message at a time goes into the session: two attaches typing at
  /// once would interleave their keystrokes.
  Future<void> _typing = Future.value();

  /// Types [message] into [agent], the session being watched, rather than
  /// into a Claude of this chat's own: shown at once as being sent, and as
  /// sent only when the session's own transcript has it.
  void _typeInto(ClaudeAgent agent, String message) {
    final said = ChatSaid(message, mine: true)..delivery = Delivery.sending;
    _pending.add(said);
    _recorded[said] = Completer<void>();
    _say(said);
    // For the session the user is looking at as they send: another picked
    // before it goes in leaves it unsent, see [_movedOn].
    final target = _target;
    final replaced = _replaced.future;
    // Whatever goes wrong, the message says it was not delivered rather than
    // sitting at "sending", and the next one still gets its turn.
    _typing = _typing.then(
      (_) => _deliver(said, agent, target, replaced).catchError(
        (Object error) => _undelivered(said, 'Not delivered: $error'),
      ),
    );
  }

  /// [said] was meant for [agent], and this chat has gone to another session
  /// or process since: it is not typed anywhere. Told where the user now
  /// looks, with what they wrote, since the view it was in may be gone.
  ///
  /// [typed] says it had already been typed into the session's input line,
  /// and only the Enter that sends it was held back.
  void _movedOn(ChatSaid said, ClaudeAgent agent, {bool typed = false}) {
    final name = '“${agent.name}”';
    _undelivered(
      said,
      typed
          ? 'Typed into $name but not sent: this chat moved off it first. It '
                'is in its input line at the terminal.'
          : 'Not sent: this chat moved off $name first.',
    );
    if (_disposed) return;
    // Said by [_reset] already, unless this adds what it could not know: that
    // the text was typed into the session's input line.
    if (_toldGone.remove(said) && !typed) return;
    if (_entries.contains(said) && !typed) return;
    _say(ChatNotice(
      typed
          ? 'Typed into $name but not sent: you moved to another session '
                'first. It is in its input line at the terminal. What you '
                'wrote: “${_excerpt(said.text)}”'
          : 'Not sent to $name: you moved to another session before it was '
                'delivered. What you wrote: “${_excerpt(said.text)}”',
      failed: true,
    ));
  }

  Future<void> _deliver(
    ChatSaid said,
    ClaudeAgent agent,
    int target,
    Future<void> replaced,
  ) async {
    // What it is doing now, not what the list said when it was picked.
    final ClaudeAgent? now;
    try {
      now = (await agents())
          .where((row) => row.sessionId == agent.sessionId)
          .firstOrNull;
    } catch (error) {
      return _undelivered(said, 'Could not check on it first: $error');
    }
    if (!_current(target)) return _movedOn(said, agent);
    if (now == null || !now.live) {
      return _undelivered(said, '“${agent.name}” is no longer running.');
    }
    if (now.interactive) return _typeIntoPane(said, agent, now, target);
    final openTerminal = this.openTerminal;
    if (openTerminal == null) {
      return _undelivered(said, 'This connection cannot open a terminal on '
          'the host, which typing into a session needs.');
    }
    final id = now.id;
    if (id == null) {
      return _undelivered(said, 'This session has no id that can be '
          'attached to.');
    }
    if (!_typeable(now)) {
      return _undelivered(said, '“${agent.name}” is waiting for '
          '${now.waitingText ?? 'something'} on the host'
          '${now.state == null ? '' : ' (${now.state})'}. Open it in a '
          'terminal with `claude attach $id` to answer it.');
    }
    if (!_sessionIdShape.hasMatch(id)) {
      return _undelivered(said, 'This session has no id that can be '
          'attached to.');
    }
    final CommandChannel terminal;
    try {
      terminal = await openTerminal(attachCommand(id));
    } catch (error) {
      return _undelivered(said, 'Could not open it on the host: $error');
    }
    final drawn = Completer<void>();
    final screen = const Utf8Decoder(allowMalformed: true)
        .bind(terminal.output)
        .listen(
          (chunk) {
            // Its input line: the TUI is up and a paste lands in it.
            if (chunk.contains('❯') && !drawn.isCompleted) drawn.complete();
          },
          onDone: () {
            if (!drawn.isCompleted) drawn.completeError('closed');
          },
          onError: (Object _) {},
        );
    try {
      try {
        // Until its input line is drawn, or the chat moves on: an attach to
        // a session nobody is looking at is not held for the timeout.
        await Future.any([drawn.future, replaced]).timeout(deliveryTimeout);
      } catch (_) {
        return _undelivered(said, '“${agent.name}” did not come up to type '
            'into. Open it in a terminal with `claude attach $id`.');
      }
      if (!_current(target)) return _movedOn(said, agent);
      // A moment for the rest of the screen to settle under the prompt.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!_current(target)) return _movedOn(said, agent);
      terminal.write(Uint8List.fromList(utf8.encode(_keystrokes(said.text))));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      // Typed, and the chat has moved on since: not sent with Enter, which
      // would answer in a session nobody is looking at.
      if (!_current(target)) return _movedOn(said, agent, typed: true);
      terminal.write(Uint8List.fromList(const [13]));
      // Sent only once the session has it: recorded as its next turn, or
      // queued behind the one it is running.
      try {
        await _recorded[said]!.future.timeout(deliveryTimeout);
      } on TimeoutException {
        _undelivered(said, 'Not delivered: “${agent.name}” did not record it '
            'within ${deliveryTimeout.inSeconds} s. It may be waiting for '
            'something on the host — open it in a terminal with '
            '`claude attach $id` to see.');
      }
    } finally {
      await screen.cancel();
      // The attach goes; the session keeps running either way.
      terminal.close();
    }
  }

  /// Types [said] into the tmux pane [agent], an interactive session, runs
  /// in: the way in that a terminal somebody typed `claude` into has, the
  /// CLI giving it no id to attach to. [now] is what `claude agents` says of
  /// it this moment; the host checks again right before each keystroke, see
  /// [paneCommand].
  ///
  /// ponytail: only between turns. Mid-turn a permission prompt can come up
  /// at any moment, and a digit alone answers one, so a message sent then is
  /// refused rather than queued; queue it here and send it when the turn
  /// ends, if refusing proves a nuisance.
  Future<void> _typeIntoPane(
    ChatSaid said,
    ClaudeAgent agent,
    ClaudeAgent now,
    int target,
  ) async {
    final name = '“${agent.name}”';
    final readOnly = _readOnly;
    if (readOnly != null) return _undelivered(said, 'Not typed: $readOnly');
    final waitingFor = now.waitingFor;
    if (waitingFor != null) {
      return _undelivered(said, '$name is waiting for ${now.waitingText} at '
          'its terminal. Answer it there, then send this again.');
    }
    if (now.status != 'idle') {
      return _undelivered(said, '$name is in the middle of a turn. Send this '
          'again once it has finished: typed now, it could land in a '
          'question the turn asks at its terminal.');
    }
    // Taken now: the session can record it before the host has finished
    // saying it typed it, and recording it lets this go.
    final recorded = _recorded[said]?.future;
    final keys = Uint8List.fromList(utf8.encode(_keystrokes(said.text)));
    final String answer;
    try {
      final channel = await open(
        paneCommand(agent.sessionId, pid: now.pid!, typing: keys.length),
      );
      try {
        // Opened, and the chat moved on meanwhile: nothing is written, so the
        // host's script gets no keys and types none.
        if (!_current(target)) {
          _movedOn(said, agent);
          return;
        }
        channel.write(keys);
        answer = await utf8.decoder
            .bind(channel.output)
            .join()
            .timeout(const Duration(seconds: 30));
      } finally {
        channel.close();
      }
    } catch (error) {
      return _undelivered(said, 'Not delivered: $error');
    }
    if (!RegExp(r'^sshbox:typed ', multiLine: true).hasMatch(answer)) {
      final code = RegExp(
        r'^sshbox:no (\w+)',
        multiLine: true,
      ).firstMatch(answer)?.group(1);
      final why = switch (code) {
        'terminal' || 'pane' => '$name is no longer in a tmux pane here.',
        'gone' => '$name is no longer running.',
        'busy' => '$name has started a turn, or is asking something at its '
            'terminal. Send this again once it is waiting for a message.',
        'foreground' => 'Something is in front of $name in its pane: it is '
            'suspended, or another program runs there. Bring it back at that '
            'terminal first.',
        'dialog' => '$name is showing a question or a picker at its '
            'terminal. Answer it there first.',
        'draft' => 'Something is typed into $name at its terminal and not '
            'sent yet. Send or clear it there first, so the two do not go '
            'as one.',
        _ => answer.trim().isEmpty
            ? 'The host said nothing.'
            : 'tmux would not take it: ${answer.trim()}',
      };
      return _undelivered(
        said,
        answer.contains('sshbox:pasted')
            ? 'Typed into $name but not sent — $why It is in its input line '
                  'at the terminal.'
            : 'Not typed: $why',
      );
    }
    try {
      await recorded?.timeout(deliveryTimeout);
    } on TimeoutException {
      _undelivered(said, 'Not delivered: $name did not record it within '
          '${deliveryTimeout.inSeconds} s. Look at its terminal to see why.');
    }
  }

  void _undelivered(ChatSaid said, String why) {
    said
      ..delivery = Delivery.failed
      ..why = why;
    _pending.remove(said);
    final recorded = _recorded.remove(said);
    if (recorded != null && !recorded.isCompleted) recorded.complete();
    if (!_disposed) notifyListeners();
  }

  /// Up to this many characters are typed into the session as keys; more
  /// are pasted. Measured on 2.1.277: 695 characters written at once went in
  /// as typed, and 1868 were taken for a paste.
  static const _typedLimit = 600;

  /// What goes into the session's input line for [text].
  ///
  /// Typed, not pasted, when it is short enough to be taken for typing:
  /// from 2.1.277 the CLI records a paste as `<pasted_content>`, and Claude
  /// reads a message that is nothing but pasted text as something to ask
  /// about before following — measured, it answered "Should I follow it?"
  /// where the same words typed were simply done. Typed, a newline is
  /// Ctrl+J, which the input line takes as a new line (measured), and a tab
  /// becomes spaces, since Tab there takes a suggestion. A `!` first
  /// switches the input to bash mode and runs the rest as a shell command on
  /// the host — measured, even in plan mode — so a space goes before it,
  /// which keeps it a message (measured too).
  ///
  /// ponytail: longer than [_typedLimit] it is still a paste, which Claude
  /// may ask about first; typing it in pieces was tried, and a 1.8 KB message
  /// in 200-character pieces never arrived at all.
  static String _keystrokes(String text) {
    final clean = _pasteable(text);
    if (clean.length > _typedLimit) return '\x1b[200~$clean\x1b[201~';
    final typed = clean.replaceAll('\t', '  ');
    return typed.startsWith('!') ? ' $typed' : typed;
  }

  /// Text as it may go into a paste: no escape, and no control but a newline
  /// or a tab. A paste ends at `ESC[201~`, so an escape left in it would end
  /// it early and let the rest be read as keys; the C1 controls go too, since
  /// some terminals read U+009B as an escape sequence of its own.
  static String _pasteable(String text) =>
      text.replaceAll(RegExp(r'[\x00-\x08\x0b-\x1f\x7f-\x9f]'), '');

  /// What the session writing [event] says about a message typed into it:
  /// that it has taken it as a turn, or queued it behind the one it is on.
  ///
  /// True when the line is that message's delivery and nothing more, so it is
  /// not drawn again as a turn of the user's: a `queued_command`.
  bool _confirm(Map<String, dynamic> event) {
    if (_pending.isEmpty) return false;
    final String? text;
    var queued = false;
    var delivered = false;
    switch (event['type']) {
      case 'queue-operation' when event['operation'] == 'enqueue':
        text = event['content'] as String?;
        queued = true;
      case 'queue-operation' when event['operation'] == 'remove':
        // Off the queue: delivered next, or dropped. Which, the record that
        // follows says; none within the timeout is a drop. See [_dequeued].
        _dequeued();
        return false;
      case 'attachment':
        // How a message sent while the session is mid-turn is recorded once
        // it is delivered into that turn: not as a user line, but as this.
        final attachment = event['attachment'];
        if (attachment is Map<String, dynamic> &&
            attachment['type'] == 'queued_command' &&
            attachment['prompt'] is String) {
          text = (attachment['prompt'] as String).replaceAll(_pasteTag, '');
          delivered = true;
        } else {
          text = null;
        }
      case 'user' when event['isMeta'] != true:
        final message = event['message'];
        text = message is Map<String, dynamic>
            ? _commandOrText(_userText(message['content']))
            : null;
      case 'system' when event['subtype'] == 'local_command':
        text = _commandOrText(event['content'] as String?);
      default:
        text = null;
    }
    if (text == null) return false;
    final key = _normal(text);
    // What reached the session is what was sent less what [_pasteable] took
    // out, so that is what is compared.
    final said = _pending
        .where((said) => _normal(_pasteable(said.text)) == key)
        .firstOrNull;
    if (said == null) return false;
    // Either way the session has it, and the attach can go.
    _recorded.remove(said)?.complete();
    if (queued) {
      // Still pending: it moves to where the session puts it once taken.
      said.delivery = Delivery.queued;
      return false;
    }
    if (delivered) {
      // Delivered into the running turn, and shown where it was sent from:
      // no longer waiting.
      _pending.remove(said);
      said
        ..delivery = null
        ..why = null;
      return true;
    }
    // Taken as a turn: the session's own line is drawn in its place, where
    // the session put it.
    _pending.remove(said);
    _entries.remove(said);
    return false;
  }

  /// How long after the queue gave a message up, with no record that it was
  /// delivered, it is taken as dropped.
  final Duration dropGrace;

  /// A message sat in the session's queue and the queue gave it up. It runs
  /// next, which its own record says, or it was dropped. The record of a
  /// delivery follows the removal closely, so a message still queued after
  /// [dropGrace] is taken as dropped, and said not to have arrived.
  void _dequeued() {
    final said = _pending
        .where((said) => said.delivery == Delivery.queued)
        .firstOrNull;
    if (said == null) return;
    late final Timer timer;
    timer = Timer(dropGrace, () {
      _timers.remove(timer);
      if (_disposed || !_pending.contains(said)) return;
      _undelivered(
        said,
        'Not delivered: the session took it off its queue without running '
        'it. It may have been dropped when its turn ended.',
      );
    });
    _timers.add(timer);
  }

  final Set<Timer> _timers = {};

  /// A command line in a transcript as it was typed, `/name args`, so a
  /// command typed from this chat is recognised; any other text as it is.
  static String? _commandOrText(String? text) {
    if (text == null) return null;
    final command = CommandTags.command(text);
    if (command == null) return text;
    return '/${command.name} ${command.args}'.trim();
  }

  static String _normal(String text) =>
      text.trim().replaceAll(RegExp(r'\s+'), ' ');

  Future<void> _stopFollowing() async {
    final followed = _followed;
    final follower = _follower;
    _followed = null;
    _follower = null;
    // Cancelled first, so a follow stopped on purpose says nothing about it.
    await followed?.cancel();
    follower?.close();
  }

  /// What a session id looks like: a UUID, or the short form. Anything else
  /// is not looked for — the id comes from the host, and `find -name` would
  /// read a `*` in it as a pattern however it was quoted.
  static final _sessionIdShape = RegExp(r'^[0-9A-Za-z-]{8,64}$');

  /// Reads the end of [sessionId]'s transcript into the chat, drawn as a live
  /// turn is drawn, and says where it stopped: the byte a follow takes up
  /// from, and the start of a line it cut, which the follow finishes. A
  /// transcript that cannot be read costs its history, never the pick-up: it
  /// says why, and hands back null.
  ///
  /// [keepRunning] leaves a tool call whose result has not come yet
  /// spinning, for a session being followed, whose result is still to come;
  /// otherwise it is history, and marked done.
  Future<({int from, List<int> carry})?> _loadHistory(
    String sessionId, {
    bool keepRunning = false,
    bool wait = false,
  }) async {
    if (!_sessionIdShape.hasMatch(sessionId)) {
      _say(ChatNotice('This session has no id that can be looked up.'));
      return null;
    }
    final Uint8List bytes;
    try {
      bytes = await _readAll(
        historyCommand(sessionId, wait: wait),
        Duration(seconds: wait ? 40 : 20),
      );
    } catch (error) {
      _say(ChatNotice('Its earlier turns could not be read: $error'));
      return null;
    }
    // Malformed allowed: a cut by bytes can land inside a character.
    const text = Utf8Decoder(allowMalformed: true);
    final firstLine = bytes.indexOf(10);
    final size = firstLine < 0
        ? null
        : int.tryParse(latin1.decode(bytes.sublist(0, firstLine)).trim());
    if (size == null) {
      // Not a size: the host saying why there is nothing, as it said it.
      final reason = text.convert(bytes).trim();
      _say(
        ChatNotice(
          reason.isEmpty ? 'Its earlier turns could not be read.' : reason,
        ),
      );
      return null;
    }
    var body = bytes.sublist(firstLine + 1);
    _read = body.length;
    if (size > historyLimit) {
      // Read from the middle of a line; that line is only its end, and
      // [loadEarlier] reads it whole, from where it starts. [hasEarlier]
      // says there is more, for the page to offer it.
      final from = size - body.length;
      final cut = body.indexOf(10);
      if (cut < 0) {
        // All of it one event still being written, bigger than the read.
        body = Uint8List(0);
        _shownFrom = from;
        _skipping = true;
      } else {
        body = body.sublist(cut + 1);
        _shownFrom = from + cut + 1;
      }
    }
    // Only whole lines are drawn; what follows the last one is a line still
    // being written, for the follow to finish.
    final whole = body.lastIndexOf(10) + 1;
    for (final line in const LineSplitter().convert(
      text.convert(body.sublist(0, whole)),
    )) {
      _replay(line);
    }
    if (!keepRunning) {
      for (final run in _running.values) {
        run.result = '';
      }
      _running.clear();
      _endTurn();
    }
    notifyListeners();
    return (from: size, carry: body.sublist(whole));
  }

  /// What [command] prints, whole, once the host closes it. A host that
  /// never closes the channel costs what was being read, not the chat.
  Future<Uint8List> _readAll(String command, Duration timeout) async {
    final channel = await open(command);
    try {
      return await channel.output
          .fold(BytesBuilder(copy: false), (all, chunk) => all..add(chunk))
          .then((all) => all.takeBytes())
          .timeout(timeout);
    } finally {
      channel.close();
    }
  }

  /// Reads the transcript from before what is shown and draws it above,
  /// through the same handlers the history and the follow go through:
  /// [earlierChunk] at a time, going on until something to show turns up or
  /// the start is reached, and never much past [transcriptBudget] in all.
  ///
  /// Every chunk ends where a line starts, so no event is read in halves: a
  /// line a chunk cut into is not drawn from it, and the next chunk ends where
  /// that line starts and reads it whole. One event bigger than a whole chunk
  /// cannot be held that way; it is left out, and the chat says so where it
  /// was.
  ///
  /// Throws with why, when the host could not hand it over.
  Future<void> loadEarlier() async {
    final sessionId = _pickedFrom;
    if (sessionId == null || _loadingEarlier || !canLoadEarlier) return;
    final shown = _shown;
    _loadingEarlier = true;
    notifyListeners();
    final older = <ChatEntry>[];
    // Calls in what is read whose result is not in it, nor in anything read
    // before: still running, for a session being watched.
    final running = <String, ChatToolRun>{};
    var drew = false;
    try {
      while (!drew && canLoadEarlier) {
        final end = _shownFrom;
        final start = math.max(0, end - earlierChunk);
        final body = await _readAll(
          earlierCommand(sessionId, from: start, to: end),
          const Duration(seconds: 30),
        );
        // Another session picked meanwhile: this one's turns are not its.
        if (shown != _shown) return;
        if (body.length != end - start) {
          throw SshSessionException(
            'The transcript is not what it was on the host. Pick the '
            'session again to read it afresh.',
          );
        }
        _read += body.length;
        var lineEnd = body.length;
        if (_skipping) {
          // What follows the last line break is more of the event given up
          // on; before it, lines again.
          lineEnd = body.lastIndexOf(10) + 1;
          if (lineEnd == 0) {
            _shownFrom = start;
            continue;
          }
          _skipping = false;
        }
        final whole = start == 0 ? 0 : body.indexOf(10) + 1;
        if (start > 0 && whole == lineEnd && lineEnd == body.length) {
          // One line, all of this chunk and more before it.
          _skipping = true;
          _shownFrom = start;
          older.insert(
            0,
            ChatNotice(
              'An event bigger than ${earlierChunk ~/ (1024 * 1024)} MB is '
              'left out here; it is on the host.',
            ),
          );
          continue;
        }
        _shownFrom = start + whole;
        final shownEntries = _entries;
        final shownRunning = _running;
        _entries = [];
        _running = running;
        _pastOnly = true;
        try {
          for (final line in const LineSplitter().convert(
            const Utf8Decoder(
              allowMalformed: true,
            ).convert(body.sublist(whole, lineEnd)),
          )) {
            _replay(line);
          }
          drew = _entries.isNotEmpty;
          older.insertAll(0, _entries);
        } finally {
          _entries = shownEntries;
          _running = shownRunning;
          _pastOnly = false;
        }
      }
    } finally {
      if (shown == _shown) {
        if (_watching != null) {
          _running.addAll(running);
        } else {
          for (final run in running.values) {
            run.result = '';
          }
        }
        _entries.insertAll(0, older);
        _earlier += older.length;
        _loadingEarlier = false;
        notifyListeners();
      }
    }
  }

  /// One line of a transcript. Only the conversation is kept: a transcript
  /// is mostly other things — modes, titles, costs, snapshots — and even its
  /// `user` lines are often not the user: a tool's result, which folds into
  /// its call; a line Claude Code put there itself (`isMeta`, or a string
  /// that opens with a tag such as `<task-notification>`); or a subagent's
  /// own exchange (`isSidechain`), which the session's own view leaves out.
  void _replay(String line) {
    final Object? event;
    try {
      event = jsonDecode(line);
    } catch (_) {
      return;
    }
    if (event is! Map<String, dynamic>) return;
    if (event['isMeta'] == true || event['isSidechain'] == true) return;
    final message = event['message'];
    switch (event['type']) {
      case 'assistant':
        _onAssistantTurn(event);
        _onAssistant(message);
      // Written once the turn is over, measured; an assistant line that
      // ends the turn has usually said so already.
      case 'system' when event['subtype'] == 'turn_duration':
        _endTurn();
      case 'attachment':
        _onQueuedCommand(event['attachment']);
      case 'system' when event['subtype'] == 'local_command':
        if (event['content'] case final String text) _onCommandLine(text);
      case 'user' when message is Map<String, dynamic>:
        final said = _userText(message['content']);
        if (said == null) {
          _onToolResults(message, structured: event['toolUseResult']);
          return;
        }
        final text = said.trim();
        if (_onCommandLine(text)) return;
        // ponytail: a message the user typed that itself opens with `<` is
        // taken for one Claude Code wrote, and left out.
        if (text.isEmpty || text.startsWith('<')) return;
        if (text.startsWith('[Request interrupted')) {
          _endTurn();
        } else {
          _startTurn(event['timestamp']);
        }
        _entries.add(
          text.startsWith('[Request interrupted')
              ? ChatNotice('The user interrupted this turn.')
              : ChatSaid(text, mine: true),
        );
    }
  }

  /// A message that was sent while the session was mid-turn, as it is
  /// recorded once delivered into the turn: a turn of the user's, as an
  /// ordinary user line is. Nothing is drawn for one the user did not type
  /// (`humanTurn: false`) or that opens with `<`, a tag Claude Code wrote.
  void _onQueuedCommand(Object? attachment) {
    if (attachment is! Map<String, dynamic> ||
        attachment['type'] != 'queued_command' ||
        attachment['humanTurn'] == false) {
      return;
    }
    final prompt = attachment['prompt'];
    if (prompt is! String) return;
    final text = prompt.replaceAll(_pasteTag, '').trim();
    if (text.isEmpty || text.startsWith('<')) return;
    _entries.add(ChatSaid(text, mine: true));
  }

  /// A command the session ran, or what one printed, drawn as such: see
  /// [CommandTags]. False for any other line.
  bool _onCommandLine(String text) {
    if (CommandTags.output(text) case final output?) {
      final last = _entries.lastOrNull;
      if (last is ChatCommand && last.output == null) {
        last.output = output;
      } else if (output.isNotEmpty) {
        _entries.add(ChatNotice(output));
      }
      return true;
    }
    if (CommandTags.command(text) case final command?) {
      _entries.add(ChatCommand(command.name, args: command.args));
      return true;
    }
    return false;
  }

  /// What a `user` line's content says the user typed: a plain string, as a
  /// terminal records it, or the text blocks this chat sends. Null for a
  /// line that is a tool's result instead.
  static String? _userText(Object? content) => switch (content) {
    final String text => text.replaceAll(_pasteTag, ''),
    final List blocks
        when !blocks.any(
          (block) => block is Map && block['type'] == 'tool_result',
        ) =>
      blocks
          .whereType<Map<String, dynamic>>()
          .where((block) => block['type'] == 'text')
          .map((block) => block['text'] as String? ?? '')
          .join('\n'),
    _ => null,
  };

  /// How 2.1.277 marks what was pasted into a message:
  /// `<pasted_content id="…">` and `</pasted_content id="…">` around it.
  /// Taken out, so a paste reads as what was pasted, and a message this chat
  /// pasted is recognised as the one it sent.
  static final _pasteTag = RegExp(r'</?pasted_content id="[^"]*">');

  /// THE INVARIANT, kept here and in [_current]: nothing this chat writes
  /// reaches a process or session that has been replaced, and no write is
  /// dropped without saying so.
  ///
  /// What a write is for is a number, [_target], that goes up whenever the
  /// thing writes go to changes: the process stopped or restarted (a ⋮ mode
  /// change, a reconnect), a new one started, another session picked or a
  /// new chat begun, a watched session picked up or finished, the process
  /// ending, the tab closing. A write is made for the target the user acted
  /// on, which it captures when they act, and checks again right before it
  /// goes out, after every wait in between: [_current] says no once the
  /// target is another, and the write is told to the user instead
  /// ([_movedOn], [send]).
  ///
  /// The writes that pass through it: a message, an answer or a dismissal
  /// into this chat's own `claude -p` ([_write]); keys typed into a watched
  /// session through `claude attach`, and into a tmux pane ([_deliver],
  /// [_typeIntoPane]). A new chat's first message starts a session of its
  /// own with `claude --bg`, which is not a write to an old one.
  int _target = 0;

  bool _current(int target) => !_disposed && target == _target;

  /// Completes the next time the target changes, for a wait that has nothing
  /// else to wake it: see [_deliver].
  Completer<void> _replaced = Completer<void>();

  /// The target is another from here on: whatever was captured before is
  /// stale, and a question the old process asked can no longer be answered.
  void _retarget() {
    _target++;
    final woken = _replaced;
    _replaced = Completer<void>();
    if (!woken.isCompleted) woken.complete();
    for (final ask in _asks.values) {
      ask.requestId = null;
    }
  }

  /// Writes [message] to this chat's own process, for [target] — now, by
  /// default. False, and nothing written, when that is no longer the process
  /// there is.
  bool _write(Map<String, dynamic> message, {int? target}) {
    final channel = _channel;
    if (channel == null || !_current(target ?? _target)) return false;
    channel.write(Uint8List.fromList(utf8.encode('${jsonEncode(message)}\n')));
    return true;
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
        _onAssistantTurn(event);
        _onAssistant(event['message']);
        notifyListeners();
      case 'user':
        if (_onToolResults(
          event['message'],
          structured: event['tool_use_result'],
        )) {
          notifyListeners();
        }
      case 'control_request':
        _onControlRequest(event);
      case 'control_cancel_request':
        _onControlCancel(event);
      case 'result':
        _busy = false;
        _endTurn();
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

  /// Claude's side of a turn, into the transcript. True when it added
  /// anything, for the caller to redraw.
  bool _onAssistant(Object? message) {
    if (message is! Map<String, dynamic>) return false;
    final content = message['content'];
    if (content is! List) return false;
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
        case 'tool_use' when block['name'] == askTool:
          final id = block['id'] as String? ?? '';
          // The CLI's request for the answer may have come first.
          if (_asks.containsKey(id)) break;
          final ask = ChatAsk.parse(id, block['input']);
          if (ask == null) break;
          _asks[id] = ask;
          _entries.add(ChatQuestion(ask));
          if (_orphans.remove(id) case final orphan?) {
            _settle(ask, _orphanAnswers.remove(id), failed: orphan.failed);
          }
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
          _noteTaskCall(run.name, run.input, run.id);
          // Its result may have been read already, before this call was.
          if (_orphans.remove(run.id) case final orphan?) {
            run
              ..result = orphan.result
              ..failed = orphan.failed;
            // Its result was read before it was: a task call takes effect now.
            _noteTaskResult(run.id, orphan.result, orphan.failed);
          } else {
            _running[run.id] = run;
          }
          changed = true;
      }
    }
    return changed;
  }

  /// A `user` event is not the user: it is what the tools Claude ran gave
  /// back, which folds into the call that asked for it.
  ///
  /// [structured] is the event's own `tool_use_result`, which is where a
  /// question's answers are.
  bool _onToolResults(Object? message, {Object? structured}) {
    if (message is! Map<String, dynamic>) return false;
    final content = message['content'];
    if (content is! List) return false;
    var changed = false;
    for (final block in content) {
      if (block is! Map<String, dynamic>) continue;
      if (block['type'] != 'tool_result') continue;
      final id = block['tool_use_id'];
      final result = _resultText(block['content']);
      final failed = block['is_error'] == true;
      _noteTaskResult(id, result, failed);
      if (_asks[id] case final ask?) {
        _settle(ask, structured, failed: failed);
        changed = true;
        continue;
      }
      final run = _running.remove(id);
      if (run == null) {
        // Its call is further back than anything read yet: kept for when
        // [loadEarlier] reaches it.
        if (id is String) {
          _orphans[id] = (result: result, failed: failed);
          _orphanAnswers[id] = structured;
        }
        continue;
      }
      run
        ..result = result
        ..failed = failed;
      changed = true;
    }
    return changed;
  }

  /// A question's end: answered, with [structured] holding the answers, or
  /// dismissed. Nothing asks for it any more either way.
  void _settle(ChatAsk ask, Object? structured, {required bool failed}) {
    ask.requestId = null;
    final answers = ChatAsk.answersIn(structured);
    if (answers != null && !failed) {
      ask.answers = answers;
    } else {
      ask.declined = true;
    }
  }

  /// The only tool this chat ever allows, matched by exactly this name.
  static const askTool = 'AskUserQuestion';

  /// A request from the CLI for the host to decide. Only `can_use_tool` is
  /// known, and every one gets an answer: the CLI waits for it, so a request
  /// left alone stops the turn.
  ///
  /// THE PERMISSION POLICY, all of it in this method and [answer]:
  /// - `allow` is sent in one place only, [answer]: for a question the CLI
  ///   asked about as [askTool], spelt exactly so, once, and the user
  ///   answered. Its `updatedInput` is that call's own input with `answers`
  ///   added, and nothing else.
  /// - Everything else is refused or errored here: any other tool, a
  ///   lookalike name, a question this chat cannot show or that was settled
  ///   already, a request kind it does not know. This chat has no way to ask
  ///   about a tool; what Claude may do without being asked is the ⋮ menu's.
  void _onControlRequest(Map<String, dynamic> event) {
    final id = event['request_id'];
    if (id is! String) return;
    final request = event['request'];
    // The CLI waits for every request it sends: one this chat cannot read is
    // answered with an error, not left.
    if (request is! Map<String, dynamic>) {
      _respondError(id, 'Not a request this chat can read.');
      return;
    }
    if (request['subtype'] != 'can_use_tool') {
      _respondError(id, 'Not a request this chat answers.');
      return;
    }
    final tool = request['tool_name'];
    if (tool == askTool) {
      final callId = request['tool_use_id'];
      var ask = callId is String ? _asks[callId] : null;
      if (ask == null && callId is String) {
        ask = ChatAsk.parse(callId, request['input']);
        if (ask != null) {
          _asks[callId] = ask;
          _entries.add(ChatQuestion(ask));
        }
      }
      // One that is open: a question settled already is not asked again.
      if (ask != null && ask.open) {
        // Asked again while still open: the newer request is the one the
        // CLI waits on, and the older is answered with an error rather than
        // left waiting.
        final older = ask.requestId;
        if (older != null && older != id) {
          _respondError(older, 'The question was asked again.');
        }
        ask
          ..requestId = id
          ..target = _target;
        notifyListeners();
        return;
      }
    }
    _respond(id, {
      'behavior': 'deny',
      'message':
          'This chat cannot approve a tool, so ${_nameOf(tool)} was '
          'refused. What Claude may do without being asked is set in the '
          'menu beside the box.',
    });
  }

  /// A tool's name as host text, for a message: bounded, with control
  /// characters out.
  static String _nameOf(Object? tool) {
    if (tool is! String || tool.isEmpty) return 'the tool';
    final clean = tool.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), '');
    return clean.length > 64 ? '${clean.substring(0, 64)}…' : clean;
  }

  bool _respond(
    String requestId,
    Map<String, Object?> response, {
    int? target,
  }) => _write({
    'type': 'control_response',
    'response': {
      'subtype': 'success',
      'request_id': requestId,
      'response': response,
    },
  }, target: target);

  void _respondError(String requestId, String message) => _write({
    'type': 'control_response',
    'response': {
      'subtype': 'error',
      'request_id': requestId,
      'error': message,
    },
  });

  /// The CLI withdrew a request, as it does when the turn is interrupted: a
  /// question it no longer waits on cannot be answered.
  void _onControlCancel(Map<String, dynamic> event) {
    for (final ask in _asks.values) {
      if (ask.requestId != null && ask.requestId == event['request_id']) {
        ask.requestId = null;
        notifyListeners();
      }
    }
  }

  /// Answers [ask] with [answers], by question text, and goes on with the
  /// turn. False when it cannot be answered — it was, or the CLI no longer
  /// waits, or the process is gone — and nothing was sent.
  bool answer(ChatAsk ask, Map<String, String> answers) {
    final id = ask.requestId;
    if (id == null || ask.target == null || !ask.answerable) return false;
    // An answer for each question and for nothing else.
    final texts = {for (final q in ask.questions) q.question};
    if (answers.length != texts.length || !texts.containsAll(answers.keys)) {
      return false;
    }
    // The one `allow` this chat sends: see [_onControlRequest]. To the
    // process that asked, and to no other.
    final sent = _respond(id, {
      'behavior': 'allow',
      'updatedInput': {...ask.input, 'answers': answers},
    }, target: ask.target);
    if (!sent) return false;
    ask
      ..requestId = null
      ..answers = Map.of(answers);
    notifyListeners();
    return true;
  }

  /// Dismisses [ask] without an answer, and tells Claude so.
  bool decline(ChatAsk ask) {
    final id = ask.requestId;
    if (id == null || ask.target == null || !ask.answerable) return false;
    final sent = _respond(id, {
      'behavior': 'deny',
      'message': 'The user dismissed the question without answering.',
    }, target: ask.target);
    if (!sent) return false;
    ask
      ..requestId = null
      ..declined = true;
    notifyListeners();
    return true;
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
    _retarget();
    _endTurn();
    _entries.add(ChatNotice('Claude is no longer running on this host.'));
    notifyListeners();
  }

  Future<void> _stop() async {
    _retarget();
    await _stopFollowing();
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
    _disposed = true;
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    unawaited(_stop());
    super.dispose();
  }

  bool _disposed = false;

  /// Nothing once the tab has closed. What was under way when it did — a
  /// new chat's start, a line Claude was still writing, a message's
  /// delivery — finishes on the host's time, not the tab's, and telling a
  /// disposed notifier threw: on a Mac it leaked past the test that closed
  /// the tab and failed the ones after it (run 36879651063).
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
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
  ///
  /// Permission prompts go to this chat over stdio, as the SDK's hosts get
  /// them, rather than being turned off with `--permission-prompts none`:
  /// measured, `none` also withholds the AskUserQuestion tool, which only a
  /// host that can answer it is given. So every `can_use_tool` request must
  /// be answered, or the CLI waits for ever: [_onControlRequest] shows the
  /// question and refuses everything else, as `none` did.
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
        '--permission-prompt-tool stdio$again 2>&1';
    return 'sh -c ${_shellQuote(script)}';
  }

  /// What the host runs to list its Claude sessions.
  ///
  /// `--json` is the one that does not want a terminal, which is what makes
  /// this possible over an exec channel at all. Without `--all` it lists the
  /// sessions still running; with it, the finished background ones as well
  /// (80 rows, 21 KB, on a working machine). Claude is found and the whole
  /// script quoted exactly as [command] does it.
  ///
  /// The pins follow it after a line of their own, so one round trip brings
  /// both: `jobs/pins.json` beside the CLI's other state, a JSON array of the
  /// short ids pinned in `claude agents` — found by watching which file
  /// changed when a session was pinned, since the listing itself never says.
  static String agentsCommand({bool all = false}) => 'sh -c '
      '${_shellQuote('$_findClaude'
          '"\$c" agents --json${all ? ' --all' : ''} 2>&1; '
          r'printf "\n--- pins\n"; '
          r'cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/jobs/pins.json" '
          '2>/dev/null')}';

  /// How much of a transcript is read, from its end.
  ///
  /// ponytail: the last 512 KB. Transcripts measured on a working machine run
  /// to 1 MB at the median, 11 MB at the 90th percentile and past 100 MB at
  /// the top, and a single line can be 12 MB — a tool's whole answer, or a
  /// picture — so the cut is by bytes, never by lines. [loadEarlier] pages
  /// further back.
  static const historyLimit = 512 * 1024;

  /// How much [loadEarlier] reads in one go: a few minutes of the busiest
  /// hour measured, and more of an ordinary one. Held only while it is drawn.
  static const earlierChunk = 2 * 1024 * 1024;

  /// ponytail: at most about 32 MB of one transcript is read into a chat,
  /// the tail and every earlier chunk together; past it the rest stays on the
  /// host. Measured on this machine's transcripts, the busiest hour wrote
  /// 30 MB and the p90 hour 2–23 MB, and what the chat keeps of them — text,
  /// tool inputs, results cut to 4000 characters — is 2–9 % of what is read,
  /// so about 3 MB at most. A transcript that is nothing but text would keep
  /// all of it. Let the oldest entries go as earlier ones come in, if a chat
  /// has to reach further back than that.
  static const transcriptBudget = 32 * 1024 * 1024;

  /// What the host runs to hand over bytes [from] to [to] of a session's
  /// transcript, for [loadEarlier]: the transcript found and quoted as
  /// [historyCommand] does it, and then only numbers, so nothing from the
  /// host reaches the command. `tail -c +N` seeks in a file rather than
  /// reading up to it, so a chunk near the start of 100 MB costs what one
  /// near the end does.
  static String earlierCommand(
    String sessionId, {
    required int from,
    required int to,
  }) => 'sh -c '
      '${_shellQuote('${_findTranscript(sessionId)}'
          'tail -c +${from + 1} "\$f" | head -c ${to - from}')}';

  /// What the host runs to hand over the end of a session's transcript: its
  /// size in bytes on the first line, then the last [historyLimit] bytes.
  ///
  /// Found by its id with `find`, not by working out the directory Claude
  /// Code files it under: that naming is the CLI's own business and can
  /// change between versions, and the id is the one thing that names the
  /// file. Where the projects live follows CLAUDE_CONFIG_DIR, as the CLI
  /// does. The id is quoted for sh, and the whole script once more for the
  /// login shell, as [command] quotes its values.
  ///
  /// [wait] gives a transcript that is not there yet up to 10 s to appear.
  static String historyCommand(String sessionId, {bool wait = false}) =>
      'sh -c '
      '${_shellQuote('${_findTranscript(sessionId, wait: wait)}'
          // The size is read once, and the read stops there: a session
          // still writing must not have its newest bytes handed over twice,
          // here and again by the follow that starts at this size.
          r's=$(wc -c < "$f" | tr -d " "); echo "$s"; '
          'if [ "\$s" -gt $historyLimit ]; then '
          'tail -c +\$((s - $historyLimit + 1)) "\$f" | head -c $historyLimit; '
          r'else head -c "$s" "$f"; fi')}';

  /// What the host runs to hand over what a running session goes on to write,
  /// from byte [from] of its transcript — where the history read stopped —
  /// for as long as its process, [pid], is alive.
  ///
  /// Measured: a background session's transcript grows an event at a time
  /// while its turn runs, each tool call as it is issued and each result as
  /// it returns, so following the file is live, not turn by turn.
  ///
  /// Three things end it, and none leaves anything behind on the host:
  /// - The session's process going, checked every 2 s with `kill -0`. Then
  ///   the tail is given a second to hand over the last lines, and a line of
  ///   its own saying so, `sshbox:ended`, follows them.
  /// - The channel closing, when the tab closes or the connection goes. An
  ///   exec channel with no pty hangs up nothing, so the shell reads its own
  ///   stdin in the foreground, and the end of it is the channel gone.
  /// - The tail dying on its own.
  ///
  /// The id is found and quoted as [historyCommand] does it; [from] and
  /// [pid] are numbers, and nothing else from the host reaches the command.
  static String followCommand(
    String sessionId, {
    required int from,
    required int pid,
  }) => 'sh -c '
      '${_shellQuote('${_findTranscript(sessionId)}'
          'tail -c +${from + 1} -f "\$f" & t=\$!; '
          '( while kill -0 $pid 2>/dev/null && kill -0 \$t 2>/dev/null; '
          'do sleep 2; done; '
          'if ! kill -0 $pid 2>/dev/null; then sleep 1; kill \$t 2>/dev/null; '
          'echo; echo sshbox:ended; fi; '
          r'kill $$ 2>/dev/null ) & w=$!; '
          r'cat >/dev/null 2>&1; kill $t $w 2>/dev/null')}';

  /// What the host runs to start a new conversation as a background session
  /// with [prompt] as its first message: `claude --bg`, in [cwd] as [command]
  /// runs, with the chat's permission mode.
  ///
  /// The prompt is what the user typed, so it is quoted once for sh and the
  /// whole script once more, and it comes after `--`, so a message that
  /// opens with a dash is a message and not an option — measured, a prompt
  /// of `--help: …` was taken as said. Measured too: `--bg` starts a session
  /// with no prompt at all, but one that is then `blocked`; `--session-id` is
  /// ignored with `--bg`, which is why the id is read back from what it
  /// prints; and `--permission-prompts none` changes nothing there, a tool
  /// needing approval still waiting at its dialog.
  ///
  /// ponytail: a message is one argument, so past the host's limit on one
  /// (128 KB on Linux) the shell refuses it, and says so in the chat.
  static String backgroundCommand(
    String prompt, {
    String? cwd,
    ChatPermission permission = ChatPermission.acceptEdits,
  }) {
    final start = cwd == null || cwd.trim().isEmpty
        ? ''
        : 'cd ${_shellQuote(cwd)} || exit 1; ';
    final script = '$_findClaude$start'
        '"\$c" --bg --permission-mode ${permission.flag} '
        '-- ${_shellQuote(_pasteable(prompt))} </dev/null 2>&1';
    return 'sh -c ${_shellQuote(script)}';
  }

  /// The short id `claude --bg` printed for the session it started, from
  /// its first line: `backgrounded · e02182f4 · name`, coloured. Null when
  /// it printed no such line — the host saying why instead.
  static String? backgroundId(String output) {
    final id = RegExp(
      r'^backgrounded · ([0-9A-Za-z-]+)',
      multiLine: true,
    ).firstMatch(_plain(output))?.group(1);
    return id != null && _sessionIdShape.hasMatch(id) ? id : null;
  }

  /// [text] without the colours a terminal program writes.
  static String _plain(String text) =>
      text.replaceAll(RegExp(r'\x1b\[[0-9;?]*[A-Za-z]'), '');

  /// The oldest Claude Code that has everything chat mode uses, read off the
  /// CLI's own changelog (CHANGELOG.md in github.com/anthropics/claude-code):
  /// - `--permission-prompts none`, which this chat's `claude --bg` sessions
  ///   no longer need and its `claude -p` once started with: 2.1.259. The
  ///   newest of them all, so it stays the minimum.
  /// - `claude agents --json`: 2.1.145; its `waitingFor`: 2.1.162; its `id`,
  ///   `state` and `--all`: 2.1.169.
  /// - `claude --bg`: 2.1.140 names it; `claude attach`: 2.1.198 is the
  ///   first to, so it may be older. Both older than the minimum either way.
  /// - `-p` with stream-json out: 0.2.66, and in: 1.0.18. `--resume`: 0.2.93.
  ///   `--fork-session` is no longer used.
  /// - `jobs/pins.json` is not in the changelog, only pinning itself, in
  ///   2.1.147; a host without the file only shows nothing pinned.
  static const minimumVersion = (2, 1, 259);

  /// What the host runs to say which Claude Code it has: `--version`, with
  /// Claude found as [command] finds it and the script quoted as it quotes.
  static String versionCommand() =>
      'sh -c ${_shellQuote('$_findClaude"\$c" --version 2>&1')}';

  /// The version in what `claude --version` printed — `2.1.277 (Claude
  /// Code)` — or null for anything else. Its last line, since stderr comes
  /// along and a warning can go before it, must be three numbers and after
  /// them, if anything, only the CLI's own name: a pre-release tag, a build
  /// of some other program, or nothing at all is not taken for a version.
  static (int, int, int)? parseVersion(String output) {
    final lines = output.trim().split('\n');
    final match = RegExp(
      r'^(\d{1,6})\.(\d{1,6})\.(\d{1,6})(?: \(Claude Code\))?$',
    ).firstMatch(lines.last.trim());
    if (match == null) return null;
    return (int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!));
  }

  /// Whether [version] is [minimum] or newer, compared part by part as
  /// numbers: 2.1.100 is newer than 2.1.99.
  static bool meetsMinimum(
    (int, int, int) version, [
    (int, int, int) minimum = minimumVersion,
  ]) {
    final (major, minor, patch) = version;
    final (needMajor, needMinor, needPatch) = minimum;
    if (major != needMajor) return major > needMajor;
    if (minor != needMinor) return minor > needMinor;
    return patch >= needPatch;
  }

  static String _versionName((int, int, int) version) =>
      '${version.$1}.${version.$2}.${version.$3}';

  /// Why chat cannot run with the Claude Code that answered [output] to
  /// [versionCommand], or null when it can. An answer that is not a version
  /// is not taken as new enough: chat stays shut, and says what came back.
  static String? versionRefusal(String output) {
    final text = output.trim();
    if (text.startsWith(_notInstalled)) return text;
    final needs = _versionName(minimumVersion);
    final version = parseVersion(text);
    if (version == null) {
      final said = text.length > 120 ? '${text.substring(0, 120)}…' : text;
      return 'Could not tell which Claude Code this host has — chat needs '
          '$needs or newer, and the host answered '
          '${said.isEmpty ? 'nothing' : '“$said”'}.';
    }
    if (meetsMinimum(version)) return null;
    return 'Claude Code ${_versionName(version)} on this host is too old for '
        'chat — it needs $needs or newer.';
  }

  /// What the host runs to type into a running background session: `claude
  /// attach` with its short [id], on the pty [openTerminal] gives it. Claude
  /// is found as [command] finds it, and the id quoted once for sh, the whole
  /// script once more.
  static String attachCommand(String id) => 'sh -c '
      '${_shellQuote('$_findClaude'
          'exec "\$c" attach ${_shellQuote(id)}')}';

  /// What the host runs to find the tmux pane an interactive session runs in
  /// — process [pid], session [sessionId] — and, given the length of what to
  /// type, to type it there: that many bytes read from stdin, then Enter.
  ///
  /// The CLI gives an interactive session no id to attach to, so the pane is
  /// the only way in. It is found by the session's terminal, never guessed:
  /// the pane whose tty is the one `ps` says the process has, on the tmux
  /// server the tabs use. A tty belongs to one pane and nothing else, so
  /// there is no near miss — a Claude run in a plain terminal, inside
  /// `script`, or over ssh from the pane has a tty no pane holds, and is
  /// said to be in none.
  ///
  /// Every check runs again right before the text goes in, and again before
  /// Enter, since the listing the chat read may be a second old. Measured on
  /// 2.1.278: a digit alone answers a permission prompt, no Enter needed, and
  /// a dialog swallows what is typed and takes Enter as yes — so nothing is
  /// typed unless all of these hold, and each failure says which:
  /// - `~/.claude/sessions/<pid>.json`, the file `claude agents` is read
  ///   from, still names this session, `idle`, and waiting for nothing. An
  ///   interactive session has no `state`, but a permission prompt turns it
  ///   `waiting`, measured. Not `busy` either: mid-turn, a prompt can come up
  ///   at any moment, and between turns none can come without a turn.
  /// - Claude is the foreground of its terminal, not suspended with a shell
  ///   in front of it, where Enter would run the message as a command.
  /// - Its input line has the keyboard: the cursor is showing, on the `❯`
  ///   line, just after it — so no draft of somebody's at that terminal is
  ///   sent along. Measured: a permission prompt or a picker hides the
  ///   cursor.
  /// - Nothing on screen says `Esc to cancel` or `Enter to confirm`, as
  ///   every dialog measured did: one of them, "Teach auto mode about your
  ///   environment?", came up after a turn with the session still `idle`.
  ///
  /// ponytail: the checks read Claude Code's own screen and state file, so a
  /// release that redraws the prompt or renames a field makes them refuse,
  /// never type blind; a dialog that says neither phrase and leaves the
  /// cursor on the input line would get through, and none was found.
  ///
  /// The text never touches the command line or tmux's parser: it comes on
  /// stdin into `load-buffer`, and `paste-buffer -r` writes it to that one
  /// pane's terminal as it is — not `send-keys`, which would copy it into
  /// every pane of a window with `synchronize-panes` on, and hand it to a
  /// pane's copy mode as key bindings. Every command before `head` reads
  /// /dev/null, so none of them eats it. [pid] is a number and [sessionId]
  /// is quoted once for sh, the whole script once more.
  static String paneCommand(
    String sessionId, {
    required int pid,
    int typing = 0,
  }) {
    final type = typing <= 0
        ? r'echo "sshbox:pane $w"'
        : r'j="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions/$p.json"; '
              'ready() { '
              r'grep -q "\"sessionId\":\"$s\"" "$j" </dev/null 2>/dev/null '
              '|| no gone; '
              r'grep -q "\"status\":\"idle\"" "$j" </dev/null && '
              r'! grep -q "\"waitingFor\"" "$j" </dev/null || no busy; '
              r'set -- $(ps -o pgid=,tpgid= -p $p </dev/null 2>/dev/null); '
              r'[ -n "$1" ] && [ "$1" = "$2" ] || no foreground; '
              r'"$t" -u capture-pane -p -t "$w" </dev/null 2>/dev/null | '
              'grep -q -e "Esc to cancel" -e "Enter to confirm" && no dialog; '
              r'c=$("$t" display -p -t "$w" '
              r'"#{cursor_flag} #{cursor_x} #{cursor_y}" </dev/null '
              '2>/dev/null); '
              r'set -- $c; [ "$1" = 1 ] || no dialog; }; '
              'ready; set -- \$c; '
              r'[ "$2" = 2 ] && "$t" -u capture-pane -p -t "$w" -S "$3" -E "$3" '
              '</dev/null 2>/dev/null | grep -q "^❯" || no draft; '
              r'b=sshbox-chat-$$; '
              'head -c $typing | '
              r'"$t" load-buffer -b "$b" - && '
              r'"$t" paste-buffer -r -d -b "$b" -t "$w" </dev/null || '
              r'{ "$t" delete-buffer -b "$b" </dev/null 2>/dev/null; '
              'no paste; }; '
              'echo sshbox:pasted; sleep 1; ready; '
              r'printf "\r" | "$t" load-buffer -b "$b" - && '
              r'"$t" paste-buffer -r -d -b "$b" -t "$w" </dev/null || '
              'no enter; '
              r'echo "sshbox:typed $w"';
    return 'sh -c '
        '${_shellQuote('${TmuxSession.findTmux}'
            'p=$pid; s=${_shellQuote(sessionId)}; '
            r'no() { echo "sshbox:no $1"; exit 0; }; '
            r'y=$(ps -o tty= -p $p </dev/null 2>/dev/null | tr -d " "); '
            r'case $y in ""|"?"|"??") no terminal;; esac; '
            r'w=$("$t" list-panes -a -F "#{pane_tty} #{pane_id}" </dev/null '
            r'2>/dev/null | awk -v y="/dev/$y" '
            r"'$1 == y { n++; w = $2 } END { if (n == 1) print w }'); "
            r'[ -n "$w" ] || no pane; '
            '$type')}';
  }

  /// Finds [sessionId]'s transcript into `$f`, or says there is none and
  /// stops — by its id, not by the directory the CLI files it under. With
  /// [wait], a transcript not there yet is looked for once a second for
  /// 10 s: a session just started writes its first line a moment later.
  static String _findTranscript(String sessionId, {bool wait = false}) {
    final find =
        'f=\$(find "\$d" -type f -name ${_shellQuote('$sessionId.jsonl')} '
        '2>/dev/null | head -n 1); ';
    final again = wait
        ? 'i=0; while [ -z "\$f" ] && [ \$i -lt 10 ]; do sleep 1; '
              'i=\$((i + 1)); ${find}done; '
        : '';
    return r'd="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"; '
        '$find$again'
        r'[ -n "$f" ] || { echo "No transcript for this session on the '
        r'host."; exit 1; }; ';
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
      r'ok "$c" || { echo "'
      '$_notInstalled'
      r' (looked on PATH, in ~/.local/bin, ~/.claude/local and the usual '
      r'package managers)"; exit 1; }; ';

  /// How the host says it has no Claude Code, which the version check passes
  /// on as it is.
  static const _notInstalled = 'Claude Code is not installed on this host';

  /// Wraps a value so the remote shell sees exactly these bytes.
  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", r"'\''")}'";
}
