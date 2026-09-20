import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/notifications/notification_gateway.dart';
import 'package:sshbox/src/session/local_transport.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/hosts_page.dart';
import 'package:sshbox/src/ui/key_bar.dart';
import 'package:sshbox/src/ui/magic_key.dart';
import 'package:sshbox/src/ui/mermaid_view.dart';
import 'package:sshbox/src/ui/terminal_page.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'fake_web_view.dart';

import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// A shell that is up the moment it is asked for, and carries nothing else:
/// no files, no commands, no forwards — which is exactly what the local
/// transport offers.
class _Shell implements SessionTransport, TerminalSession {
  @override
  final status = ValueNotifier(SessionStatus.connected);

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
  Stream<String> get output => const Stream.empty();

  @override
  Future<void> dispose() async {}

  /// send, resize and failure: nothing to do, nothing to say.
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _NoSecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String? value) async {}

  @override
  Future<void> purgeHost(String hostId) async {}
}

/// Opens everything, and remembers what it was handed.
class _Launcher extends UrlLauncherPlatform {
  final opened = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    opened.add(url);
    return true;
  }
}

/// Every desktop build: what holds for the Mac holds for Linux and Windows.
final _desktop = TargetPlatformVariant({
  TargetPlatform.macOS,
  TargetPlatform.linux,
  TargetPlatform.windows,
});
final _phone = TargetPlatformVariant.only(TargetPlatform.android);

/// The desktops webview_flutter has nothing for.
final _noWebView = TargetPlatformVariant({
  TargetPlatform.linux,
  TargetPlatform.windows,
});

class _BareNotifications extends FlutterLocalNotificationsPlatform {}

/// A pty that is up and never says a word, for [LocalTransport] to start.
class _Pty implements Pty {
  @override
  Stream<Uint8List> get output => const Stream.empty();

