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

    // xterm2 decides each move alone, so a drag no press began went on
    // sending moves with a button held, and no release ever ended it.
    testWidgets('hears no moves of a drag it was sent no press for: Shift let '
        'go mid-drag, or the right button', (tester) async {
      await pumpPage(tester);
      session.terminal.write(text * 30);
      session.terminal.write('\x1b[?1000h\x1b[?1002h\x1b[?1006h');
      await tester.pump();
      shell.sent.clear();

      final render = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal;
      Offset at(int col) => render.localToGlobal(
        render.getOffset(CellOffset(col, 17)) +
            render.cellSize.center(Offset.zero),
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      final shifted = await tester.startGesture(
        at(2),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 200));
      await shifted.moveTo(at(4));
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      for (var col = 5; col <= 8; col++) {
        await shifted.moveTo(at(col));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await shifted.up();
      await tester.pump(const Duration(milliseconds: 500));
      expect(shown(shell.sent), '');

      final right = await tester.startGesture(
        at(2),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pump(const Duration(milliseconds: 200));
      for (var col = 3; col <= 8; col++) {
        await right.moveTo(at(col));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await right.up();
      await tester.pump(const Duration(milliseconds: 500));
      expect(shown(shell.sent), '');
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('keeps a held drag\'s release through a second pointer', (
      tester,
    ) async {
      await pumpPage(tester);
      session.terminal.write(text * 30);
      session.terminal.write('\x1b[?1000h\x1b[?1002h\x1b[?1006h');
      await tester.pump();
      shell.sent.clear();

      final drag = await heldDrag(tester);
      // A tap on a desktop's touchscreen while the mouse is held.
      final touch = await tester.startGesture(
        tester.getCenter(find.byType(TerminalView)),
        pointer: 9,
      );
      await touch.up();
      await tester.pump(const Duration(milliseconds: 500));
      await drag.up();
      await tester.pump(const Duration(milliseconds: 500));

      final sent = shell.sent.join();
      expect(RegExp(r'\x1b\[<0;\d+;\d+M').allMatches(sent).length, 1);
      expect(RegExp(r'\x1b\[<0;\d+;\d+m').allMatches(sent).length, 1);
      expect(shell.sent.last, '\x1b[<0;7;18m');
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('hears the release of a drag whose pane goes away', (
      tester,
    ) async {
      await pumpPage(tester);
      session.terminal.write(text * 30);
      session.terminal.write('\x1b[?1000h\x1b[?1002h\x1b[?1006h');
      await tester.pump();
      shell.sent.clear();

      final drag = await heldDrag(tester);
      // The tab closed with the button still down.
      await tester.pumpWidget(const SizedBox());
      expect(shell.sent.first, '\x1b[<0;3;18M');
      expect(shell.sent.last, '\x1b[<0;7;18m');
      await drag.up();
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  });

  testWidgets('on Android a tap reaches a program reading clicks as the press '
      'and release xterm2 sent', (tester) async {
    await pumpPage(tester);
    session.terminal.write(text * 30);
    session.terminal.write('\x1b[?1000h\x1b[?1006h');
    await tester.pump();
    shell.sent.clear();

    final render = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .renderTerminal;
    await tester.tapAt(
      render.localToGlobal(
        render.getOffset(const CellOffset(7, 10)) +
            render.cellSize.center(Offset.zero),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(shown(shell.sent), 'ESC[<0;8;11M ESC[<0;8;11m');
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

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

  // macOS and every terminal on it: the second click of a double click, held
  // and dragged, grows the word selection word by word. xterm2 selected
  // characters from the press instead, and from a quick drag never selected
  // the word at all.
  group('in a shell, a held double click', () {
    Offset cellAt(WidgetTester tester, int col, int row) {
      final render = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal;
      return render.localToGlobal(
        render.getOffset(CellOffset(col, row)) +
            render.cellSize.center(Offset.zero),
      );
    }

    String selected(WidgetTester tester) =>
        session.terminal.buffer.getText(controller(tester).selection!);

    Future<TestGesture> secondClick(
      WidgetTester tester, {
      required int col,
      required int clicks,
    }) async {
      for (var i = 1; i < clicks; i++) {
        await tester.tapAt(
          cellAt(tester, col, 10),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(milliseconds: 60));
      }
      return tester.startGesture(
        cellAt(tester, col, 10),
        kind: PointerDeviceKind.mouse,
      );
    }

    for (final hold in [0, 200]) {
      testWidgets('extends the word by words as it is dragged right and '
          'left, held $hold ms before it moves', (tester) async {
        await pumpPage(tester);
        session.terminal.write(text * 30);
        await tester.pump();

        final g = await secondClick(tester, col: 14, clicks: 2);
        await tester.pump(Duration(milliseconds: hold));
        expect(selected(tester), 'this');
        for (var col = 15; col <= 20; col++) {
          await g.moveTo(cellAt(tester, col, 10));
          await tester.pump(const Duration(milliseconds: 16));
        }
        // To the middle of "a": whole words, "this is a".
        expect(selected(tester), 'this is a');
        for (var col = 13; col >= 7; col--) {
          await g.moveTo(cellAt(tester, col, 10));
          await tester.pump(const Duration(milliseconds: 16));
        }
        // Back past the word's start, into "world": it grows leftwards.
        expect(selected(tester), 'world this');
        await g.up();
        await tester.pump(const Duration(milliseconds: 500));
        expect(selected(tester), 'world this');
      }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
    }

    testWidgets('copies what it selected as the button comes up, spaces '
        'kept', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      await pumpPage(tester);
      session.terminal.write(text * 30);
      await tester.pump();

      final g = await secondClick(tester, col: 14, clicks: 2);
      await tester.pump(const Duration(milliseconds: 200));
      await g.moveTo(cellAt(tester, 20, 10));
      await tester.pump(const Duration(milliseconds: 16));
      expect(copied, isNull);
      await g.up();
      await tester.pump(const Duration(milliseconds: 500));
      expect(copied, 'this is a');
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('under a program tracking the mouse, Shift keeps it the '
        "terminal's: the word grows and the program hears nothing", (
      tester,
    ) async {
      await pumpPage(tester);
      session.terminal.write(text * 30);
      session.terminal.write('\x1b[?1000h\x1b[?1002h\x1b[?1006h');
      await tester.pump();
      shell.sent.clear();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      final g = await secondClick(tester, col: 14, clicks: 2);
      await tester.pump(const Duration(milliseconds: 200));
      await g.moveTo(cellAt(tester, 20, 10));
      await tester.pump(const Duration(milliseconds: 16));
      await g.up();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump(const Duration(milliseconds: 500));
      expect(shell.sent, isEmpty);
      expect(selected(tester), 'this is a');
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('lets go of the selection when focus leaves mid-gesture, the '
        'up never coming', (tester) async {
      await pumpPage(tester);
      session.terminal.write(text * 30);
      await tester.pump();

      final g = await secondClick(tester, col: 14, clicks: 2);
      await tester.pump(const Duration(milliseconds: 200));
      expect(selected(tester), 'this');

      // The window blurred with the button down: no up, no cancel.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      // Select all, the menu's, and the clear a tracked press makes, both
      // used to be ignored until the next press.
      controller(tester).clearSelection();
      expect(controller(tester).selection, isNull);
      await g.up();
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('lets go of the gesture when the window is hidden straight '
        'from resumed, as a real minimize on Linux does', (tester) async {
      await pumpPage(tester);
      session.terminal.write(text * 30);
      await tester.pump();

      final g = await secondClick(tester, col: 14, clicks: 2);
      await tester.pump(const Duration(milliseconds: 200));
      expect(selected(tester), 'this');

      // No inactive step between: AppLifecycleListener asserts on this jump.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      // An owned selection ignores a clear; one let go of takes it.
      controller(tester).clearSelection();
      expect(controller(tester).selection, isNull);
      await g.up();
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('a triple click drags by lines', (tester) async {
      await pumpPage(tester);
      session.terminal.write(text * 30);
      await tester.pump();

      final g = await secondClick(tester, col: 14, clicks: 3);
      await tester.pump(const Duration(milliseconds: 200));
      await g.moveTo(cellAt(tester, 20, 12));
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        selected(tester).trimRight().split('\n').length,
        3,
        reason: selected(tester),
      );
      await g.up();
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('then Shift+click, or Shift and a drag, extends the '
        'selection to the cell', (tester) async {
      await pumpPage(tester);
      session.terminal.write(text * 30);
      await tester.pump();

      final g = await secondClick(tester, col: 7, clicks: 2);
      await g.up();
      await tester.pump(const Duration(milliseconds: 500));
      expect(selected(tester), 'world');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      final shift = await tester.startGesture(
        cellAt(tester, 18, 10),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(selected(tester), 'world this is');
      await shift.moveTo(cellAt(tester, 24, 10));
      await tester.pump(const Duration(milliseconds: 16));
      expect(selected(tester), 'world this is a lin');
      await shift.up();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump(const Duration(milliseconds: 500));
      expect(selected(tester), 'world this is a lin');

      // A plain press afterwards starts a selection of its own again.
      final fresh = await tester.startGesture(
        cellAt(tester, 2, 12),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 200));
      await fresh.moveTo(cellAt(tester, 6, 12));
      await tester.pump(const Duration(milliseconds: 16));
      await fresh.up();
      await tester.pump(const Duration(milliseconds: 500));
      expect(selected(tester), 'llo w');
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  });

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

  testWidgets('a lone ⌘ leaves the selection, so ⌘C copies it, under the '
      'kitty protocol Claude Code turns on', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    await pumpPage(tester);
    session.terminal.write(text * 30);
    // Flags 1 and 4, Claude Code's.
    session.terminal.write('\x1b[>5u');
    await tester.pump();
    final drag = await heldDrag(tester);
    await drag.up();
    await tester.pump(const Duration(milliseconds: 500));
    shell.sent.clear();
    copied = null;

    // ⌘ also arms the link key on a Mac.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump(const Duration(milliseconds: 500));

    // xterm2 sent the lone ⌘ as ESC[57444;9u, which counted as typing and
    // let the selection go before C came.
    // Nor a lock key alone.
    await tester.sendKeyEvent(LogicalKeyboardKey.capsLock);
    await tester.sendKeyEvent(LogicalKeyboardKey.capsLock);
    expect(shell.sent, isEmpty);
    expect(copied, 'llo w');
    expect(
      session.terminal.buffer.getText(controller(tester).selection!),
      'llo w',
    );

    // A program that asks for every key, flag 8, still gets a lone ⌘.
    session.terminal.write('\x1b[>13u');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    expect(shell.sent, isNotEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
