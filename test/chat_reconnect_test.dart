import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';

class _NoSecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String? value) async {}

  @override
  Future<void> purgeHost(String hostId) async {}
}

/// One connection to the host: it knows only which commands ran on it.
class _Conn implements SessionTransport, TerminalSession, ChannelCapable {
  final commands = <String>[];

  @override
  final status = ValueNotifier(SessionStatus.connected);

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
      output: Stream<Uint8List>.empty(),
      write: (Uint8List data) {},
      close: () {},
    );
  }

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
);

void main() {
  test('after a reconnect the chat runs its commands on the new connection, '
      'and says it is not connected while there is none', () async {
    final first = _Conn();
    final second = _Conn();
    final made = [first, second];
    final session = LiveSession(host: _host, transport: (_, _) => made.removeAt(0));
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());
    final chat = session.chat;

    await chat.open('on the first');
    expect(first.commands, ['on the first']);

    // Dropped: nothing to run a command on, and said so.
    await session.disconnect();
    await expectLater(
      chat.open('while down'),
      throwsA(
        isA<SshSessionException>().having(
          (e) => e.message,
          'message',
          'Not connected.',
        ),
      ),
    );
    expect(first.commands, ['on the first']);
    expect(second.commands, isEmpty);

    await session.connect(secrets: _NoSecrets());
    await chat.open('on the second');
    expect(second.commands, ['on the second']);
    expect(first.commands, ['on the first'], reason: 'the old one is not used');
  });
}
