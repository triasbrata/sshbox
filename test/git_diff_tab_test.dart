import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/files/file_browser.dart';
import 'package:sshbox/src/git/git_diff.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/git_diff_page.dart';
import 'package:sshbox/src/ui/git_page.dart';
import 'package:sshbox/src/ui/settings_page.dart';
import 'package:sshbox/src/ui/tabs_shell.dart';

import 'fake_file_browser.dart';
import 'package:sshbox/src/ui/tui.dart';

class _NoSecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String? value) async {}

  @override
  Future<void> purgeHost(String hostId) async {}
}

/// A host with one repository on it, one changed file and one commit.
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

  /// Every git command the panel and the diff tabs ran, in order.
  final ran = <String>[];

  /// What `git diff` prints now. A test changes it to prove Reload asks the
  /// host again rather than showing what it first read.
  String unstaged = '-was this\n+is this';

  /// Makes the next diff fail the way git does: a message and a status.
  bool fail = false;

  @override
  Stream<String> run(String command, {bool pty = false}) {
    ran.add(command);
    List<String> said(List<String> lines) => [
      ...lines,
      '',
      '__jeansh_git_status:0',
    ];
    if (command.contains('--show-toplevel')) {
      return Stream.fromIterable(['/home/me/dev']);
    }
    if (command.contains("'--abbrev-ref'")) {
      return Stream.fromIterable(said(['main']));
    }
    if (command.contains("'status'")) {
      return Stream.fromIterable(said(['MM lib/main.dart']));
    }
    if (command.contains("'log'")) {
      return Stream.fromIterable(
        said(['abc1234\tme\t2 hours ago\tThe first commit']),
      );
    }
    if (command.contains("'ls-files'")) return Stream.fromIterable(said([]));
    if (command.contains("'show'")) {
      return Stream.fromIterable(said(_patch(['-gone', '+here'])));
    }
    if (command.contains("'diff'")) {
      if (fail) {
        return Stream.fromIterable([
          "fatal: no such path 'lib/main.dart' in HEAD",
          '',
          '__jeansh_git_status:128',
        ]);
      }
      return Stream.fromIterable(
        said(
          _patch(
            command.contains("'--staged'")
                ? ['-staged was', '+staged is']
                : unstaged.split('\n'),
          ),
        ),
      );
    }
    // The page's own probe.
    return Stream.value('sshbox\t42\t0\tbash\t/home/me');
  }

  /// A one-line change to lib/main.dart, as git prints it.
  static List<String> _patch(List<String> hunk) => [
    'diff --git a/lib/main.dart b/lib/main.dart',
    'index 1111111111111111111111111111111111111111..'
        '2222222222222222222222222222222222222222 100644',
    '--- a/lib/main.dart',
    '+++ b/lib/main.dart',
    '@@ -1 +1 @@',
    ...hunk,
  ];
}

const _box = HostProfile(
  id: 'box',
  label: 'box',
  host: 'box.example',
  username: 'me',
);

/// The diff tab shows [was] removed and [now] added, each once.
void _shows(String was, String now) {
  expect(find.byType(GitDiffPage), findsOneWidget);
  expect(find.text(was, findRichText: true), findsOneWidget);
  expect(find.text(now, findRichText: true), findsOneWidget);
}

