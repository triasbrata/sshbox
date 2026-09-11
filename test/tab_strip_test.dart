import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/ui/tabs_shell.dart';

TabRef _shell(WidgetTester tester, String id, String label) {
  // Never connected: the strip only reads the session's name and status.
  final session = LiveSession(
    host: HostProfile(id: id, label: label, host: '10.0.2.2', username: 'me'),
  );
  addTearDown(session.dispose);
  return (session: session, kind: TabKind.terminal, path: null, web: null);
}

Future<void> _pump(
  WidgetTester tester,
  List<TabRef> tabs, {
  void Function(LiveSession session)? onReconnect,
  void Function(String hostId)? onDuplicate,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          TabStrip(
            tabs: tabs,
            activeIndex: 1,
            onSelect: (_, {kind = TabKind.terminal, path, web}) {},
            onClose: (_) {},
            onReconnect: onReconnect ?? (_) {},
            onDuplicate: onDuplicate ?? (_) {},
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
    final hosts = tester.getRect(find.byTooltip('Hosts'));
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

    // Not asked to connect yet — the page does that after its first frame —
    // so there is nothing to come back from.
    await _pump(tester, [tab], onReconnect: onReconnect);
    expect(find.byTooltip('Close box'), findsOneWidget);
    expect(find.byTooltip('Reconnect'), findsNothing);

    await tab.session.connect(secrets: _NoSecrets());
    await _pump(tester, [tab], onReconnect: onReconnect);
    expect(find.byTooltip('Close box'), findsNothing);

    await tester.tap(find.byTooltip('Reconnect'));
    expect(reconnected, same(tab.session));
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
}
