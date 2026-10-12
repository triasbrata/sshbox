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

/// A host whose connect waits on [gate], then comes up or refuses.
class _Host implements SessionTransport, TerminalSession {
  _Host(this.gate, {this.refuse = false});

  final Completer<void> gate;
  final bool refuse;
  final sent = <String>[];

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
    await gate.future;
    if (refuse) throw const SshSessionException('Connection refused.');
    status.value = SessionStatus.connected;
    return this;
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
  void send(String data) => sent.add(data);

  @override
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) {}

  @override
  Future<void> dispose() async {}
}

const _box = HostProfile(
  id: 'host-1',
  label: 'box',
  host: '10.0.2.2',
  username: 'me',
);

void main() {
  test('what is typed, pasted and tapped before the shell is ready goes in '
      'once, in order, when it is', () async {
    final gate = Completer<void>();
    final host = _Host(gate);
    final session = LiveSession(host: _box, transport: (_, _) => host);
    addTearDown(session.dispose);
    final connecting = session.connect(secrets: _NoSecrets());
    await pumpEventQueue();

    session.terminal.onOutput!('l'); // a key
    session.sendRaw('\x1b[A'); // the key bar
    session.terminal.paste('s -la'); // a paste
    session.terminal.onOutput!('\r');
    expect(host.sent, isEmpty, reason: 'nothing before the channel is open');

    gate.complete();
    await connecting;
    expect(host.sent.join(), 'l\x1b[As -la\r');
    expect(host.sent, hasLength(4));

    // After that it is written straight away, and nothing is written twice.
    session.terminal.onOutput!('x');
    expect(host.sent.last, 'x');
    expect(host.sent, hasLength(5));
    expect(session.takeInputProblem(), isNull);
  });

  test('past 64 KB the rest is dropped, and said', () async {
    final gate = Completer<void>();
    final host = _Host(gate);
    final session = LiveSession(host: _box, transport: (_, _) => host);
    addTearDown(session.dispose);
    final connecting = session.connect(secrets: _NoSecrets());
    await pumpEventQueue();

    session.sendRaw('a' * LiveSession.heldInputLimit);
    session.sendRaw('b');
    gate.complete();
    await connecting;
    expect(host.sent.join(), 'a' * LiveSession.heldInputLimit);
    expect(session.takeInputProblem(), contains('part of it was not sent'));
  });

  test('a shell that fails to start drops what was typed, says so, and '
      'never types it into a later connection', () async {
    final gate = Completer<void>();
    final failing = _Host(gate, refuse: true);
    final working = _Host(Completer<void>()..complete());
    var next = failing;
    final session = LiveSession(host: _box, transport: (_, _) => next);
    addTearDown(session.dispose);
    final connecting = session.connect(secrets: _NoSecrets());
    await pumpEventQueue();

    session.terminal.onOutput!('rm -rf x\r');
    gate.complete();
    await connecting;
    expect(session.isConnected, isFalse);
    expect(failing.sent, isEmpty);
    expect(session.takeInputProblem(), contains('was not sent'));
    expect(session.takeInputProblem(), isNull, reason: 'said once');

    next = working;
    await session.connect(secrets: _NoSecrets());
    expect(session.isConnected, isTrue);
    expect(working.sent, isEmpty, reason: 'the old input is not replayed');
  });

  test('a connect given up on drops what was typed', () async {
    final host = _Host(Completer<void>());
    final session = LiveSession(host: _box, transport: (_, _) => host);
    addTearDown(session.dispose);
    unawaited(session.connect(secrets: _NoSecrets()));
    await pumpEventQueue();
    session.terminal.onOutput!('secret\r');
    session.abandon();
    expect(session.takeInputProblem(), contains('was not sent'));
    expect(host.sent, isEmpty);
  });
}
