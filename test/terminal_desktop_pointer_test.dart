import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/terminal_page.dart';
import 'package:xterm2/xterm.dart';

class _NoSecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String? value) async {}
  @override
  Future<void> purgeHost(String hostId) async {}
}

class _Shell implements SessionTransport, TerminalSession {
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
}

void main() {
  late _Shell shell;
  late LiveSession session;

  Future<void> pumpPage(WidgetTester tester) async {
    shell = _Shell();
    session = LiveSession(
      host: const HostProfile(
        id: 'h',
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
          onOpenFile: (path, {line}) {},
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
  }

  Future<void> trackpad(WidgetTester tester, Offset by) async {
    final g = await tester.startGesture(
      tester.getCenter(find.byType(TerminalView)),
      kind: PointerDeviceKind.trackpad,
    );
    for (var i = 0; i < 10; i++) {
      await g.panZoomUpdate(
        tester.getCenter(find.byType(TerminalView)),
        pan: by * (i + 1).toDouble(),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.panZoomEnd();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('a trackpad scrolls the scrollback on a Mac', (tester) async {
    await pumpPage(tester);
    for (var i = 0; i < 200; i++) {
      session.terminal.write('line $i\r\n');
    }
    await tester.pump();
    final scroll = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(TerminalView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    final bottom = scroll.position.pixels;

    await trackpad(tester, const Offset(0, 20));
    expect(scroll.position.pixels, lessThan(bottom));
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('a trackpad scroll reaches a program that reads the mouse at '
      'the pointer, not at the last click', (tester) async {
    await pumpPage(tester);
    // Claude Code's fullscreen view: the alternate screen, the mouse in SGR.
    session.terminal.write('\x1b[?1049h\x1b[?1000h\x1b[?1006h');
    await tester.pump();

    final view = tester.state<TerminalViewState>(find.byType(TerminalView));
    final render = view.renderTerminal;
    String cellOf(Offset global) {
      final cell = render.getCellOffset(render.globalToLocal(global));
      return '${cell.x + 1};${cell.y + 1}';
    }

    // A click on the bottom row, where Claude Code's prompt is.
    final box = tester.getRect(find.byType(TerminalView));
    final prompt = Offset(box.center.dx, box.bottom - 12);
    await tester.tapAt(prompt, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 500));
    shell.sent.clear();

    await trackpad(tester, const Offset(0, 20));
    expect(shell.sent, isNotEmpty);
    // Every wheel at the cell under the pointer. It went to the click's cell,
    // the prompt, which Claude Code does not scroll.
    expect(shell.sent, everyElement('\x1b[<64;${cellOf(box.center)}M'));
    expect(cellOf(box.center), isNot(cellOf(prompt)));
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  String shown(List<String> sent) =>
      sent.map((each) => each.replaceAll('\x1b', 'ESC')).join(' ');

  Future<TestGesture> heldDrag(WidgetTester tester, {int row = 17}) async {
    final render = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .renderTerminal;
    Offset at(int col) => render.localToGlobal(
      render.getOffset(CellOffset(col, row)) +
          render.cellSize.center(Offset.zero),
    );
    final drag = await tester.startGesture(
      at(2),
      kind: PointerDeviceKind.mouse,
    );
    // Held a moment before it moves, as a hand does.
    await tester.pump(const Duration(milliseconds: 200));
    for (var col = 3; col <= 6; col++) {
      await drag.moveTo(at(col));
      await tester.pump(const Duration(milliseconds: 16));
    }
    return drag;
  }

  Future<void> doubleClick(WidgetTester tester) async {
    final render = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .renderTerminal;
    final word = render.localToGlobal(
      render.getOffset(const CellOffset(7, 10)) +
          render.cellSize.center(Offset.zero),
    );
    for (var i = 0; i < 2; i++) {
      await tester.tapAt(word, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.pump(const Duration(milliseconds: 500));
  }

  TerminalController controller(WidgetTester tester) =>
      tester.widget<TerminalView>(find.byType(TerminalView)).controller!;

  const text = 'hello world this is a line of text here\r\n';

  group('a program tracking drags, as Claude Code does', () {
    testWidgets('gets a held drag whole: press, moves, release', (
      tester,
    ) async {
      await pumpPage(tester);
      session.terminal.write(text * 30);
      // Button-event tracking, in SGR.
      session.terminal.write('\x1b[?1000h\x1b[?1002h\x1b[?1006h');
      await tester.pump();
      shell.sent.clear();

      final drag = await heldDrag(tester);
      await drag.up();
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        shown(shell.sent),
        'ESC[<0;3;18M ESC[<32;4;18M ESC[<32;5;18M ESC[<32;6;18M '
        'ESC[<32;7;18M ESC[<0;7;18m',
      );
      // The program selects: none of xterm2's over it.
      expect(controller(tester).selection, isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('hears a double click as two whole clicks, and a drag after '
        'it', (tester) async {
      await pumpPage(tester);
      session.terminal.write(text * 30);
      // Every mode, as Claude Code's fullscreen view asks.
      session.terminal.write('\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h');
      await tester.pump();
      shell.sent.clear();

      await doubleClick(tester);
      // xterm2 sent a release for a single tap only, so the second click's
      // never went: Claude Code was left dragging, and nothing selected
      // after a double click.
      expect(
        shown(shell.sent),
        [for (var i = 0; i < 2; i++) 'ESC[<0;8;11M ESC[<0;8;11m'].join(' '),
      );
      expect(controller(tester).selection, isNull);

      shell.sent.clear();
      final drag = await heldDrag(tester);
      await drag.up();
      await tester.pump(const Duration(milliseconds: 500));
      expect(shell.sent.first, 'ESC[<0;3;18M'.replaceAll('ESC', '\x1b'));
      expect(shell.sent.last, 'ESC[<0;7;18m'.replaceAll('ESC', '\x1b'));
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('leaves Shift+drag to the terminal\'s own selection', (
      tester,
    ) async {
      await pumpPage(tester);
      session.terminal.write(text * 30);
      session.terminal.write('\x1b[?1000h\x1b[?1002h\x1b[?1006h');
      await tester.pump();
      shell.sent.clear();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      final drag = await heldDrag(tester);
      await drag.up();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump(const Duration(milliseconds: 500));

      expect(shell.sent, isEmpty);
      expect(
        session.terminal.buffer.getText(controller(tester).selection!),
        'llo w',
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  });

  testWidgets('a program reading clicks alone gets no half a click from a '
      'drag, which selects, and a click whole', (tester) async {
    await pumpPage(tester);
    session.terminal.write(text * 30);
    // Normal tracking: clicks, no drags.
    session.terminal.write('\x1b[?1000h\x1b[?1006h');
    await tester.pump();
    shell.sent.clear();

    final drag = await heldDrag(tester);
    await drag.up();
    await tester.pump(const Duration(milliseconds: 500));
    // The press went out 100 ms in and its release never did.
    expect(shell.sent, isEmpty);
    expect(
      session.terminal.buffer.getText(controller(tester).selection!),
      'llo w',
    );

    await doubleClick(tester);
    expect(
      shown(shell.sent),
      [for (var i = 0; i < 2; i++) 'ESC[<0;8;11M ESC[<0;8;11m'].join(' '),
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('in a shell, a drag after a double click selects, from the word '
      'and away from it', (tester) async {
    await pumpPage(tester);
    session.terminal.write(text * 30);
    await tester.pump();

    await doubleClick(tester);
    expect(
      session.terminal.buffer.getText(controller(tester).selection!),
      'world',
    );
    for (final row in [10, 17]) {
      final drag = await heldDrag(tester, row: row);
      await drag.up();
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        session.terminal.buffer.getText(controller(tester).selection!),
        'llo w',
      );
    }
    expect(shell.sent, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
