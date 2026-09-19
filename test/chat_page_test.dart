import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/chat_page.dart';

class _NoSecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String? value) async {}

  @override
  Future<void> purgeHost(String hostId) async {}
}

/// A host that is up at once and can run a command beside the shell — which
/// is all a chat needs of a session.
class _Shell
    implements
        SessionTransport,
        TerminalSession,
        ChannelCapable,
        TerminalChannelCapable {
  /// What was typed into each terminal opened on the host.
  final typed = <List<String>>[];

  @override
  Future<CommandChannel> openTerminal(
    String command, {
    int columns = 120,
    int rows = 40,
  }) async {
    commands.add(command);
    final keys = <String>[];
    typed.add(keys);
    final screen = StreamController<Uint8List>();
    // `claude attach` drawing its input line.
    scheduleMicrotask(
      () => screen.add(Uint8List.fromList(utf8.encode(' ❯ '))),
    );
    return (
      output: screen.stream,
      write: (Uint8List data) => keys.add(utf8.decode(data)),
      close: () => unawaited(screen.close()),
    );
  }

  /// Every command started on the host, and the pipes each one was given.
  final commands = <String>[];
  final written = <String>[];

  /// A channel of its own per command, as the host gives one: the chat opens
  /// a second when it picks a session up, and the first one's is over.
  final _channels = <StreamController<Uint8List>>[];

  @override
  Future<TerminalSession> connect({
    required HostProfile host,
    required SecretStore secrets,
    required int columns,
    required int rows,
    bool shell = true,
    Map<String, String> environment = const {},
    Future<Map<String, String>> Function(ForwardCapable host)? beforeShell,
  }) async => this;

  /// What `claude agents --json` answers, when a test sets one.
  String? listing;

  /// What the history command answers: the transcript's size, then its end.
  /// A session that has said nothing, unless a test says otherwise.
  String history = '0\n';

  /// The running session's transcript as it grows, once something follows
  /// it.
  StreamController<Uint8List>? follow;

  /// The session writing one more line to its transcript.
  void adds(Map<String, Object?> line) => follow!.add(
    Uint8List.fromList(utf8.encode('${jsonEncode(line)}\n')),
  );

  @override
  Future<CommandChannel> open(String command) async {
    commands.add(command);
    if (command.contains(' -f ')) {
      final controller = StreamController<Uint8List>();
      follow = controller;
      return (
        output: controller.stream,
        write: (Uint8List data) {},
        close: () {},
      );
    }
    if (command.contains('.jsonl')) {
      return (
        output: Stream.value(Uint8List.fromList(utf8.encode(history))),
        write: (Uint8List data) {},
        close: () {},
      );
    }
    final rows = listing;
    if (rows != null && command.contains('agents --json')) {
      // One shot: the listing, then the command is over.
      return (
        output: Stream.value(Uint8List.fromList(utf8.encode(rows))),
        write: (Uint8List data) {},
        close: () {},
      );
    }
    final output = StreamController<Uint8List>();
    _channels.add(output);
    return (
      output: output.stream,
      write: (Uint8List data) => written.add(utf8.decode(data)),
      close: output.close,
    );
  }

  /// One event from Claude, as the process writes it, down the channel it is
  /// talking on now.
  void event(Map<String, dynamic> event) => _channels.last.add(
    Uint8List.fromList(utf8.encode('${jsonEncode(event)}\n')),
  );

  @override
  final status = ValueNotifier(SessionStatus.connected);

  @override
  Stream<String> get output => const Stream.empty();

  @override
  String? get failure => null;

  @override
  void send(String data) {}

  @override
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) {}

  @override
  Future<void> dispose() async {}
}

/// The end of a session's transcript, as the host hands it over.
String _history(List<Map<String, Object?>> lines) {
  final body = lines.map(jsonEncode).join('\n');
  return '${utf8.encode(body).length}\n$body\n';
}

final _nightlyHistory = _history([
  {'type': 'mode'},
  {
    'type': 'user',
    'message': {'role': 'user', 'content': 'is the nightly build green?'},
  },
  {
    'type': 'assistant',
    'message': {
      'role': 'assistant',
      'content': [
        {'type': 'text', 'text': 'It failed at the lint step.'},
      ],
    },
  },
]);

