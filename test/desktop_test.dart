import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
// Come with flutter_local_notifications, and are needed only to make the
// Linux plugin without loading libc. The plugin is named from its own file
// because the package's export picks a stub without it for the analyzer.
// ignore: depend_on_referenced_packages, implementation_imports
import 'package:flutter_local_notifications_linux/src/flutter_local_notifications.dart'
    as linux;
// ignore: depend_on_referenced_packages, implementation_imports
import 'package:flutter_local_notifications_linux/src/notifications_manager.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/files/file_browser.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/files/transfers.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/notifications/notification_gateway.dart';
import 'package:sshbox/src/session/local_transport.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/hosts_page.dart';
import 'package:sshbox/src/ui/desktop_clipboard.dart';
import 'package:sshbox/src/ui/key_bar.dart';
import 'package:sshbox/src/ui/magic_key.dart';
import 'package:sshbox/src/ui/mermaid_view.dart';
import 'package:sshbox/src/ui/terminal_page.dart';
import 'package:sshbox/src/ui/terminal_paste.dart' show desktopClipboard;
import 'package:xterm2/xterm.dart' show TerminalView;
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'fake_drop.dart';
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

/// A Linux desktop with no notification server, as a bare window manager or
/// a headless session has: D-Bus refuses every post to a name nobody owns.
class _NoNotificationServer extends linux.LinuxFlutterLocalNotificationsPlugin {
  // The plugin's own manager opens libc.so.6 as it is made, which only a
  // Linux machine has, and this one's show and cancel never reach it.
  _NoNotificationServer() : super.private(_NoManager());

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    LinuxNotificationDetails? notificationDetails,
    String? payload,
  }) => Future.error(const _ServiceUnknown());

  @override
  Future<void> cancel({required int id}) =>
      Future.error(const _ServiceUnknown());
}

/// Stands in for the manager, so the test runs on a Mac too.
class _NoManager implements LinuxNotificationManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Stands in for dbus's DBusServiceUnknownException, the package being no
/// dependency of the app's own.
class _ServiceUnknown implements Exception {
  const _ServiceUnknown();

  @override
  String toString() =>
      'DBusServiceUnknownException: org.freedesktop.DBus.Error.ServiceUnknown: '
      'The name org.freedesktop.Notifications was not provided by any '
      '.service files';
}

/// A Linux clipboard holding [picture], without wl-paste or xclip.
class _PictureClipboard extends DesktopClipboard {
  _PictureClipboard(this.picture);

  final File picture;

  @override
  Future<SharedFile?> image(int limit, {required bool windows}) async =>
      (path: picture.path, name: 'shot.png');
}

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

/// A pty that keeps what it is sent, for a paste to land in.
class _TypedPty extends _Pty {
  final typed = StringBuffer();

  @override
  void write(Uint8List data) => typed.write(utf8.decode(data));
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

