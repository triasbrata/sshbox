import 'dart:async';
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
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/settings_page.dart';

import 'tui_finders.dart';

/// A host whose address refuses at once, with the jeansh command switched on.
const _host = HostProfile(
  id: 'h1',
  label: 'WSL via tailnet',
  host: '127.0.0.1',
  port: 1,
  username: 'e2e',
  installOpenCommand: true,
);

/// A host that is up the moment it is asked for, answers the install of the
/// jeansh command with [answer] and lets a test write to its terminal.
class _Box
    implements
        SessionTransport,
        TerminalSession,
        CommandCapable,
        ChannelCapable {
  _Box(this.answer);

  final String answer;
  final out = StreamController<String>.broadcast();
  final secrets = <String>[];

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
  Stream<String> run(String command, {bool pty = false}) =>
      const Stream.empty();

  @override
  Future<CommandChannel> open(String command) async {
    final reply = StreamController<Uint8List>();
    return (
      output: reply.stream,
      write: (data) {
        secrets.add(utf8.decode(data).trim());
        reply.add(Uint8List.fromList(utf8.encode('$answer\n')));
        reply.close();
      },
      close: () {},
    );
  }

  @override
  final status = ValueNotifier(SessionStatus.connected);

  @override
  Stream<String> get output => out.stream;

  @override
  String? get failure => null;

  @override
  void send(String data) {}

  @override
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) {}

  @override
  Future<void> dispose() async {}
}

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
    (call) async => null,
  );
  messenger.setMockStreamHandler(
    const EventChannel('com.llfbandit.app_links/events'),
    MockStreamHandler.inline(onListen: (_, _) {}),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _start(
  WidgetTester tester, {
  _Box? over,
  bool settle = true,
}) async {
  await tester.pumpWidget(
    SshboxApp(
      key: UniqueKey(),
      transport: over == null ? null : (_, _) => over,
    ),
  );
  if (settle) await _settle(tester);
}

/// Pumps a frame at a time until [finder] finds one, up to five seconds: a
/// toast stays up for a second, so it is caught as it is shown.
Future<void> _until(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsOneWidget);
}

