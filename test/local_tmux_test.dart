import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/app.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/local_transport.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/session/tmux.dart';
import 'package:sshbox/src/system_fonts.dart';
import 'package:sshbox/src/ui/hosts_page.dart';
import 'package:sshbox/src/ui/settings_page.dart';
import 'package:sshbox/src/ui/tabs_shell.dart';
import 'package:xterm2/xterm.dart';

/// The Local shell in tmux: found on this machine the way an SSH host's is,
/// or as Settings gives it, and brought back after a restart.

Future<String> _script(String path, String body) async {
  await File(path).create(recursive: true);
  await File(path).writeAsString('#!/bin/sh\n$body\n');
  await Process.run('chmod', ['+x', path]);
  return path;
}

/// This machine as a windowed app sees it, in [dir]: a PATH with only what
/// the attach script needs besides tmux, a login shell that finds nothing,
/// and the variables of a tmux session the app was started from inside,
/// which must never reach the tmux the Local shell runs.
Future<Map<String, String>> _bareMachine(Directory dir) async {
  final bin = await Directory('${dir.path}/bin').create();
  for (final tool in ['/bin/sh', '/usr/bin/tail', '/usr/bin/grep']) {
    await Link('${bin.path}/${tool.split('/').last}').create(tool);
  }
  return {
    'HOME': dir.path,
    'PATH': bin.path,
    'SHELL': await _script('${dir.path}/login-shell', 'echo'),
    'TMUX': '/tmp/tmux-1000/default,4242,0',
    'TMUX_PANE': '%3',
  };
}

/// A tmux that notes how it was run in [calls], and where from in `env`,
/// and speaks no control mode, so a tab gives up on it.
Future<String> _fakeTmux(
  String path,
  Directory dir, {
  String calls = 'calls',
}) => _script(
  path,
  'echo "\$*" >> ${dir.path}/$calls; '
  'echo "cwd=\$PWD tmux=\${TMUX-} pane=\${TMUX_PANE-}" >> ${dir.path}/env',
);

/// Starts a tab's tmux session on this machine as a tmux tab does, and hands
/// back why it did not start, once it has given up.
Future<String?> _attach(LocalTransport transport, String name) async {
  final session = await transport.connect(
    host: localHost(),
    secrets: InMemorySecretStore(),
    columns: 80,
    rows: 24,
    shell: false,
  );
  final tmux = TmuxSession(
    name: name,
    channel: await (session as ChannelCapable).open(TmuxSession.command(name)),
    newTerminal: Terminal.new,
    transform: (data) => data,
    onChanged: () {},
    onEnded: () {},
    size: (80, 24),
  );
  expect(await tmux.attached, isFalse);
  tmux.dispose();
  await session.dispose();
  return tmux.problem;
}

final _everyRun = [
  'show -gv update-environment',
  allOf(
    startsWith('-u -C set -ga update-environment'),
    endsWith('new-session -A -s sshbox-found'),
  ),
];

