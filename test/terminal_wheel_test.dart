import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/telemetry/app_log.dart';
import 'package:sshbox/src/telemetry/input_log.dart';
import 'package:sshbox/src/ui/tabs_shell.dart';
import 'package:sshbox/src/ui/terminal_page.dart';
import 'package:xterm2/xterm.dart';

/// JEANSH-H: Claude Code's fullscreen view stops scrolling with the wheel
/// while PageUp still works.
///
/// xterm2 hands a program the wheel through a scroll view of its own, which
/// listens to its ScrollPosition. Flutter replaces that position whenever
/// the view's dependencies change, as they do when the terminal is moved in
/// the tree: a tab page, held by a GlobalKey, moving to another slot when a
/// tab before it closes. xterm2 5.2.0 moved only its layout listener to the
/// new position, never the one that turns a scroll into wheel events, so
/// after one move the wheel sent nothing for as long as the terminal lived.
/// third_party/xterm2 carries the fix.

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

/// A host whose tmux answers every command and lays out one pane, %1, at
/// 80x24.
class _TmuxHost implements SessionTransport, TerminalSession, ChannelCapable {
  final _output = StreamController<Uint8List>();
  final commands = <String>[];
  var _number = 0;

  @override
  Future<TerminalSession> connect({
    required HostProfile host,
    required SecretStore secrets,
    required int columns,
    required int rows,
    bool shell = true,
    Map<String, String> environment = const {},
    Future<Map<String, String>> Function(ForwardCapable host)? beforeShell,
  }) async {
    status.value = SessionStatus.connected;
    return this;
  }

  void _say(String line) =>
      _output.add(Uint8List.fromList(utf8.encode('$line\n')));

  @override
  Future<CommandChannel> open(String command) async {
    _say('%session-changed \$1 sshbox-test');
    return (
      output: _output.stream,
      write: (data) {
        for (final command in utf8.decode(data).trim().split('\n')) {
          commands.add(command);
          final number = ++_number;
          _say('%begin 1789000000 $number 1');
          if (command.startsWith('display -p "#{window_id}')) {
            _say('@1\tb25d,80x24,0,0,1\t%1');
          }
          _say('%end 1789000000 $number 1');
        }
      },
      close: () {},
    );
  }

  @override
  final ValueNotifier<SessionStatus> status = ValueNotifier(
    SessionStatus.connecting,
  );
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
}

HostProfile _host(String id, {bool tmux = false}) => HostProfile(
  id: id,
  label: id,
  host: '10.0.2.2',
  username: 'me',
  useTmux: tmux,
);

/// Claude Code's fullscreen view: the alternate screen, the mouse in SGR.
const _claudeModes = '\x1b[?1049h\x1b[?1003h\x1b[?1006h';

final _wheelUp = RegExp(r'^\x1b\[<64;\d+;\d+M$');

