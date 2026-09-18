import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/session/tmux.dart';
import 'package:xterm2/xterm.dart';

/// Where tmux may live: Homebrew on Apple silicon puts it in /opt/homebrew/bin,
/// which a bare environment's PATH would otherwise miss.
const _path = '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin';

/// Runs what a tab runs on its host, here, the way an SSH exec channel runs
/// it: no tty, a bare environment, and a tmux server of its own under [dir]
/// so the machine's own sessions are never touched.
///
/// `exec`, so the process is tmux's client itself and closing the channel
/// ends it, as sshd closing a channel does. Killing a shell in front of it
/// instead left the client running, attached, and the server with it.
///
/// [environment] is whatever else the channel brought, as the device's
/// variables come with it.
Future<(Process, CommandChannel)> _start(
  String name,
  Directory dir, {
  String path = _path,
  Map<String, String> environment = const {},
}) async {
  final process = await Process.start(
    '/bin/sh',
    ['-c', 'exec ${TmuxSession.command(name)}'],
    environment: {
      'HOME': Platform.environment['HOME'] ?? dir.path,
      'PATH': path,
      'SHELL': '/bin/sh',
      'TMUX_TMPDIR': dir.path,
      ...environment,
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
    'PATH': _path,
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
  // Where a host's tmux is looked for off PATH, in this machine's own tree.
  final tmuxInPlace = [
    '/opt/homebrew/bin/tmux',
    '/usr/local/bin/tmux',
    '/opt/local/bin/tmux',
    '/home/linuxbrew/.linuxbrew/bin/tmux',
    '/run/current-system/sw/bin/tmux',
    '/snap/bin/tmux',
  ].where((path) => File(path).existsSync()).firstOrNull;
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
      // The pane's shell, sitting at its prompt, somewhere real.
      final foreground = await tmux.foreground();
      expect(foreground?.shellInForeground, isTrue);
      expect(foreground!.program, isNotEmpty);
      expect(Directory(foreground.cwd).existsSync(), isTrue);

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

  test(
    "the device's variables reach new panes, whoever started the server",
    () async {
      // A tmux server already running, started without them.
      await _tmux(dir, [
        'set',
        '-g',
        'default-shell',
        '/bin/sh',
        ';',
        'new-session',
        '-d',
        '-s',
        'elsewhere',
      ]);
      const name = 'sshbox-env';
      Future<(Process, CommandChannel)> start(String key) => _start(
        name,
        dir,
        environment: {'LC_SSHBOX_KEY': key, 'LC_SSHBOX_HOST_ID': 'host-1'},
      );
      // What the focused pane's shell has, and not the line typed to ask.
      Future<void> printed(TmuxSession tmux, String values) async {
        tmux.send(
          r'echo "<$LC_SSHBOX_KEY $LC_SSHBOX_HOST_ID>"'
          '\r',
        );
        await _until(() => _text(tmux.focused!).contains('<$values>'));
      }

      var (process, channel) = await start('key-1');
      var tmux = _session(name, channel);
      expect(await tmux.attached, isTrue);
      await _until(() => tmux.panes.length == 1);
      await printed(tmux, 'key-1 host-1');

      // Back after a reconnect, with a key a reset has replaced since.
      tmux.dispose();
      await process.exitCode;
      (process, channel) = await start('key-2');
      tmux = _session(name, channel);
      expect(await tmux.attached, isTrue);
      await _until(() => tmux.panes.length == 1);
      await tmux.split(sideBySide: true);
      await _until(
        () => tmux.panes.length == 2 && tmux.focused == tmux.panes.last,
      );
      await printed(tmux, 'key-2 host-1');

      // Listed once, however often a tab attaches.
      final listed = await _tmux(dir, ['show', '-gv', 'update-environment']);
      expect('LC_SSHBOX_KEY'.allMatches('${listed.stdout}'), hasLength(1));
      expect(
        'LC_SSHBOX_NOTIFY_SECRET'.allMatches('${listed.stdout}'),
        hasLength(1),
      );

      tmux.dispose();
      await process.exitCode;
    },
    skip: hasTmux ? false : 'tmux is not installed here',
  );

  group(
    'on a host whose exec channel has no tmux on PATH',
    () {
      /// The channel as a Mac gives it: no tmux on PATH, only what the script
      /// needs besides, and a login shell whose profile greets first, then
      /// prints [loginFinds] for `command -v tmux`.
      Future<Map<String, String>> bareHost({String loginFinds = ''}) async {
        final bin = await Directory('${dir.path}/bin').create();
        for (final tool in ['/bin/sh', '/usr/bin/tail', '/usr/bin/grep']) {
          await Link('${bin.path}/${tool.split('/').last}').create(tool);
        }
        return {
          'HOME': dir.path,
          'PATH': bin.path,
          'SHELL': await _script(
            '${dir.path}/login-shell',
            'echo Last login: today\necho $loginFinds',
          ),
        };
      }

      /// A tmux that only notes how it was run, a line per run.
      Future<String> fakeTmux(String path) =>
          _script(path, 'echo "\$*" >> ${dir.path}/calls');

      /// How the fake tmux was run, once the tab has given up on it for not
      /// speaking control mode — and with nothing else on the channel.
      Future<List<String>> ran(Map<String, String> host) async {
        final (process, channel) = await _start(
          'sshbox-found',
          dir,
          environment: host,
        );
        final tmux = _session('sshbox-found', channel);
        expect(await tmux.attached, isFalse);
        expect(tmux.problem, 'tmux did not start on this host.');
        tmux.dispose();
        await process.exitCode;
        return File('${dir.path}/calls').readAsLines();
      }

      final everyRun = [
        'show -gv update-environment',
        allOf(
          startsWith('-u -C set -ga update-environment'),
          endsWith('new-session -A -s sshbox-found'),
        ),
      ];

      test(
        'finds it in ~/.local/bin, and runs every tmux from there',
        () async {
          final host = await bareHost();
          await fakeTmux('${dir.path}/.local/bin/tmux');
          expect(await ran(host), everyRun);
        },
      );

      test(
        "finds it on the login shell's PATH, past what the profile says",
        () async {
          final tmux = await fakeTmux('${dir.path}/brew/bin/tmux');
          expect(await ran(await bareHost(loginFinds: tmux)), everyRun);
        },
      );

      test('says tmux is nowhere rather than hanging', () async {
        // A name, not a path: not taken for tmux.
        final host = await bareHost(loginFinds: 'tmux');
        final (process, channel) = await _start(
          'sshbox-none',
          dir,
          environment: host,
        );
        final tmux = _session('sshbox-none', channel);
        expect(await tmux.attached, isFalse);
        expect(
          tmux.problem,
          'tmux is not installed on this host '
          '(looked on PATH, in Homebrew and the other usual places)',
        );
        tmux.dispose();
        await process.exitCode;
      });
    },
    // A real one there is found before anything these tests put down.
    skip: tmuxInPlace == null ? false : 'tmux is at $tmuxInPlace',
  );
}

/// A shell script at [path], ready to run.
Future<String> _script(String path, String body) async {
  await File(path).create(recursive: true);
  await File(path).writeAsString('#!/bin/sh\n$body\n');
  await Process.run('chmod', ['+x', path]);
  return path;
}
