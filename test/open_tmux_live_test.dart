import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/session/clipboard_terminal.dart';
import 'package:sshbox/src/session/open_command.dart';
import 'package:sshbox/src/session/open_request.dart';
import 'package:sshbox/src/session/tmux.dart';

const _path = '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin';

/// `jeansh <file>` typed in a pane of a real tmux, on a server of the test's
/// own, reaches the app through control mode as OSC 52 does.
void main() {
  final hasTmux =
      Process.runSync('sh', ['-c', 'command -v tmux']).exitCode == 0;
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('jeansh-tmux'));
  tearDown(() async {
    if (hasTmux) {
      await Process.run(
        'tmux',
        ['kill-server'],
        environment: {'PATH': _path, 'TMUX_TMPDIR': dir.path},
        includeParentEnvironment: false,
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // A pane's shell still writing as it goes.
    }
  });

  test(
    'the sequence a pane writes arrives, and only with the secret',
    () async {
      installOpenCommand('${dir.path}/bin');
      File('${dir.path}/note.md').writeAsStringSync('hi');
      File('${dir.path}/forged')
          .writeAsStringSync('\x1b]7733;open;wrong;1;abcdef012;${'L2V0Yy9wYXNzd2Q='}\x07');
      final opened = <String>[];
      final requests = OpenRequests(onOpen: opened.add, secret: 'the-secret');

      final process = await Process.start(
        '/bin/sh',
        ['-c', 'exec ${TmuxSession.command('sshbox-jeansh-open')}'],
        environment: {
          'HOME': dir.path,
          'PATH': _path,
          'SHELL': '/bin/sh',
          'TMUX_TMPDIR': dir.path,
          openSecretVariable: 'the-secret',
        },
        includeParentEnvironment: false,
      );
      unawaited(process.stdin.done.catchError((Object _) {}));
      final tmux = TmuxSession(
        name: 'sshbox-jeansh-open',
        channel: (
          output: process.stdout.map(Uint8List.fromList),
          write: process.stdin.add,
          close: process.kill,
        ),
        newTerminal: () => ClipboardTerminal(
          onPrivateOSC: (code, args) => requests.handle(code, args),
        ),
        transform: (data) => data,
        onChanged: () {},
        onEnded: () {},
        size: (80, 20),
        record: false,
      );
      addTearDown(() async {
        await tmux.kill();
        tmux.dispose();
      });
      expect(await tmux.attached, isTrue);
      for (var i = 0; i < 250 && tmux.panes.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      // A file with a forged sequence, shown with cat: nothing.
      tmux.send("cat '${dir.path}/forged'\r");
      // The command itself, from the pane's own directory.
      tmux.send("cd '${dir.path}' && sh bin/jeansh note.md\r");
      for (var i = 0; i < 250 && opened.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(opened, ['${dir.resolveSymbolicLinksSync()}/note.md']);
    },
    skip: hasTmux ? false : 'tmux is not installed here',
  );

  test("on a tmux server that was already running, only the app's own session "
      'gets the secret', () async {
    final bin = '${dir.path}/bin';
    installOpenCommand(bin);
    File('${dir.path}/note.md').writeAsStringSync('hi');
    final env = {
      'HOME': dir.path,
      'PATH': _path,
      'SHELL': '/bin/sh',
      'TMUX_TMPDIR': dir.path,
    };
    // The user's own session, on a server running before Jeansh comes.
    await Process.run(
      'tmux',
      ['new-session', '-d', '-s', 'mine', '-x', '80', '-y', '20', 'sh'],
      environment: env,
      includeParentEnvironment: false,
    );
    final opened = <String>[];
    final requests = OpenRequests(onOpen: opened.add, secret: 'the-secret');
    final process = await Process.start(
      '/bin/sh',
      ['-c', 'exec ${TmuxSession.command('sshbox-jeansh-late')}'],
      environment: {...env, openSecretVariable: 'the-secret'},
      includeParentEnvironment: false,
    );
    unawaited(process.stdin.done.catchError((Object _) {}));
    final tmux = TmuxSession(
      name: 'sshbox-jeansh-late',
      channel: (
        output: process.stdout.map(Uint8List.fromList),
        write: process.stdin.add,
        close: process.kill,
      ),
      newTerminal: () => ClipboardTerminal(
        onPrivateOSC: (code, args) => requests.handle(code, args),
      ),
      transform: (data) => data,
      onChanged: () {},
      onEnded: () {},
      size: (80, 20),
      record: false,
    );
    addTearDown(() async {
      await tmux.kill();
      tmux.dispose();
    });
    expect(await tmux.attached, isTrue);
    for (var i = 0; i < 250 && tmux.panes.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    tmux.send("cd '${dir.path}' && sh bin/jeansh note.md\r");
    for (var i = 0; i < 250 && opened.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(opened, ['${dir.resolveSymbolicLinksSync()}/note.md']);

    // The user's own session never had it.
    final shown = await Process.run(
      'tmux',
      ['show-environment', '-t', 'mine'],
      environment: env,
      includeParentEnvironment: false,
    );
    expect((shown.stdout as String).contains('the-secret'), isFalse);
  }, skip: hasTmux ? false : 'tmux is not installed here');
}
