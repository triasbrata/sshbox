import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/settings_page.dart';
import 'package:sshbox/src/ui/terminal_page.dart';
import 'package:sshbox/src/ui/toast.dart';
import 'package:xterm2/xterm.dart';

/// A shell that is up the moment it is asked for, and keeps what the
/// terminal sends the host.
class _Shell implements SessionTransport, TerminalSession {
  final sent = <String>[];

  @override
  final status = ValueNotifier(SessionStatus.connected);

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
  Stream<String> get output => const Stream.empty();

  @override
  void send(String data) => sent.add(data);

  @override
  Future<void> dispose() async {}

  /// resize and failure: nothing to do, nothing to say.
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _NoSecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String? value) async {}

  @override
  Future<void> purgeHost(String hostId) async {}
}

final _desktop = TargetPlatformVariant({
  TargetPlatform.macOS,
  TargetPlatform.linux,
  TargetPlatform.windows,
});
final _phone = TargetPlatformVariant.only(TargetPlatform.android);

Finder _toast(String message) => find.ancestor(
  of: find.text(message),
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is ToastCard && widget.type == ToastificationType.success,
  ),
);

void main() {
  late _Shell shell;
  late LiveSession session;

  /// What went on the system clipboard, one entry a write.
  late List<String?> copied;

  /// What the system clipboard holds, for whoever asks.
  const secret = 'hunter2, copied a minute ago';

  setUp(() {
    copied = [];
    copyOnSelect.value = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String?);
          }
          if (call.method == 'Clipboard.getData') return {'text': secret};
          return null;
        });
  });

  tearDown(() {
    copyOnSelect.value = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    shell = _Shell();
    session = LiveSession(
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
        home: TerminalPage(
          session: session,
          secrets: _NoSecrets(),
          onOpenFile: (_, {line}) {},
          onOpenWeb: (_) {},
          onOpenChat: () {},
          onOpenGit: () {},
          onOpenDiff: (_) {},
          onSaveFileRoot: (_) async {},
        ),
      ),
    );
    await session.connect(secrets: _NoSecrets());
    await tester.pump();
    tester
        .widget<TerminalView>(find.byType(TerminalView))
        .focusNode!
        .requestFocus();
    await tester.pump();
  }

  /// Long enough for a toast to have slid in.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  /// Where on screen the middle of the cell at [column] on [row] is.
  Offset cellAt(WidgetTester tester, int column, [int row = 0]) {
    final render = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .renderTerminal;
    return render.localToGlobal(
      render.getOffset(CellOffset(column, row)) +
          render.cellSize.center(Offset.zero),
    );
  }

  Future<void> mouseDrag(WidgetTester tester, int from, int to) async {
    final mouse = await tester.startGesture(
      cellAt(tester, from),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveTo(cellAt(tester, (from + to) ~/ 2));
    await mouse.moveTo(cellAt(tester, to));
    await mouse.up();
    await settle(tester);
  }

  group("a program's OSC 52", () {
    testWidgets('puts its text on the clipboard, and says so', (tester) async {
      await pumpPage(tester);
      // Claude Code's /copy of a reply longer than xterm2 would read.
      final reply = List.filled(2000, 'git push origin --delete x\n').join();
      session.terminal.write(
        '\x1b]52;c;${base64.encode(utf8.encode(reply))}\x07',
      );
      await settle(tester);

      expect(copied, [reply]);
      expect(_toast('Copied from the terminal'), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('asking for the clipboard is never answered', (tester) async {
      await pumpPage(tester);
      session.terminal.write('\x1b]52;c;?\x07');
      // The C1 form, which xterm2's own parser reads, and its view would
      // answer for a terminal with focus.
      session.terminal.write('\u009d52;c;?\x07');
      await settle(tester);

      final encoded = base64.encode(utf8.encode(secret));
      expect(shell.sent.where((data) => data.contains(encoded)), isEmpty);
      expect(shell.sent.where((data) => data.contains(']52;')), isEmpty);
    });
  });

  group('copy on select', () {
    // Spaced the way Claude Code's renderer spaces it, with cursor moves,
    // which a copy has to turn back into spaces: see selectedText.
    const line = 'git\x1b[Cpush\x1b[Corigin\x1b[C--delete\x1b[Csome-branch';

    testWidgets('copies what the mouse selects as it comes up', (tester) async {
      await pumpPage(tester);
      session.terminal.write(line);
      await tester.pump();

      await mouseDrag(tester, 0, 7);

      expect(copied, ['git push']);
      expect(_toast('Copied'), findsOneWidget);
      await tester.pumpAndSettle();
    }, variant: _desktop);

    testWidgets('copies a double-clicked word, not sending Tab', (
      tester,
    ) async {
      await pumpPage(tester);
      session.terminal.write(line);
      await tester.pump();
      shell.sent.clear();

      for (var i = 0; i < 2; i++) {
        final mouse = await tester.startGesture(
          cellAt(tester, 10),
          kind: PointerDeviceKind.mouse,
        );
        await mouse.up();
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(kDoubleTapTimeout);
      await settle(tester);

      expect(shell.sent, isNot(contains('\t')));
      expect(copied, ['origin']);
      await tester.pumpAndSettle();
    }, variant: _desktop);

    testWidgets('copies nothing when it is turned off', (tester) async {
      copyOnSelect.value = false;
      await pumpPage(tester);
      session.terminal.write(line);
      await tester.pump();

      await mouseDrag(tester, 0, 7);

      expect(copied, isEmpty);
    }, variant: _desktop);

    testWidgets('is never a phone\'s, whose selection has its own Copy', (
      tester,
    ) async {
      await pumpPage(tester);
      session.terminal.write(line);
      await tester.pump();

      await mouseDrag(tester, 0, 7);

      expect(copied, isEmpty);
    }, variant: _phone);
  });
}
