import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/pane_record.dart';
import 'package:sshbox/src/session/session_manager.dart';
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
///
/// HOME is [dir] too: the attach prunes pane records under HOME against the
/// panes of the server it asks, which here is the test's own, so under the
/// real HOME it would take the machine's own records for gone.
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
      'HOME': dir.path,
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

/// Waits for [condition], and on giving up says what [state] was then.
Future<void> _until(bool Function() condition, [String Function()? state]) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(state == null ? 'timed out' : 'timed out: ${state()}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

TmuxSession _session(
  String name,
  CommandChannel channel, {
  bool record = false,
}) => TmuxSession(
  name: name,
  channel: channel,
  newTerminal: Terminal.new,
  transform: (data) => data,
  onChanged: () {},
  onEnded: () {},
  size: (60, 20),
  record: record,
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
    // A pane's shell may still be writing as it goes: bash, which is macOS's
    // sh, saves its history into HOME on the hangup, and kill-server has
    // returned by then.
    for (var tries = 0; ; tries++) {
      try {
        await dir.delete(recursive: true);
        return;
      } on FileSystemException {
        if (tries == 20) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  test(
    'splits, types, reattaches to the same panes, and ends with the tab',
    () async {
      const name = 'sshbox-live';
      var (process, channel) = await _start(name, dir);
      var tmux = _session(name, channel);
      expect(await tmux.attached, isTrue);
      await _until(
        () => tmux.panes.length == 1,
        () => '${tmux.panes.length} panes',
      );
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
          r'echo "<$LC_SSHBOX_KEY $LC_SSHBOX_HOST_ID $FORCE_HYPERLINK>"'
          '\r',
        );
        await _until(
          () => _text(tmux.focused!).contains('<$values>'),
          () =>
              'no <$values> on the focused pane, which shows:\n'
              '${_text(tmux.focused!).trimRight()}\n'
              'where tmux has:\n'
              '${Process.runSync('tmux', ['capture-pane', '-p', '-t', '%${tmux.focused!.id}'], environment: {'PATH': _path, 'TMUX_TMPDIR': dir.path}, includeParentEnvironment: false).stdout}'.trimRight(),
        );
      }

      var (process, channel) = await start('key-1');
      var tmux = _session(name, channel);
      expect(await tmux.attached, isTrue);
      await _until(
        () => tmux.panes.length == 1,
        () => '${tmux.panes.length} panes',
      );
      await printed(tmux, 'key-1 host-1 1');

      // Back after a reconnect, with a key a reset has replaced since.
      tmux.dispose();
      await process.exitCode;
      (process, channel) = await start('key-2');
      tmux = _session(name, channel);
      expect(await tmux.attached, isTrue);
      await _until(
        () => tmux.panes.length == 1,
        () => '${tmux.panes.length} panes',
      );
      await tmux.split(sideBySide: true);
      await _until(
        () => tmux.panes.length == 2 && tmux.focused == tmux.panes.last,
      );
      await printed(tmux, 'key-2 host-1 1');

      // Listed once, however often a tab attaches.
      final listed = await _tmux(dir, ['show', '-gv', 'update-environment']);
      expect('LC_SSHBOX_KEY'.allMatches('${listed.stdout}'), hasLength(1));
      expect(
        'LC_SSHBOX_NOTIFY_SECRET'.allMatches('${listed.stdout}'),
        hasLength(1),
      );
      expect('FORCE_HYPERLINK'.allMatches('${listed.stdout}'), hasLength(1));

      tmux.dispose();
      await process.exitCode;
    },
    skip: hasTmux ? false : 'tmux is not installed here',
  );

  test(
    'FORCE_HYPERLINK reaches a server an earlier version listed its names '
    "on, and never the user's own session",
    () async {
      // A server an earlier version attached to, holding its list, and a
      // session of the user's own, which Claude Code would have write links
      // for a terminal this app knows nothing about.
      await _tmux(dir, [
        'set',
        '-g',
        'default-shell',
        '/bin/sh',
        ';',
        'set',
        '-ga',
        'update-environment',
        ' LC_SSHBOX_KEY LC_SSHBOX_HOST_ID LC_SSHBOX_NOTIFY_URL '
            'LC_SSHBOX_NOTIFY_SECRET',
        ';',
        'new-session',
        '-d',
        '-s',
        'mine',
      ]);
      const name = 'sshbox-links';
      final (process, channel) = await _start(name, dir);
      final tmux = _session(name, channel);
      expect(await tmux.attached, isTrue);
      await _until(() => tmux.panes.length == 1);
      tmux.send(r'echo "<$FORCE_HYPERLINK>"' '\r');
      await _until(
        () => _text(tmux.focused!).contains('<1>'),
        () => _text(tmux.focused!).trimRight(),
      );

      // A window the user opens in their own session afterwards.
      final out = File('${dir.path}/mine.env');
      await _tmux(dir, [
        'new-window',
        '-t',
        '=mine',
        'env > ${out.path}',
      ]);
      await _until(out.existsSync);
      await _until(() => out.readAsStringSync().contains('PATH='));
      expect(out.readAsStringSync(), isNot(contains('FORCE_HYPERLINK')));

      final listed = await _tmux(dir, ['show', '-gv', 'update-environment']);
      expect('FORCE_HYPERLINK'.allMatches('${listed.stdout}'), hasLength(1));

      tmux.dispose();
      await process.exitCode;
    },
    skip: hasTmux ? false : 'tmux is not installed here',
  );

  group('pane records', () {
    const name = 'sshbox-rec';
    // The host's home is the test's own, where the records go.
    Future<(Process, CommandChannel)> start() =>
        _start(name, dir, environment: {'HOME': dir.path});
    Directory records() =>
        Directory('${dir.path}/${PaneRecord.dir(name)}');
    // The record as the app shows it.
    String read(String record) {
      final file = File('${records().path}/$record');
      if (!file.existsSync()) return '';
      return renderRecord(
        file.readAsBytesSync(),
        columns: 60,
        rows: 20,
      ).join('\n');
    }

    Future<String> tmuxSays(List<String> args) async =>
        '${(await _tmux(dir, args)).stdout}'.trim();
    String tmuxNow(List<String> args) => '${Process.runSync(
      'tmux',
      args,
      environment: {'PATH': _path, 'TMUX_TMPDIR': dir.path},
      includeParentEnvironment: false,
    ).stdout}'.trim();

    test(
      'keeps what clear wiped, what came with nothing attached, and a pane '
      'split off later, in private files, and only for the app\'s session',
      () async {
        var (process, channel) = await start();
        var tmux = _session(name, channel, record: true);
        expect(await tmux.attached, isTrue);
        // One of the user's own, on the same server.
        await _tmux(dir, ['new-session', '-d', '-s', 'elsewhere']);
        await _until(() => tmux.panes.length == 1);
        final first = (await tmux.recordName(tmux.panes.single))!;
        await _until(() => File('${records().path}/$first').existsSync());

        // 1. Wiped from the pane by clear, and still in the record.
        tmux.send(r'echo wiped-$((6*7)); clear' '\r');
        await _until(
          () => read(first).contains('wiped-42'),
          () => read(first),
        );
        await _until(
          () => !tmuxNow(['capture-pane', '-p', '-t', '$name:'])
              .contains('wiped-42'),
        );
        expect(read(first), contains('wiped-42'));

        // 2. Written while nothing is attached: the phone locked.
        tmux.dispose();
        await process.exitCode;
        expect(await tmuxSays(['list-clients']), isEmpty);
        await _tmux(dir, [
          'send-keys', '-t', '$name:', r'echo away-$((6*7))', 'Enter',
        ]);
        await _until(() => read(first).contains('away-42'), () => read(first));

        // 3. A pane split off later, with nothing attached either.
        await _tmux(dir, ['split-window', '-t', '$name:']);
        final panes = (await tmuxSays([
          'list-panes', '-s', '-t', name, '-F', '#{pid}-#{pane_id}',
        ])).split('\n');
        expect(panes, hasLength(2));
        final split = panes.last;
        await _tmux(dir, [
          'send-keys', '-t', split.split('-').last, r'echo split-$((6*7))',
          'Enter',
        ]);
        await _until(() => read(split).contains('split-42'), () => read(split));

        // Private: the files 0600, the app's directories 0700.
        for (final record in [first, split]) {
          final mode = File('${records().path}/$record').statSync().mode;
          expect(mode & 0x1ff, 0x180, reason: record);
        }
        for (final path in [
          records().path,
          records().parent.path,
          records().parent.parent.path,
        ]) {
          expect(Directory(path).statSync().mode & 0x1ff, 0x1c0, reason: path);
        }

        // Nothing for the user's own session, nor for every session.
        await _tmux(dir, ['split-window', '-t', 'elsewhere:']);
        expect(
          await tmuxSays([
            'list-panes', '-s', '-t', 'elsewhere', '-F', '#{pane_pipe}',
          ]),
          '0\n0',
        );
        for (final hook in PaneRecord.hooks) {
          expect(await tmuxSays(['show-hooks', '-g', hook]), hook);
        }
        expect(records().parent.listSync(), hasLength(1));
      },
      skip: hasTmux ? false : 'tmux is not installed here',
    );

    test(
      'turned off, stops; and an attach prunes what a gone pane left',
      () async {
        var (process, channel) = await start();
        var tmux = _session(name, channel, record: true);
        expect(await tmux.attached, isTrue);
        await _until(() => tmux.panes.length == 1);
        final live = (await tmux.recordName(tmux.panes.single))!;
        await _until(() => File('${records().path}/$live').existsSync());
        tmux.dispose();
        await process.exitCode;

        // A week and more untouched: a pane still there, and one gone, in a
        // session gone too.
        final gone = File('${records().parent.path}/sshbox-old/1-%9');
        await gone.create(recursive: true);
        // Not `touch -d '10 days ago'`: BSD touch takes no such date, fails,
        // and leaves the file new, so nothing is old enough to prune.
        final old = DateTime.now().subtract(const Duration(days: 10));
        for (final path in [gone.path, '${records().path}/$live']) {
          await File(path).setLastModified(old);
        }

        (process, channel) = await start();
        tmux = _session(name, channel);
        expect(await tmux.attached, isTrue);
        await _until(
          () => !gone.parent.existsSync(),
          () => '${gone.parent.listSync()}',
        );
        expect(File('${records().path}/$live').existsSync(), isTrue);

        // Off: the pipes close and the hooks go.
        await _until(
          () =>
              tmuxNow(['list-panes', '-s', '-t', name, '-F', '#{pane_pipe}']) ==
              '0',
        );
        expect(await tmuxSays(['show-hooks', '-t', '=$name:']), isEmpty);
        tmux.dispose();
        await process.exitCode;
      },
      skip: hasTmux ? false : 'tmux is not installed here',
    );
  });

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

  test(
    'a session name from the host reaches tmux whole, as one argument, and '
    'nothing in it runs — through a real shell',
    () async {
      // Everything a name tmux accepts can hold that a shell would read:
      // spaces, both quotes, a command substitution, a backtick, a
      // semicolon, a backslash, and tmux's own `#` and `%`.
      const nasty =
          'it\'s "x" \$(touch pwned-sub) `touch pwned-tick`; '
          'touch pwned-semi \\ #h %p';
      final bin = await Directory('${dir.path}/bin').create();
      // touch too, so a name that ran would leave its mark.
      for (final tool in [
        '/bin/sh',
        '/usr/bin/tail',
        '/usr/bin/grep',
        '/usr/bin/tr',
        '/usr/bin/touch',
      ]) {
        await Link('${bin.path}/${tool.split('/').last}').create(tool);
      }
      // A tmux that writes down each argument it was given, one to a line,
      // then a line of its own after each run, and says yes to anything.
      await _script(
        '${bin.path}/tmux',
        'printf "%s\\n" "\$@" >> ${dir.path}/argv; '
            'echo "<end>" >> ${dir.path}/argv; echo yes',
      );
      Future<List<List<String>>> runs(String command) async {
        final argv = File('${dir.path}/argv');
        if (argv.existsSync()) await argv.delete();
        final result = await Process.run(
          '/bin/sh',
          ['-c', command],
          workingDirectory: dir.path,
          environment: {
            'HOME': dir.path,
            'PATH': bin.path,
            'SHELL': '/bin/sh',
          },
          includeParentEnvironment: false,
        );
        expect(
          dir.listSync().map((entry) => entry.path.split('/').last),
          isNot(anyElement(startsWith('pwned'))),
          reason: 'something in the name ran',
        );
        expect(result.stderr, isEmpty, reason: command);
        final calls = <List<String>>[[]];
        for (final line in await argv.readAsLines()) {
          line == '<end>' ? calls.add([]) : calls.last.add(line);
        }
        return calls..removeLast();
      }

      final attach = await runs(TmuxSession.attachExisting(nasty));
      expect(attach.last.sublist(attach.last.length - 3), [
        'attach-session',
        '-t',
        '=$nasty',
      ]);
      final start = await runs(TmuxSession.command(nasty));
      expect(start.last.sublist(start.last.length - 4), [
        'new-session',
        '-A',
        '-s',
        nasty,
      ]);
      // Nothing of the name before tmux's own arguments: a name left in
      // `$@` would be taken for a tmux command.
      expect(start.last.take(3), ['-u', '-C', 'set']);
      final exists = await runs(TmuxSession.exists(nasty));
      expect(exists.single, ['has-session', '-t', '=$nasty']);
    },
  );

  test(
    'a session gone since it was listed is not swapped for one whose name '
    'starts the same',
    () async {
      const name = 'build';
      await _tmux(dir, ['new-session', '-d', '-s', 'build-2']);
      // Without `=`, tmux takes a name that begins only one session's for
      // that session.
      expect(
        (await _tmux(dir, ['has-session', '-t', name])).exitCode,
        0,
        reason: "tmux's own prefix match, which the exact match is there for",
      );
      final process = await Process.start(
        '/bin/sh',
        ['-c', 'exec ${TmuxSession.attachExisting(name)}'],
        environment: {
          'HOME': dir.path,
          'PATH': _path,
          'SHELL': '/bin/sh',
          'TMUX_TMPDIR': dir.path,
        },
        includeParentEnvironment: false,
      );
      unawaited(process.stdin.done.catchError((Object _) {}));
      final tmux = _session(name, (
        output: process.stdout.map(Uint8List.fromList),
        write: process.stdin.add,
        close: process.kill,
      ));
      // tmux gives no reason: in control mode its refusal is an empty
      // `%error` for a command nobody here wrote.
      expect(await tmux.attached, isFalse);
      tmux.dispose();
      await process.exitCode;
      expect(
        (await _tmux(dir, ['has-session', '-t', '=$name'])).exitCode,
        isNot(0),
        reason: 'attaching never makes a session',
      );
    },
    skip: hasTmux ? false : 'tmux is not installed here',
  );

  group('attach and detach, through a tab', () {
    const host = HostProfile(
      id: 'here',
      label: 'here',
      host: 'here',
      username: 'me',
      useTmux: true,
    );

    bool alive(String name) =>
        Process.runSync(
          'tmux',
          ['has-session', '-t', '=$name'],
          environment: {'PATH': _path, 'TMUX_TMPDIR': dir.path},
          includeParentEnvironment: false,
        ).exitCode ==
        0;

    /// A tab on this machine, added to [manager] as the connect sheet adds
    /// one. With [pick], it is Attach's: once connected it is handed every
    /// session the host lists, into [listed], and joins the one [pick]
    /// names.
    Future<LiveSession> open(
      SessionManager manager,
      _Here here, {
      String? pick,
      List<TmuxSessionInfo>? listed,
    }) async {
      final session = manager.create(
        host,
        transport: (_, _) => here,
        pickTmux: pick != null,
      );
      manager.add(session);
      await session.connect(
        secrets: InMemorySecretStore(),
        pickTmux: (found) async {
          listed?.addAll(found);
          return pick;
        },
      );
      expect(session.error, isNull);
      await _until(() => session.tmux?.panes.isNotEmpty ?? false);
      return session;
    }

    test(
      'Detach leaves the program running and writing and its record going; '
      'Attach lists it, idle, and joins the same pane; the ✕ ends it',
      () async {
        final here = _Here(dir);
        final manager = SessionManager();
        final tab = await open(manager, here);
        final name = tab.tmuxName;
        final tmux = tab.tmux!;
        final record = (await tmux.recordName(tmux.panes.single))!;
        final ticks = File('${dir.path}/ticks');
        int counted() =>
            ticks.existsSync() ? ticks.readAsLinesSync().length : 0;
        // Something long-running: a count, to a file and to the pane.
        tmux.send(
          r'i=0; while :; do i=$((i+1)); echo $i >> "$HOME/ticks"; '
          r'echo tick-$i; sleep 0.1; done'
          '\r',
        );
        await _until(() => counted() >= 3, () => '${counted()} ticks');

        await manager.detach(tab.id);
        expect(manager.sessions, isEmpty);
        // The tab's client is gone from the host, as a detach says...
        await Future.wait([
          for (final process in here.started) process.exitCode,
        ]).timeout(const Duration(seconds: 5));
        expect(
          '${(await _tmux(dir, ['list-clients'])).stdout}'.trim(),
          isEmpty,
        );
        // ...and the session, what runs in it and its record are all still
        // going, with nobody attached, two seconds on: a Detach that killed,
        // hung up on the pane or took its pipe down fails here.
        expect(alive(name), isTrue);
        // Waited for rather than timed: a loaded machine forks slowly, and a
        // tick every 0.1s has come to twelve in two seconds, not twenty.
        final before = counted();
        await Future<void>.delayed(const Duration(seconds: 2));
        expect(alive(name), isTrue);
        final then = counted();
        await _until(
          () => counted() > math.max(then, before + 10),
          () => '${counted()} ticks, ${before + 10} wanted',
        );
        final file = File('${dir.path}/${PaneRecord.dir(name)}/$record');
        await _until(
          () => file.readAsStringSync().contains('tick-${before + 10}'),
          () => file.readAsStringSync(),
        );

        // Another tab on the host, so the listing has one in use to show.
        final other = await open(manager, here);

        // Attach: the host lists it — nobody attached, one window — and the
        // tab joins the same pane, still counting.
        final listed = <TmuxSessionInfo>[];
        final back = await open(manager, here, pick: name, listed: listed);
        expect(back.tmuxName, name);
        expect(
          listed.map((session) => session.name),
          unorderedEquals([name, other.tmuxName]),
        );
        final away = listed.firstWhere((session) => session.name == name);
        expect((away.windows, away.attached, away.inUse), (1, 0, false));
        expect(
          listed.firstWhere((s) => s.name == other.tmuxName).inUse,
          isTrue,
        );
        final pane = back.tmux!.panes.single;
        expect('${pane.id}', record.split('%').last);
        final seen = counted();
        await _until(
          () => _text(pane).contains('tick-${seen + 3}'),
          () => _text(pane),
        );

        // The ✕ on a session the app made: it and what runs in it end.
        await manager.close(back.id);
        await _until(() => !alive(name));
        final last = counted();
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(counted(), lessThanOrEqualTo(last + 1));
        await manager.close(other.id);
        await _until(() => !alive(other.tmuxName));
      },
      skip: hasTmux ? false : 'tmux is not installed here',
    );

    test(
      'a session the user made is listed and joined by its exact name, and '
      'left as it was: no record, no hook taken down, and the ✕ leaves it '
      'running',
      () async {
        // Not ASCII either: a listing without -u, on a channel with no
        // UTF-8 locale, writes each of those characters down to `_`.
        const nasty = 'it\'s "x" \$(touch pwned) `id`; y \\ ##h %p café 🚀';
        await _tmux(dir, ['new-session', '-d', '-s', nasty]);
        // tmux keeps the name as it was made — `#` read as its own format
        // there, so `##` is kept as one, and a backslash written out as two
        // — and what the listing gives is what attaching asks for, a `#` in
        // it taken as itself.
        final listing = await _tmux(dir, [
          '-u',
          'list-sessions',
          '-F',
          '#{session_name}',
        ]);
        final stored = '${listing.stdout}'.trim();
        expect(stored, 'it\'s "x" \$(touch pwned) `id`; y \\\\ #h %p café 🚀');
        await _tmux(dir, [
          'send-keys', '-t', '=$stored:', 'echo nasty-was-here', 'Enter',
        ]);
        // And one with an ordinary name, carrying a hook of the user's own:
        // a name a record's pipe and a tmux target would both take, were
        // anything of the app's to go near it.
        const plain = 'my build';
        await _tmux(dir, [
          'new-session', '-d', '-s', plain, ';',
          'set-hook', '-t', '=$plain:', 'after-split-window', 'display ok',
        ]);

        final manager = SessionManager();
        final here = _Here(dir);
        // The app's own listing, through the same shell, reads it whole.
        final listed = <TmuxSessionInfo>[];
        final back = await open(manager, here, pick: stored, listed: listed);
        expect(listed.map((session) => session.name), contains(stored));
        expect(back.ownTmux, isFalse);
        await _until(
          () => _text(back.tmux!.panes.single).contains('nasty-was-here'),
          () => _text(back.tmux!.panes.single),
        );
        expect(File('${dir.path}/pwned').existsSync(), isFalse);
        await manager.detach(back.id);
        expect(alive(stored), isTrue);

        final mine = await open(manager, here, pick: plain);
        expect(mine.tmux!.record, isNull);
        // Whatever an attach sets going has gone to tmux by the time a
        // question asked after it is answered.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await mine.tmux!.foreground();
        final pipes = await _tmux(dir, [
          'list-panes', '-s', '-t', '=$plain', '-F', '#{pane_pipe}',
        ]);
        expect('${pipes.stdout}'.trim(), '0');
        final hooks = await _tmux(dir, ['show-hooks', '-t', '=$plain:']);
        expect('${hooks.stdout}', contains('display-message ok'));
        expect(
          Directory('${dir.path}/.local/state/jeansh').existsSync(),
          isFalse,
        );
        // The ✕, not Detach: a session the app did not make is not its to
        // end.
        await manager.close(mine.id);
        await Future.wait([
          for (final process in here.started) process.exitCode,
        ]).timeout(const Duration(seconds: 5));
        expect(alive(plain), isTrue);
        expect(alive(stored), isTrue);
      },
      skip: hasTmux ? false : 'tmux is not installed here',
    );

    test(
      'Attach on a host with no tmux sessions says so, and joins nothing',
      () async {
        final session = SessionManager().create(
          host,
          transport: (_, _) => _Here(dir),
          pickTmux: true,
        );
        var asked = false;
        await session.connect(
          secrets: InMemorySecretStore(),
          pickTmux: (_) async {
            asked = true;
            return null;
          },
        );
        expect(asked, isFalse);
        expect(session.isConnected, isFalse);
        expect(session.error, 'No tmux sessions are running on here.');
        expect(
          (await _tmux(dir, ['list-sessions'])).exitCode,
          isNot(0),
          reason: 'asking made a session',
        );
        session.dispose();
      },
      skip: hasTmux ? false : 'tmux is not installed here',
    );
  });
}

