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

final _desktop = TargetPlatformVariant({
  TargetPlatform.linux,
  TargetPlatform.macOS,
});

void main() {
  late SessionManager manager;
  late Map<String, _Shell> shells;
  late List<String> duplicated;

  /// The shell with a connected tab for each of [ids], the last one showing.
  Future<void> pump(WidgetTester tester, List<String> ids) async {
    SharedPreferences.setMockInitialValues({});
    manager = SessionManager();
    addTearDown(manager.closeAll);
    shells = {};
    duplicated = [];
    for (final id in ids) {
      final shell = shells[id] = _Shell();
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
          onOpenHost: (id) async => duplicated.add(id),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> rightClick(WidgetTester tester, Offset at) async {
    await tester.tapAt(
      at,
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
  }

  Finder item(String text) => find.widgetWithText(PopupMenuItem<VoidCallback>, text);

  testWidgets(
    "a right-click in a terminal gives its own items, then the tab's",
    (tester) async {
      await pump(tester, ['box']);
      await rightClick(tester, tester.getCenter(find.byType(TerminalView)));

      expect(item('Paste'), findsOneWidget);
      expect(item('Duplicate session'), findsOneWidget);
      expect(find.byType(PopupMenuDivider), findsOneWidget);
      // The terminal's own come first.
      expect(
        tester.getTopLeft(item('Paste')).dy,
        lessThan(tester.getTopLeft(item('Duplicate session')).dy),
      );

      await tester.tap(item('Duplicate session'));
      await tester.pumpAndSettle();
      expect(duplicated, ['box']);
    },
    variant: _desktop,
  );

  testWidgets(
    'a program reading the mouse gets the right-click, unless Shift is held',
    (tester) async {
      await pump(tester, ['box']);
      tester
          .widget<TerminalView>(find.byType(TerminalView))
          .terminal
          .write('\x1b[?1000h');
      await tester.pump();
      final at = tester.getCenter(find.byType(TerminalView));

      await rightClick(tester, at);
      expect(find.text('Duplicate session'), findsNothing);
      expect(shells['box']!.sent.join(), contains('\x1b[M"'));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await rightClick(tester, at);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(item('Paste'), findsOneWidget);
      expect(item('Duplicate session'), findsOneWidget);
    },
    variant: _desktop,
  );

  testWidgets(
    "a right-click in a file tab opens the tab's menu, and a file-tree row "
    'keeps its own',
    (tester) async {
      await pump(tester, ['box', 'other']);
      // The file tab's menu is its grouping, there being more than one tab.
      final box = manager.sessions.firstWhere((s) => s.host.id == 'box');
      manager.openFile(box.id, '/home/me/notes.txt');
      await tester.pumpAndSettle();

      await rightClick(tester, tester.getCenter(find.byType(AppBar).last));
      expect(item('Group with…'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      // Back on the shell, a row in its files drawer.
      manager.select(box.id);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Browse files'));
      await tester.pumpAndSettle();
      await rightClick(tester, tester.getCenter(find.text('dev').last));
      expect(find.text('Set as root'), findsOneWidget);
      expect(find.text('Duplicate session'), findsNothing);
      expect(find.text('Group with…'), findsNothing);
    },
    variant: _desktop,
  );

  testWidgets(
    "a right-click in a group's other pane focuses it and opens its menu",
    (tester) async {
      await pump(tester, ['one', 'two']);
      await tester.longPress(find.text('two'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Group with…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('one').last);
      await tester.pumpAndSettle();
      expect(find.byType(TerminalView), findsNWidgets(2));

      // "two" holds the keys; "one" is the pane not focused.
      await rightClick(
        tester,
        tester.getCenter(find.byType(TerminalView).first),
      );
      expect(item('Take out of group'), findsOneWidget);
      await tester.tap(item('Duplicate session'));
      await tester.pumpAndSettle();
      expect(duplicated, ['one']);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      expect(shells['one']!.sent, contains('b'));
      expect(shells['two']!.sent, isNot(contains('b')));
    },
    variant: _desktop,
  );

  testWidgets(
    "a right-click that focuses a group's pane leaves the keys with its menu, "
    'and a second one on that pane opens one menu that stays open',
    (tester) async {
      await pump(tester, ['one', 'two']);
      await tester.longPress(find.text('two'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Group with…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('one').last);
      await tester.pumpAndSettle();
      final pane = tester.getCenter(find.byType(TerminalView).first);
      // Two menus would be two of each, the one below still on screen.
      Finder all(String text) => find.text(text, skipOffstage: false);

      // "two" holds the keys: this focuses "one", and its menu takes Escape.
      await rightClick(tester, pane);
      expect(all('Take out of group'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(all('Take out of group'), findsNothing);
      expect(shells['one']!.sent.join(), isNot(contains('\x1b')));

      // "one" holds the keys now: right-click it again.
      await tester.tapAt(
        pane,
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(all('Take out of group'), findsOneWidget);
      expect(all('Paste'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(all('Take out of group'), findsNothing);

      // And the keys are back with the pane clicked.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      expect(shells['one']!.sent, contains('b'));
      expect(shells['two']!.sent, isNot(contains('b')));
    },
    variant: _desktop,
  );

  testWidgets('on Android a right-click in a tab opens nothing new', (
    tester,
  ) async {
    await pump(tester, ['box']);
    await rightClick(tester, tester.getCenter(find.byType(TerminalView)));
    expect(find.text('Duplicate session'), findsNothing);
    expect(find.text('Paste'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
