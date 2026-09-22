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
  id: '$_wslPrefix$distro',
  label: distro,
  host: 'localhost',
  username: _userName(),
);

const _wslPrefix = 'wsl:';

/// The distro a [wslHost] id names, and null for any other host's.
String? wslDistroOf(String hostId) =>
    hostId.startsWith(_wslPrefix) ? hostId.substring(_wslPrefix.length) : null;

/// Whether [hostId] is one of this machine's own shells, [localHost] or a
/// [wslHost], rather than a saved host.
bool isLocalHostId(String hostId) =>
    hostId == localHostId || wslDistroOf(hostId) != null;

/// Opens nothing, and says why: a tab of this machine's own shells brought
/// back where there can be none — a Local shell on a phone, a WSL one off
/// Windows — rather than one that vanishes.
class RefusedTransport implements SessionTransport {
  const RefusedTransport(this.reason);

  final String reason;

  @override
  Future<TerminalSession> connect({
    required HostProfile host,
    required SecretStore secrets,
    required int columns,
    required int rows,
    bool shell = true,
    Map<String, String> environment = const {},
    Future<Map<String, String>> Function(ForwardCapable host)? beforeShell,
  }) async => throw SshSessionException(reason);
}

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
/// the git tab runs through, and [ChannelCapable], which is what tmux's
/// control mode runs through: see [connect]'s `shell`.
class LocalTransport implements SessionTransport {
  /// [windows] and [environment] stand in for [Platform.isWindows] and
  /// [Platform.environment], for tests, and [distros] for [wslDistros].
  LocalTransport({
    this.shell,
    this.wslDistro,
    this.tmux,
    this.startPty = Pty.start,
    bool? windows,
    Map<String, String>? environment,
    Future<List<String>> Function()? distros,
  }) : _windows = windows ?? Platform.isWindows,
       _env = environment ?? Platform.environment,
       _distros = distros ?? wslDistros;

  /// The program a session runs, defaulting to the user's login shell and
  /// falling back to `/bin/bash`, which macOS still ships; PowerShell on
  /// Windows.
  final String? shell;

  /// The WSL distro to open instead, on Windows: see [wslDistros].
  final String? wslDistro;

  /// The tmux binary to run rather than the one `TmuxSession` would find,
  /// handed to every command as `SSHBOX_TMUX`. Null finds it.
  final String? tmux;

