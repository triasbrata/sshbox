import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/files/file_browser.dart';
import 'package:sshbox/src/git/git_diff.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/git_page.dart';

import 'fake_file_browser.dart';

class _NoSecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String? value) async {}

  @override
  Future<void> purgeHost(String hostId) async {}
}

const _main = '/home/me/dev';
const _agent = '/home/me/dev/.claude/worktrees/agent-x';

/// A host with one repository and one worktree of it, the way Claude Code
/// leaves them: each checkout answers with its own branch and its own
/// changes, told apart by the `-C` every command carries.
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

  /// Every command the panel ran, in order.
  final ran = <String>[];

  @override
  Stream<String> run(String command, {bool pty = false}) {
    ran.add(command);
    Stream<String> said(List<String> lines) =>
        Stream.fromIterable([...lines, '', '__jeansh_git_status:0']);
    if (command.contains('--show-toplevel')) {
      // What the search prints: the repository it found, then git's own
      // listing of that repository's worktrees.
      return Stream.fromIterable([
        _main,
        'worktree $_main',
        'HEAD 1111111',
        'branch refs/heads/main',
        '',
        'worktree $_agent',
        'HEAD 2222222',
        'branch refs/heads/agent',
        '',
      ]);
    }
    final agent = command.contains("-C '$_agent'");
    if (command.contains("'--abbrev-ref'")) {
      return said([agent ? 'agent' : 'main']);
    }
    if (command.contains("'status'")) {
      return said([agent ? ' M lib/agent.dart' : ' M lib/main.dart']);
    }
    if (command.contains("'log'")) {
      return said([
        agent
            ? '2222222\tme\t1 hour ago\tWork in the worktree'
            : '1111111\tme\t2 hours ago\tThe first commit',
      ]);
    }
    return const Stream.empty();
  }
}

/// Lets the git commands finish. Not pumpAndSettle: the progress bar runs
/// while they do.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late _Shell shell;
  late List<GitDiff> opened;

  Future<void> pumpPanel(WidgetTester tester) async {
    shell = _Shell();
    opened = [];
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
        home: GitPage(session: session, onOpenDiff: opened.add),
      ),
    );
    await session.connect(secrets: _NoSecrets());
    await _settle(tester);
  }

  testWidgets('a worktree is in the picker, and picking it shows its own '
      'branch and changes', (tester) async {
    await pumpPanel(tester);
    expect(find.text('main'), findsOneWidget);
    expect(find.text('lib/main.dart'), findsOneWidget);

    await tester.tap(find.text('dev'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('agent-x  worktree of dev').last);
    await _settle(tester);

    expect(find.text('agent'), findsOneWidget);
    expect(find.text('lib/agent.dart'), findsOneWidget);
    expect(find.text('lib/main.dart'), findsNothing);
    expect(shell.ran.last, contains("-C '$_agent'"));
  });
}
