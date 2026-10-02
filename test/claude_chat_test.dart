import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/chat/claude_chat.dart';
import 'package:sshbox/src/session/terminal_session.dart';

/// Claude Code's end of `claude -p --output-format stream-json`: whatever the
/// test says it wrote, and whatever the app sent it.
typedef OpenFor = Future<CommandChannel> Function(String command);

class _FakeClaude {
  final _output = StreamController<Uint8List>();
  final written = <String>[];
  var closed = false;

  late final CommandChannel channel = (
    output: _output.stream,
    write: (Uint8List data) => written.add(utf8.decode(data)),
    close: () {
      closed = true;
      unawaited(_output.close());
    },
  );

  /// One event, as the process writes it: one JSON object, one line.
  void event(Map<String, dynamic> event) =>
      _output.add(Uint8List.fromList(utf8.encode('${jsonEncode(event)}\n')));

  void line(String text) =>
      _output.add(Uint8List.fromList(utf8.encode('$text\n')));

  Future<void> end() => _output.close();

  /// The messages the app sent, decoded.
  List<Map<String, dynamic>> get sent => [
    for (final line in written)
      jsonDecode(line.trim()) as Map<String, dynamic>,
  ];
}

/// A transcript as the host keeps it: one JSON object a line, in the shapes
/// measured off real ones — most lines are not the conversation at all.
String _transcript(String sessionId) => [
  {'type': 'mode', 'sessionId': sessionId},
  {'type': 'permission-mode', 'sessionId': sessionId},
  {'type': 'attachment', 'sessionId': sessionId, 'isSidechain': false},
  // What the user typed, as the terminal records it: a plain string.
  {
    'type': 'user',
    'sessionId': sessionId,
    'isSidechain': false,
    'message': {'role': 'user', 'content': 'why is nginx slow?'},
  },
  // Put there by Claude Code, not typed: an image's caption, a notification.
  {
    'type': 'user',
    'sessionId': sessionId,
    'isMeta': true,
    'message': {'role': 'user', 'content': '[Image: original 1080x2400]'},
  },
  {
    'type': 'user',
    'sessionId': sessionId,
    'message': {
      'role': 'user',
      'content': '<task-notification>\n<task-id>b52</task-id>',
    },
  },
  {
    'type': 'assistant',
    'sessionId': sessionId,
    'message': {
      'role': 'assistant',
      'content': [
        {'type': 'thinking', 'thinking': '', 'signature': 'CAQS'},
      ],
    },
  },
  {
    'type': 'assistant',
    'sessionId': sessionId,
    'message': {
      'role': 'assistant',
      'content': [
        {'type': 'text', 'text': 'Let me read the error log.'},
        {
          'type': 'tool_use',
          'id': 'toolu_old',
          'name': 'Bash',
          'input': {'command': 'tail -n 50 /var/log/nginx/error.log'},
        },
      ],
    },
  },
  {
    'type': 'user',
    'sessionId': sessionId,
    'message': {
      'role': 'user',
      'content': [
        {
          'type': 'tool_result',
          'tool_use_id': 'toolu_old',
          'content': '3 upstream timeouts',
        },
      ],
    },
  },
  // A subagent's own chatter, which the session's own view leaves out.
  {
    'type': 'assistant',
    'sessionId': sessionId,
    'isSidechain': true,
    'message': {
      'role': 'assistant',
      'content': [
        {'type': 'text', 'text': 'subagent working'},
      ],
    },
  },
  {
    'type': 'assistant',
    'sessionId': sessionId,
    'message': {
      'role': 'assistant',
      'content': [
        {'type': 'text', 'text': 'Three upstream timeouts.'},
      ],
    },
  },
  // What this chat sends is text blocks, and it is the user's words too.
  {
    'type': 'user',
    'sessionId': sessionId,
    'message': {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': 'and the fix?'},
      ],
    },
  },
  {
    'type': 'user',
    'sessionId': sessionId,
    'message': {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': '[Request interrupted by user]'},
      ],
    },
  },
  {'type': 'system', 'subtype': 'turn_duration', 'sessionId': sessionId},
].map(jsonEncode).join('\n');

/// A host with a transcript on it: the history command gets [history], the
/// chat itself a channel of its own.
({List<String> commands, Future<CommandChannel> Function(String) open})
_hostWithHistory(String? history) {
  final commands = <String>[];
  return (
    commands: commands,
    open: (String command) async {
      commands.add(command);
      if (command.contains(' -f ')) {
        // Following a session that, for this test, adds nothing more.
        return (
          output: StreamController<Uint8List>().stream,
          write: (Uint8List data) {},
          close: () {},
        );
      }
      if (command.contains('.jsonl')) {
        return (
          output: Stream.value(
            Uint8List.fromList(utf8.encode(history ?? '')),
          ),
          write: (Uint8List data) {},
          close: () {},
        );
      }
      if (command.contains('/usage')) return _says(usageOnHost);
      if (command.contains('/tasks')) return _says(tasksOnHost);
      return _FakeClaude().channel;
    },
  );
}

/// What `claude -p /usage` prints, for the next ask; empty reports no limit.
String usageOnHost = '';

/// A channel that says one thing and is then done.
CommandChannel _says(String text) => (
  output: Stream.value(Uint8List.fromList(utf8.encode(text))),
  write: (Uint8List data) {},
  close: () {},
);

/// What the session's task store holds on the host, for the next read of it.
String tasksOnHost = '';

/// [claude] for everything but a read of the plan's usage or of the task
/// store, which are answered from [usageOnHost] and [tasksOnHost] as the host
/// would.
Future<CommandChannel> Function(String) _routed(_FakeClaude claude) =>
    (command) async => command.contains('/usage')
        ? _says(usageOnHost)
        : command.contains('/tasks')
        ? _says(tasksOnHost)
        : claude.channel;

const _live = ClaudeAgent(
  sessionId: '3cae97ea-5874-4a0b-b8bd-6ad88edf0e2f',
  name: 'nginx look',
  cwd: '/srv/app',
  kind: 'background',
  id: '3cae97ea',
  status: 'idle',
  pid: 1241689,
);

/// [_live], had somebody typed `claude` into a terminal instead: no short id
/// to attach to, and no state.
final _interactive = ClaudeAgent(
  sessionId: _live.sessionId,
  name: _live.name,
  cwd: _live.cwd,
  kind: 'interactive',
  status: 'idle',
  pid: _live.pid,
);

/// [_live], once its process has gone: continued in place, not watched.
final _finished = ClaudeAgent(
  sessionId: _live.sessionId,
  name: _live.name,
  cwd: _live.cwd,
  kind: 'background',
  id: _live.id,
);

/// The history command's answer for a session that has said nothing yet.
CommandChannel _noHistory() => (
  output: Stream.value(Uint8List.fromList(utf8.encode('0\n'))),
  write: (Uint8List data) {},
  close: () {},
);

/// A host with a live session on it: the history command gets [history],
/// the follow command a channel this test writes into as the session goes
/// on, and Claude itself — if anything starts it — a channel of its own.
class _LiveHost {
  _LiveHost(
    this.history, {
    this.state = 'done',
    this.status,
    this.waitingFor,
    this.interactive = false,
  });

  final String history;

  /// Whether the watched session is one somebody started at a terminal:
  /// listed with no short id and no state, as the CLI lists one.
  final bool interactive;

  /// What finding its tmux pane answers, and what typing into it answers.
  String pane = 'sshbox:pane %3\n';
  String typedAnswer = 'sshbox:pasted\nsshbox:typed %3\n';

  /// Every command that typed into a pane, and what went to it on stdin.
  final paneTyping = <({String command, List<String> stdin})>[];

  /// What `claude agents` says the watched session is doing right now.
  String? state;

  /// Its `status` and `waitingFor`, where a test says. Otherwise `busy`
  /// mid-turn and `idle` between turns, as the CLI gives them.
  String? status;
  String? waitingFor;
  final commands = <String>[];
  StreamController<Uint8List>? follow;
  var followClosed = false;

  /// Every terminal opened on the host: the command, what was typed into it,
  /// and whether it has been closed — in the order they were opened.
  final terminals = <({String command, List<String> typed, List<bool> closed})>[];

  /// Whether a terminal draws a prompt to type at. A TUI that never comes up
  /// is a test's to ask for.
  var terminalsDraw = true;

  /// What `claude agents` lists instead of the watched session, where a test
  /// says: one it has just started.
  Map<String, Object?>? listed;

  /// When set, `claude agents` answers only once it completes, as a slow
  /// host answers: what the session does meanwhile goes on.
  Future<void>? agentsGate;

  Future<CommandChannel> openTerminal(String command) async {
    commands.add(command);
    final typed = <String>[];
    final closed = [false];
    terminals.add((command: command, typed: typed, closed: closed));
    final screen = StreamController<Uint8List>();
    if (terminalsDraw) {
      // What `claude attach` draws: its input line, which is the prompt.
      scheduleMicrotask(
        () => screen.add(Uint8List.fromList(utf8.encode('\x1b[2J ❯ '))),
      );
    }
    var drawn = 0;
    // The input line as Claude Code draws it: what is typed as it comes, and
    // each path pasted as its chip a moment later, once it has read the file.
    var line = '';
    void redraw() =>
        screen.add(Uint8List.fromList(utf8.encode('\r\n❯ $line')));
    return (
      output: screen.stream,
      write: (Uint8List data) {
        final keys = utf8.decode(data);
        typed.add(keys);
        chipsWhenTyped.add(drawn);
        if (!drawChips) return;
        if (keys.startsWith('\x1b[200~/')) {
          Timer(chipDelay, () {
            drawn++;
            line += '[Image #9] ';
            redraw();
          });
        } else if (keys != '\r') {
          line += keys;
          redraw();
        }
      },
      close: () {
        closed[0] = true;
        unawaited(screen.close());
      },
    );
  }

  /// Whether a terminal draws a chip for each path pasted into it.
  var drawChips = false;

  /// How long a pasted path takes to become its chip.
  var chipDelay = const Duration(milliseconds: 50);

  /// How many chips each terminal had drawn when each of its writes came.
  final chipsWhenTyped = <int>[];

  Future<CommandChannel> open(String command) async {
    commands.add(command);
    if (command.contains('list-panes')) {
      final stdin = <String>[];
      if (command.contains('load-buffer')) {
        paneTyping.add((command: command, stdin: stdin));
      }
      return (
        output: Stream.value(
          Uint8List.fromList(
            utf8.encode(command.contains('load-buffer') ? typedAnswer : pane),
          ),
        ),
        write: (Uint8List data) => stdin.add(utf8.decode(data)),
        close: () {},
      );
    }
    final started = listed;
    if (command.contains('agents --json') && started != null) {
      return (
        output: Stream.value(
          Uint8List.fromList(utf8.encode(jsonEncode([started]))),
        ),
        write: (Uint8List data) {},
        close: () {},
      );
    }
    if (command.contains('agents --json')) {
      final gate = agentsGate;
      if (gate != null) await gate;
      final listed = jsonEncode([
        {
          'pid': _live.pid,
          if (!interactive) 'id': _live.id,
          'cwd': _live.cwd,
          'kind': interactive ? 'interactive' : 'background',
          'sessionId': _live.sessionId,
          'name': _live.name,
          'status': status ?? (state == 'working' ? 'busy' : 'idle'),
          if (!interactive) 'state': ?state,
          'waitingFor': ?waitingFor,
        },
      ]);
      return (
        output: Stream.value(Uint8List.fromList(utf8.encode(listed))),
        write: (Uint8List data) {},
        close: () {},
      );
    }
    if (command.contains(' -f ')) {
      final controller = StreamController<Uint8List>();
      follow = controller;
      followClosed = false;
      return (
        output: controller.stream,
        write: (Uint8List data) {},
        close: () => followClosed = true,
      );
    }
    if (command.contains('.jsonl')) {
      return (
        output: Stream.value(Uint8List.fromList(utf8.encode(history))),
        write: (Uint8List data) {},
        close: () {},
      );
    }
    if (command.contains('/usage')) return _says(usageOnHost);
    if (command.contains('/tasks')) return _says(tasksOnHost);
    return _FakeClaude().channel;
  }

  /// The session writing one more line to its transcript.
  void adds(Object line) => follow!.add(
    Uint8List.fromList(
      utf8.encode(line is String ? line : '${jsonEncode(line)}\n'),
    ),
  );

  /// Whether Claude itself was started — a copy, or the session resumed.
  bool get startedClaude =>
      commands.any((command) => command.contains('stream-json'));
}