      expect(find.text('2 OPEN'), findsOneWidget);
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
      // flutter_pty's own copy of the environment is all it needs there,
      // and that this terminal opens a hyperlink.
      expect(started.environment, {'FORCE_HYPERLINK': '1'});
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
          distros: () async => ['Debian', 'Ubuntu-22.04'],
        ),
      );

      expect(started.executable, r'C:\WINDOWS\System32\wsl.exe');
      // The distro is an argument of its own, never spliced into a command.
      expect(started.arguments, ['-d', 'Ubuntu-22.04', '--cd', '~']);
      final env = started.environment!;
      expect(env['TERM'], 'xterm-256color');
      // TERM reaches inside by name, and so does FORCE_HYPERLINK; what the
      // user had there stays.
      expect(env['WSLENV'], 'USERPROFILE/p:TERM:FORCE_HYPERLINK');
      expect(env['FORCE_HYPERLINK'], '1');
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

    test('no shell for a WSL distro removed since, and says so, for a tab '
        'brought back that names one', () async {
      var started = false;
      final transport = LocalTransport(
        wslDistro: 'Ubuntu-22.04',
        startPty:
            (
              _, {
              arguments = const [],
              workingDirectory,
              environment,
              rows = 25,
              columns = 80,
              ackRead = false,
            }) {
              started = true;
              return _Pty();
            },
        windows: true,
        environment: _windowsEnv,
        distros: () async => ['Debian'],
      );

      for (final shell in [true, false]) {
        await expectLater(
          transport.connect(
            host: wslHost('Ubuntu-22.04'),
            secrets: _NoSecrets(),
            columns: 80,
            rows: 25,
            shell: shell,
          ),
          throwsA(
            isA<SshSessionException>().having(
              (error) => error.message,
              'message',
              'WSL has no distro called Ubuntu-22.04 on this machine any more.',
            ),
          ),
        );
      }
      expect(started, isFalse);
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

      expect(find.text('1 OPEN'), findsOneWidget);
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

  group('a paste into a local shell', () {
    late _TypedPty pty;
    late Directory temp;

    /// What the Mac's clipboard half answers: a copy of the picture, or none.
    Map<String, String>? image;
    String? clipboardText;
    var askedForImage = false;

    const channel = MethodChannel('sshbox/share');

    setUp(() {
      temp = Directory.systemTemp.createTempSync('local-paste-test');
      image = null;
      clipboardText = null;
      askedForImage = false;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'clipboardImage') return null;
        askedForImage = true;
        return image;
      });
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method != 'Clipboard.getData') return null;
        return clipboardText == null ? null : {'text': clipboardText};
      });
    });

    tearDown(() {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      temp.deleteSync(recursive: true);
      transfers.clearFinished();
    });

    /// A terminal page on a real [LocalTransport], its pty ours: this machine,
    /// or with [wslDistro] a WSL distro on Windows.
    Future<LiveSession> pumpLocal(
      WidgetTester tester, {
      String? wslDistro,
    }) async {
      pty = _TypedPty();
      final session = LiveSession(
        host: wslDistro == null ? localHost() : wslHost(wslDistro),
        transport: (_, _) => LocalTransport(
          wslDistro: wslDistro,
          windows: wslDistro != null,
          distros: () async => [?wslDistro],
          environment: wslDistro != null
              ? _windowsEnv
              : {'SHELL': '/bin/zsh', 'HOME': temp.path},
          startPty: (
            executable, {
            arguments = const [],
            workingDirectory,
            environment,
            rows = 25,
            columns = 80,
            ackRead = false,
          }) => pty,
        ),
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
      tester
          .widget<TerminalView>(find.byType(TerminalView))
          .focusNode!
          .requestFocus();
      await tester.pump();
      return session;
    }

    /// ⌘V on a Mac, Ctrl+V on Linux and Windows — then real time for the
    /// files a paste writes, which a widget test's fake clock never gives.
    Future<void> paste(WidgetTester tester) async {
      final chord = defaultTargetPlatform == TargetPlatform.macOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(chord);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(chord);
      for (var i = 0; i < 100 && pty.typed.isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      // A toast goes in after the frame that asked for it, and is drawn in
      // the one after that.
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    /// Past the five seconds the host's OS is given to answer, for each of
    /// its two questions: a local shell is asked them by a real `sh`, which a
    /// test's fake clock does not wait for.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(seconds: 6));
      }
    }

    testWidgets('of a picture on a Mac keeps a copy only the user can read, '
        'and types its path', (tester) async {
      await pumpLocal(tester);
      final picture = File('${temp.path}/Screenshot 1.png')
        ..writeAsBytesSync([1, 2, 3]);
      image = {'path': picture.path, 'name': 'Screenshot 1.png'};

      await paste(tester);

      // A trailing space, as the upload to a host types one. Before, the
      // paste said "Upload failed: This session cannot transfer files." and
      // typed nothing.
      final typed = pty.typed.toString();
      expect(typed, endsWith('/Screenshot_1.png '));
      final copy = File(typed.trimRight());
      // A copy of its own: the clipboard's is emptied at the next paste.
      expect(copy.path, isNot(picture.path));
      expect(copy.readAsBytesSync(), [1, 2, 3]);
      expect(copy.statSync().mode & 0x1ff, 0x180);
      expect(copy.parent.statSync().mode & 0x1ff, 0x1c0);
      expect(find.text('Uploaded to ${copy.path}'), findsOneWidget);
      await settle(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('of a picture on Linux with no notification server still '
        'types its path, and throws nothing', (tester) async {
      FlutterLocalNotificationsPlatform.instance = _NoNotificationServer();
      // As the app does: every upload goes through [transfers].
      await NotificationGateway(onOpenLink: (_) async {})
          .followTransfers(transfers);
      await pumpLocal(tester);
      desktopClipboard = _PictureClipboard(
        File('${temp.path}/source.png')..writeAsBytesSync([1, 2, 3]),
      );
      addTearDown(() => desktopClipboard = DesktopClipboard());

      await paste(tester);

      // Before, each progress notification's refusal reached the zone
      // uncaught, which fails the test.
      final typed = pty.typed.toString();
      expect(typed, endsWith('/shot.png '));
      expect(File(typed.trimRight()).readAsBytesSync(), [1, 2, 3]);
      expect(find.text('Uploaded to ${typed.trimRight()}'), findsOneWidget);
      await settle(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('of a picture into a program that asked for bracketed paste '
        'pastes its path, which Claude Code turns into [Image #N]', (
      tester,
    ) async {
      final session = await pumpLocal(tester);
      session.terminal.write('\x1b[?2004h');
      desktopClipboard = _PictureClipboard(
        File('${temp.path}/source.png')..writeAsBytesSync([1, 2, 3]),
      );
      addTearDown(() => desktopClipboard = DesktopClipboard());

      await paste(tester);

      final typed = pty.typed.toString();
      expect(typed, startsWith('\x1b[200~/'));
      expect(typed, endsWith('/shot.png \x1b[201~'));
      await settle(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    // Escaped as iTerm2 escapes a drop, which Claude Code still takes as an
    // image and a shell reads as one word, bracketed or not.
    const escaped = r"it\'s\ a\ shot\ \(1\).png";

    testWidgets('a file dropped on a Local shell pastes its own path, '
        'escaped for the shell, nothing copied', (tester) async {
      await pumpLocal(tester);
      final file = File("${temp.path}/it's a shot (1).png")
        ..writeAsStringSync('x');

      await dropOnTerminal(tester, [file.path]);
      await tester.pump();

      expect(pty.typed.toString(), '${temp.path}/$escaped ');
      await settle(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('and bracketed, still escaped, when the program asked for '
        'it: bash 5.1 does, and would split the raw name', (tester) async {
      final session = await pumpLocal(tester);
      session.terminal.write('\x1b[?2004h');
      final file = File("${temp.path}/it's a shot (1).png")
        ..writeAsStringSync('x');

      await dropOnTerminal(tester, [file.path]);
      await tester.pump();

      expect(pty.typed.toString(), '\x1b[200~${temp.path}/$escaped \x1b[201~');
      await settle(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    test('keeps an earlier picture of the same name, and goes with the '
        'tab', () async {
      final session =
          await LocalTransport(
            windows: false,
            environment: const {'SHELL': '/bin/zsh'},
            startPty: (
              executable, {
              arguments = const [],
              workingDirectory,
              environment,
              rows = 25,
              columns = 80,
              ackRead = false,
            }) => _TypedPty(),
          ).connect(
            host: localHost(),
            secrets: _NoSecrets(),
            columns: 80,
            rows: 25,
          );
      final picture = File('${temp.path}/a.png')..writeAsBytesSync([1]);
      Future<String> send() => (session as FileUploadCapable).uploadToTmp(
        localPath: picture.path,
        fileName: 'a.png',
      );

      final first = await send();
      final second = await send();

      expect(second, isNot(first));
      expect(second, endsWith('-a.png'));
      for (final path in [first, second]) {
        expect(File(path).statSync().mode & 0x1ff, 0x180);
      }
      await session.dispose();
      expect(File(first).parent.existsSync(), isFalse);
    });

    testWidgets(
      'of text reaches the shell',
      (tester) async {
        await pumpLocal(tester);
        clipboardText = 'echo hello world';

        await paste(tester);

        expect(pty.typed.toString(), 'echo hello world');
        await settle(tester);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.macOS,
        TargetPlatform.linux,
      }),
    );

    testWidgets('of text reaches a WSL shell, which takes a picture too', (
      tester,
    ) async {
      // Windows' clipboard is read by the app itself, not the channel: here
      // it holds no picture.
      desktopClipboard = DesktopClipboard(
        start: (_, _, {environment}) async =>
            throw const ProcessException('powershell', []),
      );
      addTearDown(() => desktopClipboard = DesktopClipboard());
      final session = await pumpLocal(tester, wslDistro: 'Ubuntu');
      clipboardText = 'echo hello world';

      await paste(tester);

      expect(pty.typed.toString(), 'echo hello world');
      expect(askedForImage, isFalse);
      // Into the distro's own /tmp, see "a file put in a WSL distro".
      expect(session.canUploadFiles, isTrue);
      await settle(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  });

  group('a file put in a WSL distro or PowerShell', () {
    late Directory temp;
    late File picture;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('local-upload');
      picture = File('${temp.path}/source.png')
        ..writeAsBytesSync(List.generate(300000, (i) => i % 251));
    });

    tearDown(() => temp.deleteSync(recursive: true));

    /// [transport] connected on a pty that says nothing, as an upload's
    /// [FileUploadCapable].
    Future<FileUploadCapable> connected(LocalTransport transport) async {
      final session = await transport.connect(
        host: localHost(),
        secrets: _NoSecrets(),
        columns: 80,
        rows: 25,
      );
      addTearDown(session.dispose);
      return session as FileUploadCapable;
    }

    Pty noPty(
      String executable, {
      List<String> arguments = const [],
      String? workingDirectory,
      Map<String, String>? environment,
      int rows = 25,
      int columns = 80,
      bool ackRead = false,
    }) => _Pty();

    test('in a WSL distro lands in the distro\'s own /tmp, piped through '
        'wsl.exe, and the path typed is a Linux one', () async {
      late List<String> ran;
      final shell = await connected(
        LocalTransport(
          wslDistro: 'Ubuntu-22.04',
          distros: () async => ['Ubuntu-22.04'],
          startPty: noPty,
          windows: true,
          environment: _windowsEnv,
          tmp: '/tmp',
          startProcess: (executable, arguments) {
            ran = [executable, ...arguments];
            // Inside the distro it is sh running this; here it is this
            // machine's own, into a /tmp of the test's.
            final exec = arguments.indexOf('--exec');
            final sh = [...arguments.sublist(exec + 1)];
            sh[sh.length - 3] = temp.path;
            return Process.start('/bin/sh', sh.sublist(1));
          },
        ),
      );

      final typed = await shell.uploadToTmp(
        localPath: picture.path,
        fileName: 'pasted-20260921-070503.png',
      );

      expect(ran.take(8), [
        r'C:\WINDOWS\System32\wsl.exe',
        '-d',
        'Ubuntu-22.04',
        '--cd',
        '~',
        '--exec',
        'sh',
        '-c',
      ]);
      expect(ran[8], LocalTransport.uploadScript);
      // The distro's /tmp, each an argument of its own.
      expect(ran.sublist(9, 12), ['sh', '/tmp', 'pasted-20260921-070503.png']);
      // What the sh inside printed back: a path in its own filesystem, never
      // a Windows one a program in WSL could not open.
      expect(typed, '${temp.path}/pasted-20260921-070503.png');
      expect(typed, isNot(contains(r'\')));
      expect(File(typed).readAsBytesSync(), picture.readAsBytesSync());
    });

    test('in PowerShell lands in the user\'s %TEMP%, quoted when the path '
        'has a space', () async {
      final user = Directory('${temp.path}/Trias Gagah')..createSync();
      final shell = await connected(
        LocalTransport(
          startPty: noPty,
          windows: true,
          environment: {..._windowsEnv, 'TEMP': user.path},
          startProcess: (_, _) => throw StateError('no sh on Windows'),
        ),
      );

      final typed = await shell.uploadToTmp(
        localPath: picture.path,
        fileName: 'shot.png',
      );

      final path = '${user.path}${Platform.pathSeparator}shot.png';
      expect(typed, '"$path"');
      expect(File(path).readAsBytesSync(), picture.readAsBytesSync());
      expect(typedWindowsPath(r'C:\Temp\shot.png'), r'C:\Temp\shot.png');
    });

    test('a cancelled upload leaves nothing half written in the '
        'distro', () async {
      // wsl.exe as a cancel meets it: a process a kill ends, and behind it
      // the distro's sh, which the kill never reaches, late to start as a
      // cold distro is. Its output comes through wsl.exe, so a killed one
      // hands on nothing, and it leaves `done` behind once it has ended.
      const wsl =
          r'exec 3<&0; '
          r'(sleep 0.5; /bin/sh "$@"; s=$?; : >done; exit $s) <&3 >out & '
          r'wait $!; s=$?; cat out; exit $s';
      var distroDone = false;
      final shell = await connected(
        LocalTransport(
          wslDistro: 'Ubuntu',
          distros: () async => ['Ubuntu'],
          startPty: noPty,
          windows: true,
          environment: _windowsEnv,
          tmp: temp.path,
          startProcess: (executable, arguments) {
            final sh = arguments.sublist(arguments.indexOf('--exec') + 2);
            // The cleanup, `-c 'rm -f …'`, run at once.
            if (sh.length == 2) {
              distroDone = File('${temp.path}/done').existsSync();
              return Process.start('/bin/sh', sh);
            }
            return Process.start('/bin/sh', [
              '-c',
              wsl,
              'wsl',
              ...sh,
            ], workingDirectory: temp.path);
          },
        ),
      );

      await expectLater(
        shell.uploadToTmp(
          localPath: picture.path,
          fileName: 'shot.png',
          cancel: Future.value(),
        ),
        throwsA(
          isA<FileBrowserException>().having(
            (e) => e.fault,
            'fault',
            FileBrowserFault.cancelled,
          ),
        ),
      );
      expect(
        distroDone,
        isTrue,
        reason:
            'the half file was taken away while the sh in the distro '
            'could still write it',
      );
      expect(File('${temp.path}/shot.png').existsSync(), isFalse);
    });
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
