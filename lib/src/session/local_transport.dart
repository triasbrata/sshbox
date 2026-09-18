import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';

import '../data/secret_store.dart';
import '../models/host_profile.dart';
import 'terminal_session.dart';

/// The host a local shell runs on: this machine. Saved nowhere — it is made
/// fresh each time and never reaches [HostRepository], so it cannot be edited,
/// deleted or duplicated like a real host.
///
/// The id is fixed so [SessionManager.resume] finds the shell already open on
/// it, the way it does for a saved host.
HostProfile localHost() => HostProfile(
  id: localHostId,
  label: 'Local shell',
  host: 'localhost',
  username: Platform.environment['USER'] ?? 'local',
);

const localHostId = 'local';

/// A shell on this machine, for the desktop builds — the one thing a phone
/// cannot have: iOS forbids `fork`/`exec` outright, and Android's W^X rules
/// stop an app executing anything from its own data directory.
///
/// It is a [SessionTransport] like the SSH one, so every tab, terminal and
/// keystroke path above it is unchanged. What it does not implement is as
/// important as what it does: no [FileBrowseCapable] or [ForwardCapable], so
/// the files drawer and the tailnet forwarding switch themselves off for it
/// rather than failing at a use. [CommandCapable] it does have, which is what
/// the git tab runs through.
class LocalTransport implements SessionTransport {
  LocalTransport({this.shell, this.startPty = Pty.start});

  /// The program a session runs, defaulting to the user's login shell and
  /// falling back to `/bin/bash`, which macOS still ships.
  final String? shell;

  /// How a pty is started, so a test can hand over one of its own: the real
  /// one loads a native library this app only has on a desktop.
  final Pty Function(
    String executable, {
    List<String> arguments,
    String? workingDirectory,
    Map<String, String>? environment,
    int rows,
    int columns,
    bool ackRead,
  })
  startPty;

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
    // [beforeShell] is the SSH one's chance to ask the host for a notify port
    // and hand the relay key over. Nothing here needs either: the app and the
    // shell are the same machine, so it is not called, and its variables are
    // never in this shell's environment.
    if (!shell) {
      throw const SshSessionException(
        'A local session is a shell; it has nothing else to open.',
      );
    }
    final program = this.shell ?? Platform.environment['SHELL'] ?? '/bin/bash';
    try {
      final pty = startPty(
        program,
        // A login shell, so it reads the profile that sets PATH — without it a
        // shell started by a windowed app has the bare launchd PATH and cannot
        // find brew, fvm or anything else the user installed.
        arguments: ['-l'],
        workingDirectory: Platform.environment['HOME'],
        environment: environment.isEmpty ? null : environment,
        rows: rows,
        columns: columns,
      );
      return _LocalSession(pty);
    } catch (error) {
      throw SshSessionException('Cannot start $program: $error');
    }
  }
}

class _LocalSession implements TerminalSession, CommandCapable {
  _LocalSession(this._pty) {
    // Chunked rather than a decode per event: a character the shell writes in
    // two reads arrives split across them, and this holds the first half until
    // the rest comes. Malformed bytes are let through as the replacement
    // character — a terminal shows what it is sent.
    _subscription = _pty.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(_output.add);
    unawaited(_watchExit());
  }

  final Pty _pty;
  final _output = StreamController<String>.broadcast();
  final _status = ValueNotifier(SessionStatus.connected);
  late final StreamSubscription<String> _subscription;
  String? _failure;
  bool _disposed = false;

  Future<void> _watchExit() async {
    final code = await _pty.exitCode;
    if (_disposed) return;
    // `exit` is how a shell is meant to end, so only a code says something
    // went wrong — and even then the closed tab is the message, as it is for
    // a dropped connection.
    if (code != 0) _failure = 'The shell exited with code $code.';
    _status.value = SessionStatus.closed;
  }

  @override
  Stream<String> get output => _output.stream;

  @override
  ValueListenable<SessionStatus> get status => _status;

  @override
  String? get failure => _failure;

  @override
  void send(String data) {
    if (_disposed) return;
    _pty.write(const Utf8Encoder().convert(data));
  }

  @override
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) {
    if (_disposed) return;
    // The pty takes rows first, the terminal gives columns first.
    _pty.resize(rows, columns);
  }

  /// A command beside the shell, as the SSH transport runs one — a process of
  /// its own rather than anything typed into the pty, so what the git tab asks
  /// for never lands in the user's command line.
  ///
  /// `sh -c` because the callers write shell: pipes, redirections and `$HOME`
  /// are theirs to use. [pty] is ignored: a local process needs no terminal to
  /// be hung up, it is killed outright when the stream is cancelled.
  @override
  Stream<String> run(String command, {bool pty = false}) async* {
    if (_disposed) {
      throw const SshSessionException('This shell has ended.');
    }
    final process = await Process.start('/bin/sh', ['-c', command]);
    try {
      yield* process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter());
    } finally {
      process.kill();
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription.cancel();
    try {
      _pty.kill();
    } catch (_) {
      // Already gone: the shell exited on its own.
    }
    await _output.close();
    _status.value = SessionStatus.closed;
    _status.dispose();
  }
}
