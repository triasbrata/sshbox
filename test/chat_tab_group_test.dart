import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/files/file_browser.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/chat_page.dart';
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

class _Shell implements SessionTransport, TerminalSession, FileBrowseCapable {
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
}

List<String?> _texts(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((text) => text.data)
    .whereType<String>()
    .toList();

void main() {
  testWidgets('a chat tab groups with a terminal tab', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final manager = SessionManager();
    addTearDown(manager.closeAll);
    const host = HostProfile(
      id: 'box',
      label: 'box',
      host: '10.0.2.2',
      username: 'me',
    );
    final session = manager.open(host, transport: (_, _) => _Shell());
    await session.connect(secrets: _NoSecrets());
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
    manager.openChat(session.id);
    await tester.pumpAndSettle();
    debugPrint('strip: ${_texts(tester)}');

    await tester.tapAt(
      tester.getCenter(find.textContaining('Claude').first),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    debugPrint('menu: ${_texts(tester)}');
    await tester.tap(find.text('Group with…'));
    await tester.pumpAndSettle();
    debugPrint('dialog: ${_texts(tester)}');
    await tester.tap(find.text('box').last);
    await tester.pumpAndSettle();
    debugPrint('after: ${_texts(tester)}');

    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Tab group'), findsOneWidget);
    expect(find.byType(TerminalView), findsOneWidget);
    expect(find.byType(ChatPage), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('from inside the chat page, with another host and a file', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final manager = SessionManager();
    addTearDown(manager.closeAll);
    for (final id in ['box', 'other']) {
      await manager
          .open(
            HostProfile(id: id, label: id, host: '10.0.2.2', username: 'me'),
            transport: (_, _) => _Shell(),
          )
          .connect(secrets: _NoSecrets());
    }
    final box = manager.sessions.firstWhere((s) => s.host.id == 'box');
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
    manager.openFile(box.id, '/home/me/notes.txt');
    await tester.pumpAndSettle();
    manager.openChat(box.id);
    await tester.pumpAndSettle();

    Future<void> group(String target) async {
      await tester.tapAt(
        tester.getCenter(find.byType(ChatPage)),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      debugPrint('menu($target): ${_texts(tester).skip(10).toList()}');
      await tester.tap(find.text('Group with…'));
      await tester.pumpAndSettle();
      debugPrint(
        'dialog($target): '
        '${_texts(tester).skipWhile((t) => t != 'TAB GROUP').toList()}',
      );
      await tester.tap(find.text(target).last);
      await tester.pumpAndSettle();
      debugPrint(
        'after($target): ${_texts(tester).take(8).toList()} '
        'chat=${find.byType(ChatPage).evaluate().length} '
        'terms=${find.byType(TerminalView).evaluate().length} '
        'groups=${find.byTooltip('Tab group').evaluate().length}',
      );
      expect(tester.takeException(), isNull);
    }

    await group('other');
    await group('box · notes.txt');
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
