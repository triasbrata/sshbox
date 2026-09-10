import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/ui/tabs_shell.dart';

TabRef _shell(WidgetTester tester, String id, String label) {
  // Never connected: the strip only reads the session's name and status.
  final session = LiveSession(
    host: HostProfile(id: id, label: label, host: '10.0.2.2', username: 'me'),
  );
  addTearDown(session.dispose);
  return (session: session, kind: TabKind.terminal, path: null);
}

Future<void> _pump(WidgetTester tester, List<TabRef> tabs) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          TabStrip(
            tabs: tabs,
            activeIndex: 1,
            onSelect: (_, {TabKind kind = TabKind.terminal, String? path}) {},
            onClose: (_) {},
          ),
        ],
      ),
    ),
  ),
);

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
}