/// This machine as a host whose exec channels run what the app sends them
/// through a real `sh`, against the test's own tmux server and under its own
/// HOME, as [_start] does: the SSH transport with the SSH taken out, so a
/// [SessionManager] tab runs the real script and the real tmux.
class _Here
    implements
        SessionTransport,
        TerminalSession,
        CommandCapable,
        ChannelCapable {
  _Here(this.dir);

  final Directory dir;

  /// Every channel opened, each a tmux client.
  final started = <Process>[];

  Map<String, String> get _environment => {
    'HOME': dir.path,
    'PATH': _path,
    'SHELL': '/bin/sh',
    'TMUX_TMPDIR': dir.path,
  };

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

  /// tmux's questions, run for real. The rest a connect asks — the hostname,
  /// the OS — has no bearing here, and goes unanswered.
  @override
  Stream<String> run(String command, {bool pty = false}) async* {
    if (!command.contains('command -v tmux')) return;
    final result = await Process.run(
      '/bin/sh',
      ['-c', command],
      environment: _environment,
      includeParentEnvironment: false,
    );
    yield* Stream.fromIterable(
      const LineSplitter().convert('${result.stdout}'),
    );
  }

  @override
  Future<CommandChannel> open(String command) async {
    final process = await Process.start(
      '/bin/sh',
      ['-c', 'exec $command'],
      environment: _environment,
      includeParentEnvironment: false,
    );
    started.add(process);
    unawaited(process.stdin.done.catchError((Object _) {}));
    return (
      output: process.stdout.map(Uint8List.fromList),
      write: process.stdin.add,
      close: process.kill,
    );
  }

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

/// A shell script at [path], ready to run.
Future<String> _script(String path, String body) async {
  await File(path).create(recursive: true);
  await File(path).writeAsString('#!/bin/sh\n$body\n');
  await Process.run('chmod', ['+x', path]);
  return path;
}
