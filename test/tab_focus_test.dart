import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/files/file_browser.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/tabs_shell.dart';
import 'package:sshbox/src/ui/terminal_page.dart';
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

HostProfile _host(String id) =>
    HostProfile(id: id, label: 'box', host: '10.0.2.2', username: 'me');

void main() {
  late SessionManager manager;
  late _Shell shell;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    manager = SessionManager();
    shell = _Shell();
    manager.open(_host('host-1'), transport: (_, _) => shell);
  });

  tearDown(() => manager.closeAll());

  /// The app's one screen over [manager], its shells connected.
  Future<void> pumpTabs(WidgetTester tester) async {
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
    // Each page's first frame, and the focus its terminal takes after it.
    await tester.pump();
    await tester.pump();
  }

  /// Picks notes.txt in the files drawer, the way a finger does.
  Future<void> openFile(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Browse files'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('notes.txt'));
    await tester.pumpAndSettle();
  }

  /// The shell's terminal, found whether its tab is showing or not.
  FocusNode terminal(WidgetTester tester) => tester
      .widget<TerminalView>(find.byType(TerminalView, skipOffstage: false))
      .focusNode!;

  testWidgets('keys typed once a file opens go to its editor, not the shell', (
    tester,
  ) async {
    await pumpTabs(tester);
    await openFile(tester);
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!
      ..selection = const CodeLineSelection.collapsed(index: 0, offset: 0);
    await tester.pump();

    // A letter the shell would have sent on, and an arrow only the editor
    // moves on: the drawer closing hands nothing back to the terminal.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    // The moved caret restarts its blink on a timer; let it run out.
    await tester.pump(const Duration(seconds: 1));

    expect(editor.selection.extentIndex, 1);
    expect(shell.sent, isEmpty);
  });

  testWidgets('a hidden shell cannot take focus', (tester) async {
    await pumpTabs(tester);
    await openFile(tester);

    terminal(tester).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);

    expect(terminal(tester).hasFocus, isFalse);
    expect(shell.sent, isEmpty);
  });

  testWidgets('a tab shown again takes the keys back, without the keyboard', (
    tester,
  ) async {
    await pumpTabs(tester);
    await openFile(tester);
    tester.testTextInput.log.clear();

    await tester.tap(find.byIcon(Icons.terminal));
    await tester.pumpAndSettle();
    expect(terminal(tester).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(shell.sent, ['a']);

    await tester.tap(find.byIcon(Icons.description_outlined));
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'file editor text',
    );

    expect(
      tester.testTextInput.log.map((call) => call.method),
      isNot(contains('TextInput.show')),
    );
  });

  testWidgets('a shell whose focus fell to nothing takes the next key back', (
    tester,
  ) async {
    await pumpTabs(tester);

    // One hardware key shuts the soft keyboard's IME connection for the run
    // of the app (see TerminalTextInput), so from here the terminal's focus
    // is the only input path there is.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(shell.sent, ['a']);

    // Focus parked on the enclosing scope and handed to no one: what Flutter
    // leaves behind whenever a focused node goes away, and what a page is
    // left with when nothing puts the focus back. With the connection shut
    // there is now no input path at all — the terminal types nothing, and the
    // user's only way out is to leave the app and come back.
    terminal(tester).unfocus();
    await tester.pump();
    expect(terminal(tester).hasFocus, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    expect(shell.sent, ['a', 'b']);
  });

  testWidgets('a tab opened before a page leaves the page as it was', (
    tester,
  ) async {
    final other = manager.open(_host('host-2'), transport: (_, _) => _Shell());
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
