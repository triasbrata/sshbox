import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/session/tmux.dart';
import 'package:xterm2/xterm.dart';

/// Runs what a tab runs on its host, here, the way an SSH exec channel runs
/// it: no tty, a bare environment, and a tmux server of its own under [dir]
/// so the machine's own sessions are never touched.
Future<(Process, CommandChannel)> _start(
  String name,
  Directory dir, {
  String path = '/usr/local/bin:/usr/bin:/bin',
}) async {
  final process = await Process.start(
    '/bin/sh',
    ['-c', TmuxSession.command(name)],
    environment: {
      'HOME': Platform.environment['HOME'] ?? dir.path,
      'PATH': path,
      'SHELL': '/bin/sh',
      'TMUX_TMPDIR': dir.path,
    },
    includeParentEnvironment: false,
  );
  // Written to after tmux has gone only by a test that is already failing.
  unawaited(process.stdin.done.catchError((Object _) {}));
  final CommandChannel channel = (
    output: process.stdout.map(Uint8List.fromList),
    write: process.stdin.add,
    close: process.kill,
  );
  return (process, channel);
}

/// Runs tmux against the test's own server, and only that one. Never with
/// the parent's environment: inside tmux, `$TMUX` would point this at the
/// server the tests are running in.
Future<ProcessResult> _tmux(Directory dir, List<String> args) => Process.run(
  'tmux',
  args,
  environment: {
    'PATH': '/usr/local/bin:/usr/bin:/bin',
    'TMUX_TMPDIR': dir.path,
  },
  includeParentEnvironment: false,
);

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

TmuxSession _session(String name, CommandChannel channel) => TmuxSession(
  name: name,
  channel: channel,
  newTerminal: Terminal.new,
  transform: (data) => data,
  onChanged: () {},
  onEnded: () {},
  size: (60, 20),
);

String _text(TmuxPane pane) => pane.terminal.buffer.getText();

void main() {
  final hasTmux =
      Process.runSync('sh', ['-c', 'command -v tmux']).exitCode == 0;
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('sshbox-tmux'));
  tearDown(() async {
    if (hasTmux) await _tmux(dir, ['kill-server']);
    await dir.delete(recursive: true);
  });

  test(
    'splits, types, reattaches to the same panes, and ends with the tab',
    () async {
      const name = 'sshbox-live';
      var (process, channel) = await _start(name, dir);
      var tmux = _session(name, channel);
      expect(await tmux.attached, isTrue);
      await _until(() => tmux.panes.length == 1);
      final first = tmux.panes.single;
      expect((first.terminal.viewWidth, first.terminal.viewHeight), (60, 20));

      tmux.send('echo sshbox-was-here\r');
      await _until(
        () => 'sshbox-was-here'.allMatches(_text(first)).length >= 2,
      );

      await tmux.split(sideBySide: true);
      await _until(() => tmux.panes.length == 2);
      expect(tmux.layout!.sideBySide, isTrue);
      final [left, right] = tmux.panes;
      expect(left.cells.width + 1 + right.cells.width, 60);
      // tmux focuses the pane it made.
      await _until(() => tmux.focused == right);

      tmux.focus(left);
      final foreground = await tmux.foreground();
      expect(foreground?.command, isNotEmpty);
      expect(Directory(foreground!.path).existsSync(), isTrue);

      // A dropped connection: the channel goes, the session stays.
      tmux.dispose();
      await process.exitCode;
      (process, channel) = await _start(name, dir);
      tmux = _session(name, channel);
      expect(await tmux.attached, isTrue);
      await _until(
        () =>
            tmux.panes.length == 2 &&
            _text(tmux.panes.first).contains('sshbox-was-here'),
      );

      // Closing the tab.
      await tmux.kill();
      await process.exitCode.timeout(const Duration(seconds: 5));
      tmux.dispose();
      final gone = await _tmux(dir, ['has-session', '-t', name]);
      expect(gone.exitCode, isNot(0));
    },
    skip: hasTmux ? false : 'tmux is not installed here',
  );

  test('a host without tmux says so rather than hanging', () async {
    // A PATH with a shell on it and nothing else.
    final bin = await Directory('${dir.path}/bin').create();
    await Link('${bin.path}/sh').create('/bin/sh');
    final (process, channel) = await _start('sshbox-none', dir, path: bin.path);
    final tmux = _session('sshbox-none', channel);
    expect(await tmux.attached, isFalse);
    expect(tmux.problem, 'tmux is not installed on this host');
    tmux.dispose();
    await process.exitCode;
  });
}
