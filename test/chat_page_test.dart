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
    implements SessionTransport, TerminalSession, ChannelCapable {
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

  @override
  Future<CommandChannel> open(String command) async {
    commands.add(command);
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
      'is picked up as a copy', (tester) async {
    final shell = _Shell()
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
    // Settle the frames, then let the event loop run out: picking one up
    // closes the sheet, ends the process that was running and starts
    // another, and those hops are futures rather than frames — settling
    // alone returns while they are still in flight.
    await tester.pumpAndSettle();
    // The hops that follow are futures, not frames: the sheet's result, the
    // process being stopped and the next one started. runAsync lets the real
    // event loop run them out before this asks what the host was told.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();

    // Its process is alive, so it is branched off rather than resumed, and
    // the tab says so rather than leaving the user to guess.
    expect(shell.commands.last, contains('--fork-session'));
    expect(
      shell.commands.last,
      contains('81badf4a-7e9f-4f01-b098-6968dbe5f070'),
    );
    expect(find.textContaining('keeps running'), findsOneWidget);
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
}
