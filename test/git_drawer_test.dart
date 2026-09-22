import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/files/file_browser.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/file_browser_page.dart';
import 'package:sshbox/src/ui/git_page.dart';
import 'package:sshbox/src/ui/settings_page.dart';
import 'package:sshbox/src/ui/terminal_page.dart';

import 'fake_file_browser.dart';

/// Holds nothing; the fake shell below never asks it for anything.
class _NoSecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String? value) async {}

  @override
  Future<void> purgeHost(String hostId) async {}
}

/// A shell that is up the moment it is asked for, with one repository on it:
/// enough for the git panel to draw its picker, its branch and both lists,
/// wherever the panel happens to be shown.
class _Shell
    implements
        SessionTransport,
        TerminalSession,
        FileBrowseCapable,
        CommandCapable {
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
  void send(String data) {}

  @override
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) {}

  @override
  Future<void> dispose() async {}

  @override
  FileBrowser openFileBrowser() => FakeFileBrowser();

  /// A long branch name on purpose: the panel's header is narrower in a
  /// drawer on a phone than it ever was in a tab.
  static const branch = 'feature/a-rather-long-branch-name';

  @override
  Stream<String> run(String command, {bool pty = false}) {
    List<String> said(List<String> lines) => [
      ...lines,
      '',
      '__jeansh_git_status:0',
    ];
    if (command.contains('--show-toplevel')) {
      return Stream.fromIterable(['/home/me/dev']);
    }
    if (command.contains("'--abbrev-ref'")) {
      return Stream.fromIterable(said([branch]));
    }
    if (command.contains("'status'")) {
      return Stream.fromIterable(said([' M lib/main.dart']));
    }
    if (command.contains("'log'")) {
      return Stream.fromIterable(
        said(['abc1234\tme\t2 hours ago\tThe first commit']),
      );
    }
    if (command.contains("'ls-files'")) return Stream.fromIterable(said([]));
    if (command.contains("'diff'")) {
      return Stream.fromIterable(said(['-was this', '+is this']));
    }
    // What the page's own probe reads: a shell running nothing in particular.
    return Stream.value('sshbox\t42\t0\tbash\t/home/me');
  }
}

/// A phone, where the drawer is the tighter fit of the two.
Future<void> _phone(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(411, 850));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

/// The terminal page on a connected host, with every git tab it was asked to
/// open recorded.
Future<List<int>> _pumpTerminal(WidgetTester tester) async {
  final opened = <int>[];
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
        onOpenGit: () => opened.add(1),
        onOpenDiff: (_) {},
        onSaveFileRoot: (_) async {},
      ),
    ),
  );
  await session.connect(secrets: _NoSecrets());
  await tester.pump();
  return opened;
}