/// Lets the git commands and the diff's own read finish.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late SessionManager manager;
  late _Shell shell;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    gitInDrawer.value = false;
    manager = SessionManager();
    shell = _Shell();
    manager.open(_box, transport: (_, _) => shell);
  });

  tearDown(() async {
    await manager.closeAll();
    gitInDrawer.value = false;
  });

  /// The app's one screen, its shell connected.
  Future<void> pumpTabs(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final session in manager.sessions) {
      await session.connect(secrets: _NoSecrets());
    }
    await tester.pumpWidget(
      MaterialApp(
        home: TabsShell(
          repository: HostRepository(_NoSecrets()),
          secrets: _NoSecrets(),
          sessions: manager,
          onOpenHost: (_) async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  /// Opens the git panel the way a thumb does, and waits for its lists.
  Future<void> openGit(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Git'));
    await _settle(tester);
  }

  testWidgets('a change tapped in the panel opens its diff in a tab of its '
      'own', (tester) async {
    await pumpTabs(tester);
    await openGit(tester);
    expect(find.byType(GitPage), findsOneWidget);
    expect(find.byType(GitDiffPage), findsNothing);

    await tester.tap(find.text('lib/main.dart').last);
    await _settle(tester);

    // A tab of its own, named after the diff and marked as one on the strip.
    final diff = manager.sessions.single.diffs.single;
    expect(diff.title, 'main.dart · diff');
    expect(diff.subtitle, 'lib/main.dart · dev');
    expect(manager.activeKind, TabKind.diff);
    expect(manager.activePath, diff.key);
    expect(find.byIcon(Icons.difference_outlined), findsOneWidget);

    // The diff page, showing what git printed.
    _shows('was this', 'is this');
    expect(find.text('main.dart · diff'), findsWidgets);
    expect(find.text('lib/main.dart · dev'), findsOneWidget);

    // Nothing that would write.
    expect(find.byTooltip('Save to host'), findsNothing);
    // The panel it came from is still open, one tab away — offstage now that
    // the diff is what is showing.
    expect(find.byType(GitPage, skipOffstage: false), findsOneWidget);
  });

  testWidgets('the staged diff and the unstaged one are tabs of their own, '
      'and the same diff asked twice goes back to its tab', (tester) async {
    await pumpTabs(tester);
    await openGit(tester);

    // The one file shows in both lists: staged above, unstaged below.
    await tester.tap(find.text('lib/main.dart').first);
    await _settle(tester);
    _shows('staged was', 'staged is');

    await tester.tap(find.byIcon(Icons.account_tree_outlined).first);
    await _settle(tester);
    await tester.tap(find.text('lib/main.dart').last);
    await _settle(tester);

    final diffs = manager.sessions.single.diffs;
    expect(diffs.length, 2);
    expect(diffs.first.title, 'main.dart · staged diff');
    expect(diffs.last.title, 'main.dart · diff');

    // Asking for one already open goes back to it rather than stacking a copy.
    await tester.tap(find.byIcon(Icons.account_tree_outlined).first);
    await _settle(tester);
    await tester.tap(find.text('lib/main.dart').last);
    await _settle(tester);
    expect(manager.sessions.single.diffs.length, 2);
  });

  testWidgets('a commit tapped in History opens its diff too', (tester) async {
    await pumpTabs(tester);
    await openGit(tester);

    await tester.tap(find.text('History'));
    await _settle(tester);
    await tester.tap(find.text('The first commit'));
    await _settle(tester);

    final diff = manager.sessions.single.diffs.single;
    expect(diff.title, 'abc1234 · diff');
    expect(diff.subtitle, 'The first commit');
    _shows('gone', 'here');
    expect(shell.ran.any((c) => c.contains("'show'")), isTrue);
  });

  testWidgets('Reload runs git again rather than showing what it first read', (
    tester,
  ) async {
    await pumpTabs(tester);
    await openGit(tester);
    await tester.tap(find.text('lib/main.dart').last);
    await _settle(tester);
    _shows('was this', 'is this');

    shell.unstaged = '-was this\n+is something else';
    await tester.tap(find.byTooltip('Reload from host'));
    await _settle(tester);

    _shows('was this', 'is something else');
  });

  testWidgets('from the drawer, opening a diff shuts the drawer the tab would '
      'be under', (tester) async {
    gitInDrawer.value = true;
    await pumpTabs(tester);
    await openGit(tester);
    expect(find.byType(GitPage), findsOneWidget);
    expect(find.byType(Drawer), findsOneWidget);

    await tester.tap(find.text('lib/main.dart').last);
    await tester.pumpAndSettle();
    await _settle(tester);

    expect(find.byType(GitPage), findsNothing);
    expect(find.byType(Drawer), findsNothing);
    _shows('was this', 'is this');
  });

  testWidgets('closing the diff tab lands on the shell it was opened beside', (
    tester,
  ) async {
    await pumpTabs(tester);
    await openGit(tester);
    await tester.tap(find.text('lib/main.dart').last);
    await _settle(tester);
    expect(manager.activeKind, TabKind.diff);

    await tester.tap(find.byTooltip('Close diff'));
    await tester.pumpAndSettle();

    expect(manager.sessions.single.diffs, isEmpty);
    expect(manager.activeKind, TabKind.terminal);
    expect(find.byType(GitDiffPage), findsNothing);
  });

  testWidgets('a diff goes on working after the panel that opened it closes', (
    tester,
  ) async {
    await pumpTabs(tester);
    await openGit(tester);
    await tester.tap(find.text('lib/main.dart').last);
    await _settle(tester);

    manager.closeGit(manager.sessions.single.id);
    await _settle(tester);
    expect(find.byType(GitPage), findsNothing);

    shell.unstaged = '-was this\n+is newer still';
    await tester.tap(find.byTooltip('Reload from host'));
    await _settle(tester);
    _shows('was this', 'is newer still');
  });

  testWidgets('a diff git refuses says why, rather than spinning', (
    tester,
  ) async {
    await pumpTabs(tester);
    await openGit(tester);
    shell.fail = true;

    await tester.tap(find.text('lib/main.dart').last);
    await _settle(tester);

    expect(find.byType(GitDiffPage), findsOneWidget);
    expect(find.textContaining('no such path'), findsOneWidget);
    expect(find.byType(TuiSpinner), findsNothing);
  });

  test('a diff is not saved with the open tabs: it is a command\'s output, '
      'not a file to read again', () async {
    // Its own manager: saving starts only once the tabs have been restored.
    final saving = SessionManager();
    addTearDown(saving.closeAll);
    await saving.restoreTabs(hosts: [_box], databases: []);
    final session = saving.open(_box, transport: (_, _) => _Shell());
    saving
      ..openFile(session.id, '/home/me/dev/lib/main.dart')
      ..openDiff(
        session.id,
        GitDiff(
          key: '/home/me/dev:lib/other.dart',
          title: 'other.dart · diff',
          subtitle: 'lib/other.dart · dev',
          read: () async => '-a\n+b',
        ),
      );
    await pumpEventQueue();

    expect(session.diffs, hasLength(1));
    final saved =
        (await SharedPreferences.getInstance()).getString('sshbox.tabs.v1') ??
        '';
    // The file tab is saved and comes back; the diff beside it is not.
    expect(saved, contains('/home/me/dev/lib/main.dart'));
    expect(saved, isNot(contains('other.dart')));
    expect(saved, isNot(contains('diff')));
  });
}
