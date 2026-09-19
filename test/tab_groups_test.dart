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
import 'package:sshbox/src/ui/tab_groups.dart';
import 'package:sshbox/src/ui/tabs_shell.dart';
import 'package:xterm2/xterm.dart';

import 'fake_file_browser.dart';

class _NoSecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String? value) async {}

  @override
  Future<void> purgeHost(String hostId) async {}
}

/// A shell that is up the moment it is asked for, and keeps every byte typed
/// into it.
class _Shell implements SessionTransport, TerminalSession, FileBrowseCapable {
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

  @override
  FileBrowser openFileBrowser() => FakeFileBrowser();
}

void main() {
  test('a tab joins beside another, and a group of one is no group', () {
    final groups = TabGroups()..join('b', 'a');
    final group = groups.of('a')!;
    // Gathered where its first pane's tab is.
    expect(groups.slots(['x', 'b', 'a', 'c']), ['x', group, 'c']);

    groups.join('c', 'b');
    expect(group.ids, ['a', 'b', 'c']);
    groups.leave('a');
    expect(group.ids, ['b', 'c']);
    groups.keepOnly(['b']);
    expect(groups.of('b'), isNull);
  });

  testWidgets('grouped tabs show side by side, keys going to the focused pane', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final manager = SessionManager();
    addTearDown(manager.closeAll);
    final one = _Shell();
    final two = _Shell();
    for (final (id, shell) in [('one', one), ('two', two)]) {
      final host = HostProfile(
        id: id,
        label: id,
        host: '10.0.2.2',
        username: 'me',
      );
      await manager
          .open(host, transport: (_, _) => shell)
          .connect(secrets: _NoSecrets());
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
    await tester.pumpAndSettle();
    expect(find.byType(TerminalView), findsOneWidget);

    await tester.longPress(find.text('two'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Group with…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('one').last);
    await tester.pumpAndSettle();

    // Both on screen, the tab brought over holding the keys.
    expect(find.byType(TerminalView), findsNWidgets(2));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(two.sent, ['a']);

    // A finger on the other pane moves the keys there.
    final touch = await tester.startGesture(
      tester.getCenter(find.byType(TerminalView).first),
    );
    await tester.pump();
    await touch.up();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    expect(one.sent, ['b']);
    expect(two.sent, ['a']);

    // So does its chip, without a touch on the pane.
    await tester.tap(find.text('two'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    expect(two.sent, ['a', 'c']);
    expect(one.sent, ['b']);

    await tester.longPress(find.byTooltip('Tab group'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ungroup'));
    await tester.pumpAndSettle();
    expect(find.byType(TerminalView), findsOneWidget);
    expect(find.byTooltip('Tab group'), findsNothing);
  });
}
