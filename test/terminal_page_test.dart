import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/files/file_browser.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/file_browser_page.dart';
import 'package:sshbox/src/ui/key_bar.dart';
import 'package:sshbox/src/ui/terminal_page.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:xterm2/xterm.dart';

import 'fake_file_browser.dart';

/// The phone's url_launcher, able to open links only the [ways] it is given,
/// and failing the rest the way Android does: by throwing.
class _Launcher extends UrlLauncherPlatform {
  _Launcher(this.ways);

  final Set<PreferredLaunchMode> ways;

  /// Every launch asked for, whether it opened or not.
  final tried = <(String, PreferredLaunchMode)>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    tried.add((url, options.mode));
    if (ways.contains(options.mode)) return true;
    throw PlatformException(code: 'ACTIVITY_NOT_FOUND');
  }
}

/// Holds nothing, so a password host fails to connect before a socket is
/// ever opened: the page comes up and stays up without a network.
class _NoSecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String? value) async {}

  @override
  Future<void> purgeHost(String hostId) async {}
}

/// A shell that is up the moment it is asked for, on a host whose files are
/// [FakeFileBrowser]'s and whose terminal is running `claude` in /home/me.
class _Shell
    implements
        SessionTransport,
        TerminalSession,
        FileBrowseCapable,
        CommandCapable {
  final sent = <String>[];

  @override
  Future<TerminalSession> connect({
    required HostProfile host,
    required SecretStore secrets,
    required int columns,
    required int rows,
    bool shell = true,
  }) async => this;

  @override
  final status = ValueNotifier(SessionStatus.connected);

  @override
  Stream<String> get output => const Stream.empty();

  @override
  String? get failure => null;

  @override
  void send(String data) => sent.add(data);

  @override
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) {}

  @override
  Future<void> dispose() async {}

  /// One filesystem, whichever of the page's browsers asks for it.
  final files = FakeFileBrowser();

  @override
  FileBrowser openFileBrowser() => files;

  /// What the `/proc` probe prints on the host: nothing, where there is no
  /// `/proc` to read.
  String probe = 'sshbox\t42\t0\tclaude\t/home/me';

  @override
  Stream<String> run(String command, {bool pty = false}) =>
      Stream.value(probe);
}

