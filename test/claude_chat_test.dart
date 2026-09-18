import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/chat/claude_chat.dart';
import 'package:sshbox/src/session/terminal_session.dart';

/// Claude Code's end of `claude -p --output-format stream-json`: whatever the
/// test says it wrote, and whatever the app sent it.
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
      return _FakeClaude().channel;
    },
  );
}

const _live = ClaudeAgent(
  sessionId: '3cae97ea-5874-4a0b-b8bd-6ad88edf0e2f',
  name: 'nginx look',
  cwd: '/srv/app',
  kind: 'background',
  id: '3cae97ea',
  status: 'idle',
  pid: 1241689,
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
  _LiveHost(this.history, {this.state = 'done'});

  final String history;

  /// What `claude agents` says the watched session is doing right now.
  String? state;
  final commands = <String>[];
  StreamController<Uint8List>? follow;
  var followClosed = false;

  /// Every terminal opened on the host: the command, what was typed into it,
  /// and whether it has been closed — in the order they were opened.
  final terminals = <({String command, List<String> typed, List<bool> closed})>[];

  /// Whether a terminal draws a prompt to type at. A TUI that never comes up
  /// is a test's to ask for.
  var terminalsDraw = true;

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
    return (
      output: screen.stream,
      write: (Uint8List data) => typed.add(utf8.decode(data)),
      close: () {
        closed[0] = true;
        unawaited(screen.close());
      },
    );
  }

  Future<CommandChannel> open(String command) async {
    commands.add(command);
    if (command.contains('agents --json')) {
      final listed = jsonEncode([
        {
          'pid': _live.pid,
          'id': _live.id,
          'cwd': _live.cwd,
          'kind': 'background',
          'sessionId': _live.sessionId,
          'name': _live.name,
          'status': state == 'working' ? 'busy' : 'idle',
          'state': ?state,
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
  test('a turn becomes bubbles, and its tools fold their results in', () async {
    final claude = _FakeClaude();
    final chat = ClaudeChat(open: (_) async => claude.channel);
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
    final chat = ClaudeChat(open: (_) async => claude.channel);
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
    final chat = ClaudeChat(open: (_) async => claude.channel);
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
    final chat = ClaudeChat(open: (_) async => claude.channel);
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
    final chat = ClaudeChat(open: (_) async => claude.channel);
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

  test('the command finds Claude, starts where the files are, and '
      'resumes', () {
    final command = ClaudeChat.command(
      cwd: "/srv/it's here",
      permission: ChatPermission.bypass,
      resume: 'f44e6c8b',
    );
    // JSON both ways, and nothing that would wait for a prompt nobody can
    // answer.
    expect(command, contains('--input-format stream-json'));
    expect(command, contains('--output-format stream-json'));
    expect(command, contains('--permission-mode bypassPermissions'));
    expect(command, contains('--permission-prompts none'));
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
    final chat = ClaudeChat(open: (_) async => claude.channel);
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
    final chat = ClaudeChat(open: (_) async => claude.channel);
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
    final chat = ClaudeChat(open: (_) async => claude.channel);
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
    // is what the chat does with a read that cut a line.
    expect(host.commands.first, contains('.jsonl'));
    expect(
      chat.entries.first,
      isA<ChatNotice>().having(
        (notice) => notice.text,
        'text',
        contains('earlier'),
      ),
    );
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
    expect(host.commands.single, contains('.jsonl'));
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
    final chat = ClaudeChat(open: (_) async => claude.channel);
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
    final chat = ClaudeChat(open: (_) async => claude.channel);
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
    ClaudeChat watcher(_LiveHost host, {Duration? deliveryTimeout}) {
      final chat = ClaudeChat(
        open: host.open,
        openTerminal: host.openTerminal,
        deliveryTimeout: deliveryTimeout ?? const Duration(seconds: 30),
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

      // Into `claude attach` for that very session, as a paste, then Enter.
      final terminal = host.terminals.single;
      expect(terminal.command, contains('attach'));
      expect(terminal.command, contains(_live.id));
      expect(terminal.typed, [
        '\x1b[200~is the build green?\x1b[201~',
        '\r',
      ]);
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

    for (final state in ['blocked', 'waiting-on-you', null]) {
      test('a session whose state is ${state ?? 'not given'} is never typed '
          'into', () async {
        final host = _LiveHost('0\n', state: state);
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

    test('what is typed cannot end the paste early or send a control key',
        () async {
      final host = _LiveHost('0\n');
      final chat = watcher(host);
      await chat.continueFrom(_live);

      chat.send('a\x1b[201~\x1b[2Jb\x03c\x9bd\ne');
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      final paste = host.terminals.single.typed.first;
      expect(paste, '\x1b[200~a[201~[2Jbcd\ne\x1b[201~');
      expect('\x1b'.allMatches(paste), hasLength(2));
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
}