/// Lets a pick-up run out. Closing the drawer, reading the history and
/// starting Claude are futures, not frames, so settling the frames alone
/// returns while they are in flight; this takes turns between the two until
/// both are quiet.
Future<void> _settlePickUp(WidgetTester tester) async {
  for (var turn = 0; turn < 8; turn++) {
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  await tester.pump();
}

const _host = HostProfile(
  id: 'host-1',
  label: 'box',
  host: '10.0.2.2',
  username: 'me',
  fileRoot: '/srv/app',
);

void main() {
  testWidgets('a connected session starts Claude where its files are', (
    tester,
  ) async {
    final shell = _Shell();
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ChatPage(session: session))),
    );
    await tester.pump();

    // Started in the files' root; how the path is quoted is claude_chat_test's,
    // which runs the command through a shell rather than reading it.
    expect(shell.commands.single, contains('cd '));
    expect(shell.commands.single, contains('/srv/app'));
    expect(shell.commands.single, contains('--output-format stream-json'));
    // Nothing said yet, so the tab says where Claude is running.
    expect(find.textContaining('/srv/app'), findsOneWidget);
  });

  testWidgets('what is typed goes to Claude, and what comes back is drawn', (
    tester,
  ) async {
    final shell = _Shell();
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ChatPage(session: session))),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'check the nginx log');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();

    expect(
      jsonDecode(shell.written.single.trim()),
      containsPair('type', 'user'),
    );
    // The user's own words, on screen, and the field cleared for the next.
    expect(find.text('check the nginx log'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    // A turn is running: nothing else may be sent until it ends.
    expect(find.text('Claude is working…'), findsOneWidget);

    shell.event({
      'type': 'assistant',
      'message': {
        'content': [
          {'type': 'text', 'text': 'Looking now.'},
          {
            'type': 'tool_use',
            'id': 'toolu_01',
            'name': 'Bash',
            'input': {'command': 'tail -n 50 error.log'},
          },
        ],
      },
    });
    await tester.pump();
    await tester.pump();

    expect(find.text('Looking now.'), findsOneWidget);
    expect(find.text('Bash'), findsOneWidget);
    expect(find.text('tail -n 50 error.log'), findsOneWidget);

    shell.event({'type': 'result', 'subtype': 'success'});
    await tester.pump();
    await tester.pump();
    expect(find.text('Claude is working…'), findsNothing);
  });

  testWidgets('an unconnected session says so rather than starting anything', (
    tester,
  ) async {
    final shell = _Shell();
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ChatPage(session: session))),
    );
    await tester.pump();

    expect(shell.commands, isEmpty);
    expect(find.text('Connect this session first'), findsOneWidget);
  });

  testWidgets('the sessions on the host are offered, and one still running '
      'is watched live, updating by itself', (tester) async {
    final shell = _Shell()
      ..history = _nightlyHistory
      ..listing = jsonEncode([
        {
          'pid': 4079548,
          'id': '81badf4a',
          'cwd': '/srv/app',
          'kind': 'background',
          'startedAt': DateTime.now()
              .subtract(const Duration(hours: 2))
              .millisecondsSinceEpoch,
          'sessionId': '81badf4a-7e9f-4f01-b098-6968dbe5f070',
          'name': 'the nightly build',
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
      ]);
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ChatPage(session: session))),
    );
    await tester.pump();

    await tester.tap(find.text('Sessions on this host'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Both kinds are listed, each saying what it is and where it runs.
    expect(find.text('the nightly build'), findsOneWidget);
    expect(find.text('dev-e0'), findsOneWidget);
    expect(find.textContaining('at a terminal'), findsOneWidget);
    expect(find.textContaining('2h ago'), findsOneWidget);

    await tester.tap(find.text('the nightly build'));
    await _settlePickUp(tester);

    // What was already said in it is there: the conversation it had, not a
    // blank tab on a session Claude remembers.
    expect(find.text('is the nightly build green?'), findsOneWidget);
    expect(find.text('It failed at the lint step.'), findsOneWidget);
    // Its process is alive, so it is followed rather than resumed or
    // copied, and the tab says so.
    expect(shell.commands.last, contains(' -f '));
    expect(
      shell.commands.last,
      contains('81badf4a-7e9f-4f01-b098-6968dbe5f070'),
    );
    expect(find.textContaining('Watching'), findsOneWidget);

    // What it says next shows by itself, without picking it again.
    shell.adds({
      'type': 'assistant',
      'message': {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'Lint fixed, build running again.'},
        ],
      },
    });
    await _settlePickUp(tester);
    expect(find.text('Lint fixed, build running again.'), findsOneWidget);
  });

  testWidgets('a host that cannot list its sessions says what it said',
      (tester) async {
    final shell = _Shell()..listing = "error: unknown command 'agents'";
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ChatPage(session: session))),
    );
    await tester.pump();

    await tester.tap(find.text('Sessions on this host'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining("unknown command 'agents'"), findsOneWidget);
  });

  testWidgets('on a tablet the sessions are a sidebar beside the chat, '
      'marking the one showing', (tester) async {
    tester.view
      ..physicalSize = const Size(1280, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final shell = _Shell()
      ..history = _nightlyHistory
      ..listing = jsonEncode([
        {
          'pid': 4079548,
          'id': '81badf4a',
          'cwd': '/srv/app',
          'kind': 'background',
          'sessionId': '81badf4a-7e9f-4f01-b098-6968dbe5f070',
          'name': 'the nightly build',
          'status': 'idle',
        },
      ]);
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ChatPage(session: session))),
    );
    await tester.pumpAndSettle();

    // In view without asking: no sheet, no drawer, and no button in the empty
    // tab to show what is already showing.
    expect(find.text('the nightly build'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Sessions on this host'),
        findsNothing);

    await tester.tap(find.text('the nightly build'));
    await _settlePickUp(tester);

    // Still beside the chat, with the one picked marked, and its
    // conversation drawn next to it.
    final row = tester.widget<ListTile>(
      find.ancestor(
        of: find.text('the nightly build'),
        matching: find.byType(ListTile),
      ),
    );
    expect(row.selected, isTrue);
    expect(find.text('is the nightly build green?'), findsOneWidget);

    // The button beside the box hides it, for room to read, and brings it
    // back.
    await tester.tap(find.byTooltip('Hide the sessions on this host'));
    await tester.pumpAndSettle();
    expect(find.text('the nightly build'), findsNothing);
    await tester.tap(find.byTooltip('Sessions on this host'));
    await tester.pumpAndSettle();
    expect(find.text('the nightly build'), findsOneWidget);
  });

  testWidgets('what is typed into a session being watched shows as sending, '
      'then as said once the session has it', (tester) async {
    tester.view
      ..physicalSize = const Size(1280, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final shell = _Shell()
      ..history = _nightlyHistory
      ..listing = jsonEncode([
        {
          'pid': 4079548,
          'id': '81badf4a',
          'cwd': '/srv/app',
          'kind': 'background',
          'sessionId': '81badf4a-7e9f-4f01-b098-6968dbe5f070',
          'name': 'the nightly build',
          'status': 'idle',
          'state': 'done',
        },
      ]);
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ChatPage(session: session))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('the nightly build'));
    await _settlePickUp(tester);

    // Open to typing while watching, and says where it goes.
    expect(
      tester.widget<TextField>(find.byType(TextField)).decoration!.hintText,
      'Message “the nightly build”…',
    );
    await tester.enterText(find.byType(TextField), 'run it once more');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    expect(find.text('Sending…'), findsOneWidget);

    for (var turn = 0; turn < 12; turn++) {
      await tester.pump(const Duration(milliseconds: 250));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    // Into the running session itself, through its attach.
    expect(shell.commands.any((command) => command.contains('attach')),
        isTrue);
    expect(shell.typed.single.first, '\x1b[200~run it once more\x1b[201~');
    expect(find.text('Sending…'), findsOneWidget);

    shell.adds({
      'type': 'user',
      'message': {'role': 'user', 'content': 'run it once more'},
    });
    await _settlePickUp(tester);

    expect(find.text('Sending…'), findsNothing);
    expect(find.text('run it once more'), findsOneWidget);
  });

  testWidgets('a session pinned in claude agents is pinned in the sidebar, '
      'first', (tester) async {
    tester.view
      ..physicalSize = const Size(1280, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Map<String, Object?> bg(String id, String name) => {
      'pid': 1,
      'id': id,
      'cwd': '/srv',
      'kind': 'background',
      'sessionId': '$id-0000-0000-0000-000000000000',
      'name': name,
      'status': 'idle',
      'state': 'done',
    };
    final shell = _Shell()
      ..listing =
          '${jsonEncode([bg('aaaa1111', 'not pinned'), bg('bbbb2222', 'pinned')])}'
          '\n--- pins\n["bbbb2222"]\n';
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ChatPage(session: session))),
    );
    await tester.pumpAndSettle();

    final rows = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((tile) => (tile.title! as Text).data)
        .toList();
    expect(rows, ['pinned', 'not pinned']);
    expect(find.byIcon(Icons.push_pin), findsOneWidget);
  });

  testWidgets('a tool row opens to its input and its result', (tester) async {
    final shell = _Shell();
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ChatPage(session: session))),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'check the nginx log');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();

    shell.event({
      'type': 'assistant',
      'message': {
        'content': [
          {
            'type': 'tool_use',
            'id': 'toolu_09',
            'name': 'Bash',
            'input': {'command': 'tail -n 50 error.log'},
          },
        ],
      },
    });
    shell.event({
      'type': 'user',
      'message': {
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'toolu_09',
            'content': '3 upstream timeouts',
          },
        ],
      },
    });
    // The turn ends, so nothing is left spinning.
    shell.event({'type': 'result', 'subtype': 'success'});
    await tester.pump();
    await tester.pump();

    // The tile keeps its open-or-shut bool in page storage under its own
    // key; the scroll views inside once stored their offset under the same
    // one and read that bool back as a double, which threw — and a release
    // build draws a widget that threw as nothing.
    await tester.tap(find.text('Bash'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(find.textContaining('"command": "tail -n 50 error.log"'),
        findsOneWidget);
    expect(find.text('3 upstream timeouts'), findsOneWidget);
  });
}