/// Taps a key bar button and lets what it opened settle.
Future<void> _tapBar(WidgetTester tester, String tooltip) async {
  await tester.tap(find.byTooltip(tooltip));
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    gitInDrawer.value = false;
    showDotfiles.value = false;
  });

  testWidgets('Tab, the default: the git button opens a tab and no drawer', (
    tester,
  ) async {
    await _phone(tester);
    final opened = await _pumpTerminal(tester);
    expect(gitInDrawer.value, isFalse);

    await _tapBar(tester, 'Git');

    expect(opened, [1]);
    expect(find.byType(GitPage), findsNothing);
    expect(find.byType(Drawer), findsNothing);
  });

  testWidgets('Drawer: the git button opens the panel over the terminal, and '
      'no tab', (tester) async {
    await _phone(tester);
    await gitInDrawer.choose(true);
    final opened = await _pumpTerminal(tester);

    await _tapBar(tester, 'Git');

    expect(opened, isEmpty);
    expect(
      find.descendant(of: find.byType(Drawer), matching: find.byType(GitPage)),
      findsOneWidget,
    );
    // The panel itself, drawn as it is in a tab: the picker, both tabs, the
    // branch, and the repository's own rows.
    expect(find.text('Changes'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
    expect(find.text(_Shell.branch), findsOneWidget);
    expect(find.text('dev'), findsOneWidget);
    expect(find.text('lib/main.dart'), findsOneWidget);

    // It closes from inside, there being no tab ✕ to do it. (A diff tapped
    // here goes to a file tab and shuts the drawer: git_diff_tab_test.)
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(GitPage), findsNothing);
  });

  testWidgets('the files tree and the git panel share the one drawer', (
    tester,
  ) async {
    await _phone(tester);
    await gitInDrawer.choose(true);
    await _pumpTerminal(tester);

    await _tapBar(tester, 'Browse files');
    expect(find.byType(FileBrowserPage), findsOneWidget);
    expect(find.byType(GitPage), findsNothing);

    // The drawer's scrim covers the key bar, so the other button is reached
    // the way a user reaches it: shut this one first.
    await tester.tapAt(const Offset(10, 300));
    await tester.pumpAndSettle();
    await _tapBar(tester, 'Git');
    expect(find.byType(GitPage), findsOneWidget);
    expect(find.byType(FileBrowserPage), findsNothing);

    await tester.tapAt(const Offset(10, 300));
    await tester.pumpAndSettle();
    await _tapBar(tester, 'Browse files');
    expect(find.byType(FileBrowserPage), findsOneWidget);
    expect(find.byType(GitPage), findsNothing);
  });

  testWidgets('Settings saves the choice, and the next start reads it back', (
    tester,
  ) async {
    // Tall enough that the whole page is built: the row sits below the fonts.
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    expect(find.text('Open the git panel as'), findsOneWidget);

    await tester.tap(find.text('Drawer'));
    await tester.pump();
    expect(gitInDrawer.value, isTrue);

    // A fresh start reads what was saved rather than the default.
    final next = GitPanelSetting();
    await next.load();
    expect(next.value, isTrue);

    await tester.tap(find.text('Tab'));
    await tester.pump();
    await next.load();
    expect(next.value, isFalse);
  });

  testWidgets('a page built after a restart opens the drawer the saved choice '
      'asks for', (tester) async {
    await _phone(tester);
    SharedPreferences.setMockInitialValues({'sshbox.git.drawer': true});
    await gitInDrawer.load();

    final opened = await _pumpTerminal(tester);
    await _tapBar(tester, 'Git');

    expect(opened, isEmpty);
    expect(find.byType(GitPage), findsOneWidget);
  });

  /// A row of the files tree, rather than any text of that name.
  Finder treeRow(String name) => find.descendant(
    of: find.byType(FileBrowserPage),
    matching: find.text(name),
  );

  testWidgets('Show dotfiles stays chosen when the drawer shuts and opens '
      'again', (tester) async {
    await _phone(tester);
    await _pumpTerminal(tester);

    await _tapBar(tester, 'Browse files');
    expect(treeRow('.bashrc'), findsNothing);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show dotfiles'));
    await tester.pumpAndSettle();
    expect(treeRow('.bashrc'), findsOneWidget);

    // Shut through the scrim, which throws the tree away, then opened again.
    await tester.tapAt(const Offset(10, 300));
    await tester.pumpAndSettle();
    expect(find.byType(FileBrowserPage), findsNothing);
    await _tapBar(tester, 'Browse files');

    expect(treeRow('.bashrc'), findsOneWidget);
    expect(showDotfiles.value, isTrue);
  });

  testWidgets('a tree built after a restart shows dotfiles when that was the '
      'saved choice', (tester) async {
    await _phone(tester);
    SharedPreferences.setMockInitialValues({'sshbox.files.dotfiles': true});
    await showDotfiles.load();

    await _pumpTerminal(tester);
    await _tapBar(tester, 'Browse files');

    expect(treeRow('.bashrc'), findsOneWidget);
  });
}