Future<void> _wheel(WidgetTester tester, Finder view) async {
  final at = tester.getCenter(view);
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(at));
  await tester.sendEventToBinding(pointer.scroll(const Offset(0, -60)));
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  testWidgets('a terminal moved in the tree still hands the wheel on', (
    tester,
  ) async {
    final terminal = Terminal();
    final sent = <String>[];
    terminal.onOutput = sent.add;
    final key = GlobalKey();
    var wrapped = false;
    late StateSetter setState;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, set) {
            setState = set;
            final view = TerminalView(terminal, key: key);
            return wrapped
                ? Padding(padding: EdgeInsets.zero, child: view)
                : view;
          },
        ),
      ),
    );
    terminal.write(_claudeModes);
    await tester.pump();

    await _wheel(tester, find.byType(TerminalView));
    expect(sent, isNotEmpty);
    expect(sent, everyElement(matches(_wheelUp)));

    sent.clear();
    setState(() => wrapped = true);
    await tester.pump();
    await _wheel(tester, find.byType(TerminalView));
    expect(sent, isNotEmpty, reason: 'the wheel went nowhere after the move');
    expect(sent, everyElement(matches(_wheelUp)));
  });

  testWidgets('closing the tab before a shell leaves its wheel working', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final manager = SessionManager();
    addTearDown(manager.closeAll);
    final first = _Shell();
    final second = _Shell();
    final one = manager.open(_host('host-1'), transport: (_, _) => first);
    final two = manager.open(_host('host-2'), transport: (_, _) => second);
    await one.connect(secrets: _NoSecrets());
    await two.connect(secrets: _NoSecrets());
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
    manager.select(two.id);
    await tester.pump();
    await tester.pump();
    two.terminal.write(_claudeModes);
    await tester.pump();

    Finder view() => find.byWidgetPredicate(
      (widget) => widget is TerminalView && widget.terminal == two.terminal,
    );

    await _wheel(tester, view());
    expect(second.sent, isNotEmpty);
    expect(second.sent, everyElement(matches(_wheelUp)));

    // The tab before it goes, and the page slides one slot to the left.
    second.sent.clear();
    await manager.close(one.id);
    await tester.pump();
    await tester.pump();
    expect(manager.sessions, [two]);

    await _wheel(tester, view());
    expect(
      second.sent,
      isNotEmpty,
      reason: 'the wheel went nowhere once the tab before it closed',
    );
    expect(second.sent, everyElement(matches(_wheelUp)));
    expect(first.sent, isEmpty);
  });

  testWidgets('a tmux pane\'s scroll line names the session and pane, what '
      'was sent and where, and says once when its grid and tmux\'s part', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final host = _TmuxHost();
    final session = LiveSession(
      host: _host('host-1', tmux: true),
      transport: (_, _) => host,
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
    await tester.runAsync(() => session.connect(secrets: _NoSecrets()));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    final pane = session.tmux!.panes.single;
    pane.terminal.write(_claudeModes);
    await tester.pump();
    final view = find.byWidgetPredicate(
      (widget) => widget is TerminalView && widget.terminal == pane.terminal,
    );

    String scrollLine() {
      inputLog.flush();
      return appLog.current.split('\n').last;
    }

    int warnings() =>
        RegExp('scroll: session ${session.id} pane %1 grid')
            .allMatches(appLog.current)
            .length;

    host.commands.clear();
    await _wheel(tester, view);
    expect(
      scrollLine(),
      matches(
        RegExp(
          'scroll wheel → program as wheel '
          '\\(session ${session.id} pane %1, grid 80x24, tmux 80x24\\)'
          '(?: ×\\d+)?, sent [1-9]\\d* at (\\d+);(\\d+)\$',
        ),
      ),
    );
    final at = RegExp(r'at (\d+);(\d+)$').firstMatch(scrollLine())!;
    expect(int.parse(at[1]!), inInclusiveRange(1, 80));
    expect(int.parse(at[2]!), inInclusiveRange(1, 24));
    expect(
      host.commands,
      contains(startsWith('send-keys -t %1 -H 1b 5b 3c 36 34 3b')),
    );
    expect(warnings(), 0, reason: 'grid and tmux agree');

    // This grid apart from tmux's pane: said once, not at every scroll.
    pane.terminal.resize(70, 20);
    await tester.pump();
    await _wheel(tester, view);
    expect(scrollLine(), contains('grid 70x20, tmux 80x24'));
    await _wheel(tester, view);
    expect(warnings(), 1);
    expect(
      appLog.current,
      contains(
        'scroll: session ${session.id} pane %1 grid 70x20 differs '
        'from tmux 80x24',
      ),
    );

    // Together again, and apart again: said again.
    pane.terminal.resize(80, 24);
    await tester.pump();
    await _wheel(tester, view);
    expect(warnings(), 1);
    pane.terminal.resize(60, 20);
    await tester.pump();
    await _wheel(tester, view);
    expect(warnings(), 2);
    expect(appLog.current, isNot(contains('10.0.2.2')));
    await tester.pump(const Duration(seconds: 10));
  });
}