void main() {
  testWidgets('no header: its buttons ride in the key bar, and no menu', (
    tester,
  ) async {
    final session = LiveSession(
      host: const HostProfile(
        id: 'host-1',
        label: 'box',
        host: '10.0.2.2',
        username: 'me',
      ),
    );
    addTearDown(session.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: TerminalPage(
          session: session,
          secrets: _NoSecrets(),
          onOpenFile: (_) {},
          onSaveFileRoot: (_) async {},
        ),
      ),
    );
    // The page connects after its first frame, and this one fails at once.
    await tester.pump();
    expect(session.ended, isTrue);

    expect(find.byType(AppBar), findsNothing);
    expect(find.byIcon(Icons.more_vert), findsNothing);

    // Still there with no shell to talk to, the way the header's were; the
    // keys are not.
    final bar = find.byType(TerminalKeyBar);
    for (final tooltip in ['Browse files', 'Upload a file to /tmp']) {
      expect(
        find.descendant(of: bar, matching: find.byTooltip(tooltip)),
        findsOneWidget,
      );
    }
    expect(find.text('ESC'), findsNothing);
  });

  group('openUrl', () {
    /// Opens [url] on a phone that can open it only the [ways] given, and
    /// returns every way that was tried.
    Future<List<(String, PreferredLaunchMode)>> open(
      WidgetTester tester,
      String url,
      Set<PreferredLaunchMode> ways,
    ) async {
      final launcher = _Launcher(ways);
      UrlLauncherPlatform.instance = launcher;
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox())),
      );
      await openUrl(tester.element(find.byType(SizedBox)), Uri.parse(url));
      await tester.pump();
      return launcher.tried;
    }

    const inApp = PreferredLaunchMode.inAppBrowserView;
    const browser = PreferredLaunchMode.externalApplication;

    testWidgets('a web link opens in-app', (tester) async {
      expect(await open(tester, 'https://dart.dev', {inApp, browser}), [
        ('https://dart.dev', inApp),
      ]);
    });

    testWidgets('and in the browser when it cannot open in-app', (
      tester,
    ) async {
      expect(await open(tester, 'http://box.ts.net:3001', {browser}), [
        ('http://box.ts.net:3001', inApp),
        ('http://box.ts.net:3001', browser),
      ]);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('anything else goes where the phone sends it', (tester) async {
      const platform = PreferredLaunchMode.platformDefault;
      expect(await open(tester, 'mailto:me@box', {platform}), [
        ('mailto:me@box', platform),
      ]);
    });

    testWidgets('says so when nothing can open it', (tester) async {
      await open(tester, 'https://dart.dev', {});
      expect(find.text('No app can open https://dart.dev'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('Ctrl+tap', () {
    late _Shell shell;
    late _Launcher launcher;
    late List<String> opened;

    // Columns: the URL 0–15, dev/ 17–20, notes.txt 22–30, missing/x 32–40.
    const line = 'https://dart.dev dev/ notes.txt missing/x';

    Future<void> pumpPage(WidgetTester tester) async {
      shell = _Shell();
      UrlLauncherPlatform.instance = launcher = _Launcher({
        PreferredLaunchMode.inAppBrowserView,
      });
      opened = [];
      final session = LiveSession(
        host: const HostProfile(
          id: 'host-1',
          label: 'box',
          host: '10.0.2.2',
          username: 'me',
        ),
        transport: shell,
      );
      addTearDown(session.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: TerminalPage(
            session: session,
            secrets: _NoSecrets(),
            onOpenFile: opened.add,
            onSaveFileRoot: (_) async {},
          ),
        ),
      );
      // Connects after the first frame.
      await tester.pump();
      session.terminal.write(line);
      await tester.pump();
    }

    TerminalController links(WidgetTester tester) =>
        tester.widget<TerminalView>(find.byType(TerminalView)).controller!;

    Future<void> tapColumn(WidgetTester tester, int column) async {
      final render = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal;
      final cell = render.getOffset(CellOffset(column, 0)) +
          render.cellSize.center(Offset.zero);
      await tester.tapAt(render.localToGlobal(cell));
      // A lone tap lands once the double-tap window has run out.
      await tester.pump(kDoubleTapTimeout);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('underlines the links, opens a URL in-app, and uses CTRL up', (
      tester,
    ) async {
      await pumpPage(tester);
      await tester.tap(find.text('CTRL'));
      await tester.pump();
      // The URL, dev/ and missing/x. A bare name is not underlined until the
      // host says it exists.
      expect(links(tester).underlines, hasLength(3));

      await tapColumn(tester, 3);

      expect(launcher.tried, [
        ('https://dart.dev', PreferredLaunchMode.inAppBrowserView),
      ]);
      expect(shell.sent, isEmpty);
      expect(links(tester).underlines, isEmpty);
    });

    testWidgets('a folder opens the drawer there', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('CTRL'));
      await tester.pump();
      await tapColumn(tester, 18);

      final drawer = tester.widget<FileBrowserPage>(
        find.byType(FileBrowserPage),
      );
      expect(drawer.initialRoot, '/home/me/dev');
      expect(opened, isEmpty);
    });

    testWidgets('the drawer reopens scrolled where it was, but a folder '
        'opened this way starts at its top', (tester) async {
      await pumpPage(tester);
      for (var i = 0; i < 60; i++) {
        await shell.files.writeText('/home/me/file$i.txt', '');
      }
      Future<void> tapTooltip(String tooltip) async {
        await tester.tap(find.byTooltip(tooltip));
        await tester.pumpAndSettle();
      }

      final tree = find.descendant(
        of: find.byType(FileBrowserPage),
        matching: find.byType(Scrollable),
      );
      await tapTooltip('Browse files');
      await tester.drag(tree, const Offset(0, -400));
      await tester.pumpAndSettle();
      final left = tester.state<ScrollableState>(tree).position.pixels;
      expect(left, greaterThan(0));

      await tapTooltip('Close files');
      await tapTooltip('Browse files');
      expect(tester.state<ScrollableState>(tree).position.pixels, left);

      await tapTooltip('Close files');
      await tester.tap(find.text('CTRL'));
      await tester.pump();
      await tapColumn(tester, 18);
      final drawer = tester.widget<FileBrowserPage>(
        find.byType(FileBrowserPage),
      );
      expect(drawer.initialScrollOffset, 0);
    });

    testWidgets('a file opens in a tab, taken from where claude is', (
      tester,
    ) async {
      await pumpPage(tester);
      await tester.tap(find.text('CTRL'));
      await tester.pump();
      await tapColumn(tester, 24);

      expect(opened, ['/home/me/notes.txt']);
      expect(find.byType(FileBrowserPage), findsNothing);
    });

    testWidgets('a path that is not there says so', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('CTRL'));
      await tester.pump();
      await tapColumn(tester, 35);

      expect(find.text('Not found: /home/me/missing/x'), findsOneWidget);
      expect(opened, isEmpty);
    });

    testWidgets('without Ctrl a tap opens nothing and raises the keyboard', (
      tester,
    ) async {
      await pumpPage(tester);
      tester.testTextInput.log.clear();

      await tapColumn(tester, 3);

      expect(launcher.tried, isEmpty);
      expect(opened, isEmpty);
      expect(find.byType(FileBrowserPage), findsNothing);
      expect(
        tester.testTextInput.log.map((call) => call.method),
        contains('TextInput.show'),
      );
    });
  });

  group('cd from the files drawer', () {
    /// Picks "Open in terminal" on ~/dev with the host reporting [probe], and
    /// returns what reached the shell.
    Future<List<String>> openDevInTerminal(
      WidgetTester tester,
      String probe,
    ) async {
      final shell = _Shell()..probe = probe;
      final session = LiveSession(
        host: const HostProfile(
          id: 'host-1',
          label: 'box',
          host: '10.0.2.2',
          username: 'me',
        ),
        transport: shell,
      );
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: TerminalPage(
            session: session,
            secrets: _NoSecrets(),
            onOpenFile: (_) {},
            onSaveFileRoot: (_) async {},
          ),
        ),
      );
      // Connects after the first frame, and the button waits for that.
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byTooltip('Browse files'));
      await tester.pumpAndSettle();
      await tester.longPress(
        find.descendant(
          of: find.byType(FileBrowserPage),
          matching: find.text('dev'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open in terminal'));
      await tester.pumpAndSettle();
      return shell.sent;
    }

    testWidgets('a shell at its prompt goes', (tester) async {
      final sent = await openDevInTerminal(
        tester,
        'sshbox\t42\t1\tbash\t/home/me',
      );
      expect(sent, ['cd /home/me/dev\n']);
    });

    testWidgets('a shell already there is left alone', (tester) async {
      final sent = await openDevInTerminal(
        tester,
        'sshbox\t42\t1\tbash\t/home/me/dev',
      );
      expect(sent, isEmpty);
    });

    testWidgets('a running program is named and gets nothing typed into it', (
      tester,
    ) async {
      final sent = await openDevInTerminal(
        tester,
        'sshbox\t42\t0\tclaude\t/home/me',
      );
      expect(sent, isEmpty);
      expect(
        find.text('claude is running — not moving the shell'),
        findsOneWidget,
      );
      // Said in a toast, not a snack bar.
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a host that cannot say gets nothing typed either', (
      tester,
    ) async {
      final sent = await openDevInTerminal(tester, '');
      expect(sent, isEmpty);
      expect(
        find.text(
          'The host cannot say what the shell is running — not moving it',
        ),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsNothing);
    });
  });
}