  final bool _windows;
  final Map<String, String> _env;
  final Future<List<String>> Function() _distros;

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
    final distro = wslDistro;
    // A tab brought back from an earlier run can name a distro removed since,
    // which wsl.exe would answer with an error in a shell that dies at once.
    if (_windows && distro != null && !(await _distros()).contains(distro)) {
      throw SshSessionException(
        'WSL has no distro called $distro on this machine any more.',
      );
    }
    // No shell: a session for tmux, whose panes come over [_LocalSession.open]
    // and which is up for as long as it is not disposed, as a connection is.
    if (!shell) return _LocalSession(null, _process);
    // This terminal shows an OSC 8 hyperlink and a Ctrl+tap opens it, which
    // Claude Code, and every program built on `supports-hyperlinks`, learns
    // from this: without it they write a link as `LABEL (URL)`. Set here
    // outright, the pty being ours — over SSH it cannot be, sshd refusing a
    // name `AcceptEnv` does not list (see `LiveSession.connect`).
    environment = {'FORCE_HYPERLINK': '1', ...environment};
    final String program;
    final List<String> arguments;
    final String? home;
    Map<String, String>? env = environment.isEmpty ? null : environment;
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
      return _LocalSession(pty, _process);
    } catch (error) {
      throw SshSessionException('Cannot start $program: $error');
    }
  }

  /// Starts [command] beside the shell, as [_commandLine] runs it.
  ///
  /// In the login home, as an SSH exec channel starts: a windowed app's own
  /// folder is `/` on a Mac, and a tmux session made there would open its
  /// panes in it. The app's environment, but for where tmux says it is
  /// running inside one of the user's own sessions, which would point this
  /// tmux at whichever server the app was started from, and plus the tmux
  /// binary Settings gives, for `TmuxSession`'s finder to take first.
  Future<Process> _process(String command) {
    final line = _commandLine(command);
    if (line == null) {
      throw const SshSessionException(
        'This needs a Unix shell. On Windows, open a WSL shell from Home.',
      );
    }
    final tmux = this.tmux;
    return Process.start(
      line.first,
      line.sublist(1),
      workingDirectory: _windows ? null : _env['HOME'],
      environment: {
        for (final MapEntry(:key, :value) in _env.entries)
          if (key != 'TMUX' && key != 'TMUX_PANE') key: value,
        'SSHBOX_TMUX': ?tmux,
      },
      includeParentEnvironment: false,
    );
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

/// A local shell, or with no [_pty] the session a tmux tab holds, which has
/// no terminal of its own: its panes come through [open].
class _LocalSession implements TerminalSession, CommandCapable, ChannelCapable {
  _LocalSession(this._pty, this._process) {
    final pty = _pty;
    if (pty == null) return;
    // Chunked rather than a decode per event: a character the shell writes in
    // two reads arrives split across them, and this holds the first half until
    // the rest comes. Malformed bytes are let through as the replacement
    // character — a terminal shows what it is sent.
    _subscription = pty.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(_output.add);
    unawaited(_watchExit(pty));
  }

  final Pty? _pty;
  final Future<Process> Function(String command) _process;
  final _output = StreamController<String>.broadcast();
  final _status = ValueNotifier(SessionStatus.connected);
  StreamSubscription<String>? _subscription;
  String? _failure;
  bool _disposed = false;

  /// What [open] started and has not seen end, ended with the session as a
  /// connection's channels end with it.
  final _channels = <void Function()>{};

  Future<void> _watchExit(Pty pty) async {
    final code = await pty.exitCode;
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
    _pty?.write(const Utf8Encoder().convert(data));
  }

  @override
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) {
    if (_disposed) return;
    // The pty takes rows first, the terminal gives columns first.
    _pty?.resize(rows, columns);
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
    final process = await _process(command);
    // Read and dropped, as an SSH channel carries stdout alone: a pipe left
    // full would stop the command.
    unawaited(process.stderr.drain<void>());
    try {
      yield* process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter());
    } finally {
      process.kill();
    }
  }

  /// A command beside the shell that is talked to as well as listened to, in
  /// raw bytes both ways and with no pty: what tmux's control mode runs
  /// through, as an SSH exec channel carries it.
  ///
  /// Closing it closes its stdin, which ends a tmux client however many
  /// shells stand in front of it, as sshd closing a channel does, and kills
  /// the process too.
  @override
  Future<CommandChannel> open(String command) async {
    if (_disposed) {
      throw const SshSessionException('This shell has ended.');
    }
    final process = await _process(command);
    // A write after the command has gone fails here rather than anywhere.
    unawaited(process.stdin.done.catchError((Object _) {}));
    unawaited(process.stderr.drain<void>());
    var closed = false;
    void close() {
      if (closed) return;
      closed = true;
      _channels.remove(close);
      process.stdin.close().ignore();
      process.kill();
    }

    _channels.add(close);
    unawaited(process.exitCode.then((_) => _channels.remove(close)));
    return (
      output: process.stdout.map(Uint8List.fromList),
      write: (Uint8List data) {
        if (!closed) process.stdin.add(data);
      },
      close: close,
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription?.cancel();
    try {
      _pty?.kill();
    } catch (_) {
      // Already gone: the shell exited on its own.
    }
    for (final close in _channels.toList()) {
      close();
    }
    await _output.close();
    _status.value = SessionStatus.closed;
    _status.dispose();
  }
}
