import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/session/tmux.dart';
import 'package:sshbox/src/ui/tabs_shell.dart';

/// A connect that fails at once, without leaving this isolate.
///
/// The tests below connect only to get a session into its failed state. The
/// real transport now runs on an isolate of its own, whose answers arrive on
/// the real event loop rather than the one `testWidgets` drives, so a widget
/// test that let it start would wait for ever.
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

TabRef _shell(WidgetTester tester, String id, String label) {
  // Never connected: the strip only reads the session's name and status.
  final session = LiveSession(
    host: HostProfile(id: id, label: label, host: '10.0.2.2', username: 'me'),
    transport: (confirmHostKey, onAuthBanner) => _Refused(),
  );
  addTearDown(session.dispose);
  return (session: session, kind: TabKind.terminal, path: null, web: null);
}

Future<void> _pump(
  WidgetTester tester,
  List<TabRef> tabs, {
  void Function(TabRef tab)? onClose,
  void Function(LiveSession session)? onReconnect,
  void Function(String hostId)? onDuplicate,
  Future<void> Function(LiveSession from, String tmuxName)? onAttach,
  Future<void> Function(LiveSession session)? onDetach,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          TabStrip(
            tabs: tabs,
            activeIndex: 1,
            onSelect: (_, {kind = TabKind.terminal, path, web}) {},
            onClose: onClose ?? (_) {},
            onReconnect: onReconnect ?? (_) {},
            onDuplicate: onDuplicate ?? (_) {},
            onAttach: onAttach,
            onDetach: onDetach,
          ),
        ],
      ),
    ),
  ),
);

/// Holds nothing, so a password host fails to connect before a socket is
/// ever opened: an ended session without a network.
class _NoSecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String? value) async {}

  @override
  Future<void> purgeHost(String hostId) async {}
}

TabRef _file(TabRef shell, String path) =>
    (session: shell.session, kind: TabKind.file, path: path, web: null);

TabRef _chat(TabRef shell) =>
    (session: shell.session, kind: TabKind.chat, path: null, web: null);

Rect _pill(WidgetTester tester, String label) => tester.getRect(
  find.ancestor(of: find.text(label), matching: find.byType(Material)).first,
);

