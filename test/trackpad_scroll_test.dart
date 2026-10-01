import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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

  testWidgets('a drag selects and leaves a program that reads the mouse no '
      'half a click, and a click reaches it whole', (tester) async {
    await pumpPage(tester);
    session.terminal.write('hello world this is a line of text here\r\n' * 30);
    // Claude Code's fullscreen view asks for every mouse mode, in SGR.
    session.terminal.write('\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h');
    await tester.pump();
    shell.sent.clear();

    // Held a moment before it moves, as a hand does.
    final box = tester.getRect(find.byType(TerminalView));
    final drag = await tester.startGesture(
      box.center - const Offset(100, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 200));
    for (var i = 0; i < 10; i++) {
      await drag.moveBy(const Offset(20, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await drag.up();
    await tester.pump(const Duration(milliseconds: 500));

    final controller = tester
        .widget<TerminalView>(find.byType(TerminalView))
        .controller!;
    expect(controller.selection, isNotNull);
    // The press went out 100 ms in and its release never did, so Claude Code
    // took a drag of its own as going on for ever.
    expect(shell.sent, isEmpty);

    // A click, away from the selection: both halves, at its cell.
    await tester.tapAt(
      box.topLeft + const Offset(40, 20),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(shell.sent, hasLength(2));
    expect(shell.sent.first, matches(RegExp(r'^\x1b\[<0;\d+;\d+M$')));
    expect(shell.sent.last, shell.sent.first.replaceFirst(RegExp(r'M$'), 'm'));
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