Map<String, Object?> _said(String text) => {
  'type': 'assistant',
  'message': {
    'role': 'assistant',
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
};

/// Lets the events queued above reach the chat.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  // A chat closed while a host call is in flight must not go on to open
  // channels nobody will close: a tail -f or a claude -p held on the SSH
  // session for a tab that no longer exists.
  group('a chat closed mid-call opens nothing more', () {
    test('after `claude --bg` answers: no listing, no history, no tail', () async {
      final gate = Completer<void>();
      final opened = <String>[];
      final chat = ClaudeChat(
        open: (command) async {
          opened.add(command);
          if (command.contains(' --bg ')) {
            await gate.future;
            return (
              output: Stream.value(
                Uint8List.fromList(utf8.encode('backgrounded · e2e0c0de · x\n')),
              ),
              write: (Uint8List _) {},
              close: () {},
            );
          }
          // Anything later: a live session listed, a history, a tail.
          return _noHistory();
        },
      );
      final sent = chat.send('hello');
      await _settle();
      expect(opened.single, contains(' --bg '));
      chat.dispose();
      gate.complete();
      await sent;
      expect(opened, hasLength(1), reason: 'opened after dispose: $opened');
    });

    test('a claude -p whose open lands after dispose is closed', () async {
      final gate = Completer<CommandChannel>();
      final chat = ClaudeChat(open: (_) => gate.future);
      final started = chat.start();
      await _settle();
      chat.dispose();
      final claude = _FakeClaude();
      gate.complete(claude.channel);
      await started;
      expect(claude.closed, isTrue);
    });

    test('a tail whose open lands after dispose is closed', () async {
      final gate = Completer<CommandChannel>();
      final chat = ClaudeChat(
        open: (command) =>
            command.contains(' -f ') ? gate.future : Future.value(_noHistory()),
      );
      final picked = chat.continueFrom(
        const ClaudeAgent(
          sessionId: 'f44e6c8b-7c64-4ef9-8f88-aeb262622b73',
          name: 'x',
          cwd: '/srv',
          kind: 'background',
          id: 'e2e0c0de',
          state: 'done',
          pid: 4242,
        ),
      );
      await _settle();
      await _settle();
      chat.dispose();
      final tail = _FakeClaude();
      gate.complete(tail.channel);
      await picked;
      expect(tail.closed, isTrue);
    });
  });

  // What a Mac's e2e hit closing a chat tab: a "used after being disposed"
  // thrown after the test, failing the tests that came next.
  test('a chat closed while a new session starts and Claude still writes '
      'tells no one', () async {
    final started = StreamController<Uint8List>();
    final chat = ClaudeChat(
      open: (_) async =>
          (output: started.stream, write: (Uint8List _) {}, close: () {}),
    );
    final sent = chat.send('hello');
    await _settle();
    chat.dispose();
    // `claude --bg` answers after the tab has gone.
    started.add(Uint8List.fromList(utf8.encode('no session\n')));
    await started.close();
    await sent;

    final claude = _FakeClaude();
    final running = ClaudeChat(open: _routed(claude));
    await running.start();
    running.dispose();
    // A line Claude was writing as the tab closed.
    claude.event({
      'type': 'system',
      'subtype': 'init',
      'session_id': 'f44e6c8b-7c64-4ef9-8f88-aeb262622b73',
    });
    await _settle();
  });

  test('a turn becomes bubbles, and its tools fold their results in', () async {
    final claude = _FakeClaude();
    final chat = ClaudeChat(open: _routed(claude));
    addTearDown(chat.dispose);
    await chat.start();
    expect(chat.ready, isTrue);

    claude.event({
      'type': 'system',
      'subtype': 'init',
      'session_id': 'f44e6c8b-7c64-4ef9-8f88-aeb262622b73',
      'cwd': '/srv/app',
    });
    await _settle();
    expect(chat.sessionId, 'f44e6c8b-7c64-4ef9-8f88-aeb262622b73');

    chat.send('  check the nginx log  ');
    expect(chat.busy, isTrue);
    expect(claude.sent.single, {
      'type': 'user',
      'message': {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'check the nginx log'},
        ],
      },
    });

    claude.event({
      'type': 'assistant',
      'message': {
        'content': [
          {'type': 'thinking', 'thinking': '', 'signature': 'CAQShwcK'},
          {'type': 'text', 'text': 'Let me look.'},
          {
            'type': 'tool_use',
            'id': 'toolu_01',
            'name': 'Bash',
            'input': {'command': 'tail -n 50 error.log', 'description': 'Read'},
          },
        ],
      },
    });
    await _settle();

    // The tool is still running: no result, and the call is already shown.
    final run = chat.entries.whereType<ChatToolRun>().single;
    expect(run.name, 'Bash');
    expect(run.summary, 'tail -n 50 error.log');
    expect(run.done, isFalse);
    // Claude's working is not part of the transcript.
    expect(
      chat.entries.whereType<ChatSaid>().map((said) => said.text),
      ['check the nginx log', 'Let me look.'],
    );

    claude.event({
      'type': 'user',
      'message': {
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'toolu_01',
            'content': '3 upstream timeouts',
            'is_error': false,
          },
        ],
      },
    });
    await _settle();
    expect(run.done, isTrue);
    expect(run.result, '3 upstream timeouts');
    expect(run.failed, isFalse);
    // A result is not a user's turn, however it arrives.
    expect(chat.entries.whereType<ChatSaid>().length, 2);

    claude.event({'type': 'result', 'subtype': 'success'});
    await _settle();
    expect(chat.busy, isFalse);
  });

  test('a refused tool shows as one, and the turn still ends', () async {
    final claude = _FakeClaude();
    final chat = ClaudeChat(open: _routed(claude));
    addTearDown(chat.dispose);
    await chat.start();
    chat.send('fetch example.com');

    claude.event({
      'type': 'assistant',
      'message': {
        'content': [
          {
            'type': 'tool_use',
            'id': 'toolu_02',
            'name': 'WebFetch',
            'input': {'url': 'https://example.com'},
          },
        ],
      },
    });
    claude.event({
      'type': 'user',
      'message': {
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'toolu_02',
            'content':
                "Claude requested permissions to use WebFetch, but you "
                "haven't granted it yet.",
            'is_error': true,
          },
        ],
      },
    });
    await _settle();

    final run = chat.entries.whereType<ChatToolRun>().single;
    expect(run.failed, isTrue);
    expect(run.result, contains('permissions'));
  });

  test('a host with no Claude on it says so', () async {
    final claude = _FakeClaude();
    final chat = ClaudeChat(open: _routed(claude));
    addTearDown(chat.dispose);
    await chat.start();

    // Not an event: what the shell wrote to stderr, folded into stdout.
    claude.line('Claude Code is not installed on this host (looked on PATH)');
    await claude.end();
    await _settle();

    final notices = chat.entries.whereType<ChatNotice>().toList();
    expect(notices.first.text, contains('not installed'));
    expect(notices.first.failed, isTrue);
    expect(chat.ended, isTrue);
    expect(chat.ready, isFalse);
  });

  test('a tool left running when Claude goes is not left spinning', () async {
    final claude = _FakeClaude();
    final chat = ClaudeChat(open: _routed(claude));
    addTearDown(chat.dispose);
    await chat.start();
    chat.send('build it');
    claude.event({
      'type': 'assistant',
      'message': {
        'content': [
          {
            'type': 'tool_use',
            'id': 'toolu_03',
            'name': 'Bash',
            'input': {'command': 'make'},
          },
        ],
      },
    });
    await _settle();
    expect(chat.entries.whereType<ChatToolRun>().single.done, isFalse);

    await claude.end();
    await _settle();
    expect(chat.entries.whereType<ChatToolRun>().single.done, isTrue);
    expect(chat.entries.whereType<ChatToolRun>().single.failed, isTrue);
    expect(chat.busy, isFalse);
  });

  test('a big result is cut rather than kept whole', () async {
    final claude = _FakeClaude();
    final chat = ClaudeChat(open: _routed(claude));
    addTearDown(chat.dispose);
    await chat.start();
    claude.event({
      'type': 'assistant',
      'message': {
        'content': [
          {
            'type': 'tool_use',
            'id': 'toolu_04',
            'name': 'Read',
            'input': {'file_path': '/var/log/syslog'},
          },
        ],
      },
    });
    claude.event({
      'type': 'user',
      'message': {
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'toolu_04',
            'content': 'x' * 10000,
          },
        ],
      },
    });
    await _settle();
    final run = chat.entries.whereType<ChatToolRun>().single;
    expect(run.result!.length, lessThan(4200));
    expect(run.result, contains('6000 more characters'));
  });

  group('a message typed for one session does not reach another', () {
    ClaudeChat watching(_LiveHost host, {OpenFor? open}) {
      final chat = ClaudeChat(
        open: open ?? host.open,
        openTerminal: host.openTerminal,
        deliveryTimeout: const Duration(seconds: 30),
      );
      addTearDown(chat.dispose);
      return chat;
    }

    /// The notice that says where the message went instead, with what was
    /// written, since the view it was sent from is gone.
    void expectToldWhere(ClaudeChat chat, String starts) {
      final told = chat.entries
          .whereType<ChatNotice>()
          .where((n) => n.failed && n.text.startsWith(starts))
          .toList();
      // Once: said, and not twice over.
      expect(told, hasLength(1), reason: 'a notice starting "$starts"');
      expect(told.single.text, contains('hello'));
    }

    test('moved off before the host has said what it is doing: no terminal '
        'is opened at all', () async {
      final host = _LiveHost('0\n');
      final chat = watching(host);
      await chat.continueFrom(_live);

      final gate = Completer<void>();
      host.agentsGate = gate.future;
      chat.send('hello');
      await _settle();
      await chat.newChat();
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(host.terminals, isEmpty);
      expect(host.paneTyping, isEmpty);
      expectToldWhere(chat, 'Not sent to “');
    });

    test('moved off while the attach comes up: it types nothing and is let go',
        () async {
      final host = _LiveHost('0\n');
      final chat = watching(host);
      await chat.continueFrom(_live);

      chat.send('hello');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await chat.newChat();
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      expect(host.terminals.single.typed, isEmpty);
      expect(host.terminals.single.closed.single, isTrue);
      expectToldWhere(chat, 'Not sent to “');
    });

    test('moved off while an attach that never draws is waited on: it is let '
        'go at once, not after the delivery timeout', () async {
      final host = _LiveHost('0\n')..terminalsDraw = false;
      final chat = watching(host);
      await chat.continueFrom(_live);

      chat.send('hello');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(host.terminals.single.closed.single, isFalse);
      await chat.newChat();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // 30 s is the timeout: this is well inside it.
      expect(host.terminals.single.closed.single, isTrue);
      expect(host.terminals.single.typed, isEmpty);
      expectToldWhere(chat, 'Not sent to “');
    });

    test('moved off after it was typed but before Enter: the Enter that '
        'would send it is held back, and the text is said to be at the '
        'terminal', () async {
      final host = _LiveHost('0\n');
      final chat = watching(host);
      await chat.continueFrom(_live);

      chat.send('hello');
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(host.terminals.single.typed, ['hello']);
      await chat.newChat();
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      expect(host.terminals.single.typed, ['hello']);
      expect(host.terminals.single.closed.single, isTrue);
      expectToldWhere(chat, 'Typed into “');
      expect(chat.entries.whereType<ChatNotice>().last.text,
          contains('not sent'));
    });

    test('another session picked meanwhile', () async {
      final host = _LiveHost('0\n');
      final chat = watching(host);
      await chat.continueFrom(_live);

      final gate = Completer<void>();
      host.agentsGate = gate.future;
      chat.send('hello');
      await _settle();
      // Picked from the list while the message was on its way.
      final other = chat.continueFrom(
        const ClaudeAgent(
          sessionId: 'cf58d27a-da65-4e9b-a896-078306134024',
          name: 'Zsh config fix',
          cwd: '/home/me',
          kind: 'background',
          id: 'cf58d27a',
          state: 'done',
        ),
      );
      gate.complete();
      await other;
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(host.terminals, isEmpty);
      expectToldWhere(chat, 'Not sent to “');
    });

    test('a tmux pane: moved off while the host script opens, no key is '
        'written to it', () async {
      final host = _LiveHost('0\n', interactive: true);
      late final ClaudeChat chat;
      chat = watching(
        host,
        open: (command) async {
          // Replaced at the very moment the pane's channel is being opened.
          if (command.contains('load-buffer')) await chat.newChat();
          return host.open(command);
        },
      );
      await chat.continueFrom(_interactive);

      chat.send('hello');
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // The script was started, and given nothing on its stdin: no keys.
      expect(host.paneTyping.single.stdin, isEmpty);
      expect(host.terminals, isEmpty);
      expectToldWhere(chat, 'Not sent to “');
    });

    test('the session ending before the message is typed, while the Claude '
        'that takes over is still starting: it is not typed into the '
        'finished session', () async {
      final host = _LiveHost('0\n');
      final starting = Completer<void>();
      final chat = watching(
        host,
        open: (command) async {
          // The resumed Claude that takes the session over, held back.
          if (command.contains('stream-json')) await starting.future;
          return host.open(command);
        },
      );
      await chat.continueFrom(_live);

      final gate = Completer<void>();
      host.agentsGate = gate.future;
      chat.send('hello');
      await _settle();
      host.adds('\nsshbox:ended\n');
      await host.follow!.close();
      await _settle();
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // The chat went on in place, as a Claude of its own; the old attach
      // was never opened and the message says so.
      expect(host.terminals, isEmpty);
      final said = chat.entries.whereType<ChatSaid>().firstWhere(
        (said) => said.text == 'hello',
      );
      expect(said.delivery, Delivery.failed);
      expect(said.why, contains('moved off'));
      starting.complete();
      await _settle();
    });
  });

  group('a question Claude asks', () {
    // As 2.1.287 sent them, measured against a real claude -p on stdio.
    const callId = 'toolu_014VYdGV2EsfHT7aXFQdgyu9';
    const questions = [
      {
        'question': 'Which colours?',
        'header': 'Colours',
        'multiSelect': true,
        'options': [
          {'label': 'Red', 'description': 'A warm colour.'},
          {'label': 'Blue', 'description': 'A cool colour.'},
        ],
      },
      {
        'question': 'Which size?',
        'header': 'Size',
        'multiSelect': false,
        'options': [
          {'label': 'Small', 'description': 'Small.'},
          {'label': 'Large', 'description': 'Large.', 'preview': 'XL\n  L'},
        ],
      },
    ];
    const input = {'questions': questions};

    Map<String, dynamic> toolUse([String id = callId]) => {
      'type': 'assistant',
      'message': {
        'content': [
          {
            'type': 'tool_use',
            'id': id,
            'name': 'AskUserQuestion',
            'input': input,
          },
        ],
      },
    };

    Map<String, dynamic> request([String id = callId, String requestId = 'r1']) =>
        {
          'type': 'control_request',
          'request_id': requestId,
          'request': {
            'subtype': 'can_use_tool',
            'tool_name': 'AskUserQuestion',
            'display_name': 'AskUserQuestion',
            'input': input,
            'tool_use_id': id,
            'requires_user_interaction': true,
          },
        };

    Future<(ClaudeChat, _FakeClaude)> started() async {
      final claude = _FakeClaude();
      final chat = ClaudeChat(open: (_) async => claude.channel);
      addTearDown(chat.dispose);
      await chat.start();
      return (chat, claude);
    }

    test('shows as a question, which the CLI then asks this chat to answer, '
        'and the answer goes back as allow with the answers added', () async {
      final (chat, claude) = await started();
      claude.event(toolUse());
      claude.event(request());
      await _settle();

      // One entry, a question and not a tool row, now waiting on the user.
      expect(chat.entries.whereType<ChatToolRun>(), isEmpty);
      final ask = chat.entries.whereType<ChatQuestion>().single.ask;
      expect(ask.questions.map((q) => q.header), ['Colours', 'Size']);
      expect(ask.questions[0].multiSelect, isTrue);
      expect(ask.questions[1].options[1].preview, 'XL\n  L');
      expect(ask.answerable, isTrue);

      final sent = chat.answer(ask, {
        'Which colours?': 'Red, Blue',
        'Which size?': 'Gigantic',
      });
      expect(sent, isTrue);
      expect(claude.sent.single, {
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': 'r1',
          'response': {
            'behavior': 'allow',
            'updatedInput': {
              ...input,
              'answers': {
                'Which colours?': 'Red, Blue',
                'Which size?': 'Gigantic',
              },
            },
          },
        },
      });
      // Shown answered at once, and not answerable twice.
      expect(ask.answers!['Which size?'], 'Gigantic');
      expect(ask.answerable, isFalse);
      expect(chat.answer(ask, {'Which colours?': 'x', 'Which size?': 'y'}),
          isFalse);
      expect(claude.sent, hasLength(1));
    });

    test('an answer missing a question is not sent', () async {
      final (chat, claude) = await started();
      claude.event(toolUse());
      claude.event(request());
      await _settle();
      final ask = chat.entries.whereType<ChatQuestion>().single.ask;

      expect(chat.answer(ask, {'Which colours?': 'Red'}), isFalse);
      expect(claude.sent, isEmpty);
      expect(ask.answerable, isTrue);
    });

    test('dismissing it denies the call with a message', () async {
      final (chat, claude) = await started();
      claude.event(toolUse());
      claude.event(request());
      await _settle();
      final ask = chat.entries.whereType<ChatQuestion>().single.ask;

      expect(chat.decline(ask), isTrue);
      final response = (claude.sent.single['response'] as Map)['response'] as Map;
      expect(response['behavior'], 'deny');
      expect(response['message'], contains('dismissed the question'));
      expect(ask.declined, isTrue);
      expect(ask.answerable, isFalse);
    });

    test('the request may come before the call, and still makes one entry',
        () async {
      final (chat, claude) = await started();
      claude.event(request());
      claude.event(toolUse());
      await _settle();

      expect(chat.entries.whereType<ChatQuestion>(), hasLength(1));
      expect(
        chat.entries.whereType<ChatQuestion>().single.ask.answerable,
        isTrue,
      );
    });

    test('the CLI taking its request back ends the chance to answer', () async {
      final (chat, claude) = await started();
      claude.event(toolUse());
      claude.event(request());
      await _settle();
      final ask = chat.entries.whereType<ChatQuestion>().single.ask;

      claude.event({'type': 'control_cancel_request', 'request_id': 'r1'});
      await _settle();
      expect(ask.answerable, isFalse);
      expect(chat.answer(ask, {
        'Which colours?': 'Red',
        'Which size?': 'Small',
      }), isFalse);
      expect(claude.sent, isEmpty);
    });

    test('the process going away ends it too', () async {
      final (chat, claude) = await started();
      claude.event(toolUse());
      claude.event(request());
      await _settle();
      final ask = chat.entries.whereType<ChatQuestion>().single.ask;

      await claude.end();
      await _settle();
      expect(ask.answerable, isFalse);
      expect(ask.open, isTrue);
    });

    test('the tool result settles it: the answers, or a dismissal', () async {
      final (chat, claude) = await started();
      claude.event(toolUse());
      claude.event(request());
      claude.event({
        'type': 'user',
        'message': {
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': callId,
              'content': 'The user answered: "Which colours?"="Red".',
            },
          ],
        },
        'tool_use_result': {
          'questions': questions,
          'answers': {'Which colours?': 'Red', 'Which size?': 'Large'},
        },
      });
      await _settle();
      final ask = chat.entries.whereType<ChatQuestion>().single.ask;
      expect(ask.answers, {'Which colours?': 'Red', 'Which size?': 'Large'});
      expect(ask.answerable, isFalse);

      // A second question, dismissed elsewhere.
      claude.event(toolUse('toolu_2'));
      claude.event({
        'type': 'user',
        'message': {
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'toolu_2',
              'content': 'The user dismissed the question without answering.',
              'is_error': true,
            },
          ],
        },
        'tool_use_result': 'Error: The user dismissed the question.',
      });
      await _settle();
      final second = chat.entries.whereType<ChatQuestion>().last.ask;
      expect(second.declined, isTrue);
      expect(second.answers, isNull);
    });

    test('any other tool the CLI asks about is refused at once, so it never '
        'waits', () async {
      final (_, claude) = await started();
      claude.event({
        'type': 'control_request',
        'request_id': 'r9',
        'request': {
          'subtype': 'can_use_tool',
          'tool_name': 'Bash',
          'input': {'command': 'rm -rf /srv'},
          'tool_use_id': 'toolu_9',
        },
      });
      await _settle();

      final response = (claude.sent.single['response'] as Map)['response'] as Map;
      expect(claude.sent.single['response']['request_id'], 'r9');
      expect(response['behavior'], 'deny');
      expect(response['message'], contains('Bash was refused'));
    });

    // THE INVARIANT: nothing chat writes reaches a process or session that
    // has been replaced, and no write is dropped without saying so. One test
    // for each event that replaces what chat writes to.
    group('nothing is written to a process that has been replaced', () {
      const answers = {'Which colours?': 'Red', 'Which size?': 'Small'};

      /// A chat of its own, whose every Claude is a fake kept in [fakes], with
      /// a question open in the first.
      Future<(ClaudeChat, List<_FakeClaude>, ChatAsk)> asking({
        Future<void>? hold,
      }) async {
        final fakes = <_FakeClaude>[];
        final chat = ClaudeChat(
          open: (command) async {
            // Reads the chat makes beside its Claude — the transcript, its
            // tasks, the plan's usage — are not one.
            if (!command.contains('stream-json')) return _noHistory();
            if (fakes.isNotEmpty && hold != null) await hold;
            final fake = _FakeClaude();
            fakes.add(fake);
            return fake.channel;
          },
        );
        await chat.start();
        fakes.single.event(toolUse());
        fakes.single.event(request());
        await _settle();
        return (chat, fakes, chat.entries.whereType<ChatQuestion>().single.ask);
      }

      /// The answer cannot be sent, whichever way it is tried, and not even
      /// when the question still believes the old process is waiting.
      void expectNothingReaches(
        ClaudeChat chat,
        List<_FakeClaude> fakes,
        ChatAsk ask,
      ) {
        expect(ask.answerable, isFalse);
        expect(chat.answer(ask, answers), isFalse);
        expect(chat.decline(ask), isFalse);
        // The clearing is the first line; the gate is the second: put the
        // request id back, as if nothing had cleared it.
        ask.requestId = 'r1';
        expect(chat.answer(ask, answers), isFalse);
        expect(chat.decline(ask), isFalse);
        ask.requestId = null;
        for (final fake in fakes) {
          expect(fake.written, isEmpty);
        }
        expect(ask.answers, isNull);
        expect(ask.declined, isFalse);
      }

      test('a question the CLI never asked about, whatever its request id '
          'says, is not written for', () async {
        final (chat, fakes, _) = await asking();
        addTearDown(chat.dispose);
        // Made here, not from a request: no process is its own.
        final invented = ChatAsk.parse(callId, input)!..requestId = 'r-made-up';
        expect(chat.answer(invented, answers), isFalse);
        expect(chat.decline(invented), isFalse);
        expect(fakes.single.written, isEmpty);
      });

      test('a ⋮ mode change and the restart it makes', () async {
        final (chat, fakes, ask) = await asking();
        addTearDown(chat.dispose);
        await chat.restart(permission: ChatPermission.plan);
        expect(fakes, hasLength(2));
        expectNothingReaches(chat, fakes, ask);
      });

      test('a reconnect, which starts Claude again once the old one is gone',
          () async {
        final (chat, fakes, ask) = await asking();
        addTearDown(chat.dispose);
        await fakes.single.end();
        await _settle();
        await chat.resume();
        expect(fakes, hasLength(2));
        expectNothingReaches(chat, fakes, ask);
      });

      test('New chat', () async {
        final (chat, fakes, ask) = await asking();
        addTearDown(chat.dispose);
        await chat.newChat();
        expectNothingReaches(chat, fakes, ask);
      });

      test('another session picked in the sidebar', () async {
        final (chat, fakes, ask) = await asking();
        addTearDown(chat.dispose);
        await chat.continueFrom(
          const ClaudeAgent(
            sessionId: 'cf58d27a-da65-4e9b-a896-078306134024',
            name: 'Zsh config fix',
            cwd: '/home/me',
            kind: 'background',
            id: 'cf58d27a',
            state: 'done',
          ),
        );
        expect(fakes, hasLength(2));
        expectNothingReaches(chat, fakes, ask);
      });

      test('the process ending, after which a message is refused out loud',
          () async {
        final (chat, fakes, ask) = await asking();
        addTearDown(chat.dispose);
        await fakes.single.end();
        await _settle();
        expectNothingReaches(chat, fakes, ask);

        await chat.send('are you there?');
        expect(fakes.single.written, isEmpty);
        final notice = chat.entries.whereType<ChatNotice>().last;
        expect(notice.failed, isTrue);
        expect(notice.text, contains('Not sent: Claude is not running'));
        expect(notice.text, contains('are you there?'));
      });

      test('the tab closing', () async {
        final (chat, fakes, ask) = await asking();
        chat.dispose();
        expect(chat.answer(ask, answers), isFalse);
        expect(chat.decline(ask), isFalse);
        ask.requestId = 'r1';
        expect(chat.answer(ask, answers), isFalse);
        expect(fakes.single.written, isEmpty);
        expect(chat.unsendable, 'This chat is closed.');
      });

      test('a restart still under way: the box is not for sending, the old '
          'process gets nothing, and a message is refused out loud', () async {
        final release = Completer<void>();
        final (chat, fakes, ask) = await asking(hold: release.future);
        addTearDown(chat.dispose);
        final restarting = chat.restart(permission: ChatPermission.bypass);
        await _settle();

        // Between the old process and the new one.
        expect(chat.ready, isFalse);
        expect(chat.unsendable, isNotNull);
        await chat.send('hello');
        expect(fakes.single.written, isEmpty);
        expect(chat.entries.whereType<ChatNotice>().last.text,
            contains('Not sent'));
        expectNothingReaches(chat, fakes, ask);

        release.complete();
        await restarting;
        expect(chat.unsendable, isNull);
        // And the new process is written to as before.
        await chat.send('now it is up');
        expect(fakes.last.sent.single['type'], 'user');
      });

      test('a message while Claude is still answering is refused out loud, '
          'not dropped', () async {
        final (chat, fakes, _) = await asking();
        addTearDown(chat.dispose);
        await chat.send('first');
        await chat.send('second');
        expect(fakes.single.sent.where((m) => m['type'] == 'user'), hasLength(1));
        expect(chat.entries.whereType<ChatNotice>().last.text,
            allOf(contains('Not sent: Claude is still answering.'),
                contains('second')));
      });
    });

    test('only the tool spelt AskUserQuestion is ever allowed: a lookalike '
        'name, even on a real question\'s id, is denied and opens nothing',
        () async {
      for (final name in <Object?>[
        'askuserquestion',
        'ASKUSERQUESTION',
        'AskUserQuestion ',
        ' AskUserQuestion',
        'AskUserQuestion\u200b',
        'AskUserQuestionX',
        'Ask UserQuestion',
        'mcp__srv__AskUserQuestion',
        'Bash',
        '',
        null,
        5,
      ]) {
        final (chat, claude) = await started();
        // A genuine question, called but not yet asked about.
        claude.event(toolUse());
        // Then a request that carries its id and its input but another name.
        claude.event({
          'type': 'control_request',
          'request_id': 'r-lookalike',
          'request': {
            'subtype': 'can_use_tool',
            'tool_name': name,
            'input': input,
            'tool_use_id': callId,
            'requires_user_interaction': true,
          },
        });
        await _settle();

        final ask = chat.entries.whereType<ChatQuestion>().single.ask;
        expect(ask.answerable, isFalse, reason: 'a request named "$name"');
        expect(chat.answer(ask, {
          'Which colours?': 'Red',
          'Which size?': 'Small',
        }), isFalse, reason: '"$name"');
        final reply = (claude.sent.single['response'] as Map)['response'] as Map;
        expect(reply['behavior'], 'deny', reason: '"$name"');
        expect(claude.sent.single['response']['request_id'], 'r-lookalike');
        // Nothing but that one refusal was ever written.
        expect(claude.sent, hasLength(1), reason: '"$name"');
      }
    });

    test('no response but the answer\'s is an allow, and that adds `answers` '
        'to the call\'s own input and nothing else', () async {
      final (chat, claude) = await started();
      claude.event(toolUse());
      claude.event(request());
      claude.event({
        'type': 'control_request',
        'request_id': 'r-bash',
        'request': {
          'subtype': 'can_use_tool',
          'tool_name': 'Bash',
          'input': {'command': 'id'},
          'tool_use_id': 'toolu_bash',
        },
      });
      await _settle();
      final ask = chat.entries.whereType<ChatQuestion>().single.ask;
      chat.answer(ask, {'Which colours?': 'Red', 'Which size?': 'Small'});

      final allows = [
        for (final m in claude.sent)
          if (((m['response'] as Map)['response'] as Map?)?['behavior'] ==
              'allow')
            m,
      ];
      expect(allows, hasLength(1));
      final updated =
          (((allows.single['response'] as Map)['response'] as Map)['updatedInput']
              as Map);
      expect(updated.keys.toSet(), {...input.keys, 'answers'});
      expect(updated['questions'], input['questions']);
      expect((allows.single['response'] as Map)['request_id'], 'r1');
    });

    test('an answer for a question that is not there, or short of one, is '
        'not sent', () async {
      final (chat, claude) = await started();
      claude.event(toolUse());
      claude.event(request());
      await _settle();
      final ask = chat.entries.whereType<ChatQuestion>().single.ask;

      expect(chat.answer(ask, {
        'Which colours?': 'Red',
        'Which size?': 'Small',
        'Anything else?': 'rm -rf',
      }), isFalse);
      expect(claude.sent, isEmpty);
      expect(ask.answerable, isTrue);
    });

    test('a question already answered is not asked about again', () async {
      final (chat, claude) = await started();
      claude.event(toolUse());
      claude.event(request());
      await _settle();
      final ask = chat.entries.whereType<ChatQuestion>().single.ask;
      chat.answer(ask, {'Which colours?': 'Red', 'Which size?': 'Small'});
      claude.written.clear();

      claude.event(request(callId, 'r-again'));
      await _settle();
      expect(ask.answerable, isFalse);
      final reply = (claude.sent.single['response'] as Map)['response'] as Map;
      expect(reply['behavior'], 'deny');
    });

    test('a refusal names the tool only as bounded text', () async {
      final (_, claude) = await started();
      claude.event({
        'type': 'control_request',
        'request_id': 'r-long',
        'request': {
          'subtype': 'can_use_tool',
          'tool_name': 'X\x1b[31m\x07${'y' * 200}',
          'input': const {},
          'tool_use_id': 'toolu_x',
        },
      });
      await _settle();
      final message =
          ((claude.sent.single['response'] as Map)['response'] as Map)['message']
              as String;
      expect(message, isNot(contains('\x1b')));
      expect(message, isNot(contains('\x07')));
      expect(message.length, lessThan(300));
    });

    test('a request that is not even an object gets an error, never silence',
        () async {
      final (chat, claude) = await started();
      claude.event({
        'type': 'control_request',
        'request_id': 'r-bad',
        'request': 'can_use_tool',
      });
      claude.event({'type': 'control_request', 'request_id': 'r-none'});
      await _settle();

      expect(claude.sent, hasLength(2));
      for (final reply in claude.sent) {
        expect((reply['response'] as Map)['subtype'], 'error');
      }
      expect(claude.sent.map((r) => (r['response'] as Map)['request_id']),
          ['r-bad', 'r-none']);
      expect(chat.entries.whereType<ChatQuestion>(), isEmpty);
    });

    test('asked again while still open: the older request gets an error and '
        'the newer is the one answered', () async {
      final (chat, claude) = await started();
      claude.event(toolUse());
      claude.event(request(callId, 'r-old'));
      claude.event(request(callId, 'r-new'));
      await _settle();

      final older = claude.sent.single['response'] as Map;
      expect(older['subtype'], 'error');
      expect(older['request_id'], 'r-old');
      final ask = chat.entries.whereType<ChatQuestion>().single.ask;
      expect(ask.requestId, 'r-new');
      claude.written.clear();
      expect(
        chat.answer(ask, {'Which colours?': 'Red', 'Which size?': 'Small'}),
        isTrue,
      );
      expect((claude.sent.single['response'] as Map)['request_id'], 'r-new');
    });

    test('a request of a kind this chat does not know gets an error, and a '
        'malformed question is refused', () async {
      final (chat, claude) = await started();
      claude.event({
        'type': 'control_request',
        'request_id': 'r5',
        'request': {'subtype': 'something_new'},
      });
      claude.event({
        'type': 'control_request',
        'request_id': 'r6',
        'request': {
          'subtype': 'can_use_tool',
          'tool_name': 'AskUserQuestion',
          'input': {'questions': 'not a list'},
          'tool_use_id': 'toolu_6',
        },
      });
      await _settle();

      expect(chat.entries.whereType<ChatQuestion>(), isEmpty);
      expect(claude.sent, hasLength(2));
      expect((claude.sent[0]['response'] as Map)['subtype'], 'error');
      final refused = (claude.sent[1]['response'] as Map)['response'] as Map;
      expect(refused['behavior'], 'deny');
    });

    test('read back from a transcript it shows the answer that was given, '
        'and a question never answered stays open with nobody to ask',
        () async {
      // As the transcript file holds them: the call, then the user line with
      // toolUseResult. The second call has no result yet.
      final text = [
        jsonEncode(toolUse()),
        jsonEncode({
          'type': 'user',
          'message': {
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': callId,
                'content': 'The user answered: …',
              },
            ],
          },
          'toolUseResult': {
            'questions': questions,
            'answers': {'Which colours?': 'Red, Blue', 'Which size?': 'XL'},
          },
        }),
        jsonEncode(toolUse('toolu_open')),
      ].join('\n');
      final size = utf8.encode('$text\n').length;
      final host = _LiveHost('$size\n$text\n');
      final chat = ClaudeChat(open: host.open);
      addTearDown(chat.dispose);
      await chat.continueFrom(_live);

      final asks = [for (final q in chat.entries.whereType<ChatQuestion>()) q.ask];
      expect(asks, hasLength(2));
      expect(asks[0].answers, {'Which colours?': 'Red, Blue', 'Which size?': 'XL'});
      expect(asks[1].open, isTrue);
      expect(asks[1].answerable, isFalse);
      // Nothing was sent: a watched session is answered at its terminal.
      expect(host.startedClaude, isFalse);
    });

    test('a session held at a question says so, in its row and when typed '
        'into', () {
      final asking = ClaudeAgent.fromJson({
        'sessionId': 'aaaa1111-0000-0000-0000-000000000000',
        'id': 'aaaa1111',
        'status': 'idle',
        'state': 'blocked',
        'waitingFor': 'input needed',
      })!;
      final approving = ClaudeAgent.fromJson({
        'sessionId': 'bbbb2222-0000-0000-0000-000000000000',
        'status': 'idle',
        'waitingFor': 'permission prompt',
      })!;
      expect(asking.asking, isTrue);
      expect(asking.waitingText, 'an answer');
      expect(approving.asking, isFalse);
      expect(approving.waitingText, 'permission prompt');
    });
  });

  test('the command finds Claude, starts where the files are, and '
      'resumes', () {
    final command = ClaudeChat.command(
      cwd: "/srv/it's here",
      permission: ChatPermission.bypass,
      resume: 'f44e6c8b',
    );
    // JSON both ways, and permission prompts sent to this chat over stdio —
    // which is what gets it the AskUserQuestion tool; --permission-prompts
    // none withholds it.
    expect(command, contains('--input-format stream-json'));
    expect(command, contains('--output-format stream-json'));
    expect(command, contains('--permission-mode bypassPermissions'));
    expect(command, contains('--permission-prompt-tool stdio'));
    expect(command, isNot(contains('--permission-prompts none')));
    // An exec channel's shell is not a login shell: PATH first, then the
    // installer's own places, then the login shell's PATH.
    expect(command, contains(r'command -v claude'));
    expect(command, contains(r'"$HOME/.local/bin/claude"'));
    expect(command, contains(r'"$SHELL" -lc "command -v claude"'));
    // Only stdout crosses the channel, so stderr has to join it.
    expect(command, contains('2>&1'));
  });

  test('the directory and the session reach Claude exactly as given, '
      'whatever they hold', () async {
    // Run the command the way an SSH exec does — handed to a shell, which
    // runs its sh -c — with a stand-in claude that says where it started and
    // what it was given. Asserting on the command's text is what let a
    // quote that closed the outer one through: it read right and ran wrong.
    final root = await Directory.systemTemp.createTemp('chat-command');
    addTearDown(() => root.delete(recursive: true));
    final bin = await Directory('${root.path}/bin').create();
    final claude = File('${bin.path}/claude')
      ..writeAsStringSync('#!/bin/sh\npwd\nprintf "%s\\n" "\$@"\n');
    await Process.run('chmod', ['+x', claude.path]);
    const session = r"s'1 $(echo RAN)";

    for (final name in ['my dir', "it's here", r'$(echo RAN)', 'a;b']) {
      final dir = await Directory('${root.path}/$name').create();
      final result = await Process.run(
        'sh',
        ['-c', ClaudeChat.command(cwd: dir.path, resume: session)],
        environment: {'PATH': '${bin.path}:/usr/bin:/bin'},
      );
      final lines = (result.stdout as String).split('\n');
      expect(lines.first, dir.path, reason: 'started in "$name"');
      final at = lines.indexOf('--resume');
      expect(at, isNot(-1), reason: 'resumed in "$name"');
      expect(lines[at + 1], session, reason: 'the session, in "$name"');
      expect(result.stdout, isNot(contains('RAN\n')), reason: name);
    }
  });

  test('with no directory of its own it starts where the login does', () {
    expect(ClaudeChat.command(), isNot(contains('cd ')));
    expect(
      ClaudeChat.command(),
      contains('--permission-mode acceptEdits'),
    );
    expect(ClaudeChat.command(), isNot(contains('--resume')));
  });

  test('changing what Claude may do restarts it on the same '
      'conversation', () async {
    final channels = <_FakeClaude>[];
    final commands = <String>[];
    final chat = ClaudeChat(
      open: (command) async {
        commands.add(command);
        final claude = _FakeClaude();
        channels.add(claude);
        return claude.channel;
      },
    );
    addTearDown(chat.dispose);
    await chat.start();
    channels.single.event({
      'type': 'system',
      'subtype': 'init',
      'session_id': 'abc-123',
    });
    await _settle();

    await chat.restart(permission: ChatPermission.plan);
    expect(chat.permission, ChatPermission.plan);
    expect(channels.first.closed, isTrue);
    expect(commands.length, 2);
    expect(commands.first, isNot(contains('--resume')));
    // The second process picks the conversation up where the first left it.
    // How the id is quoted is the test above's; this one is that it is there.
    expect(commands.last, contains('--resume'));
    expect(commands.last, contains('abc-123'));
    expect(commands.last, contains('--permission-mode plan'));
    expect(chat.ready, isTrue);
    // Stopping on purpose is not Claude going away.
    expect(chat.ended, isFalse);
  });

  test('the sessions on the host come back however each row is shaped',
      () async {
    final claude = _FakeClaude();
    final chat = ClaudeChat(open: _routed(claude));
    addTearDown(chat.dispose);
    // Exactly the shapes the CLI prints: a background session at work, one
    // sitting idle, an interactive one — which carries no id and no state —
    // and one whose process has gone, which carries no pid and no status.
    claude.line(jsonEncode([
      {
        'pid': 4079548,
        'id': '81badf4a',
        'cwd': '/srv/app',
        'kind': 'background',
        'startedAt': 1789740731285,
        'sessionId': '81badf4a-7e9f-4f01-b098-6968dbe5f070',
        'name': 'chat mode feature',
        'status': 'busy',
        'state': 'working',
      },
      {
        'pid': 340952,
        'id': '1e2f8fcd',
        'cwd': '/srv/app',
        'kind': 'background',
        'sessionId': '399b2842-52ea-4019-8f0c-3f44192ab977',
        'name': 'database client ui development',
        'status': 'idle',
        'state': 'done',
      },
      {
        'pid': 1259765,
        'cwd': '/home/me',
        'kind': 'interactive',
        'sessionId': '456d3c0e-2a17-4943-a2f4-6cdd25893a19',
        'name': 'dev-e0',
        'status': 'idle',
      },
      {
        'id': 'cf58d27a',
        'cwd': '/home/me',
        'kind': 'background',
        'sessionId': 'cf58d27a-da65-4e9b-a896-078306134024',
        'name': 'Zsh config fix',
        'state': 'done',
      },
      // Nothing to resume, and nothing that is a row at all: both left out
      // rather than drawn half empty.
      {'kind': 'background', 'name': 'no session here'},
      'not a row',
    ]));
    // The fake's close waits for a listener, so the listing is under way
    // before the stream ends.
    final listing = chat.agents();
    await claude.end();
    final agents = await listing;
    expect(agents.map((agent) => agent.name), [
      'chat mode feature',
      'database client ui development',
      'dev-e0',
      'Zsh config fix',
    ]);
    final [busy, idle, interactive, finished] = agents;
    expect(busy.live, isTrue);
    expect(busy.busy, isTrue);
    expect(idle.live, isTrue);
    expect(idle.busy, isFalse);
    // An interactive session has no short id, which is why none can be
    // attached, and somebody is typing into it.
    expect(interactive.interactive, isTrue);
    expect(interactive.id, isNull);
    expect(interactive.live, isTrue);
    // No pid: the process has gone, whatever else the row says.
    expect(finished.live, isFalse);
    expect(finished.busy, isFalse);
    expect(busy.startedAt, DateTime.fromMillisecondsSinceEpoch(1789740731285));
  });

  test('a word from the host beside the list does not cost the list',
      () async {
    final claude = _FakeClaude();
    final chat = ClaudeChat(open: _routed(claude));
    addTearDown(chat.dispose);
    // stderr is folded into stdout, so a warning can sit in front of it.
    claude.line('warning: something the host wanted to say');
    claude.line(jsonEncode([
      {
        'pid': 1,
        'id': 'aaaa1111',
        'cwd': '/srv',
        'kind': 'background',
        'sessionId': 'aaaa1111-0000-0000-0000-000000000000',
        'name': 'still found',
        'status': 'idle',
      },
    ]));
    final listing = chat.agents();
    await claude.end();
    expect((await listing).single.name, 'still found');
  });

  test('a host whose Claude has no agents command says what it said',
      () async {
    final claude = _FakeClaude();
    final chat = ClaudeChat(open: _routed(claude));
    addTearDown(chat.dispose);
    claude.line("error: unknown command 'agents'");
    // The expectation is attached before the stream ends, so the throw has
    // somewhere to land.
    final listing = expectLater(
      chat.agents(),
      throwsA(
        isA<SshSessionException>().having(
          (error) => '$error',
          'what the host said',
          contains("unknown command 'agents'"),
        ),
      ),
    );
    await claude.end();
    await listing;
  });

  test('picking up a session that has finished continues it where it was',
      () async {
    final commands = <String>[];
    final chat = ClaudeChat(
      open: (command) async {
        commands.add(command);
        if (command.contains('.jsonl')) return _noHistory();
        if (command.contains('/usage')) return _says(usageOnHost);
        if (command.contains('/tasks')) return _says(tasksOnHost);
        return _FakeClaude().channel;
      },
    );
    addTearDown(chat.dispose);

    await chat.continueFrom(
      const ClaudeAgent(
        sessionId: 'cf58d27a-da65-4e9b-a896-078306134024',
        name: 'Zsh config fix',
        cwd: '/home/me',
        kind: 'background',
        id: 'cf58d27a',
      ),
    );

    expect(commands.last, contains('--resume'));
    expect(commands.last, contains('cf58d27a-da65-4e9b-a896-078306134024'));
    expect(commands.last, isNot(contains('--fork-session')));
    expect(
      chat.entries.whereType<ChatNotice>().single.text,
      allOf(contains('Zsh config fix'), isNot(contains('copy'))),
    );
  });

  test('listing the sessions, and the id of one continued, reach Claude '
      'exactly as given', () async {
    // The same real shell the command test uses: what a session id holds —
    // and a name holds anything the user typed — must not be read by any
    // shell it passes through.
    final root = await Directory.systemTemp.createTemp('chat-agents');
    addTearDown(() => root.delete(recursive: true));
    final bin = await Directory('${root.path}/bin').create();
    final claude = File('${bin.path}/claude')
      ..writeAsStringSync('#!/bin/sh\nprintf "%s\\n" "\$@"\n');
    await Process.run('chmod', ['+x', claude.path]);
    final path = {'PATH': '${bin.path}:/usr/bin:/bin'};

    final listed = await Process.run(
      'sh',
      ['-c', ClaudeChat.agentsCommand()],
      environment: path,
    );
    expect((listed.stdout as String).split('\n'), containsAllInOrder([
      'agents',
      '--json',
    ]));

    for (final session in [
      r"s'1 $(echo RAN)",
      'a;b',
      'has a space',
      r'$(touch ' '${root.path}/RAN)',
    ]) {
      final result = await Process.run(
        'sh',
        ['-c', ClaudeChat.command(resume: session)],
        environment: path,
      );
      final lines = (result.stdout as String).split('\n');
      final at = lines.indexOf('--resume');
      expect(at, isNot(-1), reason: session);
      expect(lines[at + 1], session, reason: session);
      expect(result.stdout, isNot(contains('RAN\n')), reason: session);
    }
    // Nothing a session id held was ever run.
    expect(File('${root.path}/RAN').existsSync(), isFalse);
  });

  test('picking a session up shows what was already said in it, drawn as a '
      'live turn is', () async {
    final text = _transcript(_live.sessionId);
    final host = _hostWithHistory('${utf8.encode(text).length}\n$text\n');
    final chat = ClaudeChat(open: host.open);
    addTearDown(chat.dispose);

    await chat.continueFrom(_live);

    // What the user typed — a plain string, or the text blocks this chat
    // sends — and what Claude answered, in order; nothing Claude Code put
    // there by itself, no thinking, no subagent.
    expect(
      [
        for (final entry in chat.entries)
          if (entry is ChatSaid) '${entry.mine ? 'me' : 'claude'}: ${entry.text}',
      ],
      [
        'me: why is nginx slow?',
        'claude: Let me read the error log.',
        'claude: Three upstream timeouts.',
        'me: and the fix?',
      ],
    );
    // The tool folds its result in, as it does live, and does not spin.
    final run = chat.entries.whereType<ChatToolRun>().single;
    expect(run.summary, 'tail -n 50 /var/log/nginx/error.log');
    expect(run.result, '3 upstream timeouts');
    // The interruption is said, quietly; the continuation is said after the
    // history, where it happens.
    final notices = chat.entries.whereType<ChatNotice>().toList();
    expect(notices.first.text, contains('interrupted'));
    expect(notices.last.text, contains('Watching'));
    expect(chat.entries.last, isA<ChatNotice>());
    // Its history comes first, then it is followed from there.
    expect(host.commands.first, contains('3cae97ea-5874-4a0b-b8bd-6ad88edf0e2f'));
    expect(host.commands.first, contains('.jsonl'));
    expect(host.commands.last, contains(' -f '));
  });

  test('a long transcript is read from its tail, and says so', () async {
    final text = _transcript(_live.sessionId);
    // Bigger than what is read: the first line of what came is a line cut in
    // half, and is dropped rather than misread.
    final host = _hostWithHistory(
      '${ClaudeChat.historyLimit * 40}\n'
      'e","content":"half of a line"}\n$text\n',
    );
    final chat = ClaudeChat(open: host.open);
    addTearDown(chat.dispose);

    await chat.continueFrom(_live);

    // How much the host reads is the shell test's to prove, below; this one
    // is what the chat does with a read that cut a line: drops it, and says
    // there is more for the page to offer.
    expect(host.commands.first, contains('.jsonl'));
    expect(chat.hasEarlier, isTrue);
    expect(chat.canLoadEarlier, isTrue);
    expect(chat.entries.first, isA<ChatSaid>());
    expect(chat.entries.whereType<ChatSaid>().first.text, 'why is nginx slow?');
  });

  test('a running session whose transcript cannot be read says why, and '
      'starts nothing in its place', () async {
    final host = _hostWithHistory('No transcript for this session on the host.');
    final chat = ClaudeChat(open: host.open);
    addTearDown(chat.dispose);

    await chat.continueFrom(_live);

    expect(
      chat.entries.whereType<ChatNotice>().single.text,
      contains('No transcript'),
    );
    expect(chat.watching, isNull);
    // Nothing but the history read and a read of the task store.
    expect(
      host.commands.where((c) => !c.contains('/tasks')).single,
      contains('.jsonl'),
    );
  });

  test('an id that is not a session id is never looked for on the host',
      () async {
    final host = _hostWithHistory('');
    final chat = ClaudeChat(open: host.open);
    addTearDown(chat.dispose);

    await chat.continueFrom(
      const ClaudeAgent(
        sessionId: r'x; touch /tmp/RAN',
        name: 'odd',
        cwd: '/',
        kind: 'background',
      ),
    );

    expect(host.commands.where((command) => command.contains('.jsonl')), isEmpty);
  });

  test('the transcript is found by its id, wherever the host keeps it, and '
      'the id reaches find exactly as given', () async {
    // A real shell and a real directory tree: the id and the path built from
    // it pass through two shells, and what they hold must not be read by
    // either. CLAUDE_CONFIG_DIR is honoured, since a host can move it.
    final root = await Directory.systemTemp.createTemp('chat-history');
    addTearDown(() => root.delete(recursive: true));
    final projects = await Directory(
      '${root.path}/config/projects/-srv-some-project',
    ).create(recursive: true);

    for (final id in [
      '3cae97ea-5874-4a0b-b8bd-6ad88edf0e2f',
      "it's",
      'has a space',
      // No slash: a file name cannot hold one. If this ran, RAN would appear
      // in the directory the shell was started in.
      r'$(touch RAN)',
      'a;b',
    ]) {
      File('${projects.path}/$id.jsonl').writeAsStringSync('{"line":"$id"}\n');
      final result = await Process.run(
        'sh',
        ['-c', ClaudeChat.historyCommand(id)],
        workingDirectory: root.path,
        environment: {
          'HOME': '${root.path}/nowhere',
          'CLAUDE_CONFIG_DIR': '${root.path}/config',
          'PATH': '/usr/bin:/bin',
        },
      );
      final lines = (result.stdout as String).trim().split('\n');
      expect(int.tryParse(lines.first.trim()), isNotNull, reason: id);
      expect(lines.last, contains(id.replaceAll('"', r'\"')), reason: id);
    }
    expect(File('${root.path}/RAN').existsSync(), isFalse);
  });

  test('watching a running session draws what it adds, as it adds it',
      () async {
    final text = _transcript(_live.sessionId);
    final size = utf8.encode('$text\n').length;
    final host = _LiveHost('$size\n$text\n');
    final chat = ClaudeChat(open: host.open);
    addTearDown(chat.dispose);

    await chat.continueFrom(_live);

    // Followed from exactly where the history stopped, for as long as that
    // process lives — and nothing started: watching is not talking.
    expect(chat.watching?.sessionId, _live.sessionId);
    expect(host.commands.last, contains('-c +${size + 1} -f'));
    expect(host.commands.last, contains('kill -0 ${_live.pid}'));
    expect(host.startedClaude, isFalse);
    final before = chat.entries.length;

    host.adds({
      'type': 'assistant',
      'message': {
        'role': 'assistant',
        'content': [
          {
            'type': 'tool_use',
            'id': 'toolu_live',
            'name': 'Bash',
            'input': {'command': 'systemctl reload nginx'},
          },
        ],
      },
    });
    await _settle();
    final run = chat.entries.whereType<ChatToolRun>().last;
    expect(run.summary, 'systemctl reload nginx');
    expect(run.done, isFalse);

    host.adds({
      'type': 'user',
      'message': {
        'role': 'user',
        'content': [
          {'type': 'tool_result', 'tool_use_id': 'toolu_live', 'content': 'ok'},
        ],
      },
    });
    host.adds(_said('Reloaded.'));
    await _settle();
    expect(run.result, 'ok');
    expect(chat.entries.length, before + 2);
    expect((chat.entries.last as ChatSaid).text, 'Reloaded.');
  });

  test('a line the history cut in half is finished by the follow, and '
      'drawn once', () async {
    final whole = jsonEncode(_said('said across the cut'));
    final half = whole.length ~/ 2;
    final history = '${jsonEncode(_said('before'))}\n${whole.substring(0, half)}';
    final host = _LiveHost('${utf8.encode(history).length}\n$history');
    final chat = ClaudeChat(open: host.open);
    addTearDown(chat.dispose);

    await chat.continueFrom(_live);
    host.adds('${whole.substring(half)}\n');
    await _settle();

    expect(
      chat.entries.whereType<ChatSaid>().map((said) => said.text),
      ['before', 'said across the cut'],
    );
  });

  test('when the session ends the tab says so, stops watching and '
      'continues it in place', () async {
    final host = _LiveHost('0\n');
    final chat = ClaudeChat(open: host.open);
    addTearDown(chat.dispose);
    await chat.continueFrom(_live);

    host.adds('\nsshbox:ended\n');
    await host.follow!.close();
    await _settle();

    expect(chat.watching, isNull);
    expect(
      chat.entries.whereType<ChatNotice>().last.text,
      contains('no longer running'),
    );
    // No longer live, so resumable in place: the same conversation, no copy.
    expect(host.startedClaude, isTrue);
    expect(host.commands.last, isNot(contains('--fork-session')));
  });

  test('a follow that drops without the session ending does not say it '
      'ended, and a reconnect picks it up again', () async {
    final host = _LiveHost('0\n');
    final chat = ClaudeChat(open: host.open);
    addTearDown(chat.dispose);
    await chat.continueFrom(_live);

    await host.follow!.close();
    await _settle();

    expect(chat.watching?.sessionId, _live.sessionId);
    expect(
      chat.entries.whereType<ChatNotice>().any(
        (notice) => notice.text.contains('no longer running'),
      ),
      isFalse,
    );

    final followsBefore =
        host.commands.where((command) => command.contains(' -f ')).length;
    await chat.resume();
    expect(
      host.commands.where((command) => command.contains(' -f ')).length,
      followsBefore + 1,
    );
    expect(host.startedClaude, isFalse);
  });

  test('closing the tab stops following', () async {
    final host = _LiveHost('0\n');
    final chat = ClaudeChat(open: host.open);
    await chat.continueFrom(_live);
    expect(host.followClosed, isFalse);

    chat.dispose();
    await _settle();
    expect(host.followClosed, isTrue);
  });

  test('pinned sessions come first, in the order they were pinned, and are '
      'marked', () async {
    final claude = _FakeClaude();
    final chat = ClaudeChat(open: _routed(claude));
    addTearDown(chat.dispose);
    Map<String, Object?> bg(String id, String name) => {
      'pid': 1,
      'id': id,
      'cwd': '/srv',
      'kind': 'background',
      'sessionId': '$id-0000-0000-0000-000000000000',
      'name': name,
      'status': 'idle',
    };
    claude.line(jsonEncode([
      bg('aaaa1111', 'first listed'),
      bg('bbbb2222', 'pinned second'),
      bg('cccc3333', 'pinned first'),
    ]));
    claude.line('--- pins');
    claude.line('["cccc3333","bbbb2222","gone0000"]');
    final listing = chat.agents();
    await claude.end();
    final agents = await listing;

    expect(agents.map((agent) => agent.name), [
      'pinned first',
      'pinned second',
      'first listed',
    ]);
    expect(agents.map((agent) => agent.pinned), [true, true, false]);
  });

  test('a host with no pins file has nothing pinned', () async {
    final claude = _FakeClaude();
    final chat = ClaudeChat(open: _routed(claude));
    addTearDown(chat.dispose);
    claude.line(jsonEncode([
      {
        'pid': 1,
        'id': 'aaaa1111',
        'cwd': '/srv',
        'kind': 'background',
        'sessionId': 'aaaa1111-0000-0000-0000-000000000000',
        'name': 'lone',
        'status': 'idle',
      },
    ]));
    claude.line('--- pins');
    final listing = chat.agents();
    await claude.end();

    expect((await listing).single.pinned, isFalse);
  });

  test('the listing command reads the pins beside the sessions, through a '
      'real shell', () async {
    final root = await Directory.systemTemp.createTemp('chat-pins');
    addTearDown(() => root.delete(recursive: true));
    final bin = await Directory('${root.path}/bin').create();
    File('${bin.path}/claude').writeAsStringSync(
      '#!/bin/sh\necho \'[{"id":"aaaa1111"}]\'\n',
    );
    await Process.run('chmod', ['+x', '${bin.path}/claude']);
    final jobs = await Directory('${root.path}/config/jobs').create(
      recursive: true,
    );
    File('${jobs.path}/pins.json').writeAsStringSync('["aaaa1111"]');

    final result = await Process.run(
      'sh',
      ['-c', ClaudeChat.agentsCommand()],
      environment: {
        'PATH': '${bin.path}:/usr/bin:/bin',
        'HOME': '${root.path}/nowhere',
        'CLAUDE_CONFIG_DIR': '${root.path}/config',
      },
    );
    final [listed, pins] = (result.stdout as String).split('\n--- pins\n');
    expect(jsonDecode(listed), [
      {'id': 'aaaa1111'},
    ]);
    expect(jsonDecode(pins), ['aaaa1111']);
  });

  group('following, through a real shell', () {
    late Directory root;
    late File transcript;
    Map<String, String> env() => {
      'HOME': '${root.path}/nowhere',
      'CLAUDE_CONFIG_DIR': '${root.path}/config',
      'PATH': '/usr/bin:/bin',
    };

    setUp(() async {
      root = await Directory.systemTemp.createTemp('chat-follow');
      final projects = await Directory(
        '${root.path}/config/projects/-srv',
      ).create(recursive: true);
      transcript = File('${projects.path}/${_live.sessionId}.jsonl')
        ..writeAsStringSync('{"n":1}\n{"n":2}\n');
    });
    tearDown(() => root.delete(recursive: true));

    /// A process standing in for the session, whose pid the follow watches.
    Future<Process> session() => Process.start('sleep', ['60']);

    /// Every `tail` still reading this test's transcript.
    Future<int> tails() async {
      final ps = await Process.run('ps', ['-eo', 'args']);
      return (ps.stdout as String)
          .split('\n')
          .where((line) => line.startsWith('tail') && line.contains(root.path))
          .length;
    }

    test('it hands over what is added after where it starts, and nothing '
        'before', () async {
      final alive = await session();
      addTearDown(alive.kill);
      final follow = await Process.start(
        'sh',
        [
          '-c',
          ClaudeChat.followCommand(
            _live.sessionId,
            from: '{"n":1}\n'.length,
            pid: alive.pid,
          ),
        ],
        environment: env(),
      );
      final seen = <String>[];
      final lines = follow.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      transcript.writeAsStringSync('{"n":3}\n', mode: FileMode.append);
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(seen.where((line) => line.isNotEmpty), ['{"n":2}', '{"n":3}']);
      await follow.stdin.close();
      await follow.exitCode.timeout(const Duration(seconds: 10));
      await lines.cancel();
    });

    test('it says the session ended, and ends, when its process goes',
        () async {
      final alive = await session();
      final follow = await Process.start(
        'sh',
        [
          '-c',
          ClaudeChat.followCommand(_live.sessionId, from: 0, pid: alive.pid),
        ],
        environment: env(),
      );
      final out = follow.stdout.transform(utf8.decoder).join();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      alive.kill();
      await follow.exitCode.timeout(const Duration(seconds: 15));
      expect(await out, contains('\nsshbox:ended\n'));
      expect(await tails(), 0);
    });

    test('closing the channel leaves nothing following on the host',
        () async {
      final alive = await session();
      addTearDown(alive.kill);
      final follow = await Process.start(
        'sh',
        [
          '-c',
          ClaudeChat.followCommand(_live.sessionId, from: 0, pid: alive.pid),
        ],
        environment: env(),
      );
      final drained = follow.stdout.drain<void>();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(await tails(), 1);
      // What the channel closing looks like to the host: stdin at its end.
      await follow.stdin.close();
      await follow.exitCode.timeout(const Duration(seconds: 10));
      await drained;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await tails(), 0);
    });

    test('the history read is the last of the file up to the size it '
        'reports, and never more than the limit', () async {
      // Bigger than the limit, so only its end is read — by bytes, whole
      // lines or not.
      final big = List.filled(ClaudeChat.historyLimit + 1000, 'x').join();
      transcript.writeAsStringSync(big);
      final result = await Process.run(
        'sh',
        ['-c', ClaudeChat.historyCommand(_live.sessionId)],
        environment: env(),
        stdoutEncoding: null,
      );
      final bytes = result.stdout as List<int>;
      final nl = bytes.indexOf(10);
      expect(int.parse(String.fromCharCodes(bytes.sublist(0, nl))), big.length);
      final body = bytes.sublist(nl + 1);
      expect(body.length, ClaudeChat.historyLimit);
      expect(String.fromCharCodes(body), big.substring(1000));
    });

    test('the id reaches find exactly as given, and nothing in it runs',
        () async {
      final alive = await session();
      addTearDown(alive.kill);
      for (final id in ["it's", 'has a space', r'$(touch RAN)', 'a;b']) {
        File('${transcript.parent.path}/$id.jsonl')
            .writeAsStringSync('{"id":"$id"}\n');
        final follow = await Process.start(
          'sh',
          ['-c', ClaudeChat.followCommand(id, from: 0, pid: alive.pid)],
          environment: env(),
          workingDirectory: root.path,
        );
        final first = follow.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first;
        expect(
          await first.timeout(const Duration(seconds: 5)),
          contains(id.replaceAll('"', r'\"')),
          reason: id,
        );
        await follow.stdin.close();
        await follow.exitCode.timeout(const Duration(seconds: 10));
      }
      expect(File('${root.path}/RAN').existsSync(), isFalse);
    });
  });

  group('typing into the session being watched', () {
    ClaudeChat watcher(
      _LiveHost host, {
      Duration? deliveryTimeout,
      Duration? dropGrace,
    }) {
      final chat = ClaudeChat(
        open: host.open,
        openTerminal: host.openTerminal,
        deliveryTimeout: deliveryTimeout ?? const Duration(seconds: 30),
        dropGrace: dropGrace ?? const Duration(seconds: 10),
      );
      addTearDown(chat.dispose);
      return chat;
    }

    /// The user line the session records once what was typed reaches it.
    Map<String, Object?> recorded(String text) => {
      'type': 'user',
      'message': {'role': 'user', 'content': text},
    };

    test('it goes into the running session itself, and shows as sent only '
        'once the session has recorded it', () async {
      final host = _LiveHost('0\n');
      final chat = watcher(host);
      await chat.continueFrom(_live);

      chat.send('is the build green?');
      final said = chat.entries.whereType<ChatSaid>().single;
      expect(said.delivery, Delivery.sending);
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      // Into `claude attach` for that very session, typed, then Enter.
      final terminal = host.terminals.single;
      expect(terminal.command, contains('attach'));
      expect(terminal.command, contains(_live.id));
      expect(terminal.typed, ['is the build green?', '\r']);
      // Not yet sent: the session has not recorded it.
      expect(said.delivery, Delivery.sending);

      host.adds(recorded('is the build green?'));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Once, where the session put it, and sent.
      final mine = chat.entries.whereType<ChatSaid>().where((e) => e.mine);
      expect(mine.single.text, 'is the build green?');
      expect(mine.single.delivery, isNull);
      // The attach is let go, and nothing was started, copied or stopped.
      expect(terminal.closed.single, isTrue);
      expect(host.startedClaude, isFalse);
      expect(host.commands.any((command) => command.contains(' stop ')),
          isFalse);
      expect(chat.watching?.sessionId, _live.sessionId);
    });

    test('a command typed from the chat is taken as sent once the session '
        'records it as a command', () async {
      final host = _LiveHost('0\n');
      final chat = watcher(host);
      await chat.continueFrom(_live);

      chat.send('/color cyan');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(host.terminals.single.typed, ['/color cyan', '\r']);

      // How 2.1.286 records it: tags, in a system line, then its output.
      host.adds({
        'type': 'system',
        'subtype': 'local_command',
        'content':
            '<command-name>/color</command-name>\n'
            '            <command-message>color</command-message>\n'
            '            <command-args>cyan</command-args>',
      });
      host.adds({
        'type': 'system',
        'subtype': 'local_command',
        'content':
            '<local-command-stdout>Session color set to: cyan'
            '</local-command-stdout>',
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // No message left sending, and the command drawn once, as a command.
      expect(chat.entries.whereType<ChatSaid>(), isEmpty);
      final command = chat.entries.whereType<ChatCommand>().single;
      expect(command.name, 'color');
      expect(command.args, 'cyan');
      expect(command.output, 'Session color set to: cyan');
    });

    test('a command typed from the chat that the session records in a user '
        'line is taken as sent too', () async {
      final host = _LiveHost('0\n');
      final chat = watcher(host);
      await chat.continueFrom(_live);

      chat.send('/context');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      // 2.1.286 wrote /context, /config and /agents this way.
      host.adds(
        recorded(
          '<command-name>/context</command-name>\n'
          '            <command-message>context</command-message>\n'
          '            <command-args></command-args>',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(chat.entries.whereType<ChatSaid>(), isEmpty);
      expect(chat.entries.whereType<ChatCommand>().single.name, 'context');
    });

    test('commands in a transcript read back as commands and what they '
        'printed, never as their tags', () async {
      // Lines as Claude Code 2.1.286 wrote them in a throwaway session, cut
      // to what matters.
      String user(String content, {bool meta = false}) => jsonEncode({
        'type': 'user',
        'isMeta': meta,
        'message': {'role': 'user', 'content': content},
      });
      String system(String content) => jsonEncode({
        'type': 'system',
        'subtype': 'local_command',
        'isMeta': false,
        'content': content,
      });
      final text = [
        system(
          '<command-name>/model</command-name>\n'
          '            <command-message>model</command-message>\n'
          '            <command-args></command-args>',
        ),
        system(
          '<local-command-stdout>Kept model as `Opus 5.5`'
          '</local-command-stdout>',
        ),
        user(
          '<local-command-caveat>The command below was run directly in '
          'Claude Code…</local-command-caveat>',
          meta: true,
        ),
        user(
          '<command-name>/context</command-name>\n'
          '            <command-message>context</command-message>\n'
          '            <command-args></command-args>',
        ),
        user(
          '<local-command-stdout> \x1b[1mContext Usage\x1b[22m\n'
          '\x1b[38;5;244m⛀ \x1b[39m  Opus 5.5</local-command-stdout>',
        ),
        user('## Context Usage\n\n**Model:** claude-opus-5-5', meta: true),
        user(
          '<command-message>simplify is running…</command-message>\n'
          '<command-name>/simplify</command-name>\n'
          '<command-args>lib/</command-args>',
        ),
        user('Review the changed code for reuse…', meta: true),
      ].join('\n');
      final size = utf8.encode('$text\n').length;
      final host = _LiveHost('$size\n$text\n');
      final chat = watcher(host);
      await chat.continueFrom(_live);

      final commands = chat.entries.whereType<ChatCommand>().toList();
      expect(
        [for (final c in commands) c.name],
        ['model', 'context', 'simplify'],
      );
      expect(commands[0].output, 'Kept model as `Opus 5.5`');
      // The terminal's colours are taken out.
      expect(commands[1].output, ' Context Usage\n⛀   Opus 5.5');
      expect(commands[2].args, 'lib/');
      expect(commands[2].output, isNull);
      // Nothing else: no tag, no caveat, no skill's own prompt.
      expect(chat.entries.whereType<ChatSaid>(), isEmpty);
      for (final notice in chat.entries.whereType<ChatNotice>()) {
        expect(notice.text, isNot(contains('<')));
        expect(notice.text, isNot(contains('Context Usage')));
        expect(notice.text, isNot(contains('Review the changed')));
      }
    });

    test('a message behind a running turn says it is queued', () async {
      final host = _LiveHost('0\n', state: 'working');
      final chat = watcher(host);
      await chat.continueFrom(_live);

      chat.send('then run the tests');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      host.adds({
        'type': 'queue-operation',
        'operation': 'enqueue',
        'content': 'then run the tests',
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(
        chat.entries.whereType<ChatSaid>().single.delivery,
        Delivery.queued,
      );
    });

    // How Claude Code records a message that was sent mid-turn, once it is
    // delivered into the turn: an `attachment` of type `queued_command`.
    Map<String, Object?> delivered(String prompt, {bool human = true}) => {
      'type': 'attachment',
      'attachment': {
        'type': 'queued_command',
        'prompt': prompt,
        'delivery_id': 'd-1',
        'humanTurn': human,
        'origin': {'kind': 'human'},
        'commandMode': 'prompt',
      },
    };

    Map<String, Object?> enqueued(String text) => {
      'type': 'queue-operation',
      'operation': 'enqueue',
      'content': text,
    };

    test('a queued message resolves when the session records it as delivered '
        'into its turn, and is not drawn twice', () async {
      final host = _LiveHost('0\n', state: 'working');
      final chat = watcher(host);
      await chat.continueFrom(_live);

      chat.send('then run the tests');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      host.adds(enqueued('then run the tests'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final queuedSaid = chat.entries.whereType<ChatSaid>().single;
      expect(queuedSaid.delivery, Delivery.queued);

      host.adds({'type': 'queue-operation', 'operation': 'remove'});
      host.adds(delivered('then run the tests'));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // The same bubble, where it was sent from, delivered, and no second
      // one for the record.
      final said = chat.entries.whereType<ChatSaid>().single;
      expect(said, same(queuedSaid));
      expect(said.text, 'then run the tests');
      expect(said.delivery, isNull);
      expect(said.why, isNull);
    });

    test('a message delivered into the turn that nobody typed here is a turn '
        'of the user\'s, live and read back from the history', () async {
      final text = [
        jsonEncode({
          'type': 'user',
          'message': {'role': 'user', 'content': 'start'},
        }),
        jsonEncode(delivered('typed at the terminal mid-turn')),
        jsonEncode(delivered('a system one', human: false)),
        jsonEncode(delivered('<task-notification>x</task-notification>')),
      ].join('\n');
      final size = utf8.encode('$text\n').length;
      final host = _LiveHost('$size\n$text\n');
      final chat = watcher(host);
      await chat.continueFrom(_live);

      expect(
        chat.entries.whereType<ChatSaid>().map((said) => said.text).toList(),
        ['start', 'typed at the terminal mid-turn'],
      );
      host.adds(delivered('and one more, live'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(chat.entries.whereType<ChatSaid>().last.text, 'and one more, live');
    });

    test('a queued message the queue gives up without running it is said not '
        'to have arrived, with Retry, which sends it once through the gate',
        () async {
      final host = _LiveHost('0\n', state: 'working');
      final chat = watcher(
        host,
        dropGrace: const Duration(milliseconds: 200),
      );
      await chat.continueFrom(_live);

      chat.send('then run the tests');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      host.adds(enqueued('then run the tests'));
      host.adds({'type': 'queue-operation', 'operation': 'remove'});
      // Within the grace it may still be delivered; none comes.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        chat.entries.whereType<ChatSaid>().single.delivery,
        Delivery.queued,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final failed = chat.entries.whereType<ChatSaid>().single;
      expect(failed.delivery, Delivery.failed);
      expect(failed.why, contains('took it off its queue'));

      // Retry: the same text, once, to the session as it is now.
      host.state = 'done';
      expect(chat.retry(failed), isNull);
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(chat.entries, isNot(contains(failed)));
      expect(host.terminals, hasLength(2));
      // Typed once, and sent with Enter once.
      expect(host.terminals.last.typed, ['then run the tests', '\r']);
      // The failed one is gone: a second Retry has nothing to send.
      expect(chat.retry(failed), contains('no longer here'));
      expect(host.terminals, hasLength(2));
    });

    test('a delivery that comes after the grace, with the message given up '
        'for dropped, resolves the same bubble: one bubble, delivered, no '
        'Retry', () async {
      final host = _LiveHost('0\n', state: 'working');
      final chat = watcher(
        host,
        dropGrace: const Duration(milliseconds: 100),
      );
      await chat.continueFrom(_live);

      chat.send('then run the tests');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      host.adds(enqueued('then run the tests'));
      host.adds({'type': 'queue-operation', 'operation': 'remove'});
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final said = chat.entries.whereType<ChatSaid>().single;
      expect(said.delivery, Delivery.failed);

      // The delivery was only slow.
      host.adds(delivered('then run the tests'));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(chat.entries.whereType<ChatSaid>().single, same(said));
      expect(said.delivery, isNull);
      expect(said.why, isNull);
      // Nothing to retry now: it would send the message twice.
      expect(chat.retry(said), contains('no longer here'));
      expect(host.terminals, hasLength(1));
    });

    test('a message the user removed after the grace is not matched by a '
        'late delivery', () async {
      final host = _LiveHost('0\n', state: 'working');
      final chat = watcher(
        host,
        dropGrace: const Duration(milliseconds: 100),
      );
      await chat.continueFrom(_live);

      chat.send('then run the tests');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      host.adds(enqueued('then run the tests'));
      host.adds({'type': 'queue-operation', 'operation': 'remove'});
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final said = chat.entries.whereType<ChatSaid>().single;
      chat.remove(said);

      host.adds(delivered('then run the tests'));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Removed means gone; the record is then drawn as the turn it is.
      expect(chat.entries.whereType<ChatSaid>().single, isNot(same(said)));
      expect(said.delivery, Delivery.failed);
    });

    test('a removal followed by its delivery is not a drop', () async {
      final host = _LiveHost('0\n', state: 'working');
      final chat = watcher(
        host,
        dropGrace: const Duration(milliseconds: 200),
      );
      await chat.continueFrom(_live);

      chat.send('then run the tests');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      host.adds(enqueued('then run the tests'));
      host.adds({'type': 'queue-operation', 'operation': 'remove'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      host.adds(delivered('then run the tests'));
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(chat.entries.whereType<ChatSaid>().single.delivery, isNull);
    });

    test('Retry goes to what the chat writes to now, not to the session it '
        'failed in: once that has ended and Claude has taken over, to Claude',
        () async {
      final host = _LiveHost('0\n')..terminalsDraw = false;
      final claudes = <_FakeClaude>[];
      final chat = ClaudeChat(
        open: (command) async {
          if (command.contains('stream-json')) {
            final claude = _FakeClaude();
            claudes.add(claude);
            return claude.channel;
          }
          return host.open(command);
        },
        openTerminal: host.openTerminal,
        deliveryTimeout: const Duration(milliseconds: 200),
      );
      addTearDown(chat.dispose);
      await chat.continueFrom(_live);

      // It never comes up to type into: not delivered.
      chat.send('hello');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final failed = chat.entries.whereType<ChatSaid>().single;
      expect(failed.delivery, Delivery.failed);
      expect(host.terminals, hasLength(1));

      // The session ends, and what is sent from here continues it.
      host.adds('\nsshbox:ended\n');
      await host.follow!.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(chat.watching, isNull);
      expect(claudes, hasLength(1));

      expect(chat.retry(failed), isNull);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // To the new target, and not to the old session's terminal.
      expect(host.terminals, hasLength(1));
      final message = claudes.single.sent.single;
      expect(message['type'], 'user');
      expect(
        (((message['message'] as Map)['content'] as List).single as Map)['text'],
        'hello',
      );
    });

    test('Retry is refused, with why, while there is nothing to send to, and '
        'the failed message stays', () async {
      final host = _LiveHost(
        '0\n',
        state: 'blocked',
        status: 'waiting',
        waitingFor: 'permission prompt',
      );
      final chat = watcher(host);
      await chat.continueFrom(_live);
      chat.send('anything');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final failed = chat.entries.whereType<ChatSaid>().single;
      expect(failed.delivery, Delivery.failed);

      // Replaced, and the old bubble is gone with its view.
      await chat.newChat();
      expect(chat.retry(failed), contains('no longer here'));
      expect(host.terminals, isEmpty);
    });

    test('Remove drops a failed message, and only a failed one', () async {
      final host = _LiveHost(
        '0\n',
        state: 'blocked',
        status: 'waiting',
        waitingFor: 'permission prompt',
      );
      final chat = watcher(host);
      await chat.continueFrom(_live);
      chat.send('anything');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final failed = chat.entries.whereType<ChatSaid>().single;

      chat.remove(failed);
      expect(chat.entries.whereType<ChatSaid>(), isEmpty);
    });

    // At a dialog as measured — blocked, waiting on a permission prompt —
    // or in a state this app does not know.
    for (final (state, waitingFor) in [
      ('blocked', 'permission prompt'),
      ('waiting-on-you', null),
      (null, null),
    ]) {
      test('a session whose state is ${state ?? 'not given'} is never typed '
          'into', () async {
        final host = _LiveHost(
          '0\n',
          state: state,
          status: waitingFor == null ? null : 'waiting',
          waitingFor: waitingFor,
        );
        final chat = watcher(host);
        await chat.continueFrom(_live);

        chat.send('anything');
        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(host.terminals, isEmpty);
        final said = chat.entries.whereType<ChatSaid>().single;
        expect(said.delivery, Delivery.failed);
        expect(said.why, contains('terminal'));
      });
    }

    test('two messages sent at once take turns, one terminal at a time',
        () async {
      final host = _LiveHost('0\n');
      final chat = watcher(host);
      await chat.continueFrom(_live);

      chat.send('first');
      chat.send('second');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      // The second waits for the first to be in.
      expect(host.terminals, hasLength(1));

      host.adds(recorded('first'));
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(host.terminals, hasLength(2));
      expect(host.terminals.first.closed.single, isTrue);
      expect(host.terminals.last.typed.first, contains('second'));
    });

    test('what is typed cannot send a control key, and a long message '
        'cannot end its paste early', () async {
      final host = _LiveHost('0\n');
      final chat = watcher(host);
      await chat.continueFrom(_live);

      chat.send('a\x1b[201~\x1b[2Jb\x03c\x9bd\ne\tf');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      // Typed: no escape at all, a newline stays one, and a tab — which
      // would take a suggestion — is spaces.
      expect(host.terminals.single.typed.first, 'a[201~[2Jbcd\ne  f');

      host.adds({
        'type': 'user',
        'message': {'role': 'user', 'content': 'a[201~[2Jbcd\ne  f'},
      });
      final long = 'x' * 700;
      chat.send('$long\x1b[201~y');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      // Past what is taken for typing, a paste: only its own two escapes.
      final paste = host.terminals.last.typed.first;
      expect(paste, '\x1b[200~$long[201~y\x1b[201~');
      expect('\x1b'.allMatches(paste), hasLength(2));
    });

    test('a message that opens with ! is typed as a message, not a shell '
        'command', () async {
      final host = _LiveHost('0\n');
      final chat = watcher(host);
      await chat.continueFrom(_live);

      chat.send('!important: fix the lint');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      // A space first, or the input line would take it for bash mode.
      expect(host.terminals.single.typed.first, ' !important: fix the lint');
    });

    test('a session whose turn ended on a question is typed into — blocked, '
        'but idle and waiting on nothing', () async {
      final host = _LiveHost('0\n', state: 'blocked');
      final chat = watcher(host);
      await chat.continueFrom(_live);

      chat.send('yes, go ahead');
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      expect(host.terminals.single.typed.first, 'yes, go ahead');
    });

    test('a message the session recorded as a paste is still recognised as '
        'sent, and drawn as what was pasted', () async {
      final host = _LiveHost('0\n');
      final chat = watcher(host);
      await chat.continueFrom(_live);

      final long = 'y' * 700;
      chat.send(long);
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      // As 2.1.277 records a paste.
      host.adds({
        'type': 'user',
        'message': {
          'role': 'user',
          'content':
              '\n\n<pasted_content id="1bb6">\n$long\n</pasted_content '
              'id="1bb6">\n',
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final mine = chat.entries.whereType<ChatSaid>().single;
      expect(mine.text, long);
      expect(mine.delivery, isNull);
    });

    test('a message the session never records is said not to have arrived',
        () async {
      final host = _LiveHost('0\n');
      final chat = watcher(
        host,
        deliveryTimeout: const Duration(milliseconds: 200),
      );
      await chat.continueFrom(_live);

      chat.send('hello?');
      await Future<void>.delayed(const Duration(milliseconds: 1800));

      final said = chat.entries.whereType<ChatSaid>().single;
      expect(said.delivery, Delivery.failed);
      expect(said.why, contains('did not record'));
      expect(host.terminals.single.closed.single, isTrue);
    });

    test('a session that never comes up to type into is let go', () async {
      final host = _LiveHost('0\n')..terminalsDraw = false;
      final chat = watcher(
        host,
        deliveryTimeout: const Duration(milliseconds: 200),
      );
      await chat.continueFrom(_live);

      chat.send('hello?');
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(host.terminals.single.typed, isEmpty);
      expect(host.terminals.single.closed.single, isTrue);
      expect(
        chat.entries.whereType<ChatSaid>().single.delivery,
        Delivery.failed,
      );
    });

    group('somebody started at a terminal', () {
      test('in a tmux pane, it is typed into there — no attach — and shows '
          'as sent only once the session has recorded it', () async {
        final host = _LiveHost('0\n', interactive: true);
        final chat = watcher(host);
        await chat.continueFrom(_interactive);

        // Found by the pane its terminal is, and said so; nothing read-only.
        final find = host.commands.singleWhere((c) => c.contains('list-panes'));
        expect(find, contains('p=${_live.pid};'));
        expect(chat.readOnly, isNull);
        expect(
          chat.entries.whereType<ChatNotice>().last.text,
          contains('in tmux pane %3, and what you send is typed into that '
              'pane'),
        );

        chat.send('!is the build green?');
        await Future<void>.delayed(const Duration(milliseconds: 100));

        // Its keystrokes on stdin, as for the attach: a space before the !,
        // and the host told exactly how many bytes to take.
        final typing = host.paneTyping.single;
        expect(typing.stdin, [' !is the build green?']);
        expect(typing.command, contains('dd bs=1 count=21 '));
        expect(host.terminals, isEmpty);
        final said = chat.entries.whereType<ChatSaid>().single;
        expect(said.delivery, Delivery.sending);

        host.adds({
          'type': 'user',
          'message': {'role': 'user', 'content': ' !is the build green?'},
        });
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final mine = chat.entries.whereType<ChatSaid>().single;
        expect(mine.text, '!is the build green?');
        expect(mine.delivery, isNull);
      });

      // Mid-turn a permission prompt can come up at any moment, and a digit
      // alone answers one, measured; at one, it is already up.
      for (final (status, waitingFor) in [
        ('busy', null),
        ('waiting', 'permission prompt'),
      ]) {
        test('${waitingFor ?? status}, it is not typed into', () async {
          final host = _LiveHost(
            '0\n',
            interactive: true,
            status: status,
            waitingFor: waitingFor,
          );
          final chat = watcher(host);
          await chat.continueFrom(_interactive);

          chat.send('1 more thing');
          await Future<void>.delayed(const Duration(milliseconds: 100));

          expect(host.paneTyping, isEmpty);
          final said = chat.entries.whereType<ChatSaid>().single;
          expect(said.delivery, Delivery.failed);
          expect(said.why, contains(waitingFor ?? 'middle of a turn'));
        });
      }

      test('in no tmux pane, it is read-only, and says why rather than that '
          'somebody is typing', () async {
        final host = _LiveHost('0\n', interactive: true)
          ..pane = 'sshbox:no pane\n';
        final chat = watcher(host);
        await chat.continueFrom(_interactive);

        expect(chat.readOnly, contains('outside tmux'));
        final notice = chat.entries.whereType<ChatNotice>().last.text;
        expect(notice, contains('live, read-only: it runs in a terminal '
            'outside tmux'));
        expect(notice, isNot(contains('somebody is typing')));

        chat.send('anything');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(host.paneTyping, isEmpty);
        expect(
          chat.entries.whereType<ChatSaid>().single.delivery,
          Delivery.failed,
        );
      });

      test('what the host refuses at the last moment is said, and a message '
          'typed but not sent says where it is', () async {
        final host = _LiveHost('0\n', interactive: true)
          ..typedAnswer = 'sshbox:no draft\n';
        final chat = watcher(host);
        await chat.continueFrom(_interactive);

        chat.send('first');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        host.typedAnswer = 'sshbox:pasted\nsshbox:no dialog\n';
        chat.send('second');
        await Future<void>.delayed(const Duration(milliseconds: 100));

        final [first, second] = chat.entries.whereType<ChatSaid>().toList();
        expect(first.delivery, Delivery.failed);
        expect(first.why, startsWith('Not typed: Something is typed into'));
        expect(second.delivery, Delivery.failed);
        expect(second.why, startsWith('Typed into “nginx look” but not sent'));
        expect(second.why, contains('in its input line'));
      });
    });
  });

  group('typing into a tmux pane, through a real shell and a real tmux', () {
    final hasTmux =
        Process.runSync('sh', ['-c', 'command -v tmux']).exitCode == 0;
    late Directory dir;

    /// What a host's exec channel runs under: no tty, no locale, and a tmux
    /// server of this test's own under [dir], so the machine's own sessions
    /// are never touched. HOME is [dir] too, so the state file the host reads
    /// is the one the test wrote.
    Map<String, String> env() => {
      'HOME': dir.path,
      'PATH': '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin',
      'SHELL': '/bin/sh',
      'TMUX_TMPDIR': dir.path,
    };

    /// tmux against this test's own server only — never the parent's
    /// environment, whose `$TMUX` would point it at the one the tests run in.
    Future<String> tmux(List<String> args) async {
      final result = await Process.run(
        'tmux',
        args,
        environment: {...env(), 'LANG': 'C.UTF-8'},
        includeParentEnvironment: false,
      );
      return (result.stdout as String).trim();
    }

    /// Runs [command] as the host would, [stdin] written to it as the chat
    /// writes it, and hands back what it printed.
    Future<String> host(String command, [String stdin = '']) async {
      final process = await Process.start(
        '/bin/sh',
        ['-c', command],
        environment: env(),
        includeParentEnvironment: false,
      );
      unawaited(process.stdin.done.catchError((Object _) {}));
      process.stdin.add(utf8.encode(stdin));
      final out = process.stdout.transform(utf8.decoder).join();
      await process.exitCode.timeout(const Duration(seconds: 20));
      return out;
    }

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('sshbox-chat-pane');
    });
    tearDown(() async {
      if (hasTmux) await tmux(['kill-server']);
      await dir.delete(recursive: true);
    });

    /// A stand-in for Claude Code in a pane: its terminal raw, so nothing it
    /// is sent is a signal, an echo or a translated key; Claude Code's input
    /// line drawn, `❯` and a no-break space with the cursor after them — or
    /// [screen] instead; and every byte it reads kept in [file].
    String recorder(String file, {String screen = r'\342\235\257\302\240'}) =>
        "stty raw -echo; printf '\\n$screen'; exec cat > '${dir.path}/$file'";

    /// The pane [target]'s program, once it has drawn: the process whose pid
    /// `claude agents` would give, with its state file written as Claude
    /// Code writes it.
    Future<int> started(String target, {String status = 'idle'}) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while ((await tmux(['capture-pane', '-p', '-t', target])).isEmpty) {
        if (DateTime.now().isAfter(deadline)) fail('the pane never drew');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final pid = int.parse(
        await tmux(['display', '-p', '-t', target, '#{pane_pid}']),
      );
      File('${dir.path}/.claude/sessions/$pid.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'pid': pid,
            'sessionId': _live.sessionId,
            'kind': 'interactive',
            'status': status,
          }),
        );
      return pid;
    }

    String got(String file) {
      final kept = File('${dir.path}/$file');
      return kept.existsSync() ? kept.readAsStringSync() : '';
    }

    test(
      'a message full of what a shell or tmux would act on reaches the pane '
      'as its own text, runs nothing, and reaches no pane beside it',
      () async {
        await tmux([
          'new-session', '-d', '-s', 'sshbox-chat-live', '-x', '80', '-y',
          '20', recorder('claude'),
        ]);
        await tmux([
          'split-window', '-t', 'sshbox-chat-live', recorder('beside'),
        ]);
        // What would make send-keys type into every pane of the window.
        await tmux([
          'set-window-option', '-t', 'sshbox-chat-live',
          'synchronize-panes', 'on',
        ]);
        final [pane, beside] = (await tmux([
          'list-panes', '-t', 'sshbox-chat-live', '-F', '#{pane_id}',
        ])).split('\n');
        final pid = await started(pane);
        await started(beside);

        final follow = StreamController<Uint8List>();
        final chat = ClaudeChat(
          open: (command) async {
            if (command.contains('agents --json')) {
              return (
                output: Stream.value(
                  Uint8List.fromList(
                    utf8.encode(
                      jsonEncode([
                        {
                          'pid': pid,
                          'cwd': _live.cwd,
                          'kind': 'interactive',
                          'sessionId': _live.sessionId,
                          'name': _live.name,
                          'status': 'idle',
                        },
                      ]),
                    ),
                  ),
                ),
                write: (Uint8List data) {},
                close: () {},
              );
            }
            // Finding the pane and typing into it: run for real. First, as
            // tmux's finder has a ` -f ` of its own.
            if (!command.contains('list-panes')) {
              if (command.contains(' -f ')) {
                return (
                  output: follow.stream,
                  write: (Uint8List data) {},
                  close: () {},
                );
              }
              return _noHistory();
            }
            final process = await Process.start(
              '/bin/sh',
              ['-c', command],
              environment: env(),
              includeParentEnvironment: false,
            );
            unawaited(process.stdin.done.catchError((Object _) {}));
            return (
              output: process.stdout.map(Uint8List.fromList),
              write: process.stdin.add,
              close: process.kill,
            );
          },
        );
        addTearDown(chat.dispose);
        await chat.continueFrom(
          ClaudeAgent(
            sessionId: _live.sessionId,
            name: _live.name,
            cwd: _live.cwd,
            kind: 'interactive',
            status: 'idle',
            pid: pid,
          ),
        );
        expect(chat.readOnly, isNull);
        expect(
          chat.entries.whereType<ChatNotice>().last.text,
          contains('in tmux pane $pane'),
        );

        final pwned = '${dir.path}/pwned';
        final message =
            "!touch $pwned-bang; it's \$(touch $pwned-sub) and "
            '`touch $pwned-tick` "q" \x1b[201~\x03 end';
        chat.send(message);
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!got('claude').endsWith('\r')) {
          final said = chat.entries.whereType<ChatSaid>().single;
          if (said.delivery == Delivery.failed ||
              DateTime.now().isAfter(deadline)) {
            fail('never typed: ${said.why}');
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }

        // Its own text, then Enter: a space before the !, and no escape and
        // no Ctrl+C, so the paste cannot be ended and nothing interrupted.
        final typed =
            " !touch $pwned-bang; it's \$(touch $pwned-sub) and "
            '`touch $pwned-tick` "q" [201~ end';
        expect(got('claude'), '$typed\r');
        // The pane beside it, synchronised, was sent nothing at all.
        expect(got('beside'), isEmpty);
        // Nothing on the way ran any of it.
        expect(
          dir
              .listSync()
              .map((entry) => entry.path)
              .where((path) => path.startsWith(pwned)),
          isEmpty,
        );
        // And tmux keeps no copy of it.
        expect(await tmux(['list-buffers']), isEmpty);

        // Sent once the session records it, as for the attach.
        final recorded = jsonEncode({
          'type': 'user',
          'message': {'role': 'user', 'content': typed},
        });
        follow.add(Uint8List.fromList(utf8.encode('$recorded\n')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(chat.entries.whereType<ChatSaid>().single.delivery, isNull);
      },
      skip: hasTmux ? false : 'tmux is not installed here',
    );

    test(
      'a picture\'s path goes in as a paste of its own between the text, '
      'from stdin, and nothing in it runs',
      () async {
        await tmux([
          'new-session', '-d', '-s', 'sshbox-chat-pic', '-x', '80', '-y', '20',
          recorder('claude'),
        ]);
        final pid = await started('sshbox-chat-pic');
        final pwned = '${dir.path}/pwned';
        final parts = ClaudeChat.segments('look [Image #1] here', {
          1: "/tmp/it's \$(touch $pwned-sub)\n`touch $pwned-tick`; x.png",
        });
        final bytes = [for (final part in parts) utf8.encode(part.keys)];
        final watch = Stopwatch()..start();
        final answer = await host(
          ClaudeChat.paneCommand(
            _live.sessionId,
            pid: pid,
            parts: [
              for (final (index, part) in parts.indexed)
                (
                  length: bytes[index].length,
                  picture: part.picture,
                  tokens: 0,
                ),
            ],
            chipWait: const Duration(seconds: 2),
          ),
          utf8.decode([for (final piece in bytes) ...piece]),
        );
        expect(answer, contains('sshbox:typed'));
        // The recorder draws no chip: the host waited for one as long as it
        // was told to, and no longer.
        expect(watch.elapsed, greaterThan(const Duration(seconds: 2)));
        expect(watch.elapsed, lessThan(const Duration(seconds: 6)));
        // One line: the newline taken out of the path, the rest as it is.
        expect(
          got('claude'),
          'look \x1b[200~/tmp/it\'s \$(touch $pwned-sub)`touch $pwned-tick`; '
          'x.png\x1b[201~ here\r',
        );
        expect(
          dir
              .listSync()
              .map((entry) => entry.path)
              .where((path) => path.startsWith(pwned)),
          isEmpty,
        );
      },
      skip: hasTmux ? false : 'tmux is not installed here',
    );

    test(
      'nothing is typed where a keystroke could land anywhere but an empty '
      'input line, nor into anything on no pane',
      () async {
        // Each: what its pane shows, what its state file says, and why it is
        // refused.
        final cases = [
          // A dialog: measured, every one says one of these. The input line
          // may still be drawn below it, with the cursor on it.
          (
            screen:
                r'Enter to confirm \302\267 Esc to cancel\r\n'
                r'\342\235\257\302\240',
            status: 'idle',
            refused: 'dialog',
          ),
          // A picker or a prompt hides the cursor, measured.
          (
            screen: r'\033[?25l\342\235\257\302\240',
            status: 'idle',
            refused: 'dialog',
          ),
          // Somebody's draft, which Enter would send with the message.
          (
            screen: r'\342\235\257\302\240half typed',
            status: 'idle',
            refused: 'draft',
          ),
          // Mid-turn, by the state file the host reads at the last moment.
          (screen: r'\342\235\257\302\240', status: 'busy', refused: 'busy'),
        ];
        for (final (index, setup) in cases.indexed) {
          final session = 'sshbox-chat-no$index';
          await tmux([
            'new-session', '-d', '-s', session, '-x', '80', '-y', '20',
            recorder('got$index', screen: setup.screen),
          ]);
          final pid = await started(session, status: setup.status);
          final answer = await host(
            ClaudeChat.paneCommand(_live.sessionId, pid: pid, typing: 2),
            '1\r',
          );
          expect(
            answer.trim(),
            'sshbox:no ${setup.refused}',
            reason: setup.screen,
          );
          expect(got('got$index'), isEmpty, reason: setup.screen);
        }

        // A shell in front of it — Claude suspended, say: the process is on
        // the pane's terminal, and not what reads it.
        await tmux([
          'new-session', '-d', '-s', 'sshbox-chat-behind', '-x', '80', '-y',
          '20',
          "set -m; sleep 300 & echo \$! > '${dir.path}/behind'; "
              '${recorder('front')}',
        ]);
        await started('sshbox-chat-behind');
        final behind = int.parse(
          File('${dir.path}/behind').readAsStringSync().trim(),
        );
        File('${dir.path}/.claude/sessions/$behind.json').writeAsStringSync(
          jsonEncode({'sessionId': _live.sessionId, 'status': 'idle'}),
        );
        final answer = await host(
          ClaudeChat.paneCommand(_live.sessionId, pid: behind, typing: 2),
          '1\r',
        );
        expect(answer.trim(), 'sshbox:no foreground');
        expect(got('front'), isEmpty);

        // On no terminal at all: no pane, so read-only.
        final loose = await Process.start('sleep', ['60']);
        addTearDown(loose.kill);
        final probe = await host(
          ClaudeChat.paneCommand(_live.sessionId, pid: loose.pid),
        );
        expect(probe.trim(), 'sshbox:no terminal');
      },
      skip: hasTmux ? false : 'tmux is not installed here',
    );
  });

  group('a new chat', () {
    /// What `claude --bg` printed on this machine, colours and all.
    const printed =
        'backgrounded · \x1b[36m9e1f2a3b\x1b[39m · nginx look\n'
        '\x1b[2m  claude agents             list sessions\x1b[22m\n'
        '\x1b[2m  claude attach 9e1f2a3b    open in this terminal\x1b[22m\n';

    test('the id is read back from what claude --bg printed', () {
      expect(ClaudeChat.backgroundId(printed), '9e1f2a3b');
      expect(
        ClaudeChat.backgroundId(
          'backgrounded · \x1b[36me02182f4\x1b[39m · x\x1b[2m (idle — send '
          'a prompt to start)\x1b[22m\n',
        ),
        'e02182f4',
      );
      // The host saying why instead, or an id that is no id.
      expect(ClaudeChat.backgroundId("error: unknown option '--bg'"), isNull);
      expect(ClaudeChat.backgroundId('backgrounded · ;rm'), isNull);
    });

    test('its first message starts a background session, which is then '
        'watched, and nothing of this chat\'s own is started', () async {
      final host = _LiveHost(
        '${utf8.encode(jsonEncode(_said('Looking.'))).length}\n'
        '${jsonEncode(_said('Looking.'))}\n',
      );
      final commands = <String>[];
      final chat = ClaudeChat(
        open: (command) async {
          commands.add(command);
          if (command.contains(' --bg ')) {
            return (
              output: Stream.value(Uint8List.fromList(utf8.encode(printed))),
              write: (Uint8List data) {},
              close: () {},
            );
          }
          return host.open(command);
        },
        cwd: '/srv/app',
      );
      addTearDown(chat.dispose);
      expect(chat.composing, isTrue);

      // What the listing has once it has started.
      host.listed = {
        'pid': 7,
        'id': '9e1f2a3b',
        'cwd': '/srv/app',
        'kind': 'background',
        'sessionId': '9e1f2a3b-0000-4000-8000-000000000000',
        'name': 'nginx look',
        'status': 'busy',
        'state': 'working',
      };
      await chat.send('why is nginx slow?');

      expect(commands.first, contains(' --bg '));
      expect(chat.composing, isFalse);
      expect(chat.watching?.id, '9e1f2a3b');
      expect(chat.pickedFrom, '9e1f2a3b-0000-4000-8000-000000000000');
      // Its history, waited for, then followed.
      expect(
        commands.where((c) => c.contains('.jsonl')).first,
        contains('sleep 1'),
      );
      expect(commands.last, contains(' -f '));
      expect(host.startedClaude, isFalse);
      expect(chat.entries.whereType<ChatSaid>().first.text, 'Looking.');
    });

    test('a host that will not start one says what it said, and the chat '
        'is still new', () async {
      final chat = ClaudeChat(
        open: (command) async => (
          output: Stream.value(
            Uint8List.fromList(
              utf8.encode("error: unknown option '--bg'\n"),
            ),
          ),
          write: (Uint8List data) {},
          close: () {},
        ),
      );
      addTearDown(chat.dispose);

      await chat.send('hello');

      final said = chat.entries.whereType<ChatSaid>().single;
      expect(said.delivery, Delivery.failed);
      expect(said.why, contains("unknown option '--bg'"));
      expect(chat.composing, isTrue);
      expect(chat.busy, isFalse);
    });

    test('New chat leaves a watched session running and untouched', () async {
      final host = _LiveHost('0\n');
      final chat = ClaudeChat(open: host.open);
      addTearDown(chat.dispose);
      await chat.continueFrom(_live);
      expect(chat.watching, isNotNull);

      await chat.newChat();

      expect(host.followClosed, isTrue);
      expect(chat.watching, isNull);
      expect(chat.entries, isEmpty);
      expect(chat.composing, isTrue);
      expect(chat.pickedFrom, isNull);
      // Nothing stopped, nothing started.
      expect(host.commands.any((c) => c.contains(' stop ')), isFalse);
      expect(host.startedClaude, isFalse);
    });

    test('the first message reaches claude --bg exactly as typed, and the '
        'directory too, through a real shell', () async {
      final root = await Directory.systemTemp.createTemp('chat-bg');
      addTearDown(() => root.delete(recursive: true));
      final bin = await Directory('${root.path}/bin').create();
      File('${bin.path}/claude')
          .writeAsStringSync('#!/bin/sh\npwd\nprintf "%s\\n" "\$@"\n');
      await Process.run('chmod', ['+x', '${bin.path}/claude']);

      for (final (name, prompt) in [
        ('my dir', "it's a quote"),
        (r'$(touch RAN)', r'$(touch RAN) and `touch RAN`'),
        ('a;b', 'a; touch RAN'),
        ('plain', '--help: a message that opens with a dash'),
      ]) {
        final dir = await Directory('${root.path}/$name').create();
        final result = await Process.run(
          'sh',
          [
            '-c',
            ClaudeChat.backgroundCommand(
              prompt,
              cwd: dir.path,
              permission: ChatPermission.plan,
            ),
          ],
          environment: {'PATH': '${bin.path}:/usr/bin:/bin'},
          workingDirectory: root.path,
        );
        expect((result.stdout as String).split('\n').take(6), [
          dir.path,
          '--bg',
          '--permission-mode',
          'plan',
          '--',
          prompt,
        ], reason: name);
      }
      expect(File('${root.path}/RAN').existsSync(), isFalse);
    });

    test('a transcript not written yet is waited for, through a real shell',
        () async {
      final root = await Directory.systemTemp.createTemp('chat-wait');
      addTearDown(() => root.delete(recursive: true));
      final projects = await Directory('${root.path}/config/projects/-srv')
          .create(recursive: true);
      final result = Process.run(
        'sh',
        ['-c', ClaudeChat.historyCommand(_live.sessionId, wait: true)],
        environment: {
          'HOME': '${root.path}/nowhere',
          'CLAUDE_CONFIG_DIR': '${root.path}/config',
          'PATH': '/usr/bin:/bin',
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      File('${projects.path}/${_live.sessionId}.jsonl')
          .writeAsStringSync('{"n":1}\n');
      final out = await result;
      expect((out.stdout as String).split('\n'), ['8', '{"n":1}', '']);
    });
  });

  group('which Claude Code chat needs', () {
    test('a version is three numbers, and nothing else is one', () {
      expect(ClaudeChat.parseVersion('2.1.277 (Claude Code)\n'), (2, 1, 277));
      expect(ClaudeChat.parseVersion('2.1.259'), (2, 1, 259));
      // stderr comes along: a warning before the version does not hide it.
      expect(
        ClaudeChat.parseVersion('warning: old node\n2.1.277 (Claude Code)\n'),
        (2, 1, 277),
      );
      for (final other in [
        '',
        'claude: command not found',
        '2.1 (Claude Code)',
        '2.1.277-beta (Claude Code)',
        'v2.1.277',
        '2.1.277 (Claude Code)\nwarning: after it',
        '2.1.277 (Something Else)',
        '99999999999999999999.1.1',
      ]) {
        expect(ClaudeChat.parseVersion(other), isNull, reason: other);
      }
    });

    test('versions compare as numbers, part by part', () {
      expect(ClaudeChat.minimumVersion, (2, 1, 259));
      expect(ClaudeChat.meetsMinimum((2, 1, 259)), isTrue);
      expect(ClaudeChat.meetsMinimum((2, 1, 277)), isTrue);
      expect(ClaudeChat.meetsMinimum((2, 1, 1000)), isTrue);
      expect(ClaudeChat.meetsMinimum((2, 2, 0)), isTrue);
      expect(ClaudeChat.meetsMinimum((3, 0, 0)), isTrue);
      expect(ClaudeChat.meetsMinimum((2, 1, 258)), isFalse);
      expect(ClaudeChat.meetsMinimum((2, 0, 999)), isFalse);
      expect(ClaudeChat.meetsMinimum((1, 99, 999)), isFalse);
    });

    test('2.1.100 is newer than 2.1.99, which a string compare gets wrong',
        () {
      expect('2.1.100'.compareTo('2.1.99') < 0, isTrue);
      expect(ClaudeChat.meetsMinimum((2, 1, 100), (2, 1, 99)), isTrue);
      expect(ClaudeChat.meetsMinimum((2, 1, 99), (2, 1, 100)), isFalse);
      expect(ClaudeChat.meetsMinimum((2, 10, 0), (2, 9, 99)), isTrue);
      expect(ClaudeChat.meetsMinimum((10, 0, 0), (9, 99, 99)), isTrue);
    });

    test('what the host answers becomes the reason chat is shut, or none',
        () {
      expect(ClaudeChat.versionRefusal('2.1.277 (Claude Code)\n'), isNull);
      expect(
        ClaudeChat.versionRefusal('2.0.14 (Claude Code)\n'),
        'Claude Code 2.0.14 on this host is too old for chat — it needs '
        '2.1.259 or newer.',
      );
      // Not a version is not new enough.
      expect(
        ClaudeChat.versionRefusal('bash: claude: bad interpreter'),
        allOf(contains('Could not tell'), contains('bad interpreter'),
            contains('2.1.259')),
      );
      expect(ClaudeChat.versionRefusal(''), contains('answered nothing'));
      // No Claude at all keeps what it said before.
      final missing = ClaudeChat.versionRefusal(
        'Claude Code is not installed on this host (looked on PATH, in '
        '~/.local/bin, ~/.claude/local and the usual package managers)\n',
      );
      expect(missing, startsWith('Claude Code is not installed'));
      expect(missing, isNot(contains('too old')));
    });

    test('the version is asked of the Claude chat finds, through a real '
        'shell', () async {
      final root = await Directory.systemTemp.createTemp('chat-version');
      addTearDown(() => root.delete(recursive: true));
      final bin = await Directory('${root.path}/bin').create();
      File('${bin.path}/claude').writeAsStringSync(
        '#!/bin/sh\n[ "\$1" = --version ] && echo "2.0.14 (Claude Code)"\n',
      );
      await Process.run('chmod', ['+x', '${bin.path}/claude']);

      final found = await Process.run(
        'sh',
        ['-c', ClaudeChat.versionCommand()],
        environment: {'PATH': '${bin.path}:/usr/bin:/bin'},
      );
      expect(ClaudeChat.parseVersion(found.stdout as String), (2, 0, 14));

      final none = await Process.run(
        'sh',
        ['-c', ClaudeChat.versionCommand()],
        environment: {
          'PATH': '/usr/bin:/bin',
          'HOME': '${root.path}/nowhere',
          'SHELL': '/bin/sh',
        },
      );
      expect(
        ClaudeChat.versionRefusal(none.stdout as String),
        startsWith('Claude Code is not installed on this host'),
      );
    });
  });

  test('the listing puts pinned ones first, then running, then finished, '
      'each newest first', () async {
    final claude = _FakeClaude();
    final chat = ClaudeChat(open: _routed(claude));
    addTearDown(chat.dispose);
    Map<String, Object?> row(String id, int started, {bool live = false}) => {
      if (live) 'pid': 1,
      'id': id,
      'cwd': '/srv',
      'kind': 'background',
      'startedAt': started,
      'sessionId': '$id-0000-0000-0000-000000000000',
      'name': id,
      'state': 'done',
    };
    claude.line(jsonEncode([
      row('done0old', 100),
      row('live0old', 200, live: true),
      row('done0new', 300),
      row('pin00old', 50),
      row('live0new', 400, live: true),
      row('pin00new', 500, live: true),
    ]));
    claude.line('--- pins');
    claude.line('["pin00old","pin00new"]');
    final listing = chat.agents(all: true);
    await claude.end();

    expect((await listing).map((agent) => agent.id), [
      'pin00old',
      'pin00new',
      'live0new',
      'live0old',
      'done0new',
      'done0old',
    ]);
  });

  test('the finished sessions are asked for with --all, through a real shell',
      () async {
    final root = await Directory.systemTemp.createTemp('chat-all');
    addTearDown(() => root.delete(recursive: true));
    final bin = await Directory('${root.path}/bin').create();
    File('${bin.path}/claude')
        .writeAsStringSync('#!/bin/sh\nprintf "%s\\n" "\$@"\n');
    await Process.run('chmod', ['+x', '${bin.path}/claude']);
    Future<List<String>> args({required bool all}) async {
      final result = await Process.run(
        'sh',
        ['-c', ClaudeChat.agentsCommand(all: all)],
        environment: {'PATH': '${bin.path}:/usr/bin:/bin'},
      );
      return (result.stdout as String)
          .split('\n--- pins\n')
          .first
          .trim()
          .split('\n');
    }

    expect(await args(all: true), ['agents', '--json', '--all']);
    expect(await args(all: false), ['agents', '--json']);
  });

  test('the attach command reaches Claude with the id exactly as given, '
      'through a real shell', () async {
    final root = await Directory.systemTemp.createTemp('chat-attach');
    addTearDown(() => root.delete(recursive: true));
    final bin = await Directory('${root.path}/bin').create();
    File('${bin.path}/claude')
        .writeAsStringSync('#!/bin/sh\nprintf "%s\\n" "\$@"\n');
    await Process.run('chmod', ['+x', '${bin.path}/claude']);

    for (final id in ["it's", 'has a space', r'$(touch RAN)', 'a;b']) {
      final result = await Process.run(
        'sh',
        ['-c', ClaudeChat.attachCommand(id)],
        environment: {'PATH': '${bin.path}:/usr/bin:/bin'},
        workingDirectory: root.path,
      );
      expect((result.stdout as String).split('\n').take(2), ['attach', id],
          reason: id);
    }
    expect(File('${root.path}/RAN').existsSync(), isFalse);
  });

  group('earlier turns, through a real shell', () {
    late Directory root;
    late File transcript;
    final started = <Process>[];

    setUp(() async {
      root = await Directory.systemTemp.createTemp('chat-earlier');
      final projects = await Directory(
        '${root.path}/config/projects/-srv',
      ).create(recursive: true);
      transcript = File('${projects.path}/${_live.sessionId}.jsonl');
    });
    tearDown(() async {
      for (final process in started) {
        process.kill();
      }
      started.clear();
      await root.delete(recursive: true);
    });

    /// This machine as the host: every command the chat sends to read the
    /// transcript runs through a real `sh`, exactly as it was built. Claude
    /// itself is never run: that command gets a channel that ends at once.
    Future<CommandChannel> host(String command) async {
      if (!command.contains('.jsonl')) {
        return (
          output: const Stream<Uint8List>.empty(),
          write: (Uint8List data) {},
          close: () {},
        );
      }
      final process = await Process.start(
        'sh',
        ['-c', command],
        environment: {
          'HOME': '${root.path}/nowhere',
          'CLAUDE_CONFIG_DIR': '${root.path}/config',
          'PATH': '/usr/bin:/bin',
        },
      );
      started.add(process);
      unawaited(process.stderr.drain<void>());
      return (
        output: process.stdout.map(Uint8List.fromList),
        write: (Uint8List data) => process.stdin.add(data),
        // What the channel closing looks like to the host: stdin at its end.
        close: () => unawaited(process.stdin.close().catchError((_) {})),
      );
    }

    /// One line of the transcript, [pad] bytes bigger than [event] alone.
    String line(Map<String, Object?> event, [int pad = 0]) =>
        jsonEncode({...event, 'pad': 'x' * pad});

    int sizeOf(Iterable<String> lines) =>
        lines.fold(0, (all, line) => all + utf8.encode(line).length + 1);

    /// Lines of about [size] bytes in all, each a thing Claude said, named
    /// [word] and a number — sized unevenly, so that chunks end inside lines
    /// — with what each said added to [said], in order.
    List<String> talk(String word, int size, List<String> said) {
      final lines = <String>[];
      for (var n = 0; sizeOf(lines) < size; n++) {
        // A character of three bytes, so a cut can fall inside one too.
        final text = '$word $n ✓';
        said.add(text);
        lines.add(line(_said(text), 700 + n * 7919 % 50000));
      }
      return lines;
    }

    Map<String, Object?> toolUse(String id, String name, String key,
        String value) => {
      'type': 'assistant',
      'message': {
        'role': 'assistant',
        'content': [
          {
            'type': 'tool_use',
            'id': id,
            'name': name,
            'input': {key: value},
          },
        ],
      },
    };

    Map<String, Object?> toolResult(String id, String content) => {
      'type': 'user',
      'message': {
        'role': 'user',
        'content': [
          {'type': 'tool_result', 'tool_use_id': id, 'content': content},
        ],
      },
    };

    test('they come back chunk by chunk, every event whole and in order — '
        'the one the first read cut, and the ones chunks cut', () async {
      final said = <String>[];
      final call = line(
        toolUse('toolu_edge', 'Bash', 'command', 'make test'),
        40000,
      );
      final result = line(toolResult('toolu_edge', 'all 12 passed'));
      final before = [
        ...talk('early', 3 * 1024 * 1024, said),
        // Bigger than a whole chunk: no chunk holds it whole, so it is left
        // out, and said to be.
        line(_said('too big to hold'), ClaudeChat.earlierChunk + 100000),
        ...talk('middle', 3 * 1024 * 1024, said),
        call,
        result,
      ];
      // The tail, sized so that where the first read starts falls in the
      // middle of the tool call: it reads the call's result, not the call.
      final tailSize =
          ClaudeChat.historyLimit - sizeOf([result]) - sizeOf([call]) ~/ 2;
      final after = talk('late', tailSize - 100000, said);
      final filler = line({'type': 'mode'});
      after.add(
        line({'type': 'mode'}, tailSize - sizeOf(after) - sizeOf([filler])),
      );
      final lines = [...before, ...after];
      transcript.writeAsStringSync('${lines.join('\n')}\n');
      final size = transcript.lengthSync();
      final cutAt = size - ClaudeChat.historyLimit;
      final callStarts = sizeOf(before) - sizeOf([call, result]);
      expect(cutAt, inExclusiveRange(callStarts, callStarts + sizeOf([call])));

      final chat = ClaudeChat(open: host);
      addTearDown(chat.dispose);
      await chat.continueFrom(_finished);

      // At first only the tail: the call cut off, its result read, nothing
      // earlier.
      expect(chat.entries.whereType<ChatSaid>().first.text, 'late 0 ✓');
      expect(chat.entries.whereType<ChatToolRun>(), isEmpty);
      expect(chat.hasEarlier, isTrue);

      var pages = 0;
      while (chat.canLoadEarlier) {
        await chat.loadEarlier();
        pages++;
      }

      expect(pages, greaterThan(2));
      expect(chat.hasEarlier, isFalse);
      // Every event but the one too big, once each, in the order written, and
      // no character broken where a chunk cut through it.
      expect(chat.entries.whereType<ChatSaid>().map((e) => e.text), said);
      // The call the first read cut is read whole from an earlier chunk, and
      // its result, read before it, is folded into it rather than lost.
      final run = chat.entries.whereType<ChatToolRun>().single;
      expect(run.summary, 'make test');
      expect(run.result, 'all 12 passed');
      // Where the big one was, the chat says so, once.
      final texts = [
        for (final entry in chat.entries)
          switch (entry) {
            ChatSaid(:final text) => text,
            ChatNotice(:final text) => text,
            ChatToolRun() => 'tool',
            ChatCommand(:final name) => '/$name',
            ChatQuestion() => 'question',
          },
      ];
      final gap = texts.indexWhere((text) => text.contains('left out'));
      expect(texts[gap - 1], startsWith('early '));
      expect(texts[gap + 1], 'middle 0 ✓');
      expect(texts.where((text) => text.contains('left out')), hasLength(1));
      // All of it above where the chat opened.
      expect(chat.earlier, texts.indexOf('late 0 ✓'));
    });

    test('while a running session is watched, what it adds still goes in '
        'below, and a call in the earlier part gets its result live',
        () async {
      final said = <String>[];
      final before = [
        line(toolUse('toolu_long', 'Task', 'description', 'audit the repo')),
        ...talk('earlier', 1024 * 1024, said),
      ];
      final after = talk('tail', ClaudeChat.historyLimit, said);
      transcript.writeAsStringSync('${[...before, ...after].join('\n')}\n');
      final alive = await Process.start('sleep', ['60']);
      started.add(alive);

      final chat = ClaudeChat(open: host);
      addTearDown(chat.dispose);
      await chat.continueFrom(
        ClaudeAgent(
          sessionId: _live.sessionId,
          name: _live.name,
          cwd: _live.cwd,
          kind: 'background',
          id: _live.id,
          pid: alive.pid,
        ),
      );
      expect(chat.watching, isNotNull);

      Future<void> shows(String text) async {
        for (var look = 0; look < 100; look++) {
          if (chat.entries.whereType<ChatSaid>().any((e) => e.text == text)) {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        fail('“$text” never showed');
      }

      transcript.writeAsStringSync(
        '${line(_said('live 1'))}\n',
        mode: FileMode.append,
      );
      await shows('live 1');

      while (chat.canLoadEarlier) {
        await chat.loadEarlier();
      }
      final run = chat.entries.whereType<ChatToolRun>().single;
      // Nothing has answered it yet, and the session is still running.
      expect(run.done, isFalse);

      transcript.writeAsStringSync(
        '${line(toolResult('toolu_long', 'clean'))}\n'
        '${line(_said('live 2'))}\n',
        mode: FileMode.append,
      );
      await shows('live 2');

      expect(run.result, 'clean');
      expect(chat.entries.first, same(run));
      expect(
        chat.entries.whereType<ChatSaid>().map((e) => e.text),
        [...said, 'live 1', 'live 2'],
      );
    });
  });

  group('the turn in flight', () {
    // A turn as 2.1.286 wrote it, measured on a throwaway background
    // session: the prompt, a message calling Bash, its result, and a
    // message of two blocks — thinking, then text — each block on a line of
    // its own repeating the message's usage, then the turn's duration.
    Map<String, Object?> prompt() => {
      'type': 'user',
      'timestamp': '2026-10-01T12:06:10.643Z',
      'isSidechain': false,
      'message': {'role': 'user', 'content': 'run the tests'},
    };
    Map<String, Object?> callsBash() => {
      'type': 'assistant',
      'timestamp': '2026-10-01T12:06:19.547Z',
      'message': {
        'id': 'msg_01ma8teqDx',
        'role': 'assistant',
        'stop_reason': 'tool_use',
        'usage': {'input_tokens': 2, 'output_tokens': 87},
        'content': [
          {
            'type': 'tool_use',
            'id': 'toolu_t1',
            'name': 'Bash',
            'input': {'command': 'npm test', 'description': 'Run the tests'},
          },
        ],
      },
    };
    Map<String, Object?> bashResult() => {
      'type': 'user',
      'timestamp': '2026-10-01T12:06:28.899Z',
      'message': {
        'role': 'user',
        'content': [
          {'type': 'tool_result', 'tool_use_id': 'toolu_t1', 'content': 'ok'},
        ],
      },
    };
    Map<String, Object?> answers(String type, {String? stop = 'end_turn'}) => {
      'type': 'assistant',
      'timestamp': '2026-10-01T12:06:37.713Z',
      'message': {
        'id': 'msg_01ofPoDr74',
        'role': 'assistant',
        'stop_reason': stop,
        'usage': {'input_tokens': 2, 'output_tokens': 1313},
        'content': [
          type == 'text'
              ? {'type': 'text', 'text': 'All green.'}
              : {'type': 'thinking', 'thinking': '', 'signature': 'CAQS'},
        ],
      },
    };
    const turnDuration = {
      'type': 'system',
      'subtype': 'turn_duration',
      'durationMs': 29623,
      'isMeta': false,
    };

    Future<(ClaudeChat, _LiveHost)> watch({
      String? waitingFor,
      String state = 'working',
    }) async {
      final host = _LiveHost(
        '0\n',
        state: state,
        status: waitingFor == null ? null : 'waiting',
        waitingFor: waitingFor,
      );
      final chat = ClaudeChat(open: host.open);
      addTearDown(chat.dispose);
      await chat.continueFrom(_live);
      return (chat, host);
    }

    test('starts at the prompt\'s own time, names the tool running, and '
        'counts each message once', () async {
      final (chat, host) = await watch();
      expect(chat.progress, isNull);

      host.adds(prompt());
      await _settle();
      expect(chat.progress?.started, DateTime.utc(2026, 10, 1, 12, 6, 10, 643));
      expect(chat.progress?.tokens, 0);
      expect(chat.progress?.tool, isNull);

      host.adds(callsBash());
      await _settle();
      expect(chat.progress?.tool?.name, 'Bash');
      expect(chat.progress?.tool?.summary, 'npm test');
      expect(chat.progress?.tokens, 87);

      host.adds(bashResult());
      await _settle();
      expect(chat.progress?.tool, isNull);
      expect(chat.progress?.tokens, 87);

      // Two lines of one message: its usage counted once, not twice. The
      // first block of the last message says the turn is over, too, so
      // here the message is still open: written with no stop yet.
      host.adds(answers('thinking', stop: null));
      host.adds(answers('text', stop: null));
      await _settle();
      expect(chat.progress?.tokens, 87 + 1313);
      expect(ChatProgress.count(chat.progress!.tokens), '1.4k');

      host.adds(turnDuration);
      await _settle();
      expect(chat.progress, isNull);
    });

    test('a message that ends the turn clears the line at once', () async {
      final (chat, host) = await watch();
      host
        ..adds(prompt())
        ..adds(callsBash())
        ..adds(bashResult())
        ..adds(answers('thinking'));
      await _settle();
      expect(chat.progress, isNull);
    });

    test(
      'a session picked up mid-turn shows the turn from its real start',
      () async {
        final text = [prompt(), callsBash()].map(jsonEncode).join('\n');
        final size = utf8.encode('$text\n').length;
        final host = _LiveHost('$size\n$text\n', state: 'working');
        final chat = ClaudeChat(open: host.open);
        addTearDown(chat.dispose);
        await chat.continueFrom(_live);
        expect(
          chat.progress?.started,
          DateTime.utc(2026, 10, 1, 12, 6, 10, 643),
        );
        expect(chat.progress?.tool?.summary, 'npm test');
      },
    );

    test('a finished session\'s history leaves no turn open', () async {
      final text = [prompt(), callsBash()].map(jsonEncode).join('\n');
      final size = utf8.encode('$text\n').length;
      final host = _LiveHost('$size\n$text\n');
      final chat = ClaudeChat(open: host.open);
      addTearDown(chat.dispose);
      await chat.continueFrom(_finished);
      expect(chat.progress, isNull);
    });

    test('at a permission prompt it says what it waits for, from the '
        'listing', () async {
      final (chat, host) = await watch();
      host
        ..adds(prompt())
        ..adds(callsBash());
      await _settle();
      expect(chat.progress?.waitingFor, isNull);

      host
        ..state = 'blocked'
        ..status = 'waiting'
        ..waitingFor = 'permission prompt';
      await chat.checkState();
      expect(chat.progress?.waitingFor, 'permission prompt');

      // Answered at the terminal: working again.
      host
        ..state = 'working'
        ..status = null
        ..waitingFor = null;
      await chat.checkState();
      expect(chat.progress?.waitingFor, isNull);
      expect(chat.progress, isNotNull);
    });

    test('idle at two looks running, a turn whose end was missed stops '
        'spinning', () async {
      final (chat, host) = await watch();
      host.adds(prompt());
      await _settle();
      host.state = 'done';
      await chat.checkState();
      expect(chat.progress, isNotNull);
      await chat.checkState();
      expect(chat.progress, isNull);
    });

    test(
      'idle shows nothing, and a turn that ends goes from the line',
      () async {
        final (chat, host) = await watch(state: 'done');
        expect(chat.progress, isNull);
        host.adds(prompt());
        await _settle();
        final started = chat.progress?.started;
        expect(started, isNotNull);
        host.adds(turnDuration);
        await _settle();
        expect(chat.progress, isNull);
      },
    );

    test('an interrupted turn clears the line', () async {
      final (chat, host) = await watch();
      host
        ..adds(prompt())
        ..adds({
          'type': 'user',
          'message': {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': '[Request interrupted by user]'},
            ],
          },
        });
      await _settle();
      expect(chat.progress, isNull);
    });

    test('the session going clears the line', () async {
      final (chat, host) = await watch();
      host.adds(prompt());
      await _settle();
      host.adds('sshbox:ended\n');
      await host.follow!.close();
      await _settle();
      expect(chat.progress, isNull);
    });

    test(
      'a turn of this chat\'s own runs from the send to the result',
      () async {
        final claude = _FakeClaude();
        final chat = ClaudeChat(open: _routed(claude));
        addTearDown(chat.dispose);
        await chat.start();
        final before = DateTime.now();
        await chat.send('hello');
        expect(chat.progress!.started.isBefore(before), isFalse);
        claude.event(callsBash());
        await _settle();
        expect(chat.progress?.tokens, 87);
        claude.event({'type': 'result', 'subtype': 'success'});
        await _settle();
        expect(chat.progress, isNull);
      },
    );

    test('a look that comes back after its turn ended says nothing of the '
        'next one', () async {
      final (chat, host) = await watch();
      host.adds(prompt());
      await _settle();
      final gate = Completer<void>();
      host
        ..agentsGate = gate.future
        ..state = 'blocked'
        ..status = 'waiting'
        ..waitingFor = 'permission prompt';
      final look = chat.checkState();
      await _settle();
      // Answered and finished meanwhile, and the next turn begun.
      host
        ..adds(turnDuration)
        ..adds({...prompt(), 'timestamp': '2026-10-01T12:07:00.000Z'});
      await _settle();
      gate.complete();
      await look;
      expect(chat.progress, isNotNull);
      expect(chat.progress?.waitingFor, isNull);
    });

    test('an idle look from the last turn does not count against the next',
        () async {
      final (chat, host) = await watch();
      host.adds(prompt());
      await _settle();
      final gate = Completer<void>();
      host
        ..agentsGate = gate.future
        ..state = 'done';
      final look = chat.checkState();
      await _settle();
      host
        ..adds(turnDuration)
        ..adds({...prompt(), 'timestamp': '2026-10-01T12:07:00.000Z'});
      await _settle();
      gate.complete();
      await look;
      host.agentsGate = null;
      // One idle look at the new turn: not yet two.
      await chat.checkState();
      expect(chat.progress, isNotNull);
    });

    test('times and counts read as Claude Code writes them', () {
      expect(ChatProgress.elapsed(const Duration(seconds: 33)), '33s');
      expect(ChatProgress.elapsed(const Duration(seconds: 125)), '2m 5s');
      expect(ChatProgress.elapsed(const Duration(minutes: 64)), '1h 4m');
      expect(ChatProgress.elapsed(const Duration(seconds: -3)), '0s');
      expect(ChatProgress.count(87), '87');
      expect(ChatProgress.count(1000), '1k');
      expect(ChatProgress.count(1400), '1.4k');
      expect(ChatProgress.count(12345), '12k');
    });
  });

  group('the session\'s checklist', () {
    // Shapes measured on 2.1.286: a TaskCreate has no id, which its result
    // gives; a TaskUpdate names it, with a status of in_progress, completed
    // or deleted. The words are this test's own.
    Map<String, Object?> call(
      String id,
      String name,
      Map<String, Object?> input,
    ) => {
      'type': 'assistant',
      'message': {
        'id': 'msg_$id',
        'stop_reason': 'tool_use',
        'content': [
          {'type': 'tool_use', 'id': id, 'name': name, 'input': input},
        ],
      },
    };
    Map<String, Object?> result(String id, String text, {bool error = false}) =>
        {
          'type': 'user',
          'message': {
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': id,
                'content': text,
                'is_error': error,
              },
            ],
          },
        };
    List<Map<String, Object?>> made(int n, String subject, {String? form}) => [
      call('c$n', 'TaskCreate', {
        'subject': subject,
        'description': 'd',
        'activeForm': ?form,
      }),
      result('c$n', 'Task #$n created successfully: $subject'),
    ];
    // A TaskUpdate and its result, which says it took.
    List<Map<String, Object?>> update(
      int n,
      Map<String, Object?> input, {
      bool fails = false,
    }) {
      final id = 'u$n${input.hashCode}';
      return [
        call(id, 'TaskUpdate', {'taskId': '$n', ...input}),
        result(id, fails ? 'Task not found' : 'Updated task #$n status', error: fails),
      ];
    }

    void adds(_LiveHost host, List<Map<String, Object?>> lines) {
      for (final line in lines) {
        host.adds(line);
      }
    }

    List<Map<String, Object?>> todo(String id, Map<String, Object?> input) => [
      call(id, 'TodoWrite', input),
      result(id, 'Todos have been modified successfully'),
    ];

    Future<(ClaudeChat, _LiveHost)> watch([
      List<Object?> history = const [],
    ]) async {
      final text = history.map(jsonEncode).join('\n');
      final host = _LiveHost(
        history.isEmpty ? '0\n' : '${utf8.encode('$text\n').length}\n$text\n',
        state: 'working',
      );
      final chat = ClaudeChat(open: host.open);
      addTearDown(chat.dispose);
      await chat.continueFrom(_live);
      return (chat, host);
    }

    List<String> labels(ClaudeChat chat) => [
      for (final t in chat.openTasks) '${t.status}:${t.label}',
    ];

    test('TaskCreate gets its id from the result, and TaskUpdate moves it '
        'along, live', () async {
      final (chat, host) = await watch();
      expect(chat.openTasks, isEmpty);
      for (final line in [
        ...made(1, 'Fix the bug', form: 'Fixing the bug'),
        ...made(2, 'Write the tests'),
      ]) {
        host.adds(line);
      }
      await _settle();
      expect(labels(chat), ['pending:Fix the bug', 'pending:Write the tests']);

      adds(host, update(1, {'status': 'in_progress'}));
      await _settle();
      // In progress, it reads as its active form.
      expect(labels(chat), [
        'in_progress:Fixing the bug',
        'pending:Write the tests',
      ]);

      adds(host, update(1, {'status': 'completed'}));
      await _settle();
      expect(labels(chat), ['pending:Write the tests']);
      expect(chat.tasksDone, 1);

      adds(host, update(2, {'status': 'deleted'}));
      await _settle();
      expect(chat.openTasks, isEmpty);
    });

    test(
      'a session opened mid-way rebuilds its list from the history',
      () async {
        final (chat, _) = await watch([
          ...made(1, 'One'),
          ...made(2, 'Two', form: 'Doing two'),
          ...update(2, {'status': 'in_progress'}),
          ...made(3, 'Three'),
          ...update(3, {'status': 'completed'}),
        ]);
        expect(labels(chat), ['pending:One', 'in_progress:Doing two']);
        expect(chat.tasksDone, 1);
      },
    );

    test('TodoWrite carries the whole list every time', () async {
      final (chat, host) = await watch();
      adds(host, todo('t1', {
          'todos': [
            {
              'content': 'First',
              'status': 'in_progress',
              'activeForm': 'Firsting',
            },
            {
              'content': 'Second',
              'status': 'pending',
              'activeForm': 'Seconding',
            },
          ],
        }));
      await _settle();
      expect(labels(chat), ['in_progress:Firsting', 'pending:Second']);
      adds(host, todo('t2', {
          'todos': [
            {
              'content': 'Second',
              'status': 'in_progress',
              'activeForm': 'Seconding',
            },
          ],
        }));
      await _settle();
      // The list shrank: what it no longer names is gone, not kept.
      expect(labels(chat), ['in_progress:Seconding']);
      expect(chat.tasksDone, 0);
    });

    test('a failed TaskUpdate or TodoWrite leaves the list as it was', () async {
      final (chat, host) = await watch();
      for (final line in made(1, 'Keep me')) {
        host.adds(line);
      }
      await _settle();
      adds(host, update(1, {'status': 'completed'}, fails: true));
      adds(host, update(1, {'status': 'deleted'}, fails: true));
      host
        ..adds(call('tw', 'TodoWrite', {'todos': <Object?>[]}))
        ..adds(result('tw', 'refused', error: true));
      await _settle();
      expect(labels(chat), ['pending:Keep me']);
      expect(chat.tasksDone, 0);
    });

    test('a result read before its call still makes the task', () async {
      // The tail of a transcript cut mid-way: the result first.
      final (chat, host) = await watch([
        result('c1', 'Task #1 created successfully: Late'),
        call('c1', 'TaskCreate', {'subject': 'Late', 'description': 'd'}),
      ]);
      expect(labels(chat), ['pending:Late']);
      host.adds(result('x', 'unrelated'));
    });

    // One task as the CLI's store holds it, a file of JSON.
    String stored(int n, String subject, String status, {String? form}) =>
        jsonEncode({
          'id': '$n',
          'subject': subject,
          'description': 'd',
          'activeForm': form ?? subject,
          'status': status,
          'blocks': <String>[],
          'blockedBy': <String>[],
        });

    test('tasks made before the part of the transcript read are all there, '
        'from the session\'s own store', () async {
      tasksOnHost = [
        stored(1, 'Early one', 'completed'),
        stored(2, 'Early two', 'completed'),
        stored(3, 'Early three', 'in_progress', form: 'Doing early three'),
        stored(4, 'Early four', 'pending'),
        stored(5, 'Recent', 'pending'),
      ].join('\n');
      addTearDown(() => tasksOnHost = '');
      // The transcript read holds only the newest task, and an update of one
      // it never saw made.
      final (chat, _) = await watch([
        ...made(5, 'Recent'),
        ...update(3, {'status': 'in_progress'}),
      ]);
      await _settle();
      expect(labels(chat), [
        'in_progress:Doing early three',
        'pending:Early four',
        'pending:Recent',
      ]);
      expect(chat.tasksDone, 2);
    });

    test('the header\'s counts: all of them, done, in progress and open',
        () async {
      tasksOnHost = [
        stored(1, 'a', 'completed'),
        stored(2, 'b', 'completed'),
        stored(3, 'c', 'in_progress'),
        stored(4, 'd', 'pending'),
        stored(5, 'e', 'pending'),
        stored(6, 'f', 'pending'),
      ].join('\n');
      addTearDown(() => tasksOnHost = '');
      final (chat, _) = await watch();
      await _settle();
      expect(
        (
          chat.tasksTotal,
          chat.tasksDone,
          chat.tasksInProgress,
          chat.tasksPending,
        ),
        (6, 2, 1, 3),
      );
    });

    test('a TaskCreate or TaskUpdate result makes it read the store again',
        () async {
      tasksOnHost = stored(1, 'One', 'pending');
      addTearDown(() => tasksOnHost = '');
      final (chat, host) = await watch();
      await _settle();
      int reads() => host.commands.where((c) => c.contains('/tasks')).length;
      final before = reads();
      expect(labels(chat), ['pending:One']);

      // A create arrives, and the store has a task beside it that the
      // transcript never carried.
      tasksOnHost = [
        stored(1, 'One', 'pending'),
        stored(7, 'Seven', 'pending'),
        stored(8, 'Eight', 'pending'),
      ].join('\n');
      for (final line in made(7, 'Seven')) {
        host.adds(line);
      }
      await _settle();
      await _settle();
      expect(labels(chat), [
        'pending:One',
        'pending:Seven',
        'pending:Eight',
      ]);

      // The store moved on, with a task the transcript never carried.
      tasksOnHost = [
        stored(1, 'One', 'completed'),
        stored(2, 'Two', 'in_progress', form: 'Doing two'),
        stored(9, 'Nine', 'pending'),
      ].join('\n');
      adds(host, update(1, {'status': 'completed'}));
      await _settle();
      await _settle();
      expect(reads(), greaterThan(before));
      expect(labels(chat), ['in_progress:Doing two', 'pending:Nine']);
      expect(chat.tasksDone, 1);
    });

    test('a store with nothing readable leaves what the transcript made',
        () async {
      tasksOnHost = 'no such directory\nnot json';
      addTearDown(() => tasksOnHost = '');
      final (chat, host) = await watch();
      for (final line in made(1, 'From the transcript')) {
        host.adds(line);
      }
      await _settle();
      await _settle();
      expect(labels(chat), ['pending:From the transcript']);
    });

    test('an id too long to be a number is left out, and the others load, '
        'with controls cleaned from what is drawn', () {
      final tasks = ClaudeChat.tasksFrom([
        jsonEncode({
          'id': '99999999999999999999',
          'subject': 'huge',
          'status': 'pending',
        }),
        jsonEncode({
          'id': '1',
          'subject': 'esc\u001b[31mred\u009b and \u0007bell',
          'activeForm': 'doing\u001b[0m it',
          'status': 'pending',
        }),
        stored(2, 'two', 'pending'),
      ].join('\n'));
      expect([for (final t in tasks) t.id], ['1', '2']);
      expect(tasks.first.subject, 'esc[31mred and bell');
      expect(tasks.first.activeForm, 'doing[0m it');
    });

    test('only a task as the CLI writes one is read, in the order of its '
        'number', () {
      final tasks = ClaudeChat.tasksFrom([
        stored(10, 'ten', 'pending'),
        stored(2, 'two', 'completed'),
        jsonEncode({'id': 'x1', 'subject': 'bad id', 'status': 'pending'}),
        jsonEncode({'id': '3', 'subject': 'bad status', 'status': 'weird'}),
        jsonEncode({'id': '4', 'status': 'pending'}),
        jsonEncode(['not', 'a', 'task']),
        'not json',
      ].join('\n'));
      expect([for (final t in tasks) t.id], ['2', '10']);
    });

    test('the store is read through a real shell: its files by number, the '
        'id as a value, a cap on how many, nothing run', () async {
      final dir = Directory.systemTemp.createTempSync('sshbox-tasks-');
      addTearDown(() => dir.deleteSync(recursive: true));
      const id = "it's \$(touch pwned-sub) `touch pwned-tick`";
      final tasks = Directory('${dir.path}/tasks/$id')
        ..createSync(recursive: true);
      for (var n = 1; n <= ClaudeChat.taskFiles + 20; n++) {
        File('${tasks.path}/$n.json')
            .writeAsStringSync('{\n  "id": "$n",\n  "subject": "t$n",\n'
                '  "status": "pending"\n}\n');
      }
      // Not a task's file name: never read.
      File('${tasks.path}/notes.txt').writeAsStringSync('{"id":"999"}');
      final run = await Process.run(
        'sh',
        ['-c', ClaudeChat.tasksCommand(id)],
        environment: {'CLAUDE_CONFIG_DIR': dir.path},
        workingDirectory: dir.path,
      );
      final lines = const LineSplitter().convert('${run.stdout}');
      expect(lines.length, ClaudeChat.taskFiles);
      expect(
        lines.every((line) => !line.contains('999') && line.startsWith('{')),
        isTrue,
      );
      expect(ClaudeChat.tasksFrom('${run.stdout}'), hasLength(ClaudeChat.taskFiles));
      expect(File('${dir.path}/pwned-sub').existsSync(), isFalse);
      expect(File('${dir.path}/pwned-tick').existsSync(), isFalse);
      // And a session with no store says nothing, and succeeds.
      final none = await Process.run(
        'sh',
        ['-c', ClaudeChat.tasksCommand('e2e00000-0000-4000-8000-000000000000')],
        environment: {'CLAUDE_CONFIG_DIR': dir.path},
      );
      expect((none.stdout as String).trim(), isEmpty);
      expect(none.exitCode, 0);
    });

    test('a task it never saw made, and a create that failed, are not '
        'invented', () async {
      final (chat, host) = await watch();
      host
        ..adds(update(9, {'status': 'in_progress'}).first)
        ..adds(
          call('bad', 'TaskCreate', {'subject': 'Nope', 'description': 'd'}),
        )
        ..adds(result('bad', 'no such tool', error: true));
      await _settle();
      expect(chat.openTasks, isEmpty);
    });

    test(
      'this chat\'s own turns fill it too, and a new chat empties it',
      () async {
        final claude = _FakeClaude();
        final chat = ClaudeChat(open: _routed(claude));
        addTearDown(chat.dispose);
        await chat.start();
        for (final line in made(1, 'Own task')) {
          claude.event(line);
        }
        await _settle();
        expect(labels(chat), ['pending:Own task']);
        await chat.newChat();
        expect(chat.openTasks, isEmpty);
        expect(chat.tasksDone, 0);
      },
    );
  });

  group('pictures', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('sshbox-pictures'));
    tearDown(() => dir.deleteSync(recursive: true));

    ChatPicture picture(String name, int number, [List<int>? bytes]) {
      final file = File('${dir.path}/$name')
        ..writeAsBytesSync(bytes ?? [0x89, 0x50, 0x4e, 0x47, number]);
      return ChatPicture(path: file.path, name: name, number: number);
    }

    test('to this chat\'s own Claude they go as image blocks after the text, '
        'read from here', () async {
      final claude = _FakeClaude();
      final chat = ClaudeChat(open: _routed(claude));
      addTearDown(chat.dispose);
      await chat.start();

      final shot = picture('shot.jpg', 1, [1, 2, 3]);
      await chat.send('what is [Image #1]?', pictures: [shot]);

      final content =
          (claude.sent.single['message'] as Map)['content'] as List<Object?>;
      expect(content, [
        {'type': 'text', 'text': 'what is [Image #1]?'},
        {
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': 'image/jpeg',
            'data': base64Encode([1, 2, 3]),
          },
        },
      ]);
      final said = chat.entries.whereType<ChatSaid>().single;
      expect(said.pictures.single.path, shot.path);
      expect(chat.nextPicture, 2);
    });

    test('into a running session each is uploaded and pasted as a path of '
        'its own where its [Image #N] is, the text typed around it once its '
        'chip is in, and it is sent once the session records it', () async {
      final host = _LiveHost('0\n')..drawChips = true;
      final chat = ClaudeChat(
        open: host.open,
        openTerminal: host.openTerminal,
        chipTimeout: const Duration(seconds: 10),
      );
      addTearDown(chat.dispose);
      await chat.continueFrom(_live);

      final uploaded = <String>[];
      final watch = Stopwatch()..start();
      await chat.send(
        'compare [Image #1] with [Image #2], and [Image #7] stays text',
        pictures: [picture('a.png', 1), picture('b.png', 2)],
        upload: (picture) async {
          uploaded.add(picture.name);
          return '/tmp/${picture.name}';
        },
      );
      while (host.terminals.isEmpty ||
          !host.terminals.single.typed.contains('\r')) {
        if (watch.elapsed > const Duration(seconds: 8)) fail('never sent');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      expect(uploaded, ['a.png', 'b.png']);
      expect(host.terminals.single.typed, [
        'compare ',
        '\x1b[200~/tmp/a.png\x1b[201~',
        ' with ',
        '\x1b[200~/tmp/b.png\x1b[201~',
        ', and [Image #7] stays text',
        '\r',
      ]);
      // What follows a picture waited for its chip, and not the whole
      // timeout.
      expect(host.chipsWhenTyped, [0, 0, 1, 1, 2, 2]);
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));

      // Claude numbers the chips itself, and the message is still its own.
      host.adds({
        'type': 'user',
        'imagePasteIds': [4, 5],
        'message': {
          'role': 'user',
          'content': [
            {
              'type': 'text',
              'text': 'compare [Image #4] with [Image #5], and [Image #7] '
                  'stays text',
            },
            {
              'type': 'image',
              'source': {'type': 'base64', 'data': base64Encode([9])},
            },
            {
              'type': 'image',
              'source': {'type': 'base64', 'data': base64Encode([8])},
            },
          ],
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final mine = chat.entries.whereType<ChatSaid>().single;
      expect(mine.delivery, isNull);
      expect([for (final p in mine.pictures) p.bytes], [
        [9],
        [8],
      ]);
      expect([for (final p in mine.pictures) p.number], [4, 5]);
      expect(chat.nextPicture, 6);
    });

    // The gate (see ClaudeChat._current) holds for a picture message as for
    // any other: its upload and its writes are for the target it was sent
    // for, and a failed one is retried with its pictures.
    test('moved off while its picture is uploading: no terminal is opened '
        'and nothing is typed, and it says so with what was written',
        () async {
      final host = _LiveHost('0\n')..drawChips = true;
      final chat = ClaudeChat(
        open: host.open,
        openTerminal: host.openTerminal,
        chipTimeout: const Duration(seconds: 10),
      );
      addTearDown(chat.dispose);
      await chat.continueFrom(_live);

      final upload = Completer<String>();
      await chat.send(
        'look at [Image #1]',
        pictures: [picture('a.png', 1)],
        upload: (_) => upload.future,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await chat.newChat();
      upload.complete('/tmp/a.png');
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(host.terminals, isEmpty);
      final told = chat.entries
          .whereType<ChatNotice>()
          .where((n) => n.failed && n.text.startsWith('Not sent to “'));
      expect(told, hasLength(1));
      expect(told.single.text, contains('look at [Image #1]'));
    });

    test('moved off between its parts: the text before a picture was typed, '
        'the rest is not, and Enter is held back', () async {
      final host = _LiveHost('0\n')..drawChips = true;
      final chat = ClaudeChat(
        open: host.open,
        openTerminal: host.openTerminal,
        chipTimeout: const Duration(seconds: 10),
      );
      addTearDown(chat.dispose);
      await chat.continueFrom(_live);

      await chat.send(
        'a [Image #1] b [Image #2] c',
        pictures: [picture('a.png', 1), picture('b.png', 2)],
        upload: (picture) async => '/tmp/${picture.name}',
      );
      // After the first picture's path is typed, before the second part.
      while (host.terminals.isEmpty ||
          host.terminals.single.typed.length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await chat.newChat();
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      final typed = host.terminals.single.typed;
      expect(typed, isNot(contains('\r')));
      expect(typed.join(), isNot(contains('b.png')));
      expect(host.terminals.single.closed.single, isTrue);
      // Said as what it is: part of it is in the session's input line.
      final notice = chat.entries.whereType<ChatNotice>().last;
      expect(notice.text, startsWith('Typed into “'));
      expect(notice.text, contains('a [Image #1] b [Image #2] c'));
    });

    test('a tmux pane: moved off while its picture is uploading, no key '
        'reaches the pane', () async {
      final host = _LiveHost('0\n', interactive: true);
      final chat = ClaudeChat(
        open: host.open,
        openTerminal: host.openTerminal,
      );
      addTearDown(chat.dispose);
      await chat.continueFrom(_interactive);

      final upload = Completer<String>();
      await chat.send(
        'look at [Image #1]',
        pictures: [picture('a.png', 1)],
        upload: (_) => upload.future,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await chat.newChat();
      upload.complete('/tmp/a.png');
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(host.paneTyping, isEmpty);
      expect(host.terminals, isEmpty);
    });

    test('a failed picture message is retried with its pictures, uploaded '
        'again, once, through the gate; the failed one is gone', () async {
      final host = _LiveHost('0\n')..drawChips = true;
      final chat = ClaudeChat(
        open: host.open,
        openTerminal: host.openTerminal,
        chipTimeout: const Duration(seconds: 10),
      );
      addTearDown(chat.dispose);
      await chat.continueFrom(_live);

      var attempts = 0;
      final uploaded = <String>[];
      Future<String> upload(ChatPicture picture) async {
        uploaded.add(picture.name);
        if (++attempts == 1) throw const FileSystemException('disk full');
        return '/tmp/${picture.name}';
      }

      await chat.send(
        'look at [Image #1]',
        pictures: [picture('a.png', 1)],
        upload: upload,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final failed = chat.entries.whereType<ChatSaid>().single;
      expect(failed.delivery, Delivery.failed);
      expect(failed.why, contains('could not be put on the host'));
      expect(host.terminals, isEmpty);

      expect(chat.retry(failed, upload: upload), isNull);
      final watch = Stopwatch()..start();
      while (host.terminals.isEmpty ||
          !host.terminals.single.typed.contains('\r')) {
        if (watch.elapsed > const Duration(seconds: 8)) fail('never sent');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(uploaded, ['a.png', 'a.png']);
      expect(host.terminals.single.typed, [
        'look at ',
        '\x1b[200~/tmp/a.png\x1b[201~',
        '\r',
      ]);
      expect(chat.entries, isNot(contains(failed)));
      expect(chat.entries.whereType<ChatSaid>().single.pictures, hasLength(1));
    });

    test('Retry of a picture message whose file has gone says so, and the '
        'failed message stays', () async {
      final host = _LiveHost('0\n');
      final chat = ClaudeChat(
        open: host.open,
        openTerminal: host.openTerminal,
      );
      addTearDown(chat.dispose);
      await chat.continueFrom(_live);

      final shot = picture('a.png', 1);
      await chat.send(
        'look at [Image #1]',
        pictures: [shot],
        upload: (_) async => throw const FileSystemException('disk full'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final failed = chat.entries.whereType<ChatSaid>().single;
      File(shot.path!).deleteSync();

      expect(chat.retry(failed, upload: (p) async => '/tmp/${p.name}'),
          contains('no longer on this device'));
      expect(chat.entries, contains(failed));
      expect(host.terminals, isEmpty);
    });

    test('to this chat\'s own Claude: a picture message is written only to '
        'the process it was sent for, and a failed one is retried to the '
        'new one with its pictures', () async {
      final claudes = <_FakeClaude>[];
      final chat = ClaudeChat(
        open: (command) async {
          if (command.contains('.jsonl')) return _noHistory();
          final claude = _FakeClaude();
          claudes.add(claude);
          return claude.channel;
        },
      );
      addTearDown(chat.dispose);
      await chat.start();
      final shot = picture('a.png', 1);
      await chat.send('what is [Image #1]?', pictures: [shot]);
      expect(claudes.single.sent, hasLength(1));
      // The process ends before it answers; the message did arrive there, so
      // it is not failed. A new one is sent after a restart, and a picture
      // message refused while Claude is down is not lost.
      await claudes.single.end();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await chat.send('and [Image #2]?', pictures: [picture('b.png', 2)]);
      expect(claudes.single.sent, hasLength(1));
      final notice = chat.entries.whereType<ChatNotice>().last;
      expect(notice.failed, isTrue);
      expect(notice.text, startsWith('Not sent:'));
      expect(notice.text, contains('and [Image #2]?'));
    });

    test('an [Image #N] typed as text does not stand for a chip: what '
        'follows a picture still waits for that picture\'s own', () async {
      // Slow enough that the text's own [Image #1] is on the line first.
      final host = _LiveHost('0\n')
        ..drawChips = true
        ..chipDelay = const Duration(milliseconds: 400);
      final chat = ClaudeChat(
        open: host.open,
        openTerminal: host.openTerminal,
        chipTimeout: const Duration(seconds: 10),
      );
      addTearDown(chat.dispose);
      await chat.continueFrom(_live);

      await chat.send(
        '[Image #1] is text, [Image #2] is the picture',
        pictures: [picture('b.png', 2)],
        upload: (picture) async => '/tmp/${picture.name}',
      );
      final watch = Stopwatch()..start();
      while (host.terminals.isEmpty ||
          !host.terminals.single.typed.contains('\r')) {
        if (watch.elapsed > const Duration(seconds: 8)) fail('never sent');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(host.terminals.single.typed, [
        '[Image #1] is text, ',
        '\x1b[200~/tmp/b.png\x1b[201~',
        ' is the picture',
        '\r',
      ]);
      // The text after the picture came once its chip was drawn, though the
      // line already held an [Image #1] of the user's own.
      expect(host.chipsWhenTyped, [0, 0, 1, 1]);
    });

    test('a picture that cannot go up says so, and nothing is typed', () async {
      final host = _LiveHost('0\n');
      final chat = ClaudeChat(open: host.open, openTerminal: host.openTerminal);
      addTearDown(chat.dispose);
      await chat.continueFrom(_live);

      await chat.send(
        'see [Image #1]',
        pictures: [picture('a.png', 1)],
        upload: (_) async => throw const FileSystemException('disk full'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      var said = chat.entries.whereType<ChatSaid>().last;
      expect(said.delivery, Delivery.failed);
      expect(said.why, contains('a.png could not be put on the host'));

      // A connection that cannot put a file there at all.
      await chat.send('see [Image #1]', pictures: [picture('a.png', 1)]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      said = chat.entries.whereType<ChatSaid>().last;
      expect(said.delivery, Delivery.failed);
      expect(said.why, contains('cannot put a picture on the host'));
      expect(host.terminals, isEmpty);
    });

    test('a new chat with pictures starts with no prompt, and the message is '
        'pasted into it', () async {
      final host = _LiveHost('0\n')..drawChips = true;
      final commands = <String>[];
      final chat = ClaudeChat(
        open: (command) async {
          commands.add(command);
          if (command.contains(' --bg ')) {
            return (
              output: Stream.value(
                Uint8List.fromList(
                  utf8.encode('backgrounded · 9e1f2a3b (idle — send a '
                      'prompt to start)\n'),
                ),
              ),
              write: (Uint8List data) {},
              close: () {},
            );
          }
          return host.open(command);
        },
        openTerminal: host.openTerminal,
      );
      addTearDown(chat.dispose);
      host.listed = {
        'pid': 7,
        'id': '9e1f2a3b',
        'cwd': '/srv/app',
        'kind': 'background',
        'sessionId': '9e1f2a3b-0000-4000-8000-000000000000',
        'name': '9e1f2a3b',
        'status': 'idle',
        'state': 'blocked',
      };

      await chat.send(
        '[Image #1] what is this?',
        pictures: [picture('a.png', 1)],
        upload: (picture) async => '/tmp/${picture.name}',
      );

      final start = commands.firstWhere((c) => c.contains(' --bg '));
      expect(start, isNot(contains(' -- ')));
      expect(start, isNot(contains('what is this')));
      expect(host.terminals.single.typed, [
        '\x1b[200~/tmp/a.png\x1b[201~',
        ' what is this?',
        '\r',
      ]);
      expect(chat.watching?.id, '9e1f2a3b');
    });

    test('a transcript\'s pictures are kept to draw, numbered as it numbered '
        'them, and one too big is left out', () async {
      final big = 'A' * (ClaudeChat.pictureLimit * 2);
      // Live: a line this long is past what the history's first read takes.
      final host = _LiveHost('0\n');
      final chat = ClaudeChat(open: host.open, openTerminal: host.openTerminal);
      addTearDown(chat.dispose);
      await chat.continueFrom(_live);
      host.adds({
        'type': 'user',
        'imagePasteIds': [2, 3],
        'message': {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '[Image #2] [Image #3] which?'},
            {
              'type': 'image',
              'source': {'type': 'base64', 'data': big},
            },
            {
              'type': 'image',
              'source': {'type': 'base64', 'data': base64Encode([7])},
            },
          ],
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final said = chat.entries.whereType<ChatSaid>().single;
      expect(said.pictures.single.bytes, [7]);
      expect(said.pictures.single.number, 3);
      expect(chat.nextPicture, 4);
    });

    test('the pane waits for chips counted from what its line held, with '
        'each [Image #N] typed as text on the way', () {
      final command = ClaudeChat.paneCommand(
        _live.sessionId,
        pid: 1,
        parts: [
          (length: 20, picture: false, tokens: 1),
          (length: 30, picture: true, tokens: 0),
          (length: 9, picture: false, tokens: 2),
          (length: 30, picture: true, tokens: 0),
        ],
      );
      // From c0, read before anything is typed: one typed token, then the
      // picture's chip; two more typed, then the second picture's.
      expect(command, contains('c0=\$(chips); '));
      expect(command, contains(r'-lt $((c0 + $1))'));
      expect(
        RegExp(r'chip (\d+);').allMatches(command).map((m) => m[1]),
        ['2', '5'],
      );
      expect(
        command.indexOf('c0=\$(chips); '),
        lessThan(command.indexOf('dd bs=1 count=20 ')),
      );
    });

    test('a token whose number no int holds is typed as text, and counted on '
        'the screen as Claude draws it', () {
      final parts = ClaudeChat.segments('[Image #99999999999999999999] hi [Image #1]', {
        1: '/tmp/a.png',
      });
      expect([for (final part in parts) part.keys], [
        '[Image #99999999999999999999] hi ',
        '\x1b[200~/tmp/a.png\x1b[201~',
      ]);
      expect(ClaudeChat.chipsIn(['❯ [Image #99999999999999999999] [Image #1]']), 2);
    });

    test('the chips counted are the input line\'s, not the turns above it', () {
      expect(
        ClaudeChat.chipsIn([
          '❯ [Image #1] an earlier one',
          '● Red',
          '────',
          '❯ [Image #2] [Image #3]',
          '  [Image #4]',
          '────',
          '  Opus 5.5',
        ]),
        3,
      );
      expect(ClaudeChat.chipsIn(['no prompt here [Image #1]']), 0);
    });
  });

  group('context and plan usage', () {
    setUp(ClaudeChat.forgetQuotas);
    // Shapes measured on 2.1.300 (numbers made up): an assistant message's
    // usage, a result's modelUsage, a rate_limit_event, and /usage under -p.
    Map<String, Object?> said(
      Map<String, Object?> usage, {
      String model = 'claude-opus-5-5',
    }) => {
      'type': 'assistant',
      'message': {
        'id': 'm${usage.hashCode}',
        'model': model,
        'stop_reason': 'tool_use',
        'usage': usage,
        'content': [
          {'type': 'text', 'text': 'x'},
        ],
      },
    };

    test('context is what the last request carried: input, cache and output',
        () {
      final context = ChatContext.from({
        'model': 'claude-opus-5-5',
        'usage': {
          'input_tokens': 10,
          'cache_creation_input_tokens': 1000,
          'cache_read_input_tokens': 90000,
          'output_tokens': 500,
        },
      })!;
      expect(context.tokens, 91510);
      expect(context.window, 200000);
      expect(context.fraction, closeTo(0.45755, 1e-9));
    });

    test('the window is a million past 200k or for a [1m] model, and what a '
        'result reported wins', () {
      expect(
        const ChatContext(tokens: 250000, model: 'claude-opus-5-5').window,
        1000000,
      );
      expect(const ChatContext(tokens: 1000, model: 'x[1m]').window, 1000000);
      expect(
        const ChatContext(tokens: 250000, reportedWindow: 400000).window,
        400000,
      );
    });

    test('a synthetic message, an odd shape and zeros say nothing', () {
      expect(
        ChatContext.from({
          'model': '<synthetic>',
          'usage': {'input_tokens': 5},
        }),
        isNull,
      );
      expect(ChatContext.from({'usage': 'lots'}), isNull);
      expect(ChatContext.from({'usage': {'input_tokens': -4}}), isNull);
      expect(ChatContext.from('nope'), isNull);
    });

    test('a session\'s context is its last request, from history and live',
        () async {
      final text = [
        said({
          'input_tokens': 1,
          'cache_read_input_tokens': 50000,
          'output_tokens': 10,
        }),
        said({
          'input_tokens': 1,
          'cache_read_input_tokens': 120000,
          'output_tokens': 40,
        }),
      ].map(jsonEncode).join('\n');
      final host = _LiveHost('${utf8.encode('$text\n').length}\n$text\n');
      final chat = ClaudeChat(open: host.open);
      addTearDown(chat.dispose);
      await chat.continueFrom(_live);
      expect(chat.context!.tokens, 120041);

      host.adds(
        said({
          'input_tokens': 1,
          'cache_read_input_tokens': 130000,
          'output_tokens': 5,
        }),
      );
      await _settle();
      expect(chat.context!.tokens, 130006);
    });

    test('a result gives the window, and a new chat clears the context',
        () async {
      final claude = _FakeClaude();
      final chat = ClaudeChat(open: _routed(claude));
      addTearDown(chat.dispose);
      await chat.start();
      claude.event(said({'input_tokens': 3, 'output_tokens': 2}));
      await _settle();
      expect(chat.context!.window, 200000);
      claude.event({
        'type': 'result',
        'subtype': 'success',
        'modelUsage': {
          'claude-opus-5-5': {'contextWindow': 1000000},
        },
      });
      await _settle();
      expect(chat.context!.window, 1000000);
      await chat.newChat();
      expect(chat.context, isNull);
    });

    test('a rate_limit_event of the stream gives the windows, utilization as '
        'a fraction and the reset in epoch seconds', () {
      final quota = ChatQuota.fromRateLimitEvent({
        'type': 'rate_limit_event',
        'rate_limit_info': {
          'status': 'allowed',
          'utilization': 0.28,
          'unifiedWindows': {
            'five_hour': {'utilization': 0.64, 'resetsAt': 1790931600},
            'seven_day': {'utilization': 0.28, 'resetsAt': 1791489600},
          },
        },
      }, asOf: DateTime.utc(2026, 10, 2))!;
      expect([for (final w in quota.windows) w.label], [
        'Session (5 h)',
        'Weekly',
      ]);
      expect(quota.windows.first.percent, closeTo(64, 1e-9));
      expect(
        quota.windows.first.resetsAt,
        DateTime.fromMillisecondsSinceEpoch(1790931600 * 1000, isUtc: true),
      );
    });

    test('a rate_limit_event arriving in a turn of the chat\'s own sets the '
        'quota with no ask of the host', () async {
      final claude = _FakeClaude();
      final commands = <String>[];
      final chat = ClaudeChat(
        open: (command) async {
          commands.add(command);
          return claude.channel;
        },
      );
      addTearDown(chat.dispose);
      await chat.start();
      claude.event({
        'type': 'rate_limit_event',
        'rate_limit_info': {
          'unifiedWindows': {
            'seven_day': {'utilization': 0.5, 'resetsAt': 1791489600},
          },
        },
      });
      await _settle();
      expect(chat.quota!.windows.single.label, 'Weekly');
      expect(chat.quota!.windows.single.percent, 50);
      expect(commands.where((c) => c.contains('/usage')), isEmpty);
    });

    test('/usage as Claude Code prints it under -p: each limit, its percent '
        'and its reset as printed; the rest is ignored', () {
      final quota = ChatQuota.fromUsageText(
        'You are currently using your subscription to power Claude Code\n'
        '\n'
        'Current session: 65% used · resets Oct 2, 3:59pm (Asia/Example)\n'
        'Current week (all models): 28% used · resets Oct 9, 2:59am (Asia/Example)\n'
        'Current week (Fable): 0% used · resets Oct 9, 3am (Asia/Example)\n'
        'Extra usage this month: 54% used · resets Nov 1\n'
        '\n'
        "What's contributing to your limits usage?\n"
        'Last 24h · 5689 requests · 47 sessions\n'
        '  100% of your usage was at >150k context\n',
        asOf: DateTime.utc(2026, 10, 2),
      )!;
      expect([for (final w in quota.windows) w.label], [
        'Current session',
        'Current week (all models)',
        'Current week (Fable)',
        'Extra usage this month',
      ]);
      expect([for (final w in quota.windows) w.percent], [65, 28, 0, 54]);
      expect(quota.windows.first.resetsText, 'Oct 2, 3:59pm (Asia/Example)');
    });

    test('a reset out of range, a negative one and a string are left out, '
        'and the rest of the event is kept', () {
      final quota = ChatQuota.fromRateLimitEvent({
        'type': 'rate_limit_event',
        'rate_limit_info': {
          'unifiedWindows': {
            'five_hour': {'utilization': 0.1, 'resetsAt': 1e13},
            'seven_day': {'utilization': 0.2, 'resetsAt': -5},
            'other': {'utilization': 0.3, 'resetsAt': 'soon'},
            'more': {'utilization': 0.4, 'resetsAt': 1790931600},
          },
        },
      }, asOf: DateTime.utc(2026))!;
      expect([for (final w in quota.windows) w.resetsAt == null], [
        true,
        true,
        true,
        false,
      ]);
    });

    test('controls in /usage text are cleaned from what is drawn', () {
      final quota = ChatQuota.fromUsageText(
        'Current \u001b[1msession\u001b[0m: 5% used · resets \u001b[2mlater\u009b\n',
        asOf: DateTime.utc(2026),
      )!;
      expect(quota.windows.single.label, 'Current [1msession[0m');
      expect(quota.windows.single.resetsText, '[2mlater');
    });

    test('usage nobody can read is no quota, and never throws', () {
      final at = DateTime.utc(2026);
      expect(ChatQuota.fromUsageText('', asOf: at), isNull);
      expect(ChatQuota.fromUsageText('Error: not logged in', asOf: at), isNull);
      expect(
        ChatQuota.fromUsageText('Current session: lots% used', asOf: at),
        isNull,
      );
      expect(ChatQuota.fromJson({'rate_limits': 'x'}, asOf: at), isNull);
      expect(
        ChatQuota.fromJson({
          'five_hour': {'used_percentage': 'many', 'resets_at': 'soon'},
          'seven_day': {'used_percentage': 12.5, 'resets_at': 'never'},
        }, asOf: at)!.windows.single.percent,
        12.5,
      );
    });

    test('the plan is asked once a minute at most for a host, and what it '
        'said is shared between the chats of the host', () async {
      usageOnHost = 'Current session: 10% used · resets later';
      addTearDown(() => usageOnHost = '');
      var now = DateTime.utc(2026, 10, 2, 12);
      final real = chatNow;
      chatNow = () => now;
      addTearDown(() => chatNow = real);
      final commands = <String>[];
      Future<CommandChannel> open(String command) async {
        commands.add(command);
        return command.contains('/usage') ? _says(usageOnHost) : _noHistory();
      }

      final one = ClaudeChat(open: open, hostKey: 'box');
      final two = ClaudeChat(open: open, hostKey: 'box');
      addTearDown(one.dispose);
      addTearDown(two.dispose);
      int asked() => commands.where((c) => c.contains('/usage')).length;

      await one.refreshQuota();
      await two.refreshQuota();
      expect(asked(), 1);
      expect(one.quota!.windows.single.percent, 10);
      expect(two.quota, same(one.quota));

      now = now.add(const Duration(seconds: 59));
      await one.refreshQuota();
      expect(asked(), 1);
      now = now.add(const Duration(seconds: 2));
      usageOnHost = 'Current session: 40% used';
      await two.refreshQuota();
      expect(asked(), 2);
      expect(one.quota!.windows.single.percent, 40);
    });

    test('an answer with no limit says it was not reported and keeps the '
        'last', () async {
      usageOnHost = 'Current session: 10% used';
      addTearDown(() => usageOnHost = '');
      final chat = ClaudeChat(
        open: (c) async => _says(usageOnHost),
        hostKey: 'unreported-box',
      );
      addTearDown(chat.dispose);
      await chat.refreshQuota(force: true);
      usageOnHost = 'Usage is not available.';
      await chat.refreshQuota(force: true);
      expect(chat.quotaNotReported, isTrue);
      expect(chat.quota!.windows.single.percent, 10);
    });
  });
}
