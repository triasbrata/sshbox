import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/clipboard_terminal.dart' show ClipboardTerminal;
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/terminal_page.dart';

class _NoSecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String? value) async {}

  @override
  Future<void> purgeHost(String hostId) async {}
}

/// A host with tmux on it whose control mode answers every command, and
/// refuses each `set-buffer` after the first: a paste cut in the middle.
class _Host implements SessionTransport, TerminalSession, ChannelCapable {
  final _output = StreamController<Uint8List>();
  final commands = <String>[];
  var _number = 0;
  var _sets = 0;

  @override
  Future<TerminalSession> connect({
    required HostProfile host,
    required SecretStore secrets,
    required int columns,
    required int rows,
    bool shell = true,
    Map<String, String> environment = const {},
    Future<Map<String, String>> Function(ForwardCapable host)? beforeShell,
  }) async {
    status.value = SessionStatus.connected;
    return this;
  }

  void _say(String line) => _output.add(Uint8List.fromList(utf8.encode('$line\n')));

  @override
  Future<CommandChannel> open(String command) async {
    _say('%session-changed \$1 sshbox-test');
    return (
      output: _output.stream,
      write: (data) {
        for (final command in utf8.decode(data).trim().split('\n')) {
          commands.add(command);
          final number = ++_number;
          _say('%begin 1789000000 $number 1');
          if (command.startsWith('set-buffer') && ++_sets == 2) {
            _say('bad buffer');
            _say('%error 1789000000 $number 1');
            continue;
          }
          if (command.startsWith('display -p "#{window_id}')) {
            _say('@1\tb25d,80x24,0,0,1\t%1');
          }
          _say('%end 1789000000 $number 1');
        }
      },
      close: () {},
    );
  }

  @override
  final ValueNotifier<SessionStatus> status = ValueNotifier(
    SessionStatus.connecting,
  );

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

void main() {
  testWidgets('a tmux paste that is cut short says so on the page', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final host = _Host();
    final session = LiveSession(
      host: const HostProfile(
        id: 'host-1',
        label: 'box',
        host: '10.0.2.2',
        username: 'me',
        useTmux: true,
      ),
      transport: (_, _) => host,
    );
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: TerminalPage(
          session: session,
          secrets: _NoSecrets(),
          onOpenFile: (_, {line}) {},
          onOpenWeb: (_) {},
          onOpenChat: () {},
          onOpenGit: () {},
          onOpenDiff: (_) {},
          onSaveFileRoot: (_) async {},
        ),
      ),
    );
    await tester.runAsync(() => session.connect(secrets: _NoSecrets()));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(session.tmux, isNotNull);
    expect(session.terminal, isA<ClipboardTerminal>());
    expect(find.textContaining('did not arrive whole'), findsNothing);

    // Past one chunk, so the second set-buffer is the refused one.
    session.terminal.paste('x' * 20000);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

    expect(
      host.commands.where((c) => c.startsWith('paste-buffer')),
      isEmpty,
      reason: 'a cut paste is never pasted',
    );
    expect(
      find.textContaining('The paste did not arrive whole: bad buffer'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 10));
  });
}
