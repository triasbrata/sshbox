import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/files/file_browser.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/tabs_shell.dart';
import 'package:sshbox/src/ui/terminal_page.dart';

import 'fake_file_browser.dart';

class _NoSecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String? value) async {}

  @override
  Future<void> purgeHost(String hostId) async {}
}

/// A shell that is up the moment it is asked for, on a host whose files are
/// [FakeFileBrowser]'s, and which keeps every byte typed into it.
class _Shell implements SessionTransport, TerminalSession, FileBrowseCapable {
  final sent = <String>[];

  @override
  Future<TerminalSession> connect({
    required HostProfile host,
    required SecretStore secrets,
    required int columns,
    required int rows,
    bool shell = true,
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

HostProfile _host(String id) =>
    HostProfile(id: id, label: 'box', host: '10.0.2.2', username: 'me');

void main() {
  late SessionManager manager;
  late _Shell shell;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    manager = SessionManager();
    shell = _Shell();
    manager.open(_host('host-1'), transport: shell);
  });

  tearDown(() => manager.closeAll());

  /// The app's one screen over [manager], its shells connected.
  Future<void> pumpTabs(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TabsShell(
          repository: HostRepository(_NoSecrets()),
          secrets: _NoSecrets(),
          sessions: manager,
          onOpenHost: (_) async {},
          pushToken: () => null,
        ),
      ),
    );
    // A shell connects after its page's first frame.
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a tab opened before a page leaves the page as it was', (
    tester,
  ) async {
    final other = manager.open(_host('host-2'), transport: _Shell());
    await pumpTabs(tester);
    State page() => tester.state(
      find.byWidgetPredicate(
        (widget) => widget is TerminalPage && widget.session == other,
        skipOffstage: false,
      ),
    );
    final before = page();

    // Lands between the first shell and the other one, moving it along.
    manager.openFile(manager.sessions.first.id, '/home/me/notes.txt');
    await tester.pumpAndSettle();

    expect(page(), same(before));
  });
}
