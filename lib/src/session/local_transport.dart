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
  username: _userName(),
);

const localHostId = 'local';

/// A WSL distro on this Windows machine, as a host of its own: each distro
/// counts and resumes its own shells, as a saved host does. Saved nowhere,
/// like [localHost].
HostProfile wslHost(String distro) => HostProfile(
  id: 'wsl:$distro',
  label: distro,
  host: 'localhost',
  username: _userName(),
);

/// `USER` on a Mac or Linux, `USERNAME` on Windows.
String _userName() =>
    Platform.environment['USER'] ?? Platform.environment['USERNAME'] ?? 'local';

/// Windows' own wsl.exe, by its full path: a bare name is looked for in the
/// app's folder and the working directory before System32 is reached.
String wslExecutable([Map<String, String>? env]) =>
    '${(env ?? Platform.environment)['SystemRoot'] ?? r'C:\Windows'}'
    r'\System32\wsl.exe';

/// The WSL distros installed on this machine, by name, as
/// `wsl.exe --list --quiet` gives them — and none at all anywhere but Windows,
/// where nothing is run. [windows] and [run] are for tests.
///
/// Empty too when there is no WSL to ask, or no distro in it: wsl.exe then
/// prints how to install one and exits with an error, and a card for a shell
/// that would die at once is worse than no card.
Future<List<String>> wslDistros({
  bool? windows,
  Future<ProcessResult> Function(String executable, List<String> arguments)?
  run,
}) async {
  if (!(windows ?? Platform.isWindows)) return const [];
  try {
    final result = await (run ?? _runForBytes)(wslExecutable(), const [
      '--list',
      '--quiet',
    ]);
    if (result.exitCode != 0) return const [];
    return parseWslDistros(result.stdout as List<int>);
  } on ProcessException {
    // No wsl.exe: Windows without the WSL feature at all.
    return const [];
  }
}

Future<ProcessResult> _runForBytes(String executable, List<String> arguments) =>
    Process.run(
      executable,
      arguments,
      stdoutEncoding: null,
      stderrEncoding: null,
    );

/// The distro names in what `wsl.exe --list --quiet` printed.
///
/// wsl.exe writes UTF-16LE, with or without a byte order mark, unless
/// `WSL_UTF8=1` makes it UTF-8: UTF-8 text never holds a NUL, and UTF-16 of a
/// distro name is half NULs, so the NULs tell the two apart.
///
/// Only what can be a distro name is kept — letters, digits, `.`, `-` and
/// `_`, which is all WSL allows in one — so a line of an install message is
/// never taken for a distro. Docker Desktop's and Rancher Desktop's own
/// distros are left out, as Windows Terminal leaves them out: they are the
/// engines behind those apps, with no shell for a person.
List<String> parseWslDistros(List<int> bytes) {
  final text = bytes.contains(0)
      ? String.fromCharCodes([
          for (var i = 0; i + 1 < bytes.length; i += 2)
            bytes[i] | bytes[i + 1] << 8,
        ])
      : utf8.decode(bytes, allowMalformed: true);
  return [
    for (final line in LineSplitter.split(text.replaceAll('\uFEFF', '')))
      if (_distroName.hasMatch(line.trim()) &&
          !line.trim().startsWith('docker-desktop') &&
          !line.trim().startsWith('rancher-desktop'))
        line.trim(),
  ];
}

final _distroName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');

/// `WSLENV` naming [names] too, so Windows hands them into WSL: a WSL shell
/// sees only the Windows variables that list names. What was there already
/// stays, with its flags.
@visibleForTesting
String wslEnv(String? current, Iterable<String> names) {
  final kept = [
    for (final entry in (current ?? '').split(':'))
      if (entry.isNotEmpty) entry,
  ];
  final named = {for (final entry in kept) entry.split('/').first};
  return [
    ...kept,
    for (final name in names)
      if (named.add(name)) name,
  ].join(':');
}

