import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/files/file_browser.dart';
import 'package:sshbox/src/files/transfers.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/file_browser_page.dart';
import 'package:sshbox/src/ui/key_bar.dart';
import 'package:sshbox/src/ui/settings_page.dart';
import 'package:sshbox/src/ui/tabs_shell.dart';
import 'package:sshbox/src/ui/terminal_page.dart';
import 'package:sshbox/src/ui/terminal_paste.dart' show shareTextLimit;
import 'package:sshbox/src/ui/tmux_panes.dart';
import 'package:sshbox/src/ui/toast.dart';
import 'package:toastification/toastification.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:xterm2/xterm.dart';

import 'fake_file_browser.dart';
import 'fake_file_picker.dart';

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

/// A connect that fails at once, without leaving this isolate.
///
/// The real transport now runs on an isolate of its own, whose answers arrive
/// on the real event loop rather than the one `testWidgets` drives, so a
/// widget test that let it start would wait for ever.
class _Refused implements SessionTransport {
  @override
  Future<TerminalSession> connect({
    required HostProfile host,
    required SecretStore secrets,
    required int columns,
    required int rows,
    bool shell = true,
    Map<String, String> environment = const {},
    Future<Map<String, String>> Function(ForwardCapable host)? beforeShell,
  }) async =>
      throw const SshSessionException('No password saved for this host.');
}

/// A shell that is up the moment it is asked for, on a host whose files are
/// [FakeFileBrowser]'s and whose terminal is running `claude` in /home/me.
class _Shell
    implements
        SessionTransport,
        TerminalSession,
        FileBrowseCapable,
        FileUploadCapable,
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
    Future<Map<String, String>> Function(ForwardCapable host)? beforeShell,
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

  /// Every upload asked for, and where each landed.
  final uploaded = <({String path, String name})>[];

  @override
  Future<String> uploadToTmp({
    required String localPath,
    required String fileName,
    void Function(int sent, int total)? onProgress,
    Future<void>? cancel,
  }) async {
    uploaded.add((path: localPath, name: fileName));
    return '/tmp/$fileName';
  }
}

/// Every paste test runs as Android: the clipboard's image comes over a
/// channel that exists there and nowhere else, and so does the guard in front
/// of it.
final _android = TargetPlatformVariant.only(TargetPlatform.android);