void main() {
  // The default 800dp test surface is a wide strip, where "+" would follow
  // the last tab — so these also show which layout wins for each count.

  testWidgets('a lone tab stretches between square end buttons', (
    tester,
  ) async {
    await _pump(tester, [_shell(tester, 'host-1', 'box')]);

    final strip = tester.getRect(find.byType(TabStrip));
    final hosts = tester.getRect(find.byTooltip('Home'));
    final add = tester.getRect(find.byTooltip('New tab'));
    final close = tester.getRect(find.byTooltip('Close box'));
    final pill = _pill(tester, 'box');

    // Square, and level with the tab rather than a loose icon beside it.
    expect(hosts.width, hosts.height);
    expect(add.size, hosts.size);
    expect(pill.height, hosts.height);

    // The pill spans the whole gap, with its close button at the far end.
    expect(pill.left - hosts.right, lessThan(8));
    expect(add.left - pill.right, lessThan(8));
    expect(pill.right - close.right, lessThan(12));
    expect(strip.right - add.right, lessThan(10));
  });

  testWidgets('two tabs keep their width and "+" follows the last one', (
    tester,
  ) async {
    await _pump(tester, [
      _shell(tester, 'host-1', 'box'),
      _shell(tester, 'host-2', 'other'),
    ]);

    final strip = tester.getRect(find.byType(TabStrip));
    final add = tester.getRect(find.byTooltip('New tab'));
    final first = _pill(tester, 'box');
    final last = _pill(tester, 'other');

    expect(first.height, add.height);
    expect(first.width, lessThan(strip.width / 3));
    expect(add.left - last.right, lessThan(8));
    expect(strip.right - add.right, greaterThan(strip.width / 2));
  });

  testWidgets('a shell that has ended offers to reconnect instead of close', (
    tester,
  ) async {
    final tab = _shell(tester, 'host-1', 'box');
    LiveSession? reconnected;
    void onReconnect(LiveSession session) => reconnected = session;

    // Not asked to connect yet — the connect sheet does that — so there is
    // nothing to come back from.
    await _pump(tester, [tab], onReconnect: onReconnect);
    expect(find.byTooltip('Close box'), findsOneWidget);
    expect(find.byTooltip('Reconnect'), findsNothing);

    await tab.session.connect(secrets: _NoSecrets());
    await _pump(tester, [tab], onReconnect: onReconnect);
    expect(find.byTooltip('Close box'), findsNothing);

    await tester.tap(find.byTooltip('Reconnect'));
    expect(reconnected, same(tab.session));
  });

  testWidgets('long-pressing a shell that failed to connect offers to close it', (
    tester,
  ) async {
    final tab = _shell(tester, 'host-1', 'box');
    TabRef? closed;
    void onClose(TabRef tab) => closed = tab;

    // Still live: the close button is right there on the chip.
    await _pump(tester, [tab], onClose: onClose);
    await tester.longPress(find.text('box'));
    await tester.pumpAndSettle();
    expect(find.text('Close tab'), findsNothing);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await tab.session.connect(secrets: _NoSecrets());
    await _pump(tester, [tab], onClose: onClose);
    await tester.longPress(find.text('box'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close tab'));
    await tester.pumpAndSettle();

    expect(closed, same(tab));
  });

  testWidgets('a file tab reads host · file, and gives up the host for room', (
    tester,
  ) async {
    final shell = _shell(tester, 'host-1', 'box');
    await _pump(tester, [shell, _file(shell, '/etc/a.c')]);

    expect(find.byTooltip('Close box · a.c'), findsOneWidget);

    // Not selected, so 110dp of name: too little for both at the test font's
    // size. The host is cut, the file is not.
    RenderParagraph paragraph(Finder text) => tester.renderObject(text);
    expect(paragraph(find.text(' · a.c')).didExceedMaxLines, isFalse);
    expect(paragraph(find.text('box').last).didExceedMaxLines, isTrue);
  });

  testWidgets('a chat tab reads host · Claude, as a file tab does', (
    tester,
  ) async {
    final shell = _shell(tester, 'host-1', 'box');
    await _pump(tester, [shell, _chat(shell)]);

    // Cut the same way as a file tab's name, the host first, which the file
    // tab's test covers: the test font is too wide to measure it here.
    expect(find.byTooltip('Close box · Claude'), findsOneWidget);
  });

  testWidgets('long-pressing a shell offers another session on its host', (
    tester,
  ) async {
    final shell = _shell(tester, 'host-1', 'box');
    String? duplicated;
    await _pump(tester, [
      shell,
      _file(shell, '/etc/a.c'),
    ], onDuplicate: (hostId) => duplicated = hostId);

    // A file tab has nothing of its own to duplicate.
    await tester.longPress(find.text(' · a.c'));
    await tester.pumpAndSettle();
    expect(find.text('Duplicate session'), findsNothing);

    await tester.longPress(find.text('box').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicate session'));
    await tester.pumpAndSettle();

    expect(duplicated, 'host-1');
  });

  testWidgets('a web tab is a globe named by its page, or its host till then', (
    tester,
  ) async {
    final shell = _shell(tester, 'host-1', 'box');
    final page = shell.session.openWeb(Uri.parse('http://box.ts.net:3001/'));
    TabRef web() =>
        (session: shell.session, kind: TabKind.web, path: null, web: page);

    await _pump(tester, [shell, web()]);
    expect(find.byTooltip('Close box.ts.net'), findsOneWidget);
    expect(find.byIcon(Icons.public), findsOneWidget);

    shell.session.updateWeb(page, url: page.url, title: 'Vite + React');
    await _pump(tester, [shell, web()]);
    expect(find.byTooltip('Close Vite + React'), findsOneWidget);

    // Nothing of the shell's: no menu to long-press for.
    await tester.longPress(find.text('Vite + React'));
    await tester.pumpAndSettle();
    expect(find.text('Duplicate session'), findsNothing);
  });

  testWidgets('a shell with no tmux offers neither Attach nor Detach', (
    tester,
  ) async {
    // Detaching a plain shell would be killing it, and listing sessions on a
    // host with no tmux could only fail.
    final tab = _shell(tester, 'host-1', 'box');
    await _pump(
      tester,
      [tab],
      onAttach: (_, _) async {},
      onDetach: (_) async {},
    );
    await tester.longPress(find.text('box'));
    await tester.pumpAndSettle();
    expect(find.text('Duplicate session'), findsOneWidget);
    expect(find.text('Attach to a session…'), findsNothing);
    expect(find.text('Detach'), findsNothing);
  });

  testWidgets(
    "Attach lists the app's own sessions first, each group most recently "
    'busy first, a name as plain text, and one already open not offered',
    (tester) async {
      DateTime at(int minutes) =>
          DateTime.now().subtract(Duration(minutes: minutes));
      TmuxSessionInfo row(
        String name, {
        int wrote = 0,
        int attached = 0,
        int windows = 1,
      }) => TmuxSessionInfo(
        name: name,
        windows: windows,
        attached: attached,
        created: at(600),
        activity: at(wrote),
      );
      const nasty = 'it\'s "x" \$(touch pwned) `id`; y';
      String? picked = 'unset';
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => picked = await showTmuxAttach(
                context,
                host: 'box',
                // Most recently busy first, as parseList sorts them.
                sessions: [
                  row(nasty, wrote: 1, attached: 1),
                  row('sshbox-open', wrote: 2),
                  row('build', wrote: 3, windows: 3),
                  row('sshbox-away', wrote: 5),
                ],
                open: {'sshbox-open'},
              ),
              child: const Text('attach'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('attach'));
      await tester.pumpAndSettle();

      double top(String text) => tester.getTopLeft(find.text(text)).dy;
      final order = [
        "Jeansh's own",
        'sshbox-open',
        'sshbox-away',
        'Started on the host',
        nasty,
        'build',
      ].map(top).toList();
      expect(order, orderedEquals([...order]..sort()));
      expect(find.textContaining('in use'), findsOneWidget);
      expect(find.textContaining('3 windows · started 10h ago · wrote 3m ago'),
          findsOneWidget);
      expect(find.textContaining('open in a tab here'), findsOneWidget);

      // Already a tab: shown, and not offered.
      await tester.tap(find.text('sshbox-open'));
      await tester.pumpAndSettle();
      expect(find.text('sshbox-away'), findsOneWidget);

      await tester.tap(find.text(nasty));
      await tester.pumpAndSettle();
      expect(picked, nasty);
    },
  );
}
