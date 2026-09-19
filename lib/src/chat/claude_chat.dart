import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../session/terminal_session.dart';

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

  final List<ChatEntry> _entries = [];

  List<ChatEntry> get entries => List.unmodifiable(_entries);

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

  /// The tool calls still waiting for their result, by `tool_use_id`.
  final Map<String, ChatToolRun> _running = {};

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
    final watching = _watching;
    if (watching != null) {
      _typeInto(watching, message);
      return;
    }
    if (_composing) {
      if (!_busy) await _startInBackground(message);
      return;
    }
    if (!_ready || _busy) return;
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
    if (pid != null) {
      // Unreadable, it has said why; with nothing to follow from, nothing is
      // started either.
      if (read == null) return;
      _watching = agent;
      _say(
        ChatNotice(
          'Watching “${agent.name}” live: what it does on the host shows '
          'here as it happens, and what you send goes into it.',
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
    await _stop();
    _entries.clear();
    _running.clear();
    _busy = false;
    _ended = false;
    _watching = null;
    _pending.clear();
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
      // Something else was picked meanwhile: the new session stays on the
      // host, in the list, and this chat shows what was picked.
      if (!_composing) return;
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
    final CommandChannel channel;
    try {
      channel = await open(
        followCommand(agent.sessionId, from: from, pid: pid),
      );
    } catch (error) {
      _say(ChatNotice('It could not be followed live: $error', failed: true));
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
    try {
      final event = jsonDecode(text);
      if (event is Map<String, dynamic>) _confirm(event);
    } catch (_) {
      // Drawn or not by the replay, which reads it again.
    }
    _replay(text);
    notifyListeners();
  }

  void _followDone(ClaudeAgent agent) {
    _followed = null;
    _follower = null;
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
    // Whatever goes wrong, the message says it was not delivered rather than
    // sitting at "sending", and the next one still gets its turn.
    _typing = _typing.then(
      (_) => _deliver(said, agent).catchError(
        (Object error) => _undelivered(said, 'Not delivered: $error'),
      ),
    );
  }

  Future<void> _deliver(ChatSaid said, ClaudeAgent agent) async {
    final openTerminal = this.openTerminal;
    if (openTerminal == null) {
      return _undelivered(said, 'This connection cannot open a terminal on '
          'the host, which typing into a session needs.');
    }
    // What it is doing now, not what the list said when it was picked.
    final ClaudeAgent? now;
    try {
      now = (await agents())
          .where((row) => row.sessionId == agent.sessionId)
          .firstOrNull;
    } catch (error) {
      return _undelivered(said, 'Could not check on it first: $error');
    }
    if (now == null || !now.live) {
      return _undelivered(said, '“${agent.name}” is no longer running.');
    }
    final id = now.id;
    if (id == null || now.interactive) {
      return _undelivered(said, 'Somebody is typing into “${agent.name}” at a '
          'terminal. Type there, so two people are not typing at once.');
    }
    if (!_typeable(now)) {
      return _undelivered(said, '“${agent.name}” is waiting for '
          '${now.waitingFor ?? 'something'} on the host'
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
        await drawn.future.timeout(deliveryTimeout);
      } catch (_) {
        return _undelivered(said, '“${agent.name}” did not come up to type '
            'into. Open it in a terminal with `claude attach $id`.');
      }
      // A moment for the rest of the screen to settle under the prompt.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      terminal.write(Uint8List.fromList(utf8.encode(_keystrokes(said.text))));
      await Future<void>.delayed(const Duration(milliseconds: 500));
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

  void _undelivered(ChatSaid said, String why) {
    said
      ..delivery = Delivery.failed
      ..why = why;
    _pending.remove(said);
    final recorded = _recorded.remove(said);
    if (recorded != null && !recorded.isCompleted) recorded.complete();
    notifyListeners();
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
  void _confirm(Map<String, dynamic> event) {
    if (_pending.isEmpty) return;
    final String? text;
    var queued = false;
    switch (event['type']) {
      case 'queue-operation' when event['operation'] == 'enqueue':
        text = event['content'] as String?;
        queued = true;
      case 'user' when event['isMeta'] != true:
        final message = event['message'];
        text = message is Map<String, dynamic>
            ? _userText(message['content'])
            : null;
      default:
        text = null;
    }
    if (text == null) return;
    final key = _normal(text);
    // What reached the session is what was sent less what [_pasteable] took
    // out, so that is what is compared.
    final said = _pending
        .where((said) => _normal(_pasteable(said.text)) == key)
        .firstOrNull;
    if (said == null) return;
    // Either way the session has it, and the attach can go.
    _recorded.remove(said)?.complete();
    if (queued) {
      // Still pending: it moves to where the session puts it once taken.
      said.delivery = Delivery.queued;
      return;
    }
    // Taken as a turn: the session's own line is drawn in its place, where
    // the session put it.
    _pending.remove(said);
    _entries.remove(said);
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
      final channel = await open(historyCommand(sessionId, wait: wait));
      try {
        // A host that never closes the channel costs its history, not the
        // pick-up.
        bytes = await channel.output
            .fold(BytesBuilder(copy: false), (all, chunk) => all..add(chunk))
            .then((all) => all.takeBytes())
            .timeout(Duration(seconds: wait ? 40 : 20));
      } finally {
        channel.close();
      }
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
    if (size > historyLimit) {
      // Read from the middle of a line; that line is only its end.
      final cut = body.indexOf(10);
      body = cut < 0 ? Uint8List(0) : body.sublist(cut + 1);
      _entries.add(
        ChatNotice(
          'Only the latest part of this session is shown; its earlier turns '
          'are on the host.',
        ),
      );
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
    }
    notifyListeners();
    return (from: size, carry: body.sublist(whole));
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
        _onAssistant(message);
      case 'user' when message is Map<String, dynamic>:
        final said = _userText(message['content']);
        if (said == null) {
          _onToolResults(message);
          return;
        }
        final text = said.trim();
        // ponytail: a message the user typed that itself opens with `<` is
        // taken for one Claude Code wrote, and left out.
        if (text.isEmpty || text.startsWith('<')) return;
        _entries.add(
          text.startsWith('[Request interrupted')
              ? ChatNotice('The user interrupted this turn.')
              : ChatSaid(text, mine: true),
        );
    }
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
        if (_onAssistant(event['message'])) notifyListeners();
      case 'user':
        if (_onToolResults(event['message'])) notifyListeners();
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
    return changed;
  }

  /// A `user` event is not the user: it is what the tools Claude ran gave
  /// back, which folds into the call that asked for it.
  bool _onToolResults(Object? message) {
    if (message is! Map<String, dynamic>) return false;
    final content = message['content'];
    if (content is! List) return false;
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
    return changed;
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
  /// picture — so the cut is by bytes, never by lines. Page further back on
  /// request if the tail proves too short.
  static const historyLimit = 512 * 1024;

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
  /// - `--permission-prompts none`, which every `claude -p` this chat runs
  ///   starts with: 2.1.259. The newest of them all, so the minimum.
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
  /// Code)` — or null for anything else: three numbers, and after them, if
  /// anything, only the CLI's own name. A line the host added, a build of
  /// some other program, or nothing at all is not taken for a version.
  static (int, int, int)? parseVersion(String output) {
    final match = RegExp(
      r'^(\d{1,6})\.(\d{1,6})\.(\d{1,6})(?: \(Claude Code\))?$',
    ).firstMatch(output.trim());
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