/// Where the right-click tests' hyperlink points.
const _address = 'https://edot.youtrack.cloud/issue/COR-6025';

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
      transport: (_, _) => _Refused(),
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
          onOpenChat: () {},
          onOpenGit: () {},
          onOpenDiff: (_) {},
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

  testWidgets('a key taken off in Settings leaves the open terminal\'s bar at '
      'once, and a key of your own types into the shell', (tester) async {
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => keyBarSettings.value = KeyBarSettings.defaults);
    final shell = _Shell();
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
          onOpenChat: () {},
          onOpenGit: () {},
          onOpenDiff: (_) {},
          onSaveFileRoot: (_) async {},
        ),
      ),
    );
    await session.connect(secrets: _NoSecrets());
    await tester.pump();
    expect(find.text('ESC'), findsOneWidget);

    await keyBarSettings.choose([
      // First, so it is in sight on a bar as wide as a phone.
      (id: 'custom:a', custom: (label: 'LS', send: r'ls\n', combo: null)),
      for (final item in KeyBarSettings.defaults)
        if (item.id != 'esc') item,
    ]);
    await tester.pump();

    expect(find.text('ESC'), findsNothing);
    expect(find.text('TAB'), findsOneWidget);
    await tester.tap(find.text('LS'));
    await tester.pump();
    expect(shell.sent, ['ls\r']);
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

      final tried = await open(tester, 'https://dart.dev', {
        inApp,
        browser,
      }, inTab: (url) => manager.openWeb(shell.id, url));

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

    testWidgets('a tel: goes where the phone sends it too', (tester) async {
      const platform = PreferredLaunchMode.platformDefault;
      expect(await open(tester, 'tel:+62123', {platform}), [
        ('tel:+62123', platform),
      ]);
    });

    // Every scheme but a web page, a mail and a call is refused, whoever
    // asks: an intent: starts an activity, file: reads the phone, sshbox:
    // connects to a saved host, and any app can answer to a scheme of its
    // own. The phone is never asked, the tab never opened, and the address
    // can still be copied.
    for (final url in [
      'intent://scan/#Intent;scheme=zxing;package=com.example;end',
      'sshbox://host/host-1',
      'javascript:alert(1)',
      'file:///sdcard/Download/keys.txt',
      'market://details?id=cloud.brata.terminal',
      'INTENT:#Intent;end',
    ]) {
      testWidgets('refuses $url', (tester) async {
        final tabbed = <Uri>[];
        final tried = await open(
          tester,
          url,
          PreferredLaunchMode.values.toSet(),
          inTab: tabbed.add,
        );
        // The toast's own frame, after the one that put its overlay in, and
        // its slide in.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));

        expect(tried, isEmpty);
        expect(tabbed, isEmpty);
        final scheme = Uri.parse(url).scheme;
        expect(
          _toast(
            'Not opened: a $scheme: link is not a web, mail or phone link',
            ToastificationType.warning,
          ),
          findsOneWidget,
        );

        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        await tester.tap(find.text('Copy'));
        expect(copied, Uri.parse(url).toString());
        await tester.pumpAndSettle();
      });
    }

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
            onOpenChat: () {},
            onOpenGit: () {},
            onOpenDiff: (_) {},
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

    /// Where on screen the middle of the cell at [column] on [row] is.
    Offset cellAt(WidgetTester tester, int column, [int row = 0]) {
      final render = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal;
      return render.localToGlobal(
        render.getOffset(CellOffset(column, row)) +
            render.cellSize.center(Offset.zero),
      );
    }

    Future<void> tapColumn(
      WidgetTester tester,
      int column, {
      int row = 0,
    }) async {
      await tester.tapAt(cellAt(tester, column, row));
      // A lone tap lands once the double-tap window has run out.
      await tester.pump(kDoubleTapTimeout);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets(
      'underlines the links, opens a URL in a tab, and uses CTRL up',
      (tester) async {
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
      },
    );

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

    testWidgets('an armed CTRL takes the tap but never the scroll, so the '
        'alternate screen still scrolls under a finger', (tester) async {
      await pumpPage(tester);
      // The alternate screen, where Claude Code, vim and less live: xterm2
      // has no scrollback of its own to move, so a drag becomes the arrow
      // keys the program scrolls by. That is the only way a finger can
      // scroll there — a tablet has no wheel.
      tester.widget<TerminalView>(find.byType(TerminalView)).terminal
        ..resize(40, 10)
        ..write('\x1b[?1049h');
      await tester.pump();

      await tester.tap(find.text('CTRL'));
      await tester.pump();
      shell.sent.clear();

      final drag = await tester.startGesture(
        tester.getCenter(find.byType(TerminalView)),
      );
      for (var i = 0; i < 10; i++) {
        await drag.moveBy(const Offset(0, 20));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await drag.up();
      await tester.pump(const Duration(milliseconds: 300));

      // Suspending every pointer input, as arming CTRL used to, swallowed
      // these and froze the terminal until the app was killed.
      expect(shell.sent, isNotEmpty);
      expect(shell.sent, everyElement('\x1b[A'));
    });

    group('an OSC 8 hyperlink', () {
      /// The page, with [label] on the second row as a hyperlink to
      /// [address], written the way Claude Code writes one once it believes
      /// the terminal can show it: the label alone, its address hidden.
      Future<void> pumpLink(
        WidgetTester tester,
        String address, {
        String label = 'COR-6025',
      }) async {
        await pumpPage(tester);
        tester
            .widget<TerminalView>(find.byType(TerminalView))
            .terminal
            .write('\r\n\x1b]8;;$address\x07$label\x1b]8;;\x07 after');
        await tester.pump();
      }

      testWidgets('is underlined under CTRL, and a Ctrl+tap on it opens '
          'where it points', (tester) async {
        await pumpLink(tester, 'https://edot.youtrack.cloud/issue/COR-6025');
        await tester.tap(find.text('CTRL'));
        await tester.pump();
        // The first row's three, and the hyperlink's own.
        expect(links(tester).underlines, hasLength(4));

        await tapColumn(tester, 2, row: 1);

        expect(openedWeb, [
          Uri.parse('https://edot.youtrack.cloud/issue/COR-6025'),
        ]);
        expect(launcher.tried, isEmpty);
        expect(shell.sent, isEmpty);
      });

      testWidgets('outranks what its label spells out', (tester) async {
        await pumpLink(
          tester,
          'https://example.com/elsewhere',
          label: 'https://dart.dev',
        );
        await tester.tap(find.text('CTRL'));
        await tester.pump();
        await tapColumn(tester, 3, row: 1);

        expect(openedWeb, [Uri.parse('https://example.com/elsewhere')]);
      });

      testWidgets('to a file: opens that file on the host, as its path '
          'would', (tester) async {
        await pumpLink(tester, 'file:///home/me/notes.txt', label: 'notes');
        await tester.tap(find.text('CTRL'));
        await tester.pump();
        await tapColumn(tester, 1, row: 1);

        expect(opened, ['/home/me/notes.txt']);
        expect(launcher.tried, isEmpty);
      });

      // The address was written by whatever program runs, and the label can
      // say anything: openUrl's allowlist holds for it as for any link.
      for (final address in [
        'intent://x#Intent;component=cloud.brata.terminal/.MainActivity;end',
        'javascript:alert(document.cookie)',
        'sshbox://host/host-1',
      ]) {
        testWidgets('to $address is refused', (tester) async {
          await pumpLink(tester, address, label: 'docs');
          await tester.tap(find.text('CTRL'));
          await tester.pump();
          await tapColumn(tester, 1, row: 1);
          await tester.pump(const Duration(milliseconds: 600));

          expect(launcher.tried, isEmpty);
          expect(openedWeb, isEmpty);
          expect(opened, isEmpty);
          final scheme = Uri.parse(address).scheme;
          expect(
            _toast(
              'Not opened: a $scheme: link is not a web, mail or phone link',
              ToastificationType.warning,
            ),
            findsOneWidget,
          );
          await tester.pumpAndSettle();
        });
      }

      testWidgets('never opens on a tap without Ctrl', (tester) async {
        await pumpLink(tester, 'https://edot.youtrack.cloud/issue/COR-6025');
        await tapColumn(tester, 2, row: 1);

        expect(launcher.tried, isEmpty);
        expect(openedWeb, isEmpty);
      });

      testWidgets('shows and copies its address from a long press, before '
          'anything opens it', (tester) async {
        final copied = <Object?>[];
        final platform = tester.binding.defaultBinaryMessenger;
        platform.setMockMethodCallHandler(SystemChannels.platform, (
          call,
        ) async {
          if (call.method == 'Clipboard.setData') copied.add(call.arguments);
          return null;
        });
        addTearDown(
          () =>
              platform.setMockMethodCallHandler(SystemChannels.platform, null),
        );
        await pumpLink(tester, 'https://edot.youtrack.cloud/issue/COR-6025');

        // Plain text has no address to copy.
        final plain = await tester.startGesture(cellAt(tester, 18));
        await tester.pump(kLongPressTimeout);
        await plain.up();
        await tester.pump();
        expect(find.text('Copy'), findsOneWidget);
        expect(find.text('Copy link address'), findsNothing);
        await tester.tapAt(cellAt(tester, 30, 3));
        await tester.pump(kDoubleTapTimeout);
        await tester.pump();

        final hold = await tester.startGesture(cellAt(tester, 2, 1));
        await tester.pump(kLongPressTimeout);
        await hold.up();
        await tester.pump();
        await tester.tap(find.text('Copy link address'));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));

        expect(copied, [
          {'text': 'https://edot.youtrack.cloud/issue/COR-6025'},
        ]);
        expect(
          _toast(
            'Copied https://edot.youtrack.cloud/issue/COR-6025',
            ToastificationType.success,
          ),
          findsOneWidget,
        );
        expect(openedWeb, isEmpty);
        expect(launcher.tried, isEmpty);
        await tester.pumpAndSettle();
      });
    });

    group('a right-click', () {
      late List<Object?> copied;

      /// The page, with an OSC 8 hyperlink to [_address] labelled COR-6025
      /// on the second row, and every copy kept in [copied].
      Future<void> pumpLink(WidgetTester tester) async {
        copied = [];
        final platform = tester.binding.defaultBinaryMessenger;
        platform.setMockMethodCallHandler(SystemChannels.platform, (
          call,
        ) async {
          if (call.method == 'Clipboard.setData') copied.add(call.arguments);
          if (call.method == 'Clipboard.getData') return {'text': 'pasted'};
          return null;
        });
        addTearDown(
          () =>
              platform.setMockMethodCallHandler(SystemChannels.platform, null),
        );
        await pumpPage(tester);
        tester
            .widget<TerminalView>(find.byType(TerminalView))
            .terminal
            .write('\r\n\x1b]8;;$_address\x07COR-6025\x1b]8;;\x07 after');
        await tester.pump();
      }

      Future<void> rightClick(WidgetTester tester, Offset at) async {
        await tester.tapAt(
          at,
          buttons: kSecondaryButton,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
      }

      testWidgets(
        'on a desktop opens a menu at the pointer: Copy for a selection, '
        'Paste, and Copy link address on a hyperlink',
        (tester) async {
          await pumpLink(tester);

          // Plain text, nothing selected: no Copy, and no address.
          final at = cellAt(tester, 18);
          await rightClick(tester, at);
          final paste = find.widgetWithText(PopupMenuItem<void>, 'Paste');
          expect(tester.getTopLeft(paste).dx, moreOrLessEquals(at.dx));
          expect(find.text('Copy'), findsNothing);
          expect(find.text('Copy link address'), findsNothing);
          await tester.tapAt(cellAt(tester, 30, 3));
          await tester.pumpAndSettle();

          // "https" selected, as a mouse drag would.
          final buffer = tester
              .widget<TerminalView>(find.byType(TerminalView))
              .terminal
              .buffer;
          links(
            tester,
          ).setSelection(buffer.createAnchor(0, 0), buffer.createAnchor(5, 0));
          await rightClick(tester, cellAt(tester, 2, 1));
          await tester.tap(find.text('Copy'));
          await tester.pumpAndSettle();
          await rightClick(tester, cellAt(tester, 2, 1));
          await tester.tap(find.text('Copy link address'));
          await tester.pumpAndSettle();

          expect(copied, [
            {'text': 'https'},
            {'text': _address},
          ]);
          // Copied, never opened, and nothing typed into the shell.
          expect(openedWeb, isEmpty);
          expect(launcher.tried, isEmpty);
          expect(shell.sent, isEmpty);
        },
        variant: TargetPlatformVariant.desktop(),
      );

      testWidgets('its Paste pastes, as Ctrl+V does', (tester) async {
        await pumpLink(tester);
        await rightClick(tester, cellAt(tester, 18));
        await tester.tap(find.text('Paste'));
        await tester.pumpAndSettle();

        expect(shell.sent.join(), contains('pasted'));
      }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

      testWidgets('goes to a program that reads the mouse, unless Shift is '
          'held, as in any terminal', (tester) async {
        await pumpLink(tester);
        // What vim, less or tmux asks for with its mouse on.
        tester
            .widget<TerminalView>(find.byType(TerminalView))
            .terminal
            .write('\x1b[?1000h');
        await tester.pump();

        await rightClick(tester, cellAt(tester, 2, 1));
        expect(find.text('Paste'), findsNothing);
        // The right button's press, in X10's encoding.
        expect(shell.sent.join(), contains('\x1b[M"'));

        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await rightClick(tester, cellAt(tester, 2, 1));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        expect(find.text('Copy link address'), findsOneWidget);
      }, variant: TargetPlatformVariant.desktop());

      testWidgets('on Android opens nothing new', (tester) async {
        await pumpLink(tester);
        await rightClick(tester, cellAt(tester, 2, 1));

        expect(find.text('Paste'), findsNothing);
        expect(find.text('Copy link address'), findsNothing);
      }, variant: _android);
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
            onOpenChat: () {},
            onOpenGit: () {},
            onOpenDiff: (_) {},
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
            onOpenChat: () {},
            onOpenGit: () {},
            onOpenDiff: (_) {},
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
            builder: (context, child) => ToastLayer(child: child!),
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

  group('paste', () {
    late _Shell shell;
    late Directory temp;

    /// What MainActivity answers when asked for the clipboard's image: a file
    /// of ours, no image at all, or a refusal.
    Map<String, String>? image;
    PlatformException? refusal;

    /// What the system clipboard holds as text, for the paste that is not an
    /// image.
    String? clipboardText;

    /// What was put on the system clipboard, if anything.
    String? copied;

    const channel = MethodChannel('sshbox/share');

    setUp(() {
      temp = Directory.systemTemp.createTempSync('paste-test');
      image = null;
      refusal = null;
      clipboardText = null;
      copied = null;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'clipboardImage') return null;
        if (refusal case final refused?) throw refused;
        return image;
      });
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
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

    /// A picture already copied out of the clipboard, as MainActivity hands
    /// one over: our own file, and the name to give it on the host.
    Map<String, String> pictureNamed(String name) {
      final file = File('${temp.path}/$name')..writeAsBytesSync([1, 2, 3]);
      return {'path': file.path, 'name': name};
    }

    Future<LiveSession> pumpPage(WidgetTester tester) async {
      shell = _Shell();
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

    /// The paste a hardware keyboard sends, which xterm2 would otherwise
    /// answer itself with the clipboard's text alone.
    Future<void> pressCtrlV(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump();
      // Long enough for the toast that follows to have slid in.
      await tester.pump(const Duration(milliseconds: 600));
    }

    /// Ctrl+V held down, as Android reports it: one press and then a repeat
    /// about every 50 ms for as long as the thumb stays there.
    Future<void> holdCtrlV(WidgetTester tester, {int repeats = 3}) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
      for (var i = 0; i < repeats; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyV);
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    testWidgets('an image goes to the host and its path is typed', (
      tester,
    ) async {
      await pumpPage(tester);
      image = pictureNamed('Screenshot.png');

      await pressCtrlV(tester);

      expect(shell.uploaded, [(path: image!['path'], name: 'Screenshot.png')]);
      // A trailing space, so the next thing written is an argument.
      expect(shell.sent, contains('/tmp/Screenshot.png '));
      expect(
        _toast('Uploaded to /tmp/Screenshot.png', ToastificationType.success),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
    }, variant: _android);

    testWidgets('on a Mac the picture goes up too, from Cmd+V', (tester) async {
      await pumpPage(tester);
      image = pictureNamed('Screenshot.png');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(shell.uploaded, [(path: image!['path'], name: 'Screenshot.png')]);
      expect(shell.sent, contains('/tmp/Screenshot.png '));
      await tester.pumpAndSettle();
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('where no clipboard of ours answers, a paste is text', (
      tester,
    ) async {
      await pumpPage(tester);
      // Linux and Windows have no native half yet: the channel is not even
      // asked, and what is on the clipboard as text is what is pasted.
      image = pictureNamed('Screenshot.png');
      clipboardText = 'plain';

      await pressCtrlV(tester);

      expect(shell.uploaded, isEmpty);
      expect(shell.sent.join(), contains('plain'));
      await tester.pumpAndSettle();
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    /// Where the user saw `git push origin` come out as `gitpushorigin`.
    final desktops = TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    });

    /// The key a copy or a paste chord is made with here: ⌘ on a Mac, Ctrl
    /// everywhere else.
    LogicalKeyboardKey chordKey() => defaultTargetPlatform == TargetPlatform.macOS
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;

    testWidgets('on a desktop a paste sends every space, from the keyboard '
        'and from the menu', (tester) async {
      final session = await pumpPage(tester);
      const command = 'git push origin --delete some-branch';
      clipboardText = command;

      await tester.sendKeyDownEvent(chordKey());
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(chordKey());
      await tester.pump();
      await tester.pump();
      expect(shell.sent, [command]);

      // The selection menu's Paste, from a hold on a word.
      shell.sent.clear();
      session.terminal.write('hello');
      await tester.pump();
      final render = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal;
      final hold = await tester.startGesture(
        render.localToGlobal(
          render.getOffset(
                CellOffset(1, session.terminal.buffer.absoluteCursorY),
              ) +
              render.cellSize.center(Offset.zero),
        ),
      );
      await tester.pump(kLongPressTimeout);
      await hold.up();
      await tester.pump();
      await tester.tap(find.text('Paste'));
      await tester.pump();
      await tester.pump();
      expect(shell.sent, [command]);
      await tester.pumpAndSettle();
    }, variant: desktops);

    testWidgets('on a desktop the keyboard copy keeps the spaces of a line a '
        'program drew with cursor moves', (tester) async {
      final session = await pumpPage(tester);
      final terminal = session.terminal;
      final row = terminal.buffer.absoluteCursorY;
      terminal.write(
        '\rgit\x1b[1Cpush\x1b[1Corigin\x1b[1C--delete\x1b[1Csome-branch',
      );
      tester
          .widget<TerminalView>(find.byType(TerminalView))
          .controller!
          .setSelection(
            terminal.buffer.createAnchor(0, row),
            terminal.buffer.createAnchor(terminal.viewWidth, row),
          );
      await tester.pump();

      // Ctrl+Shift+C, or ⌘C: the chord xterm2's own copy shortcut takes.
      final apple = defaultTargetPlatform == TargetPlatform.macOS;
      await tester.sendKeyDownEvent(chordKey());
      if (!apple) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
      if (!apple) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(chordKey());
      await tester.pump();

      expect(copied, 'git push origin --delete some-branch');
      // Nothing of the chord reached the shell.
      expect(shell.sent, isEmpty);
    }, variant: desktops);

    testWidgets('the upload button takes several files, and types every '
        'path in the order they were picked', (tester) async {
      useFakePicker().next = [
        for (final name in ['shot.png', 'build.log', 'notes.txt'])
          _Picked(File('${temp.path}/$name')..writeAsBytesSync([1])),
      ];
      await pumpPage(tester);

      await tester.tap(find.byTooltip('Upload a file to /tmp'));
      await tester.pumpAndSettle();

      expect(shell.uploaded.map((file) => file.name), [
        'shot.png',
        'build.log',
        'notes.txt',
      ]);
      // One line, in the order picked, each ready to be followed by the next.
      expect(shell.sent.where((text) => text.startsWith('/tmp/')), [
        '/tmp/shot.png ',
        '/tmp/build.log ',
        '/tmp/notes.txt ',
      ]);
    }, variant: _android);

    testWidgets('with no image on it, the clipboard is text as before', (
      tester,
    ) async {
      await pumpPage(tester);
      clipboardText = 'ls -la';

      await pressCtrlV(tester);

      expect(shell.uploaded, isEmpty);
      expect(shell.sent, contains('ls -la'));
      await tester.pumpAndSettle();
    }, variant: _android);

    testWidgets('a held Ctrl+V pastes once, not once per auto-repeat', (
      tester,
    ) async {
      await pumpPage(tester);
      clipboardText = 'ls -la';

      await holdCtrlV(tester);

      // Each repeat used to fall past the chord handler to xterm2's own paste
      // shortcut, whose SingleActivator takes repeats, so a thumb left on the
      // key pasted again every 50 ms — and would have uploaded a picture
      // again every 50 ms.
      expect(shell.sent.where((data) => data == 'ls -la'), hasLength(1));
      await tester.pumpAndSettle();
    }, variant: _android);

    testWidgets('a held Ctrl+V uploads the picture once', (tester) async {
      await pumpPage(tester);
      image = pictureNamed('Screenshot.png');

      await holdCtrlV(tester);

      expect(shell.uploaded, hasLength(1));
      await tester.pumpAndSettle();
    }, variant: _android);

    testWidgets('nothing it can use is said, not passed over in silence', (
      tester,
    ) async {
      await pumpPage(tester);

      await pressCtrlV(tester);

      expect(
        _toast(
          'Nothing on the clipboard a terminal can paste',
          ToastificationType.warning,
        ),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
    }, variant: _android);

    testWidgets('a picture the owning app will not hand over says so', (
      tester,
    ) async {
      await pumpPage(tester);
      refusal = PlatformException(
        code: 'unreadable',
        message:
            'com.android.chrome.FileProvider would not hand over the '
            'picture on the clipboard. Try copying it again, or share it into '
            'Jeansh.',
      );

      await pressCtrlV(tester);

      expect(shell.uploaded, isEmpty);
      expect(
        _toast(
          'com.android.chrome.FileProvider would not hand over the picture on '
          'the clipboard. Try copying it again, or share it into Jeansh.',
          ToastificationType.warning,
        ),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
    }, variant: _android);

    testWidgets('an image too big to send is refused, not uploaded', (
      tester,
    ) async {
      await pumpPage(tester);
      refusal = PlatformException(
        code: 'too_big',
        message:
            'That image is bigger than 20 MB — send it from the files '
            'drawer instead.',
      );

      await pressCtrlV(tester);

      expect(shell.uploaded, isEmpty);
      expect(
        _toast(
          'That image is bigger than 20 MB — send it from the files drawer '
          'instead.',
          ToastificationType.warning,
        ),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
    }, variant: _android);

    /// "Share with Jeansh" from another app, handed to the session the way
    /// app.dart hands a share over, and given the frames to land in.
    Future<void> share(
      WidgetTester tester,
      LiveSession session,
      List<Object> shares,
    ) async {
      session.queueUploads(shares);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    /// Everything sent to the host that mentions [text].
    List<String> sentWith(String text) =>
        shell.sent.where((data) => data.contains(text)).toList();

    testWidgets('a shared link is written at the prompt, never with an Enter', (
      tester,
    ) async {
      final session = await pumpPage(tester);

      // Chrome's link can come with a line break after it.
      await share(tester, session, ['https://example.com/a?b=c\n']);

      expect(sentWith('example.com'), ['https://example.com/a?b=c']);
      expect(shell.sent.where((data) => data.contains('\r')), isEmpty);
      expect(copied, isNull);
      await tester.pumpAndSettle();
    });

    testWidgets('several lines go in bracketed, for a shell that asked for '
        'bracketed paste', (tester) async {
      final session = await pumpPage(tester);
      session.terminal.write('\x1b[?2004h');

      await share(tester, session, ['echo one\necho two\n']);

      expect(sentWith('echo'), ['\x1b[200~echo one\necho two\x1b[201~']);
      await tester.pumpAndSettle();
    });

    testWidgets('several lines are not pasted into a shell that would run '
        'them: they go on the clipboard instead', (tester) async {
      final session = await pumpPage(tester);

      await share(tester, session, ['echo one\nrm -rf ~/work']);

      expect(sentWith('echo'), isEmpty);
      expect(copied, 'echo one\nrm -rf ~/work');
      expect(
        _toast(
          'Not pasted: this shell would run each line of it. It is on the '
          'clipboard instead.',
          ToastificationType.warning,
        ),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
    });

    testWidgets('a shared text past the ceiling is refused, not pasted', (
      tester,
    ) async {
      final session = await pumpPage(tester);

      await share(tester, session, ['x' * (shareTextLimit + 1)]);

      expect(sentWith('xxxx'), isEmpty);
      expect(copied, isNull);
      expect(
        _toast(
          'The shared text is too long to paste: 64 KB at most',
          ToastificationType.warning,
        ),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
    });

    testWidgets('a file and a text shared one after the other land in that '
        'order', (tester) async {
      final session = await pumpPage(tester);
      final shot = pictureNamed('shot.png');

      await share(tester, session, [
        (path: shot['path']!, name: 'shot.png'),
        'https://example.com',
      ]);
      await tester.pumpAndSettle();

      expect(
        shell.sent.where(
          (data) => data.contains('/tmp/') || data.contains('example.com'),
        ),
        ['/tmp/shot.png ', 'https://example.com'],
      );
    });
  });

  group('the chat button', () {
    /// Opens a page on a host whose Claude Code says it is [version], and
    /// counts the chats the button opened and the times the host was asked.
    Future<({List<void> opened, _ClaudeHost host})> pumpChat(
      WidgetTester tester,
      String version,
    ) async {
      final host = _ClaudeHost(version);
      final opened = <void>[];
      final session = LiveSession(
        host: const HostProfile(
          id: 'host-1',
          label: 'box',
          host: '10.0.2.2',
          username: 'me',
        ),
        transport: (_, _) => host,
      );
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: TerminalPage(
            session: session,
            secrets: _NoSecrets(),
            onOpenFile: (_, {line}) {},
            onOpenWeb: (_) {},
            onOpenChat: () => opened.add(null),
            onOpenGit: () {},
            onOpenDiff: (_) {},
            onSaveFileRoot: (_) async {},
          ),
        ),
      );
      await session.connect(secrets: _NoSecrets());
      await tester.pump();
      return (opened: opened, host: host);
    }

    Future<void> tapChat(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Chat with Claude'));
      await tester.pump();
      await tester.pump();
      // The toast's slide in.
      await tester.pump(const Duration(milliseconds: 600));
    }

    testWidgets('on a host whose Claude Code is too old it says so, with both '
        'versions, and opens nothing', (tester) async {
      final (:opened, :host) = await pumpChat(tester, '2.0.14 (Claude Code)');

      await tapChat(tester);

      expect(opened, isEmpty);
      expect(
        _toast(
          'Claude Code 2.0.14 on this host is too old for chat — it needs '
          '2.1.259 or newer.',
          ToastificationType.warning,
        ),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsNothing);
      await tester.pumpAndSettle();
    });

    testWidgets('its refusal stays long enough to read, where a warning '
        'would go after a second', (tester) async {
      await pumpChat(tester, '2.1.100 (Claude Code)');

      await tapChat(tester);
      await tester.pump(const Duration(milliseconds: 1400));

      expect(
        _toast(
          'Claude Code 2.1.100 on this host is too old for chat — it needs '
          '2.1.259 or newer.',
          ToastificationType.warning,
        ),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
    });

    testWidgets('on a host whose Claude Code is new enough it opens the chat, '
        'and asks the host once a connection', (tester) async {
      final (:opened, :host) = await pumpChat(tester, '2.1.277 (Claude Code)');

      await tapChat(tester);
      await tapChat(tester);

      expect(opened, hasLength(2));
      expect(host.asked, 1);
      expect(find.byType(ToastCard), findsNothing);
    });

    testWidgets('a host with no Claude Code keeps saying so', (tester) async {
      final (:opened, :host) = await pumpChat(
        tester,
        'Claude Code is not installed on this host (looked on PATH, in '
        '~/.local/bin, ~/.claude/local and the usual package managers)',
      );

      await tapChat(tester);

      expect(opened, isEmpty);
      expect(
        find.textContaining('Claude Code is not installed on this host'),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
    });
  });
}

/// A host the chat can run on: a shell with command channels beside it,
/// whose `claude --version` answers [version].
class _ClaudeHost extends _Shell implements ChannelCapable {
  _ClaudeHost(this.version);

  final String version;

  /// How many times the host was asked which Claude Code it has.
  var asked = 0;

  @override
  Future<CommandChannel> open(String command) async {
    if (command.contains('--version')) asked++;
    return (
      output: Stream.value(Uint8List.fromList('$version\n'.codeUnits)),
      write: (Uint8List data) {},
      close: () {},
    );
  }
}

/// A file picked on the phone, standing on a real file so the upload can read
/// it.
final class _Picked extends PlatformFile {
  _Picked(this.file);

  final File file;

  @override
  String get name => file.uri.pathSegments.last;

  @override
  Uri get uri => file.uri;

  @override
  get xFile => throw UnimplementedError();

  @override
  int? lengthSync() => file.lengthSync();

  @override
  Future<int> length() => file.length();

  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();

  @override
  Stream<Uint8List> readAsByteStream() =>
      file.openRead().map(Uint8List.fromList);
}