void main() {
  _more();
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'sshbox.hosts.v1': jsonEncode([_host.toJson()]),
      'sshbox.telemetry.notice': true,
      'sshbox.tabs.v1': jsonEncode({
        'sessions': [
          {'hostId': 'h1', 'tmux': 'sshbox-abc', 'files': [], 'web': []},
        ],
        'databases': [],
      }),
    }),
  );

  testWidgets('a host that leaves jeansh alone is said on screen, and a file '
      'the app cannot take is said with its reason', (tester) async {
    _quietPlatform(tester);
    final box = _Box('left alone');
    await _start(tester, over: box);
    await tester.tap(find.byTooltip('Home'));
    await tester.pump();
    await tester.tap(find.text('e2e@127.0.0.1:1'));
    // The install's answer, as a toast, and the secret that went on stdin.
    await _until(tester, find.textContaining('was left alone'));
    expect(box.secrets.single, hasLength(greaterThan(20)));

    // A right request whose path is not UTF-8.
    box.out.add(
      '\x1b]7733;open;${box.secrets.single};'
      '${DateTime.now().millisecondsSinceEpoch ~/ 1000};'
      '${(0x51000000).toRadixString(16)};${base64.encode([0x2f, 0xff])}\x07',
    );
    await _until(tester, find.textContaining('1 jeansh file was not opened'));
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('several dropped at once are counted in one word', (
    tester,
  ) async {
    _quietPlatform(tester);
    final box = _Box('installed');
    await _start(tester, over: box);
    await tester.tap(find.byTooltip('Home'));
    await tester.pump();
    await tester.tap(find.text('e2e@127.0.0.1:1'));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 300));
    // Nothing is said of a clean install.
    expect(find.textContaining('jeansh'), findsNothing);
    String osc(int n) =>
        '\x1b]7733;open;${box.secrets.single};'
        '${DateTime.now().millisecondsSinceEpoch ~/ 1000};'
        '${(0x52000000 + n).toRadixString(16)};${base64.encode([0x2f, 0xff])}'
        '\x07';
    box.out.add(osc(0));
    await tester.pump(const Duration(milliseconds: 100));
    box.out.add(osc(1));
    box.out.add(osc(2));
    // The request clock is the wall clock, which a fake one does not move.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2100)),
    );
    box.out.add(osc(3));
    await _until(tester, find.textContaining('3 jeansh files were not opened'));
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('the jeansh command that could not be put back at start is '
      'said once the app is on screen', (tester) async {
    _quietPlatform(tester);
    localOpenCommand.startupProblem = 'Could not write ~/.local/bin/jeansh: x.';
    addTearDown(() => localOpenCommand.startupProblem = null);
    await _start(tester, settle: false);
    await _until(
      tester,
      find.textContaining('Could not write ~/.local/bin/jeansh'),
    );
    await tester.pump(const Duration(seconds: 10));
  });

  group('the Settings switch', () {
    late Directory home;
    setUp(() {
      home = Directory.systemTemp.createTempSync('jeansh-switch');
      localOpenCommand.home = home.path;
    });
    tearDown(() {
      localOpenCommand.home = null;
      localOpenCommand.value = installOpenCommandDefault;
      home.deleteSync(recursive: true);
    });

    testWidgets('says why when something else is at ~/.local/bin/jeansh, and '
        'says nothing when it goes in', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 3000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Directory('${home.path}/.local/bin').createSync(recursive: true);
      File('${home.path}/.local/bin/jeansh').writeAsStringSync('mine');
      await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
      await tester.pump(const Duration(milliseconds: 300));

      final toggle = findTuiSwitch('Add the jeansh command to this computer');
      await tester.ensureVisible(toggle);
      await tester.tap(
        findTuiSwitchTrack('Add the jeansh command to this computer'),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining("is not the app's own"), findsOneWidget);
      expect(File('${home.path}/.local/bin/jeansh').readAsStringSync(), 'mine');
      await tester.pump(const Duration(seconds: 10));

      // Off, then on over a path that is free.
      File('${home.path}/.local/bin/jeansh').deleteSync();
      await tester.tap(
        findTuiSwitchTrack('Add the jeansh command to this computer'),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(
        findTuiSwitchTrack('Add the jeansh command to this computer'),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining("is not the app's own"), findsNothing);
      expect(File('${home.path}/.local/bin/jeansh').existsSync(), isTrue);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  });
}

void _more() {
  test('a local shell has its secret written only on a Mac or Linux desktop '
      'with a home', () {
    final home = Directory.systemTemp.createTempSync('jeansh-writer');
    addTearDown(() => home.deleteSync(recursive: true));
    expect(
      localOpenSecretWriter(home: home.path, desktop: false, windows: false),
      isNull,
    );
    expect(
      localOpenSecretWriter(home: home.path, desktop: true, windows: true),
      isNull,
    );
    expect(
      localOpenSecretWriter(home: '', desktop: true, windows: false),
      isNull,
    );
    final write = localOpenSecretWriter(
      home: home.path,
      desktop: true,
      windows: false,
    );
    write!('a-secret');
    expect(
      File('${home.path}/.config/jeansh/open-secret').readAsStringSync(),
      'a-secret\n',
    );
  });

  test('the switch left on says at start why the command could not be put '
      'back, and nothing when it can', () async {
    final home = Directory.systemTemp.createTempSync('jeansh-load');
    addTearDown(() {
      localOpenCommand.home = null;
      localOpenCommand.startupProblem = null;
      localOpenCommand.value = installOpenCommandDefault;
      home.deleteSync(recursive: true);
    });
    localOpenCommand.home = home.path;
    SharedPreferences.setMockInitialValues({
      'sshbox.terminal.localOpenCommand': true,
    });
    Directory('${home.path}/.local/bin').createSync(recursive: true);
    File('${home.path}/.local/bin/jeansh').writeAsStringSync('mine');
    await localOpenCommand.load();
    expect(localOpenCommand.startupProblem, contains("not the app's own"));
    File('${home.path}/.local/bin/jeansh').deleteSync();
    await localOpenCommand.load();
    expect(localOpenCommand.startupProblem, isNull);
    SharedPreferences.setMockInitialValues({});
    await localOpenCommand.load();
    expect(localOpenCommand.startupProblem, isNull);
  });
}