/// A shell on this machine, for the desktop builds — the one thing a phone
/// cannot have: iOS forbids `fork`/`exec` outright, and Android's W^X rules
/// stop an app executing anything from its own data directory.
///
/// On a Mac or Linux it is the user's login shell. On Windows it is
/// PowerShell, or with [wslDistro] a WSL distro's own shell, started in its
/// Linux home.
///
/// It is a [SessionTransport] like the SSH one, so every tab, terminal and
/// keystroke path above it is unchanged. What it does not implement is as
/// important as what it does: no [FileBrowseCapable] or [ForwardCapable], so
/// the files drawer and the tailnet forwarding switch themselves off for it
/// rather than failing at a use. [CommandCapable] it does have, which is what
/// the git tab runs through.
class LocalTransport implements SessionTransport {
  /// [windows] and [environment] stand in for [Platform.isWindows] and
  /// [Platform.environment], for tests.
  LocalTransport({
    this.shell,
    this.wslDistro,
    this.startPty = Pty.start,
    bool? windows,
    Map<String, String>? environment,
  }) : _windows = windows ?? Platform.isWindows,
       _env = environment ?? Platform.environment;

  /// The program a session runs, defaulting to the user's login shell and
  /// falling back to `/bin/bash`, which macOS still ships; PowerShell on
  /// Windows.
  final String? shell;

  /// The WSL distro to open instead, on Windows: see [wslDistros].
  final String? wslDistro;

  final bool _windows;
  final Map<String, String> _env;

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
    final String program;
    final List<String> arguments;
    final String? home;
    Map<String, String>? env = environment.isEmpty ? null : environment;
    final distro = wslDistro;
    if (!_windows) {
      program = this.shell ?? _env['SHELL'] ?? '/bin/bash';
      // A login shell, so it reads the profile that sets PATH — without it a
      // shell started by a windowed app has the bare launchd PATH and cannot
      // find brew, fvm or anything else the user installed.
      arguments = const ['-l'];
      home = _env['HOME'];
    } else {
      // The whole of the app's environment, where flutter_pty would hand on
      // only PATH, HOME and a few more by their Unix names — and a Windows
      // program without SystemRoot cannot so much as open a socket.
      env = {..._env, ...environment};
      home = _env['USERPROFILE'];
      if (distro != null) {
        program = wslExecutable(_env);
        // Each its own argument, never spliced into a command: `--cd ~` so the
        // shell starts in the Linux home rather than in whatever Windows
        // folder the app was started from, seen as /mnt/c/….
        arguments = ['-d', distro, '--cd', '~'];
        // TERM, which flutter_pty sets, reaches a WSL shell only by name in
        // WSLENV; so does anything the app itself sets.
        env['TERM'] = 'xterm-256color';
        env['WSLENV'] = wslEnv(_env['WSLENV'], ['TERM', ...environment.keys]);
      } else {
        program =
            this.shell ??
            '${_env['SystemRoot'] ?? r'C:\Windows'}'
                r'\System32\WindowsPowerShell\v1.0\powershell.exe';
        arguments = const ['-NoLogo'];
      }
    }
    try {
      final pty = startPty(
        program,
        arguments: arguments,
        workingDirectory: home,
        environment: env,
        rows: rows,
        columns: columns,
      );
      return _LocalSession(pty, _commandLine);
    } catch (error) {
      throw SshSessionException('Cannot start $program: $error');
    }
  }

  /// What runs [command] beside the shell — see [_LocalSession.run] — as the
  /// program first and its arguments after; null where no `sh` can be had.
  List<String>? _commandLine(String command) {
    final distro = wslDistro;
    if (!_windows) return ['/bin/sh', '-c', command];
    if (distro == null) return null;
    return [
      wslExecutable(_env),
      '-d',
      distro,
      '--cd',
      '~',
      '--exec',
      'sh',
      '-c',
      command,
    ];
  }
}

class _LocalSession implements TerminalSession, CommandCapable {
  _LocalSession(this._pty, this._commandLine) {
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
  final List<String>? Function(String command) _commandLine;
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
  /// are theirs to use — inside the distro, for a WSL shell. [pty] is
  /// ignored: a local process needs no terminal to be hung up, it is killed
  /// outright when the stream is cancelled.
  ///
  /// PowerShell has no `sh` beside it, so there git and Claude say to open a
  /// WSL shell rather than failing on a program that is not there.
  @override
  Stream<String> run(String command, {bool pty = false}) async* {
    if (_disposed) {
      throw const SshSessionException('This shell has ended.');
    }
    final line = _commandLine(command);
    if (line == null) {
      throw const SshSessionException(
        'This needs a Unix shell. On Windows, open a WSL shell from Home.',
      );
    }
    final process = await Process.start(line.first, line.sublist(1));
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
