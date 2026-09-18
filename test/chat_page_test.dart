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
  final _output = StreamController<Uint8List>.broadcast();

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

  @override
  Future<CommandChannel> open(String command) async {
    commands.add(command);
    return (
      output: _output.stream,
      write: (Uint8List data) => written.add(utf8.decode(data)),
      close: () {},
    );
  }

  /// One event from Claude, as the process writes it.
  void event(Map<String, dynamic> event) =>
      _output.add(Uint8List.fromList(utf8.encode('${jsonEncode(event)}\n')));

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
}