  @override
  Future<int> get exitCode => Completer<int>().future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// What [LocalTransport] asked a pty to start, one call of it.
typedef _Started = ({
  String executable,
  List<String> arguments,
  String? workingDirectory,
  Map<String, String>? environment,
});

/// Starts [transport] as a session would, and says what it ran.
Future<_Started> _start(
  LocalTransport Function(
    Pty Function(
      String executable, {
      List<String> arguments,
      String? workingDirectory,
      Map<String, String>? environment,
      int rows,
      int columns,
      bool ackRead,
    })
    startPty,
  )
  transport,
) async {
  late _Started started;
  final session = await transport((
    executable, {
    arguments = const [],
    workingDirectory,
    environment,
    rows = 25,
    columns = 80,
    ackRead = false,
  }) {
    started = (
      executable: executable,
      arguments: arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    return _Pty();
  }).connect(host: localHost(), secrets: _NoSecrets(), columns: 80, rows: 25);
  await session.dispose();
  return started;
}

/// A Windows environment, as much of it as matters here.
const _windowsEnv = {
  'SystemRoot': r'C:\WINDOWS',
  'USERPROFILE': r'C:\Users\Trias Gagah',
  'USERNAME': 'triasbrata',
  'Path': r'C:\WINDOWS\system32;C:\WINDOWS',
};

/// UTF-16LE, as wsl.exe writes it.
List<int> _utf16(String text, {bool bom = false}) => [
  if (bom) ...[0xff, 0xfe],
  for (final unit in text.codeUnits) ...[unit & 0xff, unit >> 8],
];

Future<LiveSession> _connected(WidgetTester tester) async {
  final session = LiveSession(
    host: const HostProfile(
      id: 'host-1',
      label: 'box',
      host: '10.0.2.2',
      username: 'me',
    ),
    transport: (_, _) => _Shell(),
  );
  addTearDown(session.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: TerminalPage(
        session: session,
        secrets: _NoSecrets(),
        onOpenFile: (_, {line}) {},
        onOpenWeb: (_) {},
        onOpenChat: () {},
        onOpenGit: () {},
        onOpenDiff: (_) {},
        onSaveFileRoot: (_) async {},
      ),
    ),
  );
  await session.connect(secrets: _NoSecrets());
  await tester.pump();
  return session;
}

Future<void> _pumpHome(
  WidgetTester tester, {
  Future<void> Function()? onOpenLocal,
  Future<void> Function(String distro)? onOpenWsl,
  Future<List<String>> Function()? findWslDistros,
  List<HostProfile> hosts = const [],
  SessionManager? sessions,
}) async {
  SharedPreferences.setMockInitialValues({});
  final secrets = InMemorySecretStore();
  final repository = HostRepository(secrets);
  for (final host in hosts) {
    await repository.upsert(host);
  }
  await tester.pumpWidget(
    MaterialApp(
      home: HostsPage(
        repository: repository,
        secrets: secrets,
        sessions: sessions ?? SessionManager(),
        onOpenHost: (_) async {},
        onOpenLocal: onOpenLocal,
        onOpenWsl: onOpenWsl,
        findWslDistros: findWslDistros ?? wslDistros,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('the keys a desktop does not need', () {
    testWidgets('go, and the magic key with them — but the bar stays', (
      tester,
    ) async {
      await _connected(tester);

      // The bar is where this page's own buttons live, so it stays whatever
      // keyboard the machine has.
      final bar = find.byType(TerminalKeyBar);
      expect(bar, findsOneWidget);
      for (final tooltip in ['Git', 'Browse files', 'Upload a file to /tmp']) {
        expect(
          find.descendant(of: bar, matching: find.byTooltip(tooltip)),
          findsOneWidget,
        );
      }
      // The keys themselves, and the way back to a soft keyboard there is
      // none of, do not.
      expect(find.text('ESC'), findsNothing);
      expect(
        find.descendant(of: bar, matching: find.byTooltip('Show the keyboard')),
        findsNothing,
      );
      expect(find.byType(MagicKey), findsNothing);
    }, variant: _desktop);

    testWidgets('stay on a phone, which has no keyboard of its own', (
      tester,
    ) async {
      await _connected(tester);

      expect(find.byType(TerminalKeyBar), findsOneWidget);
      expect(find.text('ESC'), findsOneWidget);
      expect(find.byTooltip('Show the keyboard'), findsOneWidget);
      expect(find.byType(MagicKey), findsOneWidget);
    }, variant: _phone);
  });

  group('a link on a desktop', () {
    testWidgets('goes to the machine\'s own browser, never to a web tab', (
      tester,
    ) async {
      final launcher = _Launcher();
      UrlLauncherPlatform.instance = launcher;
      final inTab = <Uri>[];
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (inner) {
              context = inner;
              return const SizedBox();
            },
          ),
        ),
      );

      await openUrl(
        context,
        Uri.parse('https://example.com/x'),
        inTab: inTab.add,
      );

      expect(inTab, isEmpty);
      expect(launcher.opened, ['https://example.com/x']);
    }, variant: _desktop);

    testWidgets('opens in a tab beside its shell on a phone', (tester) async {
      final launcher = _Launcher();
      UrlLauncherPlatform.instance = launcher;
      final inTab = <Uri>[];
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (inner) {
              context = inner;
              return const SizedBox();
            },
          ),
        ),
      );

      await openUrl(
        context,
        Uri.parse('https://example.com/x'),
        inTab: inTab.add,
      );

      expect(inTab, [Uri.parse('https://example.com/x')]);
      expect(launcher.opened, isEmpty);
    }, variant: _phone);
  });

  group('the local shell on Home', () {
    testWidgets('has a card of its own, and a tap opens one', (tester) async {
      var opened = 0;
      await _pumpHome(tester, onOpenLocal: () async => opened++);

      expect(find.text('Local shell'), findsOneWidget);
      // No hosts saved yet, and the empty state would have stood in front of
      // it.
      expect(find.text('A shell on this machine'), findsOneWidget);

      await tester.tap(find.text('Local shell'));
      await tester.pump();
      expect(opened, 1);
    }, variant: _desktop);

    testWidgets('counts the shells already open on this machine', (
      tester,
    ) async {
      final sessions = SessionManager();
      final secrets = InMemorySecretStore();
      for (var i = 0; i < 2; i++) {
        await sessions
            .open(localHost(), transport: (_, _) => _Shell())
            .connect(secrets: secrets);
      }

      await _pumpHome(tester, onOpenLocal: () async {}, sessions: sessions);

      expect(find.text('2 open'), findsOneWidget);
    }, variant: _desktop);

    testWidgets('is not drawn on a phone, which has no shell to open', (
      tester,
    ) async {
      await _pumpHome(
        tester,
        onOpenLocal: () async {},
        hosts: const [
          HostProfile(id: 'a', label: 'box', host: '10.0.0.1', username: 'me'),
        ],
      );

      expect(find.text('Local shell'), findsNothing);
      expect(find.text('box'), findsOneWidget);
    }, variant: _phone);
  });

  testWidgets('notifications start on Linux, whose plugin cannot say what '
      'launched the app', (tester) async {
    // Implements nothing, as Linux's own leaves launch details out: asking
    // for them threw UnimplementedError as the Linux build started.
    FlutterLocalNotificationsPlatform.instance = _BareNotifications();

    await NotificationGateway(onOpenLink: (_) async {}).initialize();
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  group('a Mermaid diagram', () {
    const markdown = '```mermaid\ngraph TD\n  A --> B\n```\n';
    Widget preview() => MaterialApp(
      home: Scaffold(
        body: MarkdownBody(
          data: markdown,
          builders: {'code': MermaidBuilder()},
        ),
      ),
    );

    testWidgets('shows as its source where there is no web view to draw it', (
      tester,
    ) async {
      // No web view platform set: a WebViewController here would throw, as
      // it does on a real Linux or Windows build.
      await tester.pumpWidget(preview());

      expect(find.byType(MermaidView), findsNothing);
      expect(find.textContaining('A --> B'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: _noWebView);

    testWidgets('is drawn wherever there is one', (tester) async {
      WebViewPlatform.instance = FakeWebViewPlatform();
      await tester.pumpWidget(preview());

      expect(find.byType(MermaidView), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  });

  group('the local shell starts', () {
    test('the login shell in the home folder on a Mac or Linux', () async {
      final started = await _start(
        (startPty) => LocalTransport(
          startPty: startPty,
          windows: false,
          environment: const {'SHELL': '/bin/zsh', 'HOME': '/home/me'},
        ),
      );

      expect(started.executable, '/bin/zsh');
      expect(started.arguments, ['-l']);
      expect(started.workingDirectory, '/home/me');
      // flutter_pty's own copy of the environment is all it needs there.
      expect(started.environment, isNull);
    });

    test('PowerShell by its full path on Windows, with the whole '
        'environment', () async {
      final started = await _start(
        (startPty) => LocalTransport(
          startPty: startPty,
          windows: true,
          environment: _windowsEnv,
        ),
      );

      expect(
        started.executable,
        r'C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe',
      );
      expect(started.arguments, ['-NoLogo']);
      expect(started.workingDirectory, r'C:\Users\Trias Gagah');
      // flutter_pty would pass only a few variables by their Unix names, and
      // a Windows program without SystemRoot cannot open a socket.
      expect(started.environment, containsPair('SystemRoot', r'C:\WINDOWS'));
      expect(started.environment, containsPair('Path', _windowsEnv['Path']));
    });

    test('a WSL distro through wsl.exe, in its Linux home', () async {
      final started = await _start(
        (startPty) => LocalTransport(
          wslDistro: 'Ubuntu-22.04',
          startPty: startPty,
          windows: true,
          environment: {..._windowsEnv, 'WSLENV': 'USERPROFILE/p'},
        ),
      );

      expect(started.executable, r'C:\WINDOWS\System32\wsl.exe');
      // The distro is an argument of its own, never spliced into a command.
      expect(started.arguments, ['-d', 'Ubuntu-22.04', '--cd', '~']);
      final env = started.environment!;
      expect(env['TERM'], 'xterm-256color');
      // TERM reaches inside by name; what the user had there stays.
      expect(env['WSLENV'], 'USERPROFILE/p:TERM');
      expect(env['SystemRoot'], r'C:\WINDOWS');
    });

    test('never a WSL distro anywhere but Windows', () async {
      final started = await _start(
        (startPty) => LocalTransport(
          wslDistro: 'Ubuntu',
          startPty: startPty,
          windows: false,
          environment: const {'SHELL': '/bin/bash', 'HOME': '/home/me'},
        ),
      );

      expect(started.executable, '/bin/bash');
    });
  });

  group('WSLENV', () {
    test('names what the app sets, once, keeping what is there', () {
      expect(wslEnv(null, ['TERM']), 'TERM');
      expect(wslEnv('', ['TERM']), 'TERM');
      expect(wslEnv('USERPROFILE/p:TERM/u', ['TERM']), 'USERPROFILE/p:TERM/u');
      expect(wslEnv('GOPATH/l', ['TERM', 'X']), 'GOPATH/l:TERM:X');
    });
  });

  group('the WSL distros', () {
    test('are read from the UTF-16LE wsl.exe writes, as captured on a real '
        'machine', () {
      // `wsl.exe --list --quiet` on DESKTOP-L2EPDPG, byte for byte: no BOM,
      // CRLF, and Docker Desktop's engine, which is no shell for a person.
      const captured = [
        85, 0, 98, 0, 117, 0, 110, 0, 116, 0, 117, 0, 13, 0, 10, 0, //
        100, 0, 111, 0, 99, 0, 107, 0, 101, 0, 114, 0, 45, 0, 100, 0, //
        101, 0, 115, 0, 107, 0, 116, 0, 111, 0, 112, 0, 13, 0, 10, 0,
      ];

      expect(parseWslDistros(captured), ['Ubuntu']);
    });

    test('keep a dash and a dot, and drop the BOM and blank lines', () {
      final bytes = _utf16(
        'Ubuntu-22.04\r\n\r\nkali-linux\r\nMy_Distro.2\r\n'
        'docker-desktop-data\r\nrancher-desktop\r\n',
        bom: true,
      );

      expect(parseWslDistros(bytes), [
        'Ubuntu-22.04',
        'kali-linux',
        'My_Distro.2',
      ]);
    });

    test('are read as UTF-8 too, which WSL_UTF8=1 asks for', () {
      expect(
        parseWslDistros([
          0xef,
          0xbb,
          0xbf,
          ...'Debian\nUbuntu-24.04\n'.codeUnits,
        ]),
        ['Debian', 'Ubuntu-24.04'],
      );
    });

    test('are none when WSL has none installed, whatever it prints', () async {
      const message =
          'Windows Subsystem for Linux has no installed distributions.\r\n'
          'You can resolve this by installing a distribution with the '
          'instructions below:\r\n\r\n'
          "Use 'wsl.exe --list --online' to list available distributions\r\n"
          "and 'wsl.exe --install <Distro>' to install.\r\n";

      expect(parseWslDistros(_utf16(message)), isEmpty);
      // And it exits with an error, which is enough on its own.
      expect(
        await wslDistros(
          windows: true,
          run: (_, _) async =>
              ProcessResult(1, -1, _utf16('Ubuntu\r\n'), <int>[]),
        ),
        isEmpty,
      );
    });

    test('are none when Windows has no wsl.exe at all', () async {
      expect(
        await wslDistros(
          windows: true,
          run: (executable, _) async =>
              throw ProcessException(executable, const [], 'not found', 2),
        ),
        isEmpty,
      );
    });

    test('are asked of wsl.exe by its full path on Windows', () async {
      String? asked;
      List<String>? arguments;
      final distros = await wslDistros(
        windows: true,
        run: (executable, args) async {
          asked = executable;
          arguments = args;
          return ProcessResult(1, 0, _utf16('Ubuntu-22.04\r\n'), <int>[]);
        },
      );

      expect(distros, ['Ubuntu-22.04']);
      expect(asked, endsWith(r'\System32\wsl.exe'));
      expect(arguments, ['--list', '--quiet']);
    });

    test('are never looked for anywhere but Windows', () async {
      var ran = false;
      final distros = await wslDistros(
        windows: false,
        run: (_, _) async {
          ran = true;
          return ProcessResult(1, 0, _utf16('Ubuntu\r\n'), <int>[]);
        },
      );

      expect(distros, isEmpty);
      expect(ran, isFalse);
      // The real check, on the machine this test runs on.
      if (!Platform.isWindows) expect(await wslDistros(), isEmpty);
    });
  });

  group('a WSL shell on Home', () {
    testWidgets('has a card for each distro, and a tap opens that one', (
      tester,
    ) async {
      final opened = <String>[];
      await _pumpHome(
        tester,
        onOpenLocal: () async {},
        onOpenWsl: (distro) async => opened.add(distro),
        findWslDistros: () async => ['Ubuntu-22.04', 'Debian'],
      );

      expect(find.text('Local shell'), findsOneWidget);
      expect(find.text('Ubuntu-22.04'), findsOneWidget);
      expect(find.text('Debian'), findsOneWidget);
      expect(find.text('A WSL shell'), findsNWidgets(2));

      await tester.tap(find.text('Debian'));
      await tester.pump();
      expect(opened, ['Debian']);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('counts its own shells, apart from the local one', (
      tester,
    ) async {
      final sessions = SessionManager();
      await sessions
          .open(wslHost('Ubuntu'), transport: (_, _) => _Shell())
          .connect(secrets: InMemorySecretStore());

      await _pumpHome(
        tester,
        onOpenLocal: () async {},
        onOpenWsl: (_) async {},
        findWslDistros: () async => ['Ubuntu'],
        sessions: sessions,
      );

      expect(find.text('1 open'), findsOneWidget);
      expect(find.text('A shell on this machine'), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('is not offered where the app hands no way to open one, as '
        'it hands none but on Windows', (tester) async {
      await _pumpHome(
        tester,
        onOpenLocal: () async {},
        findWslDistros: () async => ['Ubuntu'],
      );

      expect(find.text('Local shell'), findsOneWidget);
      expect(find.text('Ubuntu'), findsNothing);
    }, variant: _desktop);

    testWidgets(
      'finds no distro off Windows even when asked',
      (tester) async {
        // The real finder, on this machine: it runs nothing unless the process
        // is a Windows one.
        await _pumpHome(
          tester,
          onOpenLocal: () async {},
          onOpenWsl: (_) async => fail('no distro to open'),
        );

        expect(find.text('A WSL shell'), findsNothing);
      },
      variant: _desktop,
      skip: Platform.isWindows,
    );
  });

  test('the local host is this machine, saved nowhere', () {
    final host = localHost();

    expect(host.id, localHostId);
    expect(host.host, 'localhost');
    // Nothing to authenticate to, so it keeps the default rather than
    // claiming a method that would send a credential.
    expect(host.authMethod, SshAuthMethod.password);
  });
}
