import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/files/file_browser.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/file_browser_page.dart';
import 'package:sshbox/src/ui/key_bar.dart';
import 'package:sshbox/src/ui/settings_page.dart';
import 'package:sshbox/src/ui/tabs_shell.dart';
import 'package:sshbox/src/ui/terminal_page.dart';
import 'package:sshbox/src/ui/tmux_panes.dart';
import 'package:sshbox/src/ui/toast.dart';
import 'package:toastification/toastification.dart';
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
    Map<String, String> environment = const {},
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

  /// How the host answers a command, where a test says; anything else gets
  /// [probe].
  Stream<String>? Function(String command) answer = (_) => null;

  @override
  Stream<String> run(String command, {bool pty = false}) =>
      answer(command) ?? Stream.value(probe);
}

/// The toast saying [message], if it is one of [type]'s.
Finder _toast(String message, ToastificationType type) => find.ancestor(
      of: find.text(message),
      matching: find.byWidgetPredicate(
        (widget) => widget is ToastCard && widget.type == type,
      ),
    );

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
          onOpenFile: (_, {line}) {},
          onOpenWeb: (_) {},
          onSaveFileRoot: (_) async {},
        ),
      ),
    );
    // Holds nothing to sign in with, so this one fails at once.
    await session.connect(secrets: _NoSecrets());
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

  testWidgets('a font picked in Settings redraws the open terminal at once', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => terminalSettings.value = TerminalSettings.defaultStyle);
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
          onSaveFileRoot: (_) async {},
        ),
      ),
    );
    await tester.pump();
    TerminalView view() => tester.widget(find.byType(TerminalView));
    expect(view().textStyle, TerminalSettings.defaultStyle);
    final columns = session.terminal.viewWidth;

    await terminalSettings.choose(family: 'Cascadia Mono', size: 20);
    await tester.pump();

    expect(view().textStyle, terminalStyleOf('Cascadia Mono', 20));
    expect(
      view().textStyle.fontFamilyFallback,
      contains('CaskaydiaCove Nerd Font Mono'),
    );
    expect(
      tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal
          .cellSize,
      terminalCellSize(view().textStyle, TextScaler.noScaling),
    );
    // Bigger cells, fewer of them: the shell is told its new size.
    expect(session.terminal.viewWidth, lessThan(columns));
  });

  testWidgets('a key hidden in Settings leaves the open terminal\'s bar at '
      'once', (tester) async {
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => keyBarSettings.value = KeyBarSettings.defaults);
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
          onSaveFileRoot: (_) async {},
        ),
      ),
    );
    await session.connect(secrets: _NoSecrets());
    await tester.pump();
    expect(find.text('ESC'), findsOneWidget);

    await keyBarSettings.choose([
      for (final item in KeyBarSettings.defaults)
        item.id == 'esc' ? (id: 'esc', shown: false) : item,
    ]);
    await tester.pump();

    expect(find.text('ESC'), findsNothing);
    expect(find.text('TAB'), findsOneWidget);
  });

  group('openUrl', () {
    /// Opens [url] on a phone that can open it only the [ways] given, and
    /// returns every way that was tried.
    Future<List<(String, PreferredLaunchMode)>> open(
      WidgetTester tester,
      String url,
      Set<PreferredLaunchMode> ways, {
      void Function(Uri url)? inTab,
    }) async {
      final launcher = _Launcher(ways);
      UrlLauncherPlatform.instance = launcher;
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox())),
      );
      await openUrl(
        tester.element(find.byType(SizedBox)),
        Uri.parse(url),
        inTab: inTab,
      );
      await tester.pump();
      return launcher.tried;
    }

    const inApp = PreferredLaunchMode.inAppBrowserView;
    const browser = PreferredLaunchMode.externalApplication;

    testWidgets('a web link from a shell opens in a tab next to it', (
      tester,
    ) async {
      final manager = SessionManager();
      final shell = manager.open(
        const HostProfile(
          id: 'host-1',
          label: 'box',
          host: '10.0.2.2',
          username: 'me',
        ),
      );
      addTearDown(manager.closeAll);

      final tried = await open(
        tester,
        'https://dart.dev',
        {inApp, browser},
        inTab: (url) => manager.openWeb(shell.id, url),
      );

      expect(tried, isEmpty);
      expect(shell.webTabs.single.url, Uri.parse('https://dart.dev'));
      expect(manager.activeWeb, same(shell.webTabs.single));
    });

    testWidgets('but a mailto: from one goes where the phone sends it', (
      tester,
    ) async {
      const platform = PreferredLaunchMode.platformDefault;
      final tabbed = <Uri>[];
      expect(
        await open(tester, 'mailto:me@box', {platform}, inTab: tabbed.add),
        [('mailto:me@box', platform)],
      );
      expect(tabbed, isEmpty);
    });

    testWidgets('a web link with no shell beside it opens in-app', (
      tester,
    ) async {
      expect(await open(tester, 'https://dart.dev', {inApp, browser}), [
        ('https://dart.dev', inApp),
      ]);
    });

    testWidgets('and so does one from a page that has gone', (tester) async {
      final launcher = _Launcher({inApp});
      UrlLauncherPlatform.instance = launcher;
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final gone = tester.element(find.byType(SizedBox));
      await tester.pumpWidget(const MaterialApp(home: Placeholder()));

      // A toast's Open, pressed after its tab closed.
      final tabbed = <Uri>[];
      await openUrl(gone, Uri.parse('https://dart.dev'), inTab: tabbed.add);

      expect(tabbed, isEmpty);
      expect(launcher.tried, [('https://dart.dev', inApp)]);
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
      // The toast's own frame, after the one that put its overlay in, and its
      // slide in.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        _toast('No app can open https://dart.dev', ToastificationType.error),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsNothing);
      await tester.pumpAndSettle();
    });
  });

  group('Ctrl+tap', () {
    late _Shell shell;
    late _Launcher launcher;
    late List<String> opened;
    late List<Uri> openedWeb;

    // Columns: the URL 0–15, dev/ 17–20, notes.txt 22–30, missing/x 32–40.
    const line = 'https://dart.dev dev/ notes.txt missing/x';

    Future<void> pumpPage(WidgetTester tester) async {
      shell = _Shell();
      UrlLauncherPlatform.instance = launcher = _Launcher({
        PreferredLaunchMode.inAppBrowserView,
      });
      opened = [];
      openedWeb = [];
      final session = LiveSession(
        host: const HostProfile(
          id: 'host-1',
          label: 'box',
          host: '10.0.2.2',
          username: 'me',
        ),
        transport: (_, _) => shell,
      );
      addTearDown(session.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: TerminalPage(
            session: session,
            secrets: _NoSecrets(),
            onOpenFile: (path, {line}) => opened.add(path),
            onOpenWeb: openedWeb.add,
            onSaveFileRoot: (_) async {},
          ),
        ),
      );
      await session.connect(secrets: _NoSecrets());
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

    testWidgets('underlines the links, opens a URL in a tab, and uses CTRL up', (
      tester,
    ) async {
      await pumpPage(tester);
      await tester.tap(find.text('CTRL'));
      await tester.pump();
      // The URL, dev/ and missing/x. A bare name is not underlined until the
      // host says it exists.
      expect(links(tester).underlines, hasLength(3));

      await tapColumn(tester, 3);

      expect(openedWeb, [Uri.parse('https://dart.dev')]);
      expect(launcher.tried, isEmpty);
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

    testWidgets('a path that is not there says so in a red toast', (
      tester,
    ) async {
      await pumpPage(tester);
      await tester.tap(find.text('CTRL'));
      await tester.pump();
      await tapColumn(tester, 35);
      // The toast's slide in.
      await tester.pump(const Duration(milliseconds: 600));

      expect(
        _toast('Not found: /home/me/missing/x', ToastificationType.error),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsNothing);
      expect(opened, isEmpty);
      await tester.pumpAndSettle();
    });

    testWidgets('without Ctrl a tap opens nothing and raises the keyboard', (
      tester,
    ) async {
      await pumpPage(tester);
      tester.testTextInput.log.clear();

      await tapColumn(tester, 3);

      expect(launcher.tried, isEmpty);
      expect(openedWeb, isEmpty);
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
        transport: (_, _) => shell,
      );
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: TerminalPage(
            session: session,
            secrets: _NoSecrets(),
            onOpenFile: (_, {line}) {},
            onOpenWeb: (_) {},
            onSaveFileRoot: (_) async {},
          ),
        ),
      );
      await session.connect(secrets: _NoSecrets());
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
      // Not settled: that would sit out a refusal's toast as well. A frame for
      // the toast's overlay, one for the toast, and its slide in.
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
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
        _toast(
          'claude is running — not moving the shell',
          ToastificationType.warning,
        ),
        findsOneWidget,
      );
      // Said in a toast, not a snack bar.
      expect(find.byType(SnackBar), findsNothing);
      await tester.pumpAndSettle();
    });

    testWidgets('a host that cannot say gets nothing typed either', (
      tester,
    ) async {
      final sent = await openDevInTerminal(tester, '');
      expect(sent, isEmpty);
      expect(
        _toast(
          'The host cannot say what the shell is running — not moving it',
          ToastificationType.warning,
        ),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsNothing);
      await tester.pumpAndSettle();
    });
  });

  group('a server forwarded to the tailnet', () {
    late List<Uri> openedWeb;
    const said = 'Port 3000 is on a.tail1.ts.net:3001';

    /// Brings up a shell on a host set to forward ports, where vite starts on
    /// 3000 once the session is up and tailscale serves it on 3001.
    Future<void> pumpPage(WidgetTester tester) async {
      openedWeb = [];
      final serving = StreamController<String>()
        ..add('|-- tcp://a.tail1.ts.net:3001');
      final shell = _Shell()
        ..answer = (command) => command.startsWith('tailscale serve')
            ? serving.stream
            : command.contains('/proc/net/tcp')
                // The uid, a sweep with nothing up, then one with vite in it.
                ? Stream.fromIterable(['1000', '', '0100007F:0BB8 1000', ''])
                : null;
      final session = LiveSession(
        host: const HostProfile(
          id: 'host-1',
          label: 'box',
          host: '10.0.2.2',
          username: 'me',
          forwardPorts: true,
        ),
        transport: (_, _) => shell,
      );
      addTearDown(session.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: TerminalPage(
            session: session,
            secrets: _NoSecrets(),
            onOpenFile: (_, {line}) {},
            onOpenWeb: openedWeb.add,
            onSaveFileRoot: (_) async {},
          ),
        ),
      );
      await session.connect(secrets: _NoSecrets());
      // The forward lands as the page takes it in; then a frame for the
      // toast's overlay, one for it, and its slide in.
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    testWidgets('says so in an info toast that stays five seconds', (
      tester,
    ) async {
      await pumpPage(tester);
      expect(_toast(said, ToastificationType.info), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);

      // Four seconds in, still up.
      await tester.pump(const Duration(milliseconds: 3400));
      expect(find.text(said), findsOneWidget);
      // At five it goes. Not settled: that would wait out any countdown.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(find.text(said), findsNothing);
    });

    testWidgets('and its Open opens the port in a tab beside the shell', (
      tester,
    ) async {
      await pumpPage(tester);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(openedWeb, [Uri.parse('http://a.tail1.ts.net:3001')]);
      expect(find.text(said), findsNothing);
    });
  });

  group('a forward landing, through the app', () {
    const said = 'Port 3000 is on a.tail1.ts.net:3001';
    late StreamController<String> watch;
    late StreamController<String> serving;
    late SessionManager manager;

    /// The app's one screen, wrapped the way `SshboxApp` wraps it, over one
    /// shell on a host set to forward ports. The test writes what the host's
    /// watch and `tailscale serve` say.
    Future<void> pumpApp(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      watch = StreamController<String>();
      serving = StreamController<String>();
      final shell = _Shell()
        ..answer = (command) => command.startsWith('tailscale serve')
            ? serving.stream
            : command.contains('/proc/net/tcp')
                ? watch.stream
                : null;
      manager = SessionManager();
      addTearDown(manager.closeAll);
      manager.open(
        const HostProfile(
          id: 'host-1',
          label: 'box',
          host: '10.0.2.2',
          username: 'me',
          forwardPorts: true,
        ),
        transport: (_, _) => shell,
      );

      await tester.pumpWidget(
        ToastificationWrapper(
          config: toastConfig,
          child: MaterialApp(
            home: TabsShell(
              repository: HostRepository(_NoSecrets()),
              secrets: _NoSecrets(),
              sessions: manager,
              onOpenHost: (_) async {},
            ),
          ),
        ),
      );
      await manager.sessions.single.connect(secrets: _NoSecrets());
      await tester.pump();
    }

    /// A while into the session vite starts on 3000, with anything [beside]
    /// it, and tailscale answers for it with [tailscale]; with [exits], and
    /// then gives up.
    Future<void> viteStarts(
      WidgetTester tester,
      List<String> tailscale, {
      bool exits = false,
      List<String> beside = const [],
    }) async {
      // The uid, and a sweep with nothing new up.
      watch
        ..add('1000')
        ..add('');
      await tester.pump(const Duration(seconds: 2));
      watch.add('0100007F:0BB8 1000');
      beside.forEach(watch.add);
      watch.add('');
      await tester.pump();
      tailscale.forEach(serving.add);
      if (exits) unawaited(serving.close());
      // The toast's overlay, the toast, and its slide in.
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    testWidgets('with the shell showing: a blue toast at the top with Open, '
        'for five seconds', (tester) async {
      await pumpApp(tester);
      await viteStarts(tester, ['|-- tcp://a.tail1.ts.net:3001']);

      final toast = _toast(said, ToastificationType.info);
      expect(toast, findsOneWidget);
      expect(
        find.descendant(of: toast, matching: find.text('Open')),
        findsOneWidget,
      );
      // Up where the tabs are, not down by the shell's key bar.
      expect(
        tester.getTopLeft(toast).dy,
        lessThan(tester.getBottomLeft(find.byType(TabStrip)).dy),
      );
      expect(find.byType(SnackBar), findsNothing);

      await tester.pump(const Duration(milliseconds: 3400));
      expect(find.text(said), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(find.text(said), findsNothing);
    });

    testWidgets('and with a file of that session showing instead', (
      tester,
    ) async {
      await pumpApp(tester);
      manager.openFile(manager.sessions.single.id, '/home/me/notes.txt');
      await tester.pumpAndSettle();
      expect(manager.activeKind, TabKind.file);

      await viteStarts(tester, ['|-- tcp://a.tail1.ts.net:3001']);
      expect(_toast(said, ToastificationType.info), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets("vite with Cloudflare's plugin is one toast: workerd's "
        'inspector beside it stays off the tailnet', (tester) async {
      await pumpApp(tester);
      await viteStarts(
        tester,
        ['|-- tcp://a.tail1.ts.net:3001'],
        beside: ['0100007F:240D 1000'], // 127.0.0.1:9229
      );
      expect(_toast(said, ToastificationType.info), findsOneWidget);
      expect(find.byType(ToastCard), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('a server that stops says its port closed', (tester) async {
      await pumpApp(tester);
      await viteStarts(tester, ['|-- tcp://a.tail1.ts.net:3001']);
      // A sweep without vite.
      watch.add('');
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        _toast('Port 3000 closed', ToastificationType.info),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
    });

    testWidgets("a refused forward is a red toast with all of tailscale's "
        'reason, for eight seconds', (tester) async {
      const why = [
        'sending serve config: Access denied: serve config denied',
        "Use 'sudo tailscale serve --tcp 3001 tcp://localhost:3000'.",
        "To not require root, use 'sudo tailscale set --operator=\$USER' once.",
      ];
      await pumpApp(tester);
      await viteStarts(tester, why, exits: true);

      final toast = _toast('Port 3000 not forwarded', ToastificationType.error);
      expect(toast, findsOneWidget);
      // Under the title rather than in it, which stops at two lines.
      expect(
        find.descendant(of: toast, matching: find.text(why.join('\n'))),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsNothing);

      await tester.pump(const Duration(seconds: 6));
      expect(toast, findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(toast, findsNothing);
    });

    testWidgets('and so is a host that cannot forward at all', (tester) async {
      await pumpApp(tester);
      watch.add('tailscale is not installed on this host');
      unawaited(watch.close());
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      final toast = _toast('Not forwarding ports', ToastificationType.error);
      expect(
        find.descendant(
          of: toast,
          matching: find.text('tailscale is not installed on this host'),
        ),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsNothing);
      await tester.pumpAndSettle();
    });
  });
}
