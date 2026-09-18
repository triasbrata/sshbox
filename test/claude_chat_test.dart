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

  test('picking up a session that is still running branches off it rather '
      'than resuming it', () async {
    final commands = <String>[];
    final channels = <_FakeClaude>[];
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
    chat.send('this chat, before it was handed a session');
    await _settle();

    await chat.continueFrom(
      const ClaudeAgent(
        sessionId: 'aaaa1111-0000-0000-0000-000000000000',
        name: 'the one at work',
        cwd: '/srv/app',
        kind: 'background',
        id: 'aaaa1111',
        status: 'busy',
        pid: 4079548,
      ),
    );

    // The CLI refuses -p --resume for a session whose process is alive,
    // busy or idle alike, so a live one is branched off.
    expect(commands.last, contains('--fork-session'));
    expect(commands.last, contains('--resume'));
    // The id itself, not how it is quoted — the shell test below is what
    // proves the quoting, because text that reads right can still run wrong.
    expect(commands.last, contains('aaaa1111-0000-0000-0000-000000000000'));
    // A new conversation: what this chat said before is not what that
    // session said.
    expect(chat.entries.whereType<ChatSaid>(), isEmpty);
    expect(
      chat.entries.whereType<ChatNotice>().single.text,
      allOf(contains('the one at work'), contains('keeps running')),
    );

    // The fork has an id of its own from here on, and is not forked again.
    channels.last.event({
      'type': 'system',
      'subtype': 'init',
      'session_id': 'bbbb2222-0000-0000-0000-000000000000',
    });
    await _settle();
    await chat.restart();
    expect(commands.last, contains('bbbb2222-0000-0000-0000-000000000000'));
    expect(commands.last, isNot(contains('--fork-session')));
  });

  test('picking up a session that has finished continues it where it was',
      () async {
    final commands = <String>[];
    final chat = ClaudeChat(
      open: (command) async {
        commands.add(command);
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

    expect(commands.single, contains('--resume'));
    expect(commands.single, contains('cf58d27a-da65-4e9b-a896-078306134024'));
    expect(commands.single, isNot(contains('--fork-session')));
    expect(
      chat.entries.whereType<ChatNotice>().single.text,
      allOf(contains('Zsh config fix'), isNot(contains('copy'))),
    );
  });

  test('listing the sessions, and the id of one picked up, reach Claude '
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
        ['-c', ClaudeChat.command(resume: session, fork: true)],
        environment: path,
      );
      final lines = (result.stdout as String).split('\n');
      final at = lines.indexOf('--resume');
      expect(at, isNot(-1), reason: session);
      expect(lines[at + 1], session, reason: session);
      expect(lines[at + 2], '--fork-session', reason: session);
      expect(result.stdout, isNot(contains('RAN\n')), reason: session);
    }
    // Nothing a session id held was ever run.
    expect(File('${root.path}/RAN').existsSync(), isFalse);
  });
}