/// A machine that is up the moment it is asked for, and answers whether a
/// tmux session is there with [tmuxThere]. It cannot start tmux, so a tab
/// falls back to a plain shell, but what it was asked to attach is in
/// [attached], by name, and each connect in [connected].
class _Machine
    implements
        SessionTransport,
        TerminalSession,
        CommandCapable,
        ChannelCapable {
  _Machine({this.tmuxThere = true});

  final bool tmuxThere;
  final attached = <String>[];
  final checked = <String>[];

  /// The hosts connected to, by id, and whether with a shell.
  final connected = <(String, bool)>[];

  static final _name = RegExp(r"sh '(sshbox-[0-9a-z]+)'$");

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
    connected.add((host.id, shell));
    return this;
  }

  @override
  Stream<String> run(String command, {bool pty = false}) {
    final name = _name.firstMatch(command)?.group(1);
    if (command.contains('has-session') && name != null) {
      checked.add(name);
      return Stream.value(tmuxThere ? 'yes' : 'no');
    }
    return const Stream.empty();
  }

  @override
  Future<CommandChannel> open(String command) async {
    final name = _name.firstMatch(command)?.group(1);
    if (name != null) attached.add(name);
    throw const SshSessionException('tmux will not start here');
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

/// What the app finds saved: no host of the user's, and a tab for each of
/// [hostIds], each in the tmux session [tmux].
Map<String, Object> _saved(
  List<String> hostIds, {
  String tmux = 'sshbox-abc',
}) => {
  'sshbox.hosts.v1': '[]',
  // Past the first run's word about telemetry, which would lie over Home.
  'sshbox.telemetry.notice': true,
  'sshbox.tabs.v1': jsonEncode({
    'sessions': [
      for (final id in hostIds)
        {'hostId': id, 'tmux': tmux, 'files': [], 'web': []},
    ],
    'databases': [],
  }),
};

/// The platform's half of what the app asks as it starts, answered as a
/// machine with nothing to say.
void _quietPlatform(WidgetTester tester) {
  final messenger = tester.binding.defaultBinaryMessenger;
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  messenger.setMockMethodCallHandler(
    const MethodChannel('dexterous.com/flutter/local_notifications'),
    (call) async => switch (call.method) {
      'initialize' || 'requestNotificationsPermission' => true,
      'getActiveNotifications' => const <Object>[],
      _ => null,
    },
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('sshbox/share'),
    (_) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('com.llfbandit.app_links/messages'),
    (_) async => null,
  );
  messenger.setMockStreamHandler(
    const EventChannel('com.llfbandit.app_links/events'),
    MockStreamHandler.inline(onListen: (_, _) {}),
  );
}

/// The app starting over what was saved, every shell through [over].
Future<void> _start(WidgetTester tester, {_Machine? over}) async {
  await tester.pumpWidget(
    SshboxApp(
      key: UniqueKey(),
      transport: over == null ? null : (_, _) => over,
    ),
  );
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder _onStrip(Finder finder) =>
    find.descendant(of: find.byType(TabStrip), matching: finder);

/// Settings with room for every section, so none is left unbuilt below the
/// fold of a lazy list.
Future<void> _pumpSettings(WidgetTester tester) async {
  tester.view.physicalSize = const Size(900, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // The computer's own fonts are another row's business, asked of a process.
  final fonts = systemFonts;
  systemFonts = () async => null;
  addTearDown(() => systemFonts = fonts);
  await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final hasTmux =
      Process.runSync('sh', ['-c', 'command -v tmux']).exitCode == 0;
  // Where tmux is looked for off PATH, in this machine's own tree: one there
  // is found before anything these tests put down.
  final tmuxInPlace = [
    '/opt/homebrew/bin/tmux',
    '/usr/local/bin/tmux',
    '/opt/local/bin/tmux',
    '/home/linuxbrew/.linuxbrew/bin/tmux',
    '/run/current-system/sw/bin/tmux',
    '/snap/bin/tmux',
  ].where((path) => File(path).existsSync()).firstOrNull;

  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sshbox-local-tmux');
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => dir.delete(recursive: true));

  group('tmux on this machine is found', () {
    test('on PATH, as `which tmux` finds it, and run in the home folder, '
        'never pointed at the tmux the app was started inside', () async {
      final machine = await _bareMachine(dir);
      await _fakeTmux('${dir.path}/bin/tmux', dir);

      final problem = await _attach(
        LocalTransport(windows: false, environment: machine),
        'sshbox-found',
      );

      expect(problem, 'tmux did not start on this host.');
      expect(await File('${dir.path}/calls').readAsLines(), _everyRun);
      expect(
        await File('${dir.path}/env').readAsLines(),
        everyElement('cwd=${dir.path} tmux= pane='),
      );
    });

    test('off PATH, where a package manager puts it, as a windowed app on a '
        "Mac misses Homebrew's", () async {
      final machine = await _bareMachine(dir);
      await _fakeTmux('${dir.path}/.local/bin/tmux', dir);

      await _attach(
        LocalTransport(windows: false, environment: machine),
        'sshbox-found',
      );

      expect(await File('${dir.path}/calls').readAsLines(), _everyRun);
    });

    test('as the tmux binary Settings gives, and no other', () async {
      final machine = await _bareMachine(dir);
      await _fakeTmux('${dir.path}/bin/tmux', dir, calls: 'on-path');
      final given = await _fakeTmux('${dir.path}/opt/tmux-next', dir);

      await _attach(
        LocalTransport(windows: false, environment: machine, tmux: given),
        'sshbox-found',
      );

      expect(await File('${dir.path}/calls').readAsLines(), _everyRun);
      expect(File('${dir.path}/on-path').existsSync(), isFalse);
    });

    test('not at all where the binary Settings gives has gone, which says '
        'so rather than finding another', () async {
      final machine = await _bareMachine(dir);
      await _fakeTmux('${dir.path}/bin/tmux', dir);
      final gone = '${dir.path}/opt/tmux-next';

      final problem = await _attach(
        LocalTransport(windows: false, environment: machine, tmux: gone),
        'sshbox-found',
      );

      expect(problem, 'tmux is not at $gone, the path Settings gives for it');
      expect(File('${dir.path}/calls').existsSync(), isFalse);
    });
  }, skip: tmuxInPlace == null ? false : 'tmux is at $tmuxInPlace');

  group('the Local shell setting', () {
    test('is tmux to begin with, found by itself', () async {
      final setting = LocalTmuxSetting();
      await setting.load();

      expect(setting.value, (on: true, path: ''));
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final shell = localShellFor(localHostId, tmux: setting.value)!;
      expect(shell.host.useTmux, isTrue);
      final transport = shell.transport(null, (_) {}) as LocalTransport;
      expect(transport.tmux, isNull);
    });

    test('hands the tmux binary given to the Local shell, and not to a '
        'distro, which finds its own', () {
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const given = (on: true, path: '/opt/tmux/bin/tmux');

      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final local = localShellFor(localHostId, tmux: given)!;
      expect(
        (local.transport(null, (_) {}) as LocalTransport).tmux,
        given.path,
      );

      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final wsl = localShellFor(wslHost('Ubuntu').id, tmux: given)!;
      expect(wsl.host.useTmux, isTrue);
      final transport = wsl.transport(null, (_) {}) as LocalTransport;
      expect((transport.wslDistro, transport.tmux), ('Ubuntu', null));
    });

    test('is a plain shell turned off, in PowerShell, and where tmux was '
        'not found this run', () {
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(
        localShellFor(localHostId, tmux: (on: false, path: ''))!.host.useTmux,
        isFalse,
      );
      expect(
        localShellFor(
          localHostId,
          tmux: (on: true, path: ''),
          tmuxMissing: true,
        )!.host.useTmux,
        isFalse,
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(
        localShellFor(localHostId, tmux: (on: true, path: ''))!.host.useTmux,
        isFalse,
      );
      // And a saved host is no concern of it.
      expect(localShellFor('box', tmux: (on: true, path: '')), isNull);
    });

    test(
      'takes a tmux binary only as a whole path to something that runs',
      () async {
        final setting = LocalTmuxSetting();
        final notRun = await File('${dir.path}/tmux.txt').create();
        final runs = await _script('${dir.path}/tmux', 'true');
        Future<String?> saved() async => (await SharedPreferences.getInstance())
            .getString('sshbox.local.tmuxPath');

        for (final (path, problem) in [
          ('tmux', 'Give the whole path, from /.'),
          ('bin/tmux', 'Give the whole path, from /.'),
          (dir.path, 'No file is at ${dir.path}.'),
          ('${dir.path}/none', 'No file is at ${dir.path}/none.'),
          (notRun.path, '${notRun.path} is not executable.'),
        ]) {
          expect(await setting.choose(path: path), problem, reason: path);
          expect(setting.value.path, '');
          expect(await saved(), isNull);
        }

        expect(await setting.choose(path: runs), isNull);
        expect(setting.value, (on: true, path: runs));
        expect(await saved(), runs);
        // Empty finds it again.
        expect(await setting.choose(path: ''), isNull);
        expect(await saved(), '');
      },
    );

    testWidgets('is in Settings on a desktop, and a path not taken says why', (
      tester,
    ) async {
      addTearDown(() => localTmux.value = (on: true, path: ''));
      await _pumpSettings(tester);

      expect(find.text('Use tmux in the Local shell'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'tmux binary'),
        'tmux',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text('Give the whole path, from /.'), findsOneWidget);
      expect(localTmux.value.path, '');

      await tester.tap(find.text('Use tmux in the Local shell'));
      await tester.pump();
      expect(localTmux.value.on, isFalse);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('is for the WSL shells on Windows, with no path to give', (
      tester,
    ) async {
      await _pumpSettings(tester);

      expect(find.text('Use tmux in WSL shells'), findsOneWidget);
      expect(find.text('Use tmux in the Local shell'), findsNothing);
      expect(find.widgetWithText(TextField, 'tmux binary'), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('is nowhere on a phone, which has no shell of its own', (
      tester,
    ) async {
      await _pumpSettings(tester);

      expect(find.text('Privacy'), findsOneWidget, reason: 'all built');
      expect(find.text('Local shell'), findsNothing);
      expect(find.textContaining('Use tmux in'), findsNothing);
      expect(find.widgetWithText(TextField, 'tmux binary'), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });

  test('a Local shell in tmux starts an sshbox- session, shows what a command '
      'prints, and Detach leaves it running — with a real tmux', () async {
    // A server of the test's own, and a HOME of its own, since the attach
    // prunes pane records under HOME against the panes of the server asked.
    final env = {
      'HOME': dir.path,
      'PATH': '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin',
      'SHELL': '/bin/sh',
      'TMUX_TMPDIR': dir.path,
    };
    Future<ProcessResult> tmux(List<String> args) => Process.run(
      'tmux',
      args,
      environment: env,
      includeParentEnvironment: false,
    );
    addTearDown(() => tmux(['kill-server']));
    final session = LiveSession(
      host: localHost().copyWith(useTmux: true, recordPanes: false),
      transport: (_, _) => LocalTransport(windows: false, environment: env),
    );
    addTearDown(session.dispose);

    await session.connect(secrets: InMemorySecretStore());
    expect(session.error, isNull);
    final attached = session.tmux!;
    expect(session.tmuxName, matches(LiveSession.tmuxNamePattern));
    expect(
      (await tmux(['has-session', '-t', '=${session.tmuxName}'])).exitCode,
      0,
    );

    Future<void> until(bool Function() done) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!done()) {
        if (DateTime.now().isAfter(deadline)) fail('timed out');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    await until(() => attached.panes.length == 1);
    session.sendRaw('echo sshbox-\$((6 * 7))\r');
    final pane = attached.panes.single;
    await until(() => pane.terminal.buffer.getText().contains('sshbox-42'));

    await session.detach();
    expect(session.tmux, isNull);
    final left = await tmux([
      'list-sessions',
      '-F',
      '#{session_name} #{session_attached}',
    ]);
    expect(left.stdout, '${session.tmuxName} 0\n');
  }, skip: hasTmux ? false : 'tmux is not installed here');

  testWidgets('a Local shell asks for tmux, and where it gets none says so '
      'once, each shell after it opening plain straight away', (tester) async {
    SharedPreferences.setMockInitialValues(_saved([]));
    _quietPlatform(tester);
    final machine = _Machine();
    await _start(tester, over: machine);
    final card = find.descendant(
      of: find.byType(HostsPage),
      matching: find.text('Local shell'),
    );

    await tester.tap(card);
    await _settle(tester);
    // tmux first, then the plain shell it falls back to.
    expect(machine.connected, [(localHostId, false), (localHostId, true)]);
    expect(machine.attached, hasLength(1));
    expect(
      find.text('Not using tmux: tmux will not start here'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 10));

    await tester.tap(find.byTooltip('Home'));
    await tester.pump();
    await tester.tap(card);
    await _settle(tester);
    expect(machine.connected.skip(2), [(localHostId, true)]);
    expect(machine.attached, hasLength(1));
    expect(find.textContaining('Not using tmux'), findsNothing);
    expect(_onStrip(find.text('Local shell')), findsNWidgets(2));
    await tester.pump(const Duration(seconds: 10));

    // Turned off and on again, as after installing tmux: asked once more.
    addTearDown(() => localTmux.value = (on: true, path: ''));
    localTmux.value = (on: false, path: '');
    localTmux.value = (on: true, path: '');
    await tester.tap(find.byTooltip('Home'));
    await tester.pump();
    await tester.tap(card);
    await _settle(tester);
    expect(machine.attached, hasLength(2));
    await tester.pump(const Duration(seconds: 10));
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  test(
    'a Local shell carrying a channel for tmux offers no chat yet',
    () async {
      Future<bool> canChat(HostProfile host) async {
        final session = LiveSession(
          host: host,
          transport: (_, _) => _Machine(),
        );
        await session.connect(secrets: InMemorySecretStore());
        return session.canChat;
      }

      expect(await canChat(localHost()), isFalse);
      expect(await canChat(wslHost('Ubuntu')), isFalse);
      expect(
        await canChat(
          const HostProfile(
            id: 'box',
            label: 'box',
            host: 'box',
            username: 'me',
          ),
        ),
        isTrue,
      );
    },
  );

  group('a tab of this machine saved when the app went', () {
    testWidgets('comes back, the Local shell and a WSL distro alike', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(
        _saved([localHostId, wslHost('Ubuntu').id]),
      );
      _quietPlatform(tester);
      await _start(tester, over: _Machine());

      expect(_onStrip(find.text('Local shell')), findsOneWidget);
      expect(_onStrip(find.text('Ubuntu')), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('reattaches to its own tmux session when it shows', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(_saved([localHostId]));
      _quietPlatform(tester);
      final machine = _Machine();
      await _start(tester, over: machine);

      await tester.tap(_onStrip(find.text('Local shell')));
      await _settle(tester);

      expect(machine.checked, ['sshbox-abc']);
      expect(machine.attached, ['sshbox-abc']);
      await tester.pump(const Duration(seconds: 10));
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets("is what the Local card's tap connects, before it opens "
        'another', (tester) async {
      SharedPreferences.setMockInitialValues(_saved([localHostId]));
      _quietPlatform(tester);
      final machine = _Machine();
      await _start(tester, over: machine);

      await tester.tap(find.byTooltip('Home'));
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.byType(HostsPage),
          matching: find.text('Local shell'),
        ),
      );
      await _settle(tester);

      expect(_onStrip(find.text('Local shell')), findsOneWidget);
      expect(machine.attached, ['sshbox-abc']);
      await tester.pump(const Duration(seconds: 10));
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('offers a new session when its own has gone', (tester) async {
      SharedPreferences.setMockInitialValues(_saved([localHostId]));
      _quietPlatform(tester);
      final machine = _Machine(tmuxThere: false);
      await _start(tester, over: machine);

      await tester.tap(_onStrip(find.text('Local shell')));
      await _settle(tester);

      expect(machine.attached, isEmpty);
      expect(find.textContaining('sshbox-abc is no longer on'), findsWidgets);
      expect(find.text('Start a new session'), findsWidgets);
      await tester.pump(const Duration(seconds: 10));
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('comes back plain with tmux turned off', (tester) async {
      localTmux.value = (on: false, path: '');
      addTearDown(() => localTmux.value = (on: true, path: ''));
      SharedPreferences.setMockInitialValues(_saved([localHostId]));
      _quietPlatform(tester);
      final machine = _Machine();
      await _start(tester, over: machine);

      await tester.tap(_onStrip(find.text('Local shell')));
      await _settle(tester);

      expect(machine.connected, [(localHostId, true)]);
      expect(machine.checked, isEmpty);
      await tester.pump(const Duration(seconds: 10));
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('says why on a phone, where it cannot open', (tester) async {
      SharedPreferences.setMockInitialValues(_saved([localHostId]));
      _quietPlatform(tester);
      await _start(tester);

      await tester.tap(_onStrip(find.text('Local shell')));
      await _settle(tester);

      expect(
        find.text('A shell on this machine needs a desktop build of Jeansh.'),
        findsWidgets,
      );
      await tester.pump(const Duration(seconds: 10));
    });
  });
}
