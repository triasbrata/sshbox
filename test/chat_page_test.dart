import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'fake_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/chat/claude_chat.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/ui/tabs_shell.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/chat_page.dart';
import 'package:sshbox/src/ui/settings_page.dart'
    show TerminalSettings, terminalSettings, terminalStyleOf;
import 'package:sshbox/src/ui/text_size.dart';
import 'package:sshbox/src/ui/code_languages.dart';
import 'package:sshbox/src/ui/file_editor_page.dart' show PictureView;
import 'package:sshbox/src/ui/mermaid_view.dart';
import 'package:sshbox/src/ui/settings_page.dart' show chatEnterSends;
import 'package:sshbox/src/ui/terminal_schemes.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:sshbox/src/ui/tui.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'fake_web_view.dart';

/// Takes every link it is handed and remembers it: what would have gone to
/// the phone's browser, or to whatever app answers the link's scheme.
class _Launcher extends UrlLauncherPlatform {
  final opened = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    opened.add(url);
    return true;
  }
}

/// What the app put on the clipboard, in place of the phone's own.
List<String> _useFakeClipboard() {
  final copied = <String>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      copied.add((call.arguments as Map)['text'] as String);
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return copied;
}

class _NoSecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String? value) async {}

  @override
  Future<void> purgeHost(String hostId) async {}
}

/// A host that is up at once and can run a command beside the shell — which
/// is all a chat needs of a session.
class _Shell
    implements
        SessionTransport,
        TerminalSession,
        ChannelCapable,
        TerminalChannelCapable {
  /// What was typed into each terminal opened on the host.
  final typed = <List<String>>[];

  @override
  Future<CommandChannel> openTerminal(
    String command, {
    int columns = 120,
    int rows = 40,
  }) async {
    commands.add(command);
    final keys = <String>[];
    typed.add(keys);
    final screen = StreamController<Uint8List>();
    // `claude attach` drawing its input line.
    scheduleMicrotask(() => screen.add(Uint8List.fromList(utf8.encode(' ❯ '))));
    return (
      output: screen.stream,
      write: (Uint8List data) => keys.add(utf8.decode(data)),
      close: () => unawaited(screen.close()),
    );
  }

  /// Every command started on the host, and the pipes each one was given.
  final commands = <String>[];
  final written = <String>[];

  /// A channel of its own per command, as the host gives one: the chat opens
  /// a second when it picks a session up, and the first one's is over.
  final _channels = <StreamController<Uint8List>>[];

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

  /// What `claude agents --json` answers, when a test sets one.
  String? listing;

  /// What the CLI answers `initialize` with: its slash commands.
  String slashListing = '${jsonEncode({
    'type': 'control_response',
    'response': {
      'response': {
        'commands': [
          {
            'name': 'model',
            'description': 'Set the AI model for Claude Code',
            'builtin': true,
          },
          {
            'name': 'compact',
            'description': 'Free up context by summarizing the conversation',
            'builtin': true,
          },
        ],
      },
    },
  })}\n';

  /// What finding an interactive session's tmux pane answers: none, unless a
  /// test puts it in one.
  String pane = 'sshbox:no pane\n';

  /// What was written to each command that typed into a pane.
  final paneTyped = <String>[];

  /// What `claude --bg` prints, as it printed it on a real host: the short
  /// id of the session it started.
  String background =
      'backgrounded · \x1b[36m9e1f2a3b\x1b[39m · nginx look\n'
      '\x1b[2m  claude attach 9e1f2a3b    open in this terminal\x1b[22m\n';

  /// What the history command answers: the transcript's size, then its end.
  /// A session that has said nothing, unless a test says otherwise.
  String history = '0\n';

  /// When set, the next history read waits for it, as a slow host makes it
  /// wait.
  Future<void>? historyArrives;

  /// A whole transcript on the host, where a test gives one: the history
  /// command then gets its size and its end, as a real host hands them over,
  /// and a read of an earlier part the bytes it asks for.
  Uint8List? transcript;

  Uint8List _fromTranscript(Uint8List all, String command) {
    if (command.contains('wc -c')) {
      final from = math.max(0, all.length - ClaudeChat.historyLimit);
      return Uint8List.fromList([
        ...utf8.encode('${all.length}\n'),
        ...all.sublist(from),
      ]);
    }
    int number(String pattern) =>
        int.parse(RegExp(pattern).firstMatch(command)!.group(1)!);
    final from = number(r'tail -c \+(\d+)') - 1;
    return all.sublist(from, from + number(r'head -c (\d+)'));
  }

  /// The running session's transcript as it grows, once something follows
  /// it.
  StreamController<Uint8List>? follow;

  /// The session writing one more line to its transcript.
  void adds(Map<String, Object?> line) =>
      follow!.add(Uint8List.fromList(utf8.encode('${jsonEncode(line)}\n')));

  /// What the session's task store holds, as the host prints it: one line a
  /// task. Empty, and the list is what the transcript made of it.
  String tasksOut = '';

  @override
  Future<CommandChannel> open(String command) async {
    commands.add(command);
    if (command.contains('/tasks')) {
      return (
        output: Stream.value(Uint8List.fromList(utf8.encode(tasksOut))),
        write: (Uint8List data) {},
        close: () {},
      );
    }
    // Before the rest: tmux's finder has a ` -f ` of its own.
    if (command.contains('list-panes')) {
      final typing = command.contains('load-buffer');
      return (
        output: Stream.value(
          Uint8List.fromList(
            utf8.encode(typing ? 'sshbox:pasted\nsshbox:typed %4\n' : pane),
          ),
        ),
        write: (Uint8List data) => paneTyped.add(utf8.decode(data)),
        close: () {},
      );
    }
    if (command.contains('control_request')) {
      return (
        output: Stream.value(Uint8List.fromList(utf8.encode(slashListing))),
        write: (Uint8List data) {},
        close: () {},
      );
    }
    if (command.contains(' --bg ')) {
      return (
        output: Stream.value(Uint8List.fromList(utf8.encode(background))),
        write: (Uint8List data) {},
        close: () {},
      );
    }
    if (command.contains(' -f ')) {
      final controller = StreamController<Uint8List>();
      follow = controller;
      return (
        output: controller.stream,
        write: (Uint8List data) {},
        close: () {},
      );
    }
    final all = transcript;
    if (all != null && command.contains('.jsonl')) {
      return (
        output: Stream.value(_fromTranscript(all, command)),
        write: (Uint8List data) {},
        close: () {},
      );
    }
    if (command.contains('.jsonl')) {
      final bytes = Uint8List.fromList(utf8.encode(history));
      final arrives = historyArrives;
      historyArrives = null;
      return (
        output: arrives == null
            ? Stream.value(bytes)
            : Stream.fromFuture(arrives.then((_) => bytes)),
        write: (Uint8List data) {},
        close: () {},
      );
    }
    final rows = listing;
    if (rows != null && command.contains('agents --json')) {
      // One shot: the listing, then the command is over.
      return (
        output: Stream.value(Uint8List.fromList(utf8.encode(rows))),
        write: (Uint8List data) {},
        close: () {},
      );
    }
    final output = StreamController<Uint8List>();
    _channels.add(output);
    return (
      output: output.stream,
      write: (Uint8List data) => written.add(utf8.decode(data)),
      close: output.close,
    );
  }

  /// One event from Claude, as the process writes it, down the channel it is
  /// talking on now.
  void event(Map<String, dynamic> event) => _channels.last.add(
    Uint8List.fromList(utf8.encode('${jsonEncode(event)}\n')),
  );

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
}

/// The end of a session's transcript, as the host hands it over.
String _history(List<Map<String, Object?>> lines) {
  final body = lines.map(jsonEncode).join('\n');
  return '${utf8.encode(body).length}\n$body\n';
}

final _nightlyHistory = _history([
  {'type': 'mode'},
  {
    'type': 'user',
    'message': {'role': 'user', 'content': 'is the nightly build green?'},
  },
  {
    'type': 'assistant',
    'message': {
      'role': 'assistant',
      'content': [
        {'type': 'text', 'text': 'It failed at the lint step.'},
      ],
    },
  },
  // The turn is over, as a real transcript says once it is.
  {'type': 'system', 'subtype': 'turn_duration', 'durationMs': 9120},
]);

/// Where the conversation is scrolled to: its list, not the sidebar's.
ScrollPosition _conversationAt(WidgetTester tester) => tester
    .widget<CustomScrollView>(find.byType(CustomScrollView))
    .controller!
    .position;

/// Lets a pick-up run out. Closing the drawer, reading the history and
/// starting Claude are futures, not frames, so settling the frames alone
/// returns while they are in flight; this takes turns between the two until
/// both are quiet. Frames are pumped for a while rather than settled: a
/// session mid-turn spins its progress line for as long as the turn runs.
Future<void> _settlePickUp(WidgetTester tester) async {
  for (var turn = 0; turn < 8; turn++) {
    await _frames(tester);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  await tester.pump();
}

/// The reader scrolling the conversation with a mouse wheel by [dy] (negative
/// is up): the reader's own move, as against the program's jumpTo, which
/// the chat does not take for the reader.
Future<void> _wheel(WidgetTester tester, double dy) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(
    pointer.hover(tester.getCenter(find.byType(CustomScrollView))),
  );
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  await tester.pump();
}

/// What [WidgetTester.pumpAndSettle] does, less the wait for every animation
/// to stop: a second of frames, enough for a drawer or a scroll to finish.
Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 60; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// A session on the host whose process has finished, as `--all` lists it.
Map<String, Object?> _finished(String id, String name, {int started = 0}) => {
  'id': id,
  'cwd': '/srv/app',
  'kind': 'background',
  'startedAt': started,
  'sessionId': '$id-0000-4000-8000-000000000000',
  'name': name,
  'state': 'done',
};

/// Picks the finished session [name] from the list, on a phone's drawer:
/// it is continued in place, by a Claude of this chat's own.
Future<void> _continue(WidgetTester tester, String name) async {
  await tester.tap(find.text('SESSIONS ON THIS HOST'));
  await _settlePickUp(tester);
  await tester.tap(find.text(name));
  await _settlePickUp(tester);
}

const _host = HostProfile(
  id: 'host-1',
  label: 'box',
  host: '10.0.2.2',
  username: 'me',
  fileRoot: '/srv/app',
);

void main() {
  // "tab di session chat ketika di click kanan ada menu untuk merge dengan
  // tab lain": a session in the sidebar is no tab, so a right-click on it
  // must not reach the tab's menu, while the message area's still does.
  testWidgets("a right-click on a session in the sidebar is not the tab's", (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final shell = _Shell()
      ..listing = jsonEncode([_finished('aaaa0001', 'nightly build')]);
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());
    var tabMenus = 0;
    await tester.pumpWidget(
      MaterialApp(
        // As the tab shell wraps every page: a right-click nothing deeper
        // took opens the tab's menu.
        home: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onSecondaryTapUp: (_) => tabMenus++,
          child: Scaffold(body: ChatPage(session: session)),
        ),
      ),
    );
    await _settlePickUp(tester);
    Future<void> rightClick(Finder at) async {
      await tester.tapAt(
        tester.getCenter(at),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
    }

    await rightClick(find.text('nightly build'));
    await rightClick(find.text('Sessions on this host'));
    expect(tabMenus, 0);
    // Nothing picked up by it either.
    expect(shell.commands.where((c) => c.contains(' -f ')), isEmpty);

    await rightClick(find.textContaining('starts a new session'));
    expect(tabMenus, 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('a new chat starts nothing on the host until its first '
      'message, which starts a background session there and watches it', (
    tester,
  ) async {
    final shell = _Shell()
      ..listing = jsonEncode([
        {
          'pid': 7,
          'id': '9e1f2a3b',
          'cwd': '/srv/app',
          'kind': 'background',
          'sessionId': '9e1f2a3b-0000-4000-8000-000000000000',
          'name': 'nginx look',
          'status': 'busy',
          'state': 'working',
        },
      ])
      ..history = _history([
        {
          'type': 'user',
          'message': {'role': 'user', 'content': 'why is nginx slow?'},
        },
      ]);
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatPage(session: session)),
      ),
    );
    await _settlePickUp(tester);

    // Only the list is asked for: no Claude of its own, no session.
    expect(shell.commands.where((c) => !c.contains('agents --json')), isEmpty);
    // Nothing said yet, so the tab says where Claude will run, and how.
    expect(find.textContaining('/srv/app'), findsOneWidget);
    expect(find.textContaining('starts a new session'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).decoration!.hintText,
      'Start a new chat…',
    );

    await tester.enterText(find.byType(TextField), 'why is nginx slow?');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await _settlePickUp(tester);

    // Started as a background session, in the files' root; how the message
    // and the path are quoted is claude_chat_test's, through a real shell.
    final started = shell.commands.singleWhere((c) => c.contains(' --bg '));
    expect(started, contains('/srv/app'));
    expect(shell.commands.any((c) => c.contains('stream-json')), isFalse);
    // Then watched, like any session running there, and typed into.
    expect(
      shell.commands.lastWhere((c) => c.contains(' -f ')),
      contains('9e1f2a3b-0000-4000-8000'),
    );
    expect(find.text('why is nginx slow?'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).decoration!.hintText,
      'Message “nginx look”…',
    );
    // And asked for again, so the list has the session just started.
    expect(
      shell.commands.where((c) => c.contains('agents --json --all')),
      hasLength(2),
    );
  });

  testWidgets('a finished session continued here takes what is typed, and '
      'draws what comes back', (tester) async {
    final shell = _Shell()
      ..listing = jsonEncode([_finished('cf58d27a', 'Zsh config fix')]);
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatPage(session: session)),
      ),
    );
    await tester.pump();
    await _continue(tester, 'Zsh config fix');
    // Continued in place by a Claude of this chat's own, resumed.
    expect(shell.commands.last, contains('--resume'));

    await tester.enterText(find.byType(TextField), 'check the nginx log');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    expect(
      jsonDecode(shell.written.single.trim()),
      containsPair('type', 'user'),
    );
    // The user's own words, on screen, and the field cleared for the next.
    expect(find.text('check the nginx log'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    // A turn is running: nothing else may be sent until it ends.
    expect(find.textContaining('Working… (0s)'), findsOneWidget);

    shell.event({
      'type': 'assistant',
      'message': {
        'content': [
          {'type': 'text', 'text': 'Looking now.'},
          {
            'type': 'tool_use',
            'id': 'toolu_01',
            'name': 'Bash',
            'input': {'command': 'tail -n 50 error.log'},
          },
        ],
      },
    });
    await tester.pump();
    await tester.pump();

    expect(find.text('Looking now.'), findsOneWidget);
    expect(find.text('Bash'), findsOneWidget);
    expect(find.text('tail -n 50 error.log'), findsOneWidget);

    // Its last message says the turn is over before its result comes: still
    // busy, and still said to be working, not starting a session.
    shell.event({
      'type': 'assistant',
      'message': {
        'stop_reason': 'end_turn',
        'content': [
          {'type': 'text', 'text': 'Done looking.'},
        ],
      },
    });
    await tester.pump();
    await tester.pump();
    expect(find.text('Claude is working…'), findsOneWidget);

    shell.event({'type': 'result', 'subtype': 'success'});
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Working…'), findsNothing);
    expect(find.text('Claude is working…'), findsNothing);
  });

  testWidgets('a / lists the host\'s commands, and one that opens a dialog '
      'is neither offered nor sent', (tester) async {
    final shell = _Shell()
      ..listing = jsonEncode([_finished('cf58d27a', 'Zsh config fix')]);
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ChatPage(session: session))),
    );
    await tester.pump();
    await _continue(tester, 'Zsh config fix');

    // Read from the host the first time the list opens, and only then.
    expect(shell.commands.where((c) => c.contains('initialize')), isEmpty);
    await tester.enterText(find.byType(TextField), '/');
    await tester.pump();
    await tester.pump();
    expect(shell.commands.where((c) => c.contains('initialize')), hasLength(1));
    expect(find.text('/compact'), findsOneWidget);
    expect(find.text('/model'), findsNothing);

    // Typed whole and sent anyway, it is refused, and nothing reaches Claude.
    await tester.enterText(find.byType(TextField), '/model opus');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    expect(shell.written, isEmpty);
    expect(find.textContaining('run it in the terminal'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '/model opus',
    );

    await tester.enterText(find.byType(TextField), '/compact');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    expect(shell.written, hasLength(1));
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('on a phone with the keyboard up the list fits, and /con '
      'still shows /context', (tester) async {
    // The CI emulator's screen: 320 by 568, with Gboard over the bottom.
    tester.view
      ..physicalSize = const Size(320, 568)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final shell = _Shell()
      ..listing = jsonEncode([_finished('cf58d27a', 'Zsh config fix')])
      ..slashListing = '${jsonEncode({
        'type': 'control_response',
        'response': {
          'response': {
            'commands': [
              for (final name in ['compact', 'context', 'code-review'])
                {
                  'name': name,
                  'description': 'What /$name does, said at some length so '
                      'it cannot fit a phone',
                  'argumentHint': '<optional custom summarization '
                      'instructions>',
                  'builtin': true,
                },
              {
                'name': 'a-skill-whose-name-is-much-too-long-for-a-phone',
                'description': 'A skill',
              },
            ],
          },
        },
      })}\n';
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ChatPage(session: session))),
    );
    await tester.pump();
    // A chat with nothing in it yet, the keyboard up: what it says scrolls
    // rather than overflowing, as its button shrinks rather than overflowing.
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.pump();
    tester.view.resetViewInsets();
    await tester.pump();
    await _continue(tester, 'Zsh config fix');

    // The keyboard comes up as the box is typed into. An overflow is an
    // error the test framework fails on by itself.
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.pump();
    await tester.enterText(find.byType(TextField), '/');
    await tester.pump();
    await tester.pump();
    expect(find.text('/compact').hitTestable(), findsOneWidget);

    await tester.enterText(find.byType(TextField), '/con');
    await tester.pump();
    expect(find.text('/context').hitTestable(), findsOneWidget);
    // The list sits above the box and inside the room the keyboard leaves.
    final list = tester.getRect(find.text('/context'));
    expect(list.bottom, lessThanOrEqualTo(568 - 260));
    expect(
      list.bottom,
      lessThanOrEqualTo(tester.getRect(find.byType(TextField)).top),
    );
  });

  testWidgets('at the largest content text size the list\'s rows still fit '
      'on a phone', (tester) async {
    addTearDown(() => terminalSettings.value = TerminalSettings.defaultStyle);
    tester.view
      ..physicalSize = const Size(320, 568)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final shell = _Shell()
      ..listing = jsonEncode([_finished('cf58d27a', 'Zsh config fix')])
      ..slashListing = '${jsonEncode({
        'type': 'control_response',
        'response': {
          'response': {
            'commands': [
              for (final name in ['compact', 'context'])
                {
                  'name': name,
                  'description': 'What /$name does',
                  'argumentHint': '<instructions>',
                  'builtin': true,
                },
            ],
          },
        },
      })}\n';
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ChatPage(session: session))),
    );
    await tester.pump();
    await _continue(tester, 'Zsh config fix');
    terminalSettings.value = terminalStyleOf('monospace', 32);
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.pump();

    // An overflow in a row is an error the test framework fails on.
    await tester.enterText(find.byType(TextField), '/con');
    await tester.pump();
    await tester.pump();
    expect(find.text('/context'), findsOneWidget);
  });

  testWidgets('an unconnected session says so rather than starting anything', (
    tester,
  ) async {
    final shell = _Shell();
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatPage(session: session)),
      ),
    );
    await tester.pump();

    expect(shell.commands, isEmpty);
    expect(find.text('Connect this session first'), findsOneWidget);
  });

  testWidgets('what is typed while the chat is not ready is kept, Send waiting '
      'until it is', (tester) async {
    final shell = _Shell();
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ChatPage(session: session))),
    );
    await tester.pump();

    bool sendOn() =>
        tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send))
            .onPressed !=
        null;
    // Not ready, as between turns or before the connection is up: the box
    // still takes the text, and Send waits.
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    await tester.enterText(find.byType(TextField), 'next question');
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'next question',
    );
    expect(sendOn(), isFalse);

    // Ready again: the same text, and Send on.
    await session.connect(secrets: _NoSecrets());
    await tester.pump();
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'next question',
    );
    expect(sendOn(), isTrue);
  });

  testWidgets('the sessions on the host are offered, and one still running '
      'is watched live, updating by itself', (tester) async {
    final shell = _Shell()
      ..history = _nightlyHistory
      ..listing = jsonEncode([
        {
          'pid': 4079548,
          'id': '81badf4a',
          'cwd': '/srv/app',
          'kind': 'background',
          'startedAt': DateTime.now()
              .subtract(const Duration(hours: 2))
              .millisecondsSinceEpoch,
          'sessionId': '81badf4a-7e9f-4f01-b098-6968dbe5f070',
          'name': 'the nightly build',
          'status': 'idle',
          'state': 'done',
        },
        {
          'pid': 1259765,
          'cwd': '/home/me',
          'kind': 'interactive',
          'sessionId': '456d3c0e-2a17-4943-a2f4-6cdd25893a19',
          'name': 'dev-e0',
          'status': 'idle',
        },
      ]);
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatPage(session: session)),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('SESSIONS ON THIS HOST'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Both kinds are listed, each saying what it is and where it runs.
    expect(find.text('the nightly build'), findsOneWidget);
    expect(find.text('dev-e0'), findsOneWidget);
    expect(find.textContaining('at a terminal'), findsOneWidget);
    expect(find.textContaining('2h ago'), findsOneWidget);

    await tester.tap(find.text('the nightly build'));
    await _settlePickUp(tester);

    // What was already said in it is there: the conversation it had, not a
    // blank tab on a session Claude remembers.
    expect(find.text('is the nightly build green?'), findsOneWidget);
    expect(find.text('It failed at the lint step.'), findsOneWidget);
    // Its process is alive, so it is followed rather than resumed or
    // copied, and the tab says so.
    expect(shell.commands.last, contains(' -f '));
    expect(
      shell.commands.last,
      contains('81badf4a-7e9f-4f01-b098-6968dbe5f070'),
    );
    expect(find.textContaining('Watching'), findsOneWidget);

    // What it says next shows by itself, without picking it again.
    shell.adds({
      'type': 'assistant',
      'message': {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'Lint fixed, build running again.'},
        ],
      },
    });
    await _settlePickUp(tester);
    expect(find.text('Lint fixed, build running again.'), findsOneWidget);
  });

  testWidgets('a host that cannot list its sessions says what it said', (
    tester,
  ) async {
    final shell = _Shell()..listing = "error: unknown command 'agents'";
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatPage(session: session)),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('SESSIONS ON THIS HOST'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining("unknown command 'agents'"), findsOneWidget);
  });

  testWidgets('on a tablet the sessions are a sidebar beside the chat, '
      'marking the one showing', (tester) async {
    tester.view
      ..physicalSize = const Size(1280, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final shell = _Shell()
      ..history = _nightlyHistory
      ..listing = jsonEncode([
        {
          'pid': 4079548,
          'id': '81badf4a',
          'cwd': '/srv/app',
          'kind': 'background',
          'sessionId': '81badf4a-7e9f-4f01-b098-6968dbe5f070',
          'name': 'the nightly build',
          'status': 'idle',
        },
      ]);
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatPage(session: session)),
      ),
    );
    await tester.pumpAndSettle();

    // In view without asking: no sheet, no drawer, and no button in the empty
    // tab to show what is already showing.
    expect(find.text('the nightly build'), findsOneWidget);
    expect(find.text('SESSIONS ON THIS HOST'), findsNothing);

    await tester.tap(find.text('the nightly build'));
    await _settlePickUp(tester);

    // Still beside the chat, with the one picked marked, and its
    // conversation drawn next to it.
    final row = tester
        .widget<TuiChatSessionList>(find.byType(TuiChatSessionList))
        .sessions
        .singleWhere((session) => session.title == 'the nightly build');
    expect(row.selected, isTrue);
    expect(find.text('is the nightly build green?'), findsOneWidget);

    // The button beside the box hides it, for room to read, and brings it
    // back.
    await tester.tap(find.byTooltip('Hide the sessions on this host'));
    await tester.pumpAndSettle();
    expect(find.text('the nightly build'), findsNothing);
    await tester.tap(find.byTooltip('Sessions on this host'));
    await tester.pumpAndSettle();
    expect(find.text('the nightly build'), findsOneWidget);
  });

  testWidgets('what is typed into a session being watched shows as sending, '
      'then as said once the session has it', (tester) async {
    tester.view
      ..physicalSize = const Size(1280, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final shell = _Shell()
      ..history = _nightlyHistory
      ..listing = jsonEncode([
        {
          'pid': 4079548,
          'id': '81badf4a',
          'cwd': '/srv/app',
          'kind': 'background',
          'sessionId': '81badf4a-7e9f-4f01-b098-6968dbe5f070',
          'name': 'the nightly build',
          'status': 'idle',
          'state': 'done',
        },
      ]);
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatPage(session: session)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('the nightly build'));
    await _settlePickUp(tester);

    // Open to typing while watching, and says where it goes.
    expect(
      tester.widget<TextField>(find.byType(TextField)).decoration!.hintText,
      'Message “the nightly build”…',
    );
    await tester.enterText(find.byType(TextField), 'run it once more');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    expect(find.text('Sending…'), findsOneWidget);

    for (var turn = 0; turn < 12; turn++) {
      await tester.pump(const Duration(milliseconds: 250));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    // Into the running session itself, through its attach.
    expect(shell.commands.any((command) => command.contains('attach')), isTrue);
    expect(shell.typed.single.first, 'run it once more');
    expect(find.text('Sending…'), findsOneWidget);

    shell.adds({
      'type': 'user',
      'message': {'role': 'user', 'content': 'run it once more'},
    });
    await _settlePickUp(tester);

    expect(find.text('Sending…'), findsNothing);
    expect(find.text('run it once more'), findsOneWidget);
  });

  for (final wide in [true, false]) {
    testWidgets('the sessions are still there when the '
        '${wide ? 'sidebar' : 'drawer'} is hidden and shown again, without '
        'asking the host again', (tester) async {
      tester.view
        ..physicalSize = wide ? const Size(1280, 800) : const Size(400, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final shell = _Shell()
        ..listing = jsonEncode([
          {
            'pid': 4079548,
            'id': '81badf4a',
            'cwd': '/srv/app',
            'kind': 'background',
            'sessionId': '81badf4a-7e9f-4f01-b098-6968dbe5f070',
            'name': 'the nightly build',
            'status': 'idle',
            'state': 'done',
          },
        ]);
      final session = LiveSession(host: _host, transport: (_, _) => shell);
      addTearDown(session.dispose);
      await session.connect(secrets: _NoSecrets());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ChatPage(session: session)),
        ),
      );
      await _settlePickUp(tester);

      Future<void> show() async {
        await tester.tap(find.byTooltip('Sessions on this host').first);
        await _settlePickUp(tester);
      }

      Future<void> hide() async {
        if (wide) {
          await tester.tap(find.byTooltip('Hide the sessions on this host'));
        } else {
          // Tapped beside the drawer, as a thumb does.
          await tester.tapAt(const Offset(390, 400));
        }
        await _settlePickUp(tester);
      }

      if (!wide) await show();
      expect(find.text('the nightly build'), findsOneWidget);

      await hide();
      expect(find.text('the nightly build'), findsNothing);
      // Hidden, the list is not asked for, however long it stays hidden.
      final asked = shell.commands.where((c) => c.contains('agents')).length;
      await _settlePickUp(tester);
      expect(shell.commands.where((c) => c.contains('agents')).length, asked);

      // Shown, its rows are there at once, not after asking the host: it
      // only goes on to ask while on show, to keep each row's mark current.
      await tester.tap(find.byTooltip('Sessions on this host').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('the nightly build'), findsOneWidget);
      expect(shell.commands.where((c) => c.contains('agents')).length, asked);
    });
  }

  testWidgets('a session pinned in claude agents is pinned in the sidebar, '
      'first', (tester) async {
    tester.view
      ..physicalSize = const Size(1280, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Map<String, Object?> bg(String id, String name) => {
      'pid': 1,
      'id': id,
      'cwd': '/srv',
      'kind': 'background',
      'sessionId': '$id-0000-0000-0000-000000000000',
      'name': name,
      'status': 'idle',
      'state': 'done',
    };
    final shell = _Shell()
      ..listing =
          '${jsonEncode([bg('aaaa1111', 'not pinned'), bg('bbbb2222', 'pinned')])}'
          '\n--- pins\n["bbbb2222"]\n';
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatPage(session: session)),
      ),
    );
    await tester.pumpAndSettle();

    final rows = tester
        .widget<TuiChatSessionList>(find.byType(TuiChatSessionList))
        .sessions;
    expect([for (final row in rows) row.title], ['pinned', 'not pinned']);
    // termul's pinned mark, on the first alone.
    expect(rows.first.kind, TuiChatSessionKind.pinned);
    expect(find.text('★'), findsOneWidget);
  });

  testWidgets('a tool row opens to its input and its result', (tester) async {
    final shell = _Shell()
      ..listing = jsonEncode([_finished('cf58d27a', 'Zsh config fix')]);
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatPage(session: session)),
      ),
    );
    await tester.pump();
    await _continue(tester, 'Zsh config fix');
    await tester.enterText(find.byType(TextField), 'check the nginx log');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    shell.event({
      'type': 'assistant',
      'message': {
        'content': [
          {
            'type': 'tool_use',
            'id': 'toolu_09',
            'name': 'Bash',
            'input': {'command': 'tail -n 50 error.log'},
          },
        ],
      },
    });
    shell.event({
      'type': 'user',
      'message': {
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'toolu_09',
            'content': '3 upstream timeouts',
          },
        ],
      },
    });
    // The turn ends, so nothing is left spinning.
    shell.event({'type': 'result', 'subtype': 'success'});
    await tester.pump();
    await tester.pump();

    // The tile keeps its open-or-shut bool in page storage under its own
    // key; the scroll views inside once stored their offset under the same
    // one and read that bool back as a double, which threw — and a release
    // build draws a widget that threw as nothing.
    await tester.tap(find.text('Bash'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(
      find.widgetWithText(SelectableText, 'tail -n 50 error.log'),
      findsOneWidget,
    );
    expect(find.text('3 upstream timeouts'), findsOneWidget);
  });

  testWidgets('all of chat follows the content size and not the UI size: '
      'the sessions, a message, a tool row, a code block and the composer', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(1280, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    terminalSettings.value = terminalStyleOf('monospace', 26);
    addTearDown(() => terminalSettings.value = TerminalSettings.defaultStyle);
    final shell = _Shell()
      ..listing = jsonEncode([_finished('cf58d27a', 'Zsh config fix')]);
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());

    // The app's root as it is, at the largest UI size.
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const UiTextScaler(TextScaler.noScaling, 1.6)),
          child: child!,
        ),
        home: Scaffold(body: ChatPage(session: session)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zsh config fix'));
    await _settlePickUp(tester);
    await tester.enterText(find.byType(TextField), 'check the nginx log');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    shell.event({
      'type': 'assistant',
      'message': {
        'content': [
          {'type': 'text', 'text': 'Here it is:\n\n```sh\ntail error.log\n```'},
          {
            'type': 'tool_use',
            'id': 'toolu_09',
            'name': 'Bash',
            'input': {'command': 'tail -n 50 error.log'},
          },
        ],
      },
    });
    shell.event({'type': 'result', 'subtype': 'success'});
    await tester.pump();
    await tester.pump();

    double at13(Finder finder) =>
        MediaQuery.textScalerOf(tester.element(finder.first)).scale(13);
    // 26 against the default 13: twice, whatever the UI's 160% says.
    expect(at13(find.text('Zsh config fix')), 26, reason: 'the sessions');
    expect(
      at13(find.textContaining('check the nginx log', findRichText: true)),
      26,
      reason: 'a message',
    );
    expect(at13(find.text('Bash')), 26, reason: 'a tool row');
    expect(
      at13(find.textContaining('tail error.log', findRichText: true)),
      26,
      reason: 'a code block',
    );
    expect(at13(find.byType(TextField)), 26, reason: 'the composer');
  });

  group('an opened tool row', () {
    /// Picks a finished session up, has Claude call [name] with [input] and
    /// get [result] back, and opens the row.
    Future<void> opened(
      WidgetTester tester,
      String name,
      Map<String, Object?> input, {
      Object result = 'done',
      String? titled,
    }) async {
      final shell = _Shell()
        ..listing = jsonEncode([_finished('cf58d27a', 'Zsh config fix')]);
      final session = LiveSession(host: _host, transport: (_, _) => shell);
      addTearDown(session.dispose);
      await session.connect(secrets: _NoSecrets());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ChatPage(session: session)),
        ),
      );
      await tester.pump();
      await _continue(tester, 'Zsh config fix');
      await tester.enterText(find.byType(TextField), 'go on');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      shell.event({
        'type': 'assistant',
        'message': {
          'content': [
            {'type': 'tool_use', 'id': 'toolu_1', 'name': name, 'input': input},
          ],
        },
      });
      shell.event({
        'type': 'user',
        'message': {
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'toolu_1',
              'content': result,
            },
          ],
        },
      });
      shell.event({'type': 'result', 'subtype': 'success'});
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text(titled ?? name));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
    }

    /// The tree node, folded or leaf, whose line reads exactly [text].
    Finder node(String text) => find.byWidgetPredicate(
      (w) =>
          (w is RichText && w.text.toPlainText() == text) ||
          (w is EditableText && w.controller.text == text),
    );

    /// The text of the selectable block that reads exactly [text].
    TextSpan spanOf(WidgetTester tester, String text) => tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((widget) => widget.textSpan)
        .whereType<TextSpan>()
        .firstWhere((span) => span.toPlainText() == text);

    /// What the opened row shows, as against the one line beside the
    /// tool's name.
    Finder shown(String text) => find.widgetWithText(SelectableText, text);

    Finder shownContaining(String text) => find.descendant(
      of: find.byType(SelectableText),
      matching: find.textContaining(text),
    );

    /// Nothing in the opened row drawn as the JSON it came in.
    void noJson(WidgetTester tester) {
      for (final field in tester.widgetList<EditableText>(
        find.descendant(
          of: find.byType(SelectableText),
          matching: find.byType(EditableText),
        ),
      )) {
        expect(field.controller.text, isNot(contains('": "')));
        expect(field.controller.text, isNot(contains(r'\n')));
      }
    }

    testWidgets('every code box has a Copy code button holding exactly its '
        'text: a command, a file written and a result', (tester) async {
      final copied = _useFakeClipboard();
      const command = "grep -n 'error' app.log\ntail -n 5 app.log";
      await opened(tester, 'Bash', {'command': command}, result: 'a\nb');
      final buttons = find.byTooltip('Copy code');
      expect(buttons, findsNWidgets(2));
      await tester.tap(buttons.at(0));
      await tester.pump();
      await tester.tap(buttons.at(1));
      await tester.pump();
      expect(copied, [command, 'a\nb']);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('Write and Edit copy the file and the diff as shown', (
      tester,
    ) async {
      final copied = _useFakeClipboard();
      const content = 'import os\n\ndef main():\n    pass\n';
      await opened(tester, 'Write', {
        'file_path': '/srv/a.py',
        'content': content,
      });
      await tester.tap(find.byTooltip('Copy code').first);
      await tester.pump();
      expect(copied, [content]);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('Edit copies its diff with the - and + lines', (tester) async {
      final copied = _useFakeClipboard();
      await opened(tester, 'Edit', {
        'file_path': '/srv/n.conf',
        'old_string': 'listen 80;',
        'new_string': 'listen 8080;',
      });
      await tester.tap(find.byTooltip('Copy code').first);
      await tester.pump();
      expect(copied, ['- listen 80;\n+ listen 8080;']);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('Bash: the command as a command, what it is for above it', (
      tester,
    ) async {
      await opened(tester, 'Bash', {
        'command': "grep -n 'error' app.log\ntail -n 5 app.log",
        'description': 'Look for errors in the log',
        'timeout': 60000,
      });
      noJson(tester);
      expect(
        shown("grep -n 'error' app.log\ntail -n 5 app.log"),
        findsOneWidget,
      );
      expect(shown('Look for errors in the log'), findsOneWidget);
      // What the drawing does not take is still there.
      expect(shown('timeout: 60000'), findsOneWidget);
    });

    testWidgets('Write: the path, then the file with its own newlines, '
        'coloured as the editor colours it', (tester) async {
      const content = 'import os\n\n\ndef main():\n    print("hi")\n';
      await opened(tester, 'Write', {
        'file_path': '/srv/app/tool.py',
        'content': content,
      });
      noJson(tester);
      expect(shown('/srv/app/tool.py'), findsOneWidget);
      final span = spanOf(tester, content);
      final colours = <Color?>{};
      span.visitChildren((child) {
        colours.add(child.style?.color);
        return true;
      });
      expect(colours.length, greaterThan(1));
    });

    testWidgets('Edit and MultiEdit: what went out in red and what came in '
        'in green, the editor\'s colours for a diff', (tester) async {
      await opened(tester, 'MultiEdit', {
        'file_path': '/srv/app/nginx.conf',
        'edits': [
          {'old_string': 'listen 80;', 'new_string': 'listen 8080;'},
          {
            'old_string': 'gzip off;',
            'new_string': 'gzip on;\ngzip_types text/css;',
          },
        ],
      });
      noJson(tester);
      expect(shown('/srv/app/nginx.conf'), findsOneWidget);
      const diff =
          '- listen 80;\n+ listen 8080;\n\n'
          '- gzip off;\n+ gzip on;\n+ gzip_types text/css;\n';
      final colourOf = <String, Color?>{};
      spanOf(tester, diff).visitChildren((child) {
        if (child case TextSpan(:final text?)) {
          colourOf[text] = child.style?.color;
        }
        return true;
      });
      final styles = codeColoursFor(Brightness.light);
      expect(colourOf['- listen 80;\n'], styles['deletion']!.color);
      expect(colourOf['+ listen 8080;\n'], styles['addition']!.color);
      expect(colourOf['+ gzip_types text/css;\n'], styles['addition']!.color);
    });

    testWidgets('Edit: one edit, and what else it said', (tester) async {
      await opened(tester, 'Edit', {
        'file_path': '/srv/app/a.txt',
        'old_string': 'one',
        'new_string': 'two',
        'replace_all': true,
      });
      noJson(tester);
      expect(shown('- one\n+ two\n'), findsOneWidget);
      expect(shown('replace_all: true'), findsOneWidget);
    });

    testWidgets('Read: the path, and the lines read', (tester) async {
      await opened(tester, 'Read', {
        'file_path': '/srv/app/main.go',
        'offset': 10,
        'limit': 50,
      });
      expect(shown('/srv/app/main.go · lines 10–59'), findsOneWidget);
      expect(find.textContaining('offset'), findsNothing);
    });

    testWidgets('Grep and Glob: the pattern on its own, where it looked '
        'after it', (tester) async {
      await opened(tester, 'Grep', {
        'pattern': r'TODO\(\w+\)',
        'path': '/srv/app',
        'glob': '*.dart',
      });
      noJson(tester);
      expect(shown(r'TODO\(\w+\)'), findsOneWidget);
      expect(shown('path: /srv/app\nglob: *.dart'), findsOneWidget);
    });

    testWidgets('TodoWrite: a checklist', (tester) async {
      await opened(tester, 'TodoWrite', {
        'todos': [
          {'content': 'Read the log', 'status': 'completed'},
          {'content': 'Fix the config', 'status': 'in_progress'},
          {'content': 'Reload nginx', 'status': 'pending'},
        ],
      });
      noJson(tester);
      expect(shown('Read the log'), findsOneWidget);
      expect(shown('Reload nginx'), findsOneWidget);
      expect(find.byIcon(Icons.check_box), findsOneWidget);
      expect(
        find.byIcon(Icons.indeterminate_check_box_outlined),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);
    });

    testWidgets('a tool it does not know: its input a tree, text as it '
        'reads', (tester) async {
      await opened(tester, 'mcp__tracker__file_issue', {
        'title': 'Nightly is red',
        'body': 'Lint fails.\nSee the log.',
        'labels': ['ci'],
      }, titled: 'tracker · file_issue');
      noJson(tester);
      expect(node('title: Nightly is red'), findsOneWidget);
      expect(node('body: Lint fails.\nSee the log.'), findsOneWidget);
      expect(node('labels: Array(1)'), findsOneWidget);
    });

    testWidgets('an MCP tool is titled server · tool, with what it is about',
        (tester) async {
      await opened(tester, 'mcp__tracker__file_issue', {
        'title': 'Nightly is red',
      }, titled: 'tracker · file_issue');
      expect(find.text('tracker · file_issue'), findsOneWidget);
      expect(find.text('mcp__tracker__file_issue'), findsNothing);
      expect(find.text('Nightly is red'), findsOneWidget);
    });

    testWidgets('a SendMessage is titled → who: what, never as JSON', (
      tester,
    ) async {
      await opened(tester, 'SendMessage', {
        'to': 'macos double-click select',
        'summary': 'dblclick passed review',
        'message': 'All good. Merge it.',
      });
      expect(
        find.text('→ macos double-click select: dblclick passed review'),
        findsOneWidget,
      );
      expect(find.textContaining('{'), findsNothing);
    });

    testWidgets('a nested input opens and closes a node at a tap', (
      tester,
    ) async {
      await opened(tester, 'Mystery', {
        'meta': {
          'inner': {'deep': 'value'},
        },
      });
      expect(node('meta: Object(1)'), findsOneWidget);
      expect(node('deep: value'), findsNothing);
      await tester.tap(node('meta: Object(1)'));
      await tester.pump();
      await tester.tap(node('inner: Object(1)'));
      await tester.pump();
      expect(node('deep: value'), findsOneWidget);
      await tester.tap(node('meta: Object(1)'));
      await tester.pump();
      expect(node('deep: value'), findsNothing);
    });

    testWidgets('a long string is folded behind show more, and copies whole', (
      tester,
    ) async {
      final copied = _useFakeClipboard();
      final long = List.filled(50, 'abcdefghij').join();
      await opened(tester, 'Mystery', {'note': long});
      expect(node('note: ${long.substring(0, 200)}…'), findsOneWidget);
      await tester.tap(find.text('show more'));
      await tester.pump();
      expect(node('note: $long'), findsOneWidget);
      expect(find.text('show less'), findsOneWidget);
      await tester.tap(find.byTooltip('Copy code').first);
      await tester.pump();
      expect(jsonDecode(copied.single), {'note': long});
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a JSON result of a tool with no renderer is a tree too', (
      tester,
    ) async {
      await opened(tester, 'Mystery', {
        'q': 'x',
      }, result: jsonEncode({'rows': [1, 2], 'ok': true}));
      expect(node('rows: Array(2)'), findsOneWidget);
      expect(node('ok: true'), findsOneWidget);
    });

    testWidgets('shapes it did not expect throw nothing', (tester) async {
      await opened(tester, 'Mystery', {
        'a': null,
        'b': [
          1,
          {'c': []},
          null,
        ],
        'd': {},
        'e': 3.5,
        'f': {r'$oid': 'x'},
        'g': '',
      }, result: '{"cut off');
      expect(node('d: {}'), findsOneWidget);
      expect(find.text('{"cut off'), findsOneWidget);
    });

    testWidgets('a known tool of a shape it did not expect still shows '
        'everything, and throws nothing', (tester) async {
      await opened(tester, 'MultiEdit', {
        'file_path': 42,
        'edits': [
          {'old_string': 'a', 'new_string': 'b'},
          'not an edit',
        ],
      });
      expect(shownContaining('file_path: 42'), findsOneWidget);
      expect(shownContaining('"not an edit"'), findsOneWidget);
      expect(shownContaining('- a'), findsNothing);
    });

    testWidgets('a result that came back as a JSON string reads as its text', (
      tester,
    ) async {
      await opened(tester, 'Bash', {
        'command': 'cat notes',
      }, result: jsonEncode('first line\nsecond line'));
      expect(shown('first line\nsecond line'), findsOneWidget);
    });
  });

  testWidgets('the list has the finished sessions too, under their own '
      'heading, after the pinned and the running ones', (tester) async {
    tester.view
      ..physicalSize = const Size(1280, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final shell = _Shell()
      ..listing =
          '${jsonEncode([
            _finished('aaaa0001', 'finished long ago', started: 100),
            {'pid': 1, 'id': 'bbbb0002', 'cwd': '/srv', 'kind': 'background', 'startedAt': 200, 'sessionId': 'bbbb0002-0000-4000-8000-000000000000', 'name': 'running', 'status': 'idle', 'state': 'done'},
            _finished('cccc0003', 'finished lately', started: 300),
            _finished('dddd0004', 'pinned and finished', started: 50),
          ])}'
          '\n--- pins\n["dddd0004"]\n';
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatPage(session: session)),
      ),
    );
    await _settlePickUp(tester);

    expect(shell.commands.first, contains('agents --json --all'));
    final order = [
      for (final text in tester.widgetList<Text>(
        find.descendant(of: find.byType(ListView), matching: find.byType(Text)),
      ))
        // The headings are termul's section labels, drawn in capitals.
        if (const {
          'PINNED',
          'RUNNING',
          'FINISHED (2)',
          'pinned and finished',
          'running',
          'finished lately',
          'finished long ago',
        }.contains(text.data))
          text.data,
    ];
    expect(order, [
      'PINNED',
      'pinned and finished',
      'RUNNING',
      'running',
      'FINISHED (2)',
      'finished lately',
      'finished long ago',
    ]);
    expect(find.textContaining('finished ·'), findsNWidgets(3));
  });

  testWidgets('the sidebar says what picking a session does now: watched live '
      'and typed into, not copied', (tester) async {
    tester.view
      ..physicalSize = const Size(1280, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final shell = _Shell()..listing = '[]';
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatPage(session: session)),
      ),
    );
    await _settlePickUp(tester);

    expect(find.textContaining('copy'), findsNothing);
    expect(find.textContaining('nothing said here reaches it'), findsNothing);
    expect(find.textContaining('watched live'), findsOneWidget);
    expect(find.textContaining('what you send goes into it'), findsOneWidget);
  });

  testWidgets('New chat leaves the session being watched running, and the '
      'next message starts another', (tester) async {
    tester.view
      ..physicalSize = const Size(1280, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final shell = _Shell()
      ..history = _nightlyHistory
      ..listing = jsonEncode([
        {
          'pid': 4079548,
          'id': '81badf4a',
          'cwd': '/srv/app',
          'kind': 'background',
          'sessionId': '81badf4a-7e9f-4f01-b098-6968dbe5f070',
          'name': 'the nightly build',
          'status': 'idle',
          'state': 'done',
        },
      ]);
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatPage(session: session)),
      ),
    );
    await _settlePickUp(tester);
    await tester.tap(find.text('the nightly build'));
    await _settlePickUp(tester);
    expect(find.text('It failed at the lint step.'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('New chat'));
    await _settlePickUp(tester);

    // A new one: nothing of the old on screen, and the box starts one.
    expect(find.text('It failed at the lint step.'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).decoration!.hintText,
      'Start a new chat…',
    );
    // The old one was let go of, not stopped, and is still listed.
    expect(shell.commands.any((c) => c.contains(' stop ')), isFalse);
    expect(find.text('the nightly build'), findsOneWidget);
    final row = tester
        .widget<TuiChatSessionList>(find.byType(TuiChatSessionList))
        .sessions
        .singleWhere((session) => session.title == 'the nightly build');
    expect(row.selected, isFalse);
  });

  testWidgets('a session started at a terminal in no tmux pane is shown '
      'read-only, and says why', (tester) async {
    final shell = _Shell()
      ..history = _nightlyHistory
      ..listing = jsonEncode([
        {
          'pid': 1259765,
          'cwd': '/home/me',
          'kind': 'interactive',
          'sessionId': '456d3c0e-2a17-4943-a2f4-6cdd25893a19',
          'name': 'dev-e0',
          'status': 'idle',
        },
      ]);
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatPage(session: session)),
      ),
    );
    await tester.pump();
    await _continue(tester, 'dev-e0');

    // Followed live, like any running session, and its turns drawn.
    expect(shell.commands.last, contains(' -f '));
    expect(find.text('It failed at the lint step.'), findsOneWidget);
    // Said to be read-only, why, and nowhere said to take what is sent.
    expect(
      find.textContaining(
        'live, read-only: it runs in a terminal outside '
        'tmux',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('what you send'), findsNothing);
    // The box is shut; there is nothing to send.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isFalse);
    expect(
      field.decoration!.hintText,
      'Read-only: “dev-e0” cannot be typed into from here',
    );
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send))
          .onPressed,
      isNull,
    );
    expect(shell.typed, isEmpty);
  });

  testWidgets('a session started at a terminal in a tmux pane takes what is '
      'sent, typed into that pane, and shows it sent once recorded', (
    tester,
  ) async {
    final shell = _Shell()
      ..history = _nightlyHistory
      ..pane = 'sshbox:pane %4\n'
      ..listing = jsonEncode([
        {
          'pid': 1259765,
          'cwd': '/home/me',
          'kind': 'interactive',
          'sessionId': '456d3c0e-2a17-4943-a2f4-6cdd25893a19',
          'name': 'dev-e0',
          'status': 'idle',
        },
      ]);
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatPage(session: session)),
      ),
    );
    await tester.pump();
    await _continue(tester, 'dev-e0');

    expect(find.textContaining('in tmux pane %4'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isTrue);
    expect(field.decoration!.hintText, 'Message “dev-e0”…');

    await tester.enterText(find.byType(TextField), 'and the lint?');
    await tester.pump();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.send));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    // Into the pane, on stdin; no attach, which it has no id for.
    expect(shell.paneTyped, ['and the lint?']);
    expect(shell.typed, isEmpty);
    expect(find.text('Sending…'), findsOneWidget);

    shell.adds({
      'type': 'user',
      'message': {'role': 'user', 'content': 'and the lint?'},
    });
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(find.text('Sending…'), findsNothing);
    expect(find.text('and the lint?'), findsOneWidget);
  });

  testWidgets('earlier turns go in above the first one showing, and what is '
      'on screen stays where it is', (tester) async {
    tester.view
      ..physicalSize = const Size(1280, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // More than the first read takes, and less than one earlier chunk.
    final lines = [
      for (var n = 0; n < 200; n++)
        jsonEncode({
          'type': 'assistant',
          'message': {
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': 'turn $n'},
            ],
          },
          'pad': 'x' * 6000,
        }),
    ];
    final all = Uint8List.fromList(utf8.encode('${lines.join('\n')}\n'));
    // The first turn the first read has whole: the one after the line its
    // start falls in.
    final cut = all.length - ClaudeChat.historyLimit;
    var first = 0;
    for (var end = 0; end <= cut; first++) {
      end += utf8.encode(lines[first]).length + 1;
    }
    final shell = _Shell()
      ..transcript = all
      ..listing = jsonEncode([_finished('dddd0001', 'long one')]);
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatPage(session: session)),
      ),
    );
    await _settlePickUp(tester);
    await tester.tap(find.text('long one'));
    await _settlePickUp(tester);

    // Up at the top of what the first read brought, the offer of more.
    final at = _conversationAt(tester);
    await _wheel(tester, -1e6);
    expect(find.text('turn ${first - 1}'), findsNothing);
    final y = tester.getTopLeft(find.text('turn $first')).dy;
    final pixels = at.pixels;

    await tester.tap(find.text('Load earlier turns'));
    await _settlePickUp(tester);

    // Nothing on screen moved; the earlier turns are above it, all the way
    // to the first, and there is nothing further back to offer.
    expect(tester.getTopLeft(find.text('turn $first')).dy, y);
    expect(at.pixels, pixels);
    expect(find.text('Load earlier turns'), findsNothing);
    expect(tester.getTopLeft(find.text('turn ${first - 1}')).dy, lessThan(y));
    await _wheel(tester, -1e6);
    expect(find.text('turn 0'), findsOneWidget);
  });

  group('where a session was left', () {
    /// A transcript long enough to scroll: [count] answers.
    String long(String word, int count) => _history([
      for (var n = 0; n < count; n++)
        {
          'type': 'assistant',
          'message': {
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': '$word $n'},
            ],
          },
        },
    ]);

    /// Two finished sessions to move between. Where one was left is kept
    /// for as long as the app runs, so each test has sessions of its own.
    Future<({_Shell shell, ScrollPosition Function() at})> twoSessions(
      WidgetTester tester,
      String ids,
    ) async {
      tester.view
        ..physicalSize = const Size(1280, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final shell = _Shell()
        ..listing = jsonEncode([
          _finished('${ids}0001', 'first', started: 2),
          _finished('${ids}0002', 'second', started: 1),
        ]);
      final session = LiveSession(host: _host, transport: (_, _) => shell);
      addTearDown(session.dispose);
      await session.connect(secrets: _NoSecrets());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ChatPage(session: session)),
        ),
      );
      await _settlePickUp(tester);
      // The conversation's list, not the sidebar's: the one with a
      // controller of its own.
      ScrollPosition at() => _conversationAt(tester);
      return (shell: shell, at: at);
    }

    Future<void> pick(
      WidgetTester tester,
      _Shell shell,
      String name,
      String history,
    ) async {
      shell.history = history;
      await tester.tap(find.text(name));
      await _settlePickUp(tester);
    }

    testWidgets('picked again, a session comes back where it was scrolled '
        'to', (tester) async {
      final (:shell, :at) = await twoSessions(tester, 'aaaa');
      await pick(tester, shell, 'first', long('first', 60));
      // Opened at its newest.
      expect(at().pixels, at().maxScrollExtent);

      at().jumpTo(400);
      await tester.pump();
      await pick(tester, shell, 'second', long('second', 60));
      expect(at().pixels, at().maxScrollExtent);

      await pick(tester, shell, 'first', long('first', 60));
      expect(at().pixels, 400);
      expect(at().maxScrollExtent - at().pixels, greaterThan(240));
    });

    testWidgets('scrolled up only a little, a session still comes back '
        'there', (tester) async {
      final (:shell, :at) = await twoSessions(tester, 'cccc');
      await pick(tester, shell, 'first', long('first', 60));
      // A few lines up from the newest, by a finger, as the user did: well
      // inside the distance at which new output is still followed.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 120));
      await tester.pumpAndSettle();
      final place = at().pixels;
      expect(at().maxScrollExtent - place, inInclusiveRange(60, 200));

      await pick(tester, shell, 'second', long('second', 60));
      await pick(tester, shell, 'first', long('first', 60));
      expect(at().pixels, place);
    });

    testWidgets('a session of long and short turns, read slowly, comes back '
        'to what was on screen', (tester) async {
      final (:shell, :at) = await twoSessions(tester, 'eeee');
      // Short turns first and long ones after: what a list can see of it
      // from its top says nothing of how long it really is.
      final mixed = _history([
        for (var n = 0; n < 60; n++)
          {
            'type': 'assistant',
            'message': {
              'role': 'assistant',
              'content': [
                {
                  'type': 'text',
                  'text': n < 30
                      ? 'first $n'
                      : 'first $n\n\n${'a longer answer, ' * 60}\n\n'
                            '```\n${'code line\n' * 12}```',
                },
              ],
            },
          },
      ]);
      await pick(tester, shell, 'first', mixed);
      at().jumpTo(at().maxScrollExtent - 900);
      await tester.pump();
      final place = at().pixels;
      // What the reader was looking at, and where on the screen it was.
      final seen = [
        for (var n = 0; n < 60; n++)
          if (find.text('first $n').evaluate().isNotEmpty) n,
      ].first;
      final y = tester.getTopLeft(find.text('first $seen')).dy;

      // One-line turns, laid out where the long ones were.
      await pick(tester, shell, 'second', long('second', 60));
      // The host takes its time handing the transcript over.
      final arrives = Completer<void>();
      shell
        ..history = mixed
        ..historyArrives = arrives.future;
      await tester.tap(find.text('first'));
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      arrives.complete();
      await _settlePickUp(tester);
      expect(at().pixels, moreOrLessEquals(place, epsilon: 1));
      expect(tester.getTopLeft(find.text('first $seen')).dy, y);
    });

    testWidgets('closed and opened again, the tab comes back to where a '
        'session was left', (tester) async {
      tester.view
        ..physicalSize = const Size(1280, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final shell = _Shell()
        ..listing = jsonEncode([_finished('ffff0001', 'first')])
        ..history = long('first', 60);
      final session = LiveSession(host: _host, transport: (_, _) => shell);
      addTearDown(session.dispose);
      await session.connect(secrets: _NoSecrets());
      Future<void> openTab() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: ChatPage(session: session)),
          ),
        );
        await _settlePickUp(tester);
        await tester.tap(find.text('first'));
        await _settlePickUp(tester);
      }

      await openTab();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 120));
      await tester.pumpAndSettle();
      final place = _conversationAt(tester).pixels;
      expect(_conversationAt(tester).maxScrollExtent - place, greaterThan(2));

      // The tab's ✕: the page goes, and the session lets its chat go.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      session.closeChat();
      await openTab();
      expect(_conversationAt(tester).pixels, place);
    });

    testWidgets('one left at its bottom comes back at its bottom', (
      tester,
    ) async {
      final (:shell, :at) = await twoSessions(tester, 'bbbb');
      await pick(tester, shell, 'first', long('first', 60));
      await pick(tester, shell, 'second', long('second', 60));
      at().jumpTo(300);
      await tester.pump();

      // Grown meanwhile, as a running session does: still its bottom.
      await pick(tester, shell, 'first', long('first', 90));
      expect(at().pixels, at().maxScrollExtent);
      expect(find.text('first 89'), findsOneWidget);
    });
  });

  group('a mermaid fence in a reply', () {
    Future<void> pumpAnswer(WidgetTester tester, String markdown) async {
      WebViewPlatform.instance = FakeWebViewPlatform();
      final shell = _Shell()
        ..listing = jsonEncode([_finished('cf58d27a', 'Diagrams')])
        ..history = _history([
          {
            'type': 'assistant',
            'message': {
              'role': 'assistant',
              'content': [
                {'type': 'text', 'text': markdown},
              ],
            },
          },
        ]);
      final session = LiveSession(host: _host, transport: (_, _) => shell);
      addTearDown(session.dispose);
      await session.connect(secrets: _NoSecrets());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ChatPage(session: session)),
        ),
      );
      await tester.pump();
      await _continue(tester, 'Diagrams');
    }

    testWidgets('is drawn as a diagram with its source copyable, and other '
        'code stays code', (tester) async {
      final copied = _useFakeClipboard();
      await pumpAnswer(
        tester,
        'Here:\n\n```mermaid\ngraph TD\n  A --> B\n```\n\n'
        '```sh\necho hello\n```\n',
      );

      expect(
        tester.widget<MermaidView>(find.byType(MermaidView)).source,
        'graph TD\n  A --> B\n',
      );
      expect(find.textContaining('A --> B'), findsNothing);
      expect(find.textContaining('echo hello'), findsOneWidget);

      await tester.tap(find.byTooltip('Copy diagram source'));
      await tester.pumpAndSettle();
      expect(copied, ['graph TD\n  A --> B\n']);
    });

    testWidgets('one not closed yet stays code', (tester) async {
      await pumpAnswer(tester, 'Drawing:\n\n```mermaid\ngraph TD\n  A --> B');

      expect(find.byType(MermaidView), findsNothing);
      expect(find.textContaining('A --> B'), findsOneWidget);
    });
  });

  group('code in a reply', () {
    final wide = [for (var i = 0; i < 40; i++) 'word_$i'].join(' ');
    const inline = 'inline_code()';

    Future<void> pump(WidgetTester tester, String md) async {
      final shell = _Shell()
        ..listing = jsonEncode([_finished('cf58d27a', 'Sel')])
        ..history = _history([
          {
            'type': 'assistant',
            'message': {
              'role': 'assistant',
              'content': [
                {'type': 'text', 'text': md},
              ],
            },
          },
        ]);
      final session = LiveSession(host: _host, transport: (_, _) => shell);
      addTearDown(session.dispose);
      await session.connect(secrets: _NoSecrets());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ChatPage(session: session)),
        ),
      );
      await tester.pump();
      await _continue(tester, 'Sel');
    }

    RenderParagraph paragraph(WidgetTester tester, String containing) =>
        tester.renderObject<RenderParagraph>(
          find.textContaining(containing, findRichText: true).first,
        );

    /// Global ends of [word] in [para]'s text.
    (Offset, Offset) ends(RenderParagraph para, String word) {
      final at = para.text.toPlainText().indexOf(word);
      final boxes = para.getBoxesForSelection(
        TextSelection(baseOffset: at, extentOffset: at + word.length),
      );
      return (
        para.localToGlobal(boxes.first.toRect().centerLeft) +
            const Offset(1, 0),
        para.localToGlobal(boxes.last.toRect().centerRight) -
            const Offset(1, 0),
      );
    }

    Future<void> dragAndCopy(
      WidgetTester tester,
      Offset from,
      Offset to,
    ) async {
      final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      await tester.pump();
      await g.moveTo(to);
      await tester.pump();
      await g.up();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    testWidgets('desktop: a drag over inline code, the box focused, then '
        'Ctrl+C copies just it', (tester) async {
      final copied = _useFakeClipboard();
      await pump(tester, 'Words and `$inline` here.');
      await tester.tap(find.byType(TextField));
      await tester.pump();
      final (a, b) = ends(paragraph(tester, inline), inline);
      await dragAndCopy(tester, a, b);
      expect(copied, [inline]);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('desktop: a drag over a fenced block copies its lines, no '
        'fence and no language', (tester) async {
      final copied = _useFakeClipboard();
      await pump(tester, '```sh\necho one\necho two\n```\n');
      await tester.tap(find.byType(TextField));
      await tester.pump();
      final para = paragraph(tester, 'echo one');
      final (a, _) = ends(para, 'echo one');
      final (_, b) = ends(para, 'echo two');
      await dragAndCopy(tester, a, b);
      expect(copied, ['echo one\necho two']);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('Android: a long press on inline code then the toolbar\'s '
        'Copy copies it', (tester) async {
      final copied = _useFakeClipboard();
      await pump(tester, 'Words and `$inline` here.');
      final (a, b) = ends(paragraph(tester, inline), inline);
      await tester.longPressAt(Offset.lerp(a, b, 0.5)!);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Copy'));
      await tester.pump();
      // A long press takes the word under it, as everywhere on Android.
      expect(copied, ['inline_code']);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('a block with a line wider than the chat wraps: nothing '
        'scrolls sideways, nothing overflows, and every way of copying '
        'gives the line unbroken', (tester) async {
      final copied = _useFakeClipboard();
      await pump(tester, '```\n$wide\n```\n');
      expect(tester.takeException(), isNull);
      final sideways = find.byWidgetPredicate(
        (w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
      );
      expect(sideways, findsNothing);
      final para = paragraph(tester, 'word_0');
      expect(para.size.width, lessThan(tester.view.physicalSize.width));
      expect(para.size.height, greaterThan(para.text.style!.fontSize! * 2));

      // The button, clicked with a mouse.
      final click = await tester.startGesture(
        tester.getCenter(find.byTooltip('Copy code')),
        kind: PointerDeviceKind.mouse,
      );
      await click.up();
      await tester.pump();
      expect(copied, [wide]);

      // A drag across all of it, then Ctrl+C.
      copied.clear();
      final r = para.localToGlobal(Offset.zero) & para.size;
      await dragAndCopy(
        tester,
        r.topLeft + const Offset(1, 1),
        r.bottomRight - const Offset(1, 1),
      );
      expect(copied, [wide]);
      await tester.pump(const Duration(seconds: 2));
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  });

  group('code in a reply, in the real shell', () {
    const inline = 'inline_code()';

    /// The app's TabsShell holding a terminal tab and its chat, the chat
    /// shown, a finished session picked and [md] its last answer.
    Future<_Shell> pumpApp(WidgetTester tester, String md) async {
      final shell = _Shell()
        ..listing = jsonEncode([_finished('cf58d27a', 'Sel')])
        ..history = _history([
          {
            'type': 'assistant',
            'message': {
              'role': 'assistant',
              'content': [
                {'type': 'text', 'text': md},
              ],
            },
          },
        ]);
      final manager = SessionManager();
      addTearDown(manager.closeAll);
      final session = manager.open(_host, transport: (_, _) => shell);
      await session.connect(secrets: _NoSecrets());
      manager.openChat(session.id);
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
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // pumpAndSettle never settles under the shell, which animates.
      Future<void> frames() async {
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await tester.tap(find.text('SESSIONS ON THIS HOST'));
      await frames();
      await tester.tap(find.text('Sel'));
      await frames();
      return shell;
    }

    (Offset, Offset) ends(WidgetTester tester, String word) {
      final para = tester.renderObject<RenderParagraph>(
        find.textContaining(word, findRichText: true).first,
      );
      final at = para.text.toPlainText().indexOf(word);
      final boxes = para.getBoxesForSelection(
        TextSelection(baseOffset: at, extentOffset: at + word.length),
      );
      return (
        para.localToGlobal(boxes.first.toRect().centerLeft) +
            const Offset(1, 0),
        para.localToGlobal(boxes.last.toRect().centerRight) -
            const Offset(1, 0),
      );
    }

    Future<void> dragThenCopy(
      WidgetTester tester,
      (Offset, Offset) span, {
      required LogicalKeyboardKey chord,
    }) async {
      final g = await tester.startGesture(
        span.$1,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await g.moveTo(span.$2);
      await tester.pump();
      await g.up();
      await tester.pump();
      await tester.sendKeyDownEvent(chord);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(chord);
      await tester.pump();
    }

    testWidgets('inline code in the user\'s own bubble copies', (tester) async {
      final copied = _useFakeClipboard();
      await pumpApp(tester, 'ok');
      await tester.enterText(find.byType(TextField), 'try `mine_code()` now');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await dragThenCopy(
        tester,
        ends(tester, 'mine_code()'),
        chord: LogicalKeyboardKey.controlLeft,
      );
      expect(copied, ['mine_code()']);
    });

    for (final (platform, chord) in [
      (TargetPlatform.linux, LogicalKeyboardKey.controlLeft),
      (TargetPlatform.macOS, LogicalKeyboardKey.metaLeft),
    ]) {
      testWidgets('inline code in a finished reply copies on $platform', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        final copied = _useFakeClipboard();
        await pumpApp(tester, 'Words and `$inline` here.');
        await tester.tap(find.byType(TextField));
        await tester.pump();
        await dragThenCopy(tester, ends(tester, inline), chord: chord);
        debugDefaultTargetPlatformOverride = null;
        expect(copied, [inline]);
      });

      testWidgets('inline code in a reply being written copies on $platform', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        final copied = _useFakeClipboard();
        final shell = await pumpApp(tester, 'Words and `$inline` here.');
        await tester.enterText(find.byType(TextField), 'go on');
        await tester.pump();
        await tester.tap(find.byIcon(Icons.send));
        await tester.pump();
        shell.event({
          'type': 'assistant',
          'message': {
            'content': [
              {'type': 'text', 'text': 'Now a `second_code()` while it goes'},
            ],
          },
        });
        await tester.pump();
        await tester.tap(find.byType(TextField));
        await tester.pump();
        final span = ends(tester, inline);
        final g = await tester.startGesture(
          span.$1,
          kind: PointerDeviceKind.mouse,
        );
        await g.moveTo(span.$2);
        await g.up();
        await tester.pump();
        shell.event({
          'type': 'assistant',
          'message': {
            'content': [
              {'type': 'text', 'text': ' and more words'},
            ],
          },
        });
        await tester.pump();
        await tester.sendKeyDownEvent(chord);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(chord);
        await tester.pump();
        debugDefaultTargetPlatformOverride = null;
        expect(copied, [inline]);
      });
    }
  });

  group('a link in a reply', () {
    const ticket = 'https://edot.youtrack.cloud/issue/COR-6025';

    /// A finished session whose answer is [markdown], picked in the chat.
    /// Returns what went to a web tab beside the shell and what went to the
    /// phone, to its browser or any other app.
    Future<({List<Uri> inTab, List<String> launched})> pumpAnswer(
      WidgetTester tester,
      String markdown,
    ) async {
      final launcher = _Launcher();
      UrlLauncherPlatform.instance = launcher;
      final inTab = <Uri>[];
      final shell = _Shell()
        ..listing = jsonEncode([_finished('cf58d27a', 'Ticket triage')])
        ..history = _history([
          {
            'type': 'assistant',
            'message': {
              'role': 'assistant',
              'content': [
                {'type': 'text', 'text': markdown},
              ],
            },
          },
        ]);
      final session = LiveSession(host: _host, transport: (_, _) => shell);
      addTearDown(session.dispose);
      await session.connect(secrets: _NoSecrets());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatPage(session: session, onOpenWeb: inTab.add),
          ),
        ),
      );
      await tester.pump();
      await _continue(tester, 'Ticket triage');
      return (inTab: inTab, launched: launcher.opened);
    }

    /// Lets a tap's toast show without waiting it out, which settling would.
    Future<void> showToast(WidgetTester tester) async {
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    /// Presses Copy on the toast a refused link left, and waits it out.
    Future<void> copyFromToast(WidgetTester tester) async {
      await showToast(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(TuiToastCard),
          matching: find.text('COPY'),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('opens in a web tab beside the shell on a phone', (
      tester,
    ) async {
      final (:inTab, :launched) = await pumpAnswer(
        tester,
        'Filed as [COR-6025]($ticket).',
      );

      await tester.tapOnText(find.textRange.ofSubstring('COR-6025'));
      await tester.pumpAndSettle();

      expect(inTab, [Uri.parse(ticket)]);
      expect(launched, isEmpty);
    });

    testWidgets('goes to the machine\'s own browser on a desktop', (
      tester,
    ) async {
      final (:inTab, :launched) = await pumpAnswer(
        tester,
        'Filed as [COR-6025]($ticket).',
      );

      await tester.tapOnText(find.textRange.ofSubstring('COR-6025'));
      await tester.pumpAndSettle();

      expect(inTab, isEmpty);
      expect(launched, [ticket]);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('that is not a web address is launched nowhere', (
      tester,
    ) async {
      final copied = _useFakeClipboard();
      final (:inTab, :launched) = await pumpAnswer(
        tester,
        'Try [this](javascript:alert(1)) or [that](sshbox://open).',
      );

      await tester.tapOnText(find.textRange.ofSubstring('this'));
      // Nothing copied until asked: openUrl refuses a web page's own
      // navigation the same way, and a page must not fill the clipboard.
      await showToast(tester);
      expect(copied, isEmpty);
      await copyFromToast(tester);
      await tester.tapOnText(find.textRange.ofSubstring('that'));
      await copyFromToast(tester);

      // Neither to a tab nor to the phone, where a scheme is whatever app
      // answers to it — this one's own among them.
      expect(inTab, isEmpty);
      expect(launched, isEmpty);
      // Tapped all the same, rather than missed.
      expect(copied, ['javascript:alert(1)', 'sshbox://open']);
    });

    testWidgets('that is not opened has its address copied, which its label '
        'hides', (tester) async {
      final copied = _useFakeClipboard();
      await pumpAnswer(
        tester,
        'Fixed in [the chat page](lib/src/ui/chat_page.dart) and '
        '[here](javascript:alert(1)).',
      );

      await tester.tapOnText(find.textRange.ofSubstring('the chat page'));
      await showToast(tester);
      expect(copied, ['lib/src/ui/chat_page.dart']);
      expect(
        find.descendant(
          of: find.byType(TuiToastCard),
          matching: find.textContaining('lib/src/ui/chat_page.dart'),
        ),
        findsOneWidget,
      );

      await tester.pumpAndSettle();
      await tester.tapOnText(find.textRange.ofSubstring('here'));
      await copyFromToast(tester);
      expect(copied.last, 'javascript:alert(1)');
    });
  });

  group('what the user types', () {
    /// A finished session continued here, [typed] sent into it. Returns the
    /// host, what went to a web tab and what went to the phone.
    Future<({_Shell shell, List<Uri> inTab, List<String> launched})> send(
      WidgetTester tester,
      String typed,
    ) async {
      final launcher = _Launcher();
      UrlLauncherPlatform.instance = launcher;
      final inTab = <Uri>[];
      final shell = _Shell()
        ..listing = jsonEncode([_finished('cf58d27a', 'Notes')]);
      final session = LiveSession(host: _host, transport: (_, _) => shell);
      addTearDown(session.dispose);
      await session.connect(secrets: _NoSecrets());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatPage(session: session, onOpenWeb: inTab.add),
          ),
        ),
      );
      await tester.pump();
      await _continue(tester, 'Notes');
      await tester.enterText(find.byType(TextField), typed);
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      await tester.pump();
      return (shell: shell, inTab: inTab, launched: launcher.opened);
    }

    /// Every span drawn in the bubble, as (text, style).
    List<(String, TextStyle?)> bubbleSpans(WidgetTester tester) {
      final out = <(String, TextStyle?)>[];
      for (final text in tester.widgetList<RichText>(
        find.descendant(
          of: find.byType(TuiChatBubble),
          matching: find.byType(RichText),
        ),
      )) {
        text.text.visitChildren((span) {
          if (span is TextSpan && span.text != null) {
            out.add((span.text!, span.style));
          }
          return true;
        });
      }
      return out;
    }

    const typed =
        'Run **this** and see [the ticket](https://example.com/t/1):\n'
        '\n'
        '```sh\n'
        'make test\n'
        '```';

    testWidgets('goes to Claude byte for byte as typed', (tester) async {
      final (:shell, inTab: _, launched: _) = await send(tester, typed);
      final sent = jsonDecode(shell.written.single.trim()) as Map;
      expect(((sent['message'] as Map)['content'] as List).single, {
        'type': 'text',
        'text': typed,
      });
    });

    testWidgets('is drawn in its bubble as Markdown: bold, a code block with '
        'its copy button, and a link', (tester) async {
      await send(tester, typed);
      final spans = bubbleSpans(tester);

      expect(
        spans.singleWhere((s) => s.$1 == 'this').$2!.fontWeight,
        FontWeight.bold,
      );
      // No markers left on screen: drawn, not shown as source.
      expect(spans.any((s) => s.$1.contains('**')), isFalse);
      expect(spans.any((s) => s.$1.contains('```')), isFalse);
      expect(spans.any((s) => s.$1.contains('make test')), isTrue);
      expect(
        find.descendant(
          of: find.byType(TuiChatBubble),
          matching: find.byTooltip('Copy code'),
        ),
        findsOneWidget,
      );
      expect(
        spans.singleWhere((s) => s.$1 == 'the ticket').$2!.decoration,
        TextDecoration.underline,
      );
    });

    testWidgets('a link in it goes through the same allowlist as a reply\'s', (
      tester,
    ) async {
      final (:shell, :inTab, :launched) = await send(
        tester,
        'see [the ticket](https://example.com/t/1) or [refused](javascript:x)',
      );
      // The turn over, so nothing is left spinning to settle.
      shell.event({'type': 'result', 'subtype': 'success'});
      await tester.pump();
      await tester.tapOnText(find.textRange.ofSubstring('the ticket'));
      await tester.pumpAndSettle();
      expect(inTab, [Uri.parse('https://example.com/t/1')]);

      await tester.tapOnText(find.textRange.ofSubstring('refused'));
      await tester.pumpAndSettle();
      expect(inTab, hasLength(1));
      expect(launched, isEmpty);
    });

    group('a key typed while the box has no focus', () {
      Future<TextField> pumpChat(WidgetTester tester) async {
        final shell = _Shell()
          ..listing = jsonEncode([_finished('cf58d27a', 'Notes')]);
        final session = LiveSession(host: _host, transport: (_, _) => shell);
        addTearDown(session.dispose);
        await session.connect(secrets: _NoSecrets());
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: ChatPage(session: session)),
          ),
        );
        await tester.pump();
        await _continue(tester, 'Notes');
        return tester.widget<TextField>(find.byType(TextField));
      }

      testWidgets('moves the focus to the box and lands there once', (
        tester,
      ) async {
        final box = await pumpChat(tester);
        expect(box.focusNode!.hasFocus, isFalse);

        await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
        await tester.pump();

        expect(box.focusNode!.hasFocus, isTrue);
        expect(box.controller!.text, 'h');
        expect(
          box.controller!.selection,
          const TextSelection.collapsed(offset: 1),
        );
      });

      testWidgets('leaves shortcuts, Tab, Escape and the F-keys alone', (
        tester,
      ) async {
        final box = await pumpChat(tester);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        for (final key in [
          LogicalKeyboardKey.tab,
          LogicalKeyboardKey.escape,
          LogicalKeyboardKey.f5,
        ]) {
          await tester.sendKeyEvent(key);
        }
        await tester.pump();

        expect(box.focusNode!.hasFocus, isFalse);
        expect(box.controller!.text, isEmpty);
      });

      testWidgets('leaves Space to a focused button, which it presses', (
        tester,
      ) async {
        final box = await pumpChat(tester);
        Focus.of(
          tester.element(find.byIcon(Icons.view_sidebar_outlined)),
        ).requestFocus();
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump();

        expect(box.focusNode!.hasFocus, isFalse);
        expect(box.controller!.text, isEmpty);
      });

      testWidgets('leaves its keys to an open drawer', (tester) async {
        final box = await pumpChat(tester);
        await tester.tap(find.byTooltip('Sessions on this host'));
        await tester.pumpAndSettle();

        await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
        await tester.pump();

        expect(box.focusNode!.hasFocus, isFalse);
        expect(box.controller!.text, isEmpty);
      });

      testWidgets('leaves another text field its keys', (tester) async {
        final box = await pumpChat(tester);
        final other = FocusNode();
        addTearDown(other.dispose);
        // A dialog's field, over the chat.
        unawaited(
          showDialog<void>(
            context: tester.element(find.byType(ChatPage)),
            builder: (_) =>
                Dialog(child: TextField(focusNode: other, autofocus: true)),
          ),
        );
        await tester.pumpAndSettle();
        expect(other.hasFocus, isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
        await tester.pump();

        expect(other.hasFocus, isTrue);
        expect(box.controller!.text, isEmpty);
      });
    });

    group('the keyboard sends', () {
      Future<_Shell> typed(WidgetTester tester, String text) async {
        final shell = _Shell()
          ..listing = jsonEncode([_finished('cf58d27a', 'Notes')]);
        final session = LiveSession(host: _host, transport: (_, _) => shell);
        addTearDown(session.dispose);
        await session.connect(secrets: _NoSecrets());
        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: ChatPage(session: session))),
        );
        await tester.pump();
        await _continue(tester, 'Notes');
        await tester.enterText(find.byType(TextField), text);
        await tester.pump();
        return shell;
      }

      Future<void> chord(WidgetTester tester, LogicalKeyboardKey modifier) async {
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(modifier);
        await tester.pump();
      }

      String box(WidgetTester tester) =>
          tester.widget<TextField>(find.byType(TextField)).controller!.text;

      testWidgets('by default with Ctrl+Enter, a plain Enter sending nothing', (
        tester,
      ) async {
        final shell = await typed(tester, 'hello');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(shell.written, isEmpty);

        await chord(tester, LogicalKeyboardKey.controlLeft);
        expect(shell.written, hasLength(1));
        expect(box(tester), isEmpty);
      });

      testWidgets('with ⌘+Enter on a Mac', (tester) async {
        final shell = await typed(tester, 'hello');
        await chord(tester, LogicalKeyboardKey.controlLeft);
        expect(shell.written, isEmpty);
        await chord(tester, LogicalKeyboardKey.metaLeft);
        expect(shell.written, hasLength(1));
      }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

      testWidgets('with Enter when Settings says so, Shift+Enter making a new '
          'line and the chord still sending', (tester) async {
        chatEnterSends.value = true;
        addTearDown(() => chatEnterSends.value = false);
        final shell = await typed(tester, 'one');

        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        expect(shell.written, isEmpty);
        expect(box(tester), 'one\n');
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'one\ntwo',
            selection: TextSelection.collapsed(offset: 7),
          ),
        );
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(shell.written, hasLength(1));
        expect(
          (((jsonDecode(shell.written.single.trim()) as Map)['message']
                  as Map)['content'] as List)
              .single['text'],
          'one\ntwo',
        );
      });

      testWidgets('not while the list of commands is open: Enter picks, and '
          'only the chord sends', (tester) async {
        chatEnterSends.value = true;
        addTearDown(() => chatEnterSends.value = false);
        final shell = await typed(tester, '/com');
        await tester.pump();
        expect(find.text('/compact'), findsOneWidget);

        // Enter picks the command rather than sending a half-typed /com.
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(shell.written, isEmpty);
        expect(box(tester), '/compact ');
        expect(find.text('/compact'), findsNothing);

        // Gboard's own send action, the list open again, sends nothing, even
        // with a whole command in the box.
        await tester.enterText(find.byType(TextField), '/compact');
        await tester.pump();
        expect(find.text('/compact'), findsWidgets);
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pump();
        expect(shell.written, isEmpty);

        // The chord sends what is in the box, list open or not.
        await tester.enterText(find.byType(TextField), '/compact');
        await tester.pump();
        expect(find.text('/compact'), findsWidgets);
        await chord(tester, LogicalKeyboardKey.controlLeft);
        expect(shell.written, hasLength(1));
        expect(
          (((jsonDecode(shell.written.single.trim()) as Map)['message']
                  as Map)['content'] as List)
              .single['text'],
          '/compact',
        );
      });

      testWidgets('a list with nothing to pick leaves Enter to the box, so a '
          'command no one knows is refused there', (tester) async {
        chatEnterSends.value = true;
        addTearDown(() => chatEnterSends.value = false);
        final shell = await typed(tester, '/xyz');
        await tester.pump();
        expect(find.text('No command chat can run starts with /xyz'),
            findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(shell.written, isEmpty);
        expect(find.textContaining('run it in the terminal'), findsOneWidget);
        await tester.pump(const Duration(seconds: 6));
      });

      testWidgets('never with an IME\'s Enter, which confirms what it is '
          'composing', (tester) async {
        chatEnterSends.value = true;
        addTearDown(() => chatEnterSends.value = false);
        final shell = await typed(tester, 'nihao');
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'nihao',
            selection: TextSelection.collapsed(offset: 5),
            composing: TextRange(start: 0, end: 5),
          ),
        );
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await chord(tester, LogicalKeyboardKey.controlLeft);
        expect(shell.written, isEmpty);
      });
    });

    testWidgets('on a desktop the box has the focus once the chat is shown', (
      tester,
    ) async {
      final shell = _Shell();
      final session = LiveSession(host: _host, transport: (_, _) => shell);
      addTearDown(session.dispose);
      await session.connect(secrets: _NoSecrets());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ChatPage(session: session)),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('a mermaid fence in it is drawn as a diagram, as in a reply', (
      tester,
    ) async {
      WebViewPlatform.instance = FakeWebViewPlatform();
      await send(tester, 'Like this:\n\n```mermaid\ngraph TD\n  A --> B\n```');

      final diagram = find.descendant(
        of: find.byType(TuiChatBubble),
        matching: find.byType(MermaidView),
      );
      expect(tester.widget<MermaidView>(diagram).source, 'graph TD\n  A --> B\n');
    });

    testWidgets('stray stars and underscores read as written', (tester) async {
      await send(tester, '2 * 3 * 4 is snake_case_name');
      expect(find.text('2 * 3 * 4 is snake_case_name'), findsOneWidget);
    });
  });

  group('the line under a turn in flight', () {
    const sessionId = '81badf4a-7e9f-4f01-b098-6968dbe5f070';
    Map<String, Object?> row({String? waitingFor}) => {
      'pid': 4079548,
      'id': '81badf4a',
      'cwd': '/srv/app',
      'kind': 'background',
      'sessionId': sessionId,
      'name': 'the nightly build',
      'status': waitingFor == null ? 'busy' : 'waiting',
      'state': waitingFor == null ? 'working' : 'blocked',
      'waitingFor': ?waitingFor,
    };

    Future<_Shell> watching(WidgetTester tester) async {
      final shell = _Shell()
        ..history = _nightlyHistory
        ..listing = jsonEncode([row()]);
      final session = LiveSession(host: _host, transport: (_, _) => shell);
      addTearDown(session.dispose);
      await session.connect(secrets: _NoSecrets());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ChatPage(session: session)),
        ),
      );
      await _frames(tester);
      await tester.tap(find.text('SESSIONS ON THIS HOST'));
      await _settlePickUp(tester);
      await tester.tap(find.text('the nightly build'));
      await _settlePickUp(tester);
      return shell;
    }

    String line(WidgetTester tester) =>
        tester.widgetList<Text>(find.textContaining('Working…')).single.data!;

    testWidgets('ticks its seconds here, counts tokens, names the tool, and '
        'goes when the turn ends', (tester) async {
      final shell = await watching(tester);
      // Between turns: nothing.
      expect(find.textContaining('Working…'), findsNothing);

      // The clock the line reads is this test's own, moved by hand, so no
      // second of real time or of a loaded machine reaches what is asserted.
      var now = DateTime.utc(2026, 10, 1, 12, 0, 10);
      final real = chatNow;
      chatNow = () => now;
      addTearDown(() => chatNow = real);

      // A turn typed at the terminal 3 s ago by the host's clock.
      shell.adds({
        'type': 'user',
        'timestamp': now.subtract(const Duration(seconds: 3)).toIso8601String(),
        'message': {'role': 'user', 'content': 'run the tests'},
      });
      shell.adds({
        'type': 'assistant',
        'message': {
          'id': 'msg_1',
          'stop_reason': 'tool_use',
          'usage': {'output_tokens': 1400},
          'content': [
            {
              'type': 'tool_use',
              'id': 'toolu_1',
              'name': 'Bash',
              'input': {'command': 'npm test'},
            },
          ],
        },
      });
      await _settlePickUp(tester);
      expect(line(tester), 'Working… (3s · ↓ 1.4k tokens) · Bash: npm test');

      // A second later by that clock, with nothing from the host: the same
      // line, a second on, and the host not asked again.
      final before = shell.commands.length;
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(line(tester), 'Working… (4s · ↓ 1.4k tokens) · Bash: npm test');
      expect(
        shell.commands
            .skip(before)
            .where((command) => command.contains('agents --json')),
        isEmpty,
      );

      // Five seconds on, it is asked once.
      now = now.add(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 1));
      expect(
        shell.commands
            .skip(before)
            .where((command) => command.contains('agents --json')),
        hasLength(1),
      );

      shell.adds({
        'type': 'system',
        'subtype': 'turn_duration',
        'durationMs': 5000,
      });
      await _settlePickUp(tester);
      expect(find.textContaining('Working…'), findsNothing);
    });

    testWidgets('waiting at a prompt says what for and where to answer, and '
        'does not spin', (tester) async {
      final shell = await watching(tester);
      shell.listing = jsonEncode([row(waitingFor: 'permission prompt')]);
      shell.adds({
        'type': 'user',
        'message': {'role': 'user', 'content': 'touch a file'},
      });
      await _settlePickUp(tester);
      // The first look goes at once, not after the first few seconds.
      expect(
        find.textContaining('Waiting for permission prompt on the host.'),
        findsOneWidget,
      );
      expect(find.textContaining('81badf4a'), findsOneWidget);
      expect(find.textContaining('Working…'), findsNothing);
      expect(find.byIcon(Icons.pause), findsOneWidget);
    });


    Future<_Shell> watchingOnScreen(WidgetTester tester) async {
      final shell = _Shell()
        ..history = _nightlyHistory
        ..listing = jsonEncode([row()]);
      final session = LiveSession(host: _host, transport: (_, _) => shell);
      addTearDown(session.dispose);
      await session.connect(secrets: _NoSecrets());
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: ChatPage(session: session))),
      );
      await _frames(tester);
      await tester.tap(find.text('SESSIONS ON THIS HOST'));
      await _settlePickUp(tester);
      await tester.tap(find.text('the nightly build'));
      await _settlePickUp(tester);
      return shell;
    }

    /// A reply of 25 lines, about 650 px: taller than the 240 px within which
    /// the reader counts as following.
    Future<void> longReply(WidgetTester tester, _Shell shell, int n) async {
      shell.adds({
        'type': 'assistant',
        'message': {
          'id': 'msg_long_$n',
          'content': [
            {
              'type': 'text',
              'text': [
                for (var line = 1; line <= 25; line++)
                  'Long answer $n, line $line',
              ].join('\n\n'),
            },
          ],
        },
      });
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await _frames(tester);
    }

    /// The reader scrolling with a mouse wheel by [dy] (negative is up): the
    /// one input here that is the reader's and moves as little as a pixel.
    Future<void> wheel(WidgetTester tester, double dy) async {
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        pointer.hover(tester.getCenter(find.byType(CustomScrollView))),
      );
      await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
      await tester.pump();
    }

    testWidgets('at the end, a reply taller than a screen is followed to '
        'its own end, one after another', (tester) async {
      final shell = await watchingOnScreen(tester);
      for (var n = 1; n <= 6; n++) {
        await longReply(tester, shell, n);
      }
      final position = _conversationAt(tester);
      expect(position.maxScrollExtent, greaterThan(3000));
      expect(position.maxScrollExtent - position.pixels, lessThan(2));
    });

    testWidgets('following keeps the end in view when the room shrinks, the '
        'keyboard coming up', (tester) async {
      final shell = await watchingOnScreen(tester);
      for (var n = 1; n <= 3; n++) {
        await longReply(tester, shell, n);
      }
      final position = _conversationAt(tester);
      expect(position.maxScrollExtent - position.pixels, lessThan(2));

      // The keyboard: the box and the list lose 300 px, no entry is added.
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await _frames(tester);
      expect(position.maxScrollExtent - position.pixels, lessThan(2));
      expect(find.textContaining('LATEST'), findsNothing);
    });

    testWidgets('following keeps the end in view when the last row grows in '
        'place, a tool row opened', (tester) async {
      final shell = await watchingOnScreen(tester);
      for (var n = 1; n <= 3; n++) {
        await longReply(tester, shell, n);
      }
      shell
        ..adds({
          'type': 'assistant',
          'message': {
            'id': 'msg_tool',
            'stop_reason': 'tool_use',
            'content': [
              {
                'type': 'tool_use',
                'id': 'toolu_grow',
                'name': 'Bash',
                'input': {'command': 'echo grow'},
              },
            ],
          },
        })
        ..adds({
          'type': 'user',
          'message': {
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': 'toolu_grow',
                'content': [for (var i = 0; i < 40; i++) 'out $i'].join('\n'),
              },
            ],
          },
        });
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await _frames(tester);
      final position = _conversationAt(tester);
      expect(position.maxScrollExtent - position.pixels, lessThan(2));

      // Opened: the row grows under a view already at the end.
      await tester.tap(find.text('echo grow'));
      await _frames(tester);
      expect(position.maxScrollExtent - position.pixels, lessThan(2));
    });

    testWidgets('a reader scrolling inside a tool row\'s block is not '
        'scrolling the conversation: following goes on', (tester) async {
      final shell = await watchingOnScreen(tester);
      for (var n = 1; n <= 3; n++) {
        await longReply(tester, shell, n);
      }
      shell
        ..adds({
          'type': 'assistant',
          'message': {
            'id': 'msg_tall',
            'stop_reason': 'tool_use',
            'content': [
              {
                'type': 'tool_use',
                'id': 'toolu_tall',
                'name': 'Bash',
                'input': {
                  'command': [for (var i = 0; i < 80; i++) 'echo tall $i'].join('\n'),
                },
              },
            ],
          },
        })
        ..adds({
          'type': 'user',
          'message': {
            'role': 'user',
            'content': [
              {'type': 'tool_result', 'tool_use_id': 'toolu_tall', 'content': 'ok'},
            ],
          },
        });
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await _frames(tester);
      final position = _conversationAt(tester);
      expect(position.maxScrollExtent - position.pixels, lessThan(2));

      // Opened: a block taller than its cap, scrolling inside the row.
      await tester.tap(find.textContaining('echo tall 0'));
      await _frames(tester);
      expect(position.maxScrollExtent - position.pixels, lessThan(2));
      final block = find.byType(SingleChildScrollView).first;
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(tester.getCenter(block)));
      // Down inside it, then back up: an upward move in range, in the block.
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));
      await tester.pump();
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -40)));
      await tester.pump();

      expect(find.textContaining('LATEST'), findsNothing);
      await longReply(tester, shell, 4);
      expect(position.maxScrollExtent - position.pixels, lessThan(2));
    });

    testWidgets('a pixel up is enough to stop following, until the reader '
        'is back at the end', (tester) async {
      final shell = await watchingOnScreen(tester);
      for (var n = 1; n <= 3; n++) {
        await longReply(tester, shell, n);
      }
      final position = _conversationAt(tester);
      expect(position.maxScrollExtent - position.pixels, lessThan(2));

      // One pixel up: no longer following, whatever arrives.
      await wheel(tester, -1);
      final kept = position.pixels;
      await longReply(tester, shell, 4);
      await longReply(tester, shell, 5);
      expect(position.pixels, kept);

      // Back at the end by hand: following again.
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      await longReply(tester, shell, 6);
      expect(position.maxScrollExtent - position.pixels, lessThan(2));
    });

    testWidgets('the jump button shows only away from the end, counts what '
        'came in, and tapping it lands at the end and follows', (
      tester,
    ) async {
      final shell = await watchingOnScreen(tester);
      for (var n = 1; n <= 3; n++) {
        await longReply(tester, shell, n);
      }
      // At the end: no button.
      expect(find.textContaining('LATEST'), findsNothing);

      final position = _conversationAt(tester);
      await wheel(tester, -800);
      expect(find.text('LATEST'), findsOneWidget);
      await longReply(tester, shell, 4);
      expect(find.text('LATEST · 1 NEW'), findsOneWidget);
      // It sits over the list, clear of the box below.
      expect(
        tester.getRect(find.text('LATEST · 1 NEW')).bottom,
        lessThan(tester.getRect(find.byType(TextField)).top),
      );

      await tester.tap(find.text('LATEST · 1 NEW'));
      await _frames(tester);
      expect(position.maxScrollExtent - position.pixels, lessThan(2));
      expect(find.textContaining('LATEST'), findsNothing);

      // Following from there on.
      await longReply(tester, shell, 5);
      expect(position.maxScrollExtent - position.pixels, lessThan(2));
    });

    testWidgets('a run back the layout makes is not the reader scrolling up: '
        'the view put back into range leaves it following', (tester) async {
      final shell = await watchingOnScreen(tester);
      for (var n = 1; n <= 3; n++) {
        await longReply(tester, shell, n);
      }
      final position =
          _conversationAt(tester) as ScrollPositionWithSingleContext;
      expect(position.maxScrollExtent - position.pixels, lessThan(2));

      // As a keyboard going away leaves the view past its new end: out of
      // range, and the list runs it back, upward, with no drag in it.
      // ignore: invalid_use_of_protected_member
      position.forcePixels(position.maxScrollExtent + 200);
      position.goBallistic(0);
      await _frames(tester);
      expect(find.textContaining('LATEST'), findsNothing);
      await longReply(tester, shell, 4);
      expect(position.maxScrollExtent - position.pixels, lessThan(2));
    });

    testWidgets('PageUp is the reader scrolling up, though it moves the view '
        'by animateTo or jumpTo', (tester) async {
      final shell = await watchingOnScreen(tester);
      for (var n = 1; n <= 3; n++) {
        await longReply(tester, shell, n);
      }
      final position = _conversationAt(tester);
      expect(position.maxScrollExtent - position.pixels, lessThan(2));

      // What the key does where it reaches the list: a ScrollAction.
      Actions.invoke(
        tester.element(find.byType(SliverList).last),
        const ScrollIntent(
          direction: AxisDirection.up,
          type: ScrollIncrementType.page,
        ),
      );
      await _frames(tester);
      expect(find.textContaining('LATEST'), findsOneWidget);
      final kept = position.pixels;
      await longReply(tester, shell, 4);
      expect(position.pixels, kept);
    });

    testWidgets('a PageUp key press, with a reply focused, is the reader '
        'scrolling up', (tester) async {
      final shell = await watchingOnScreen(tester);
      for (var n = 1; n <= 3; n++) {
        await longReply(tester, shell, n);
      }
      final position = _conversationAt(tester);
      expect(position.maxScrollExtent - position.pixels, lessThan(2));

      // A click into a reply puts the focus on its selectable text.
      await tester.tapAt(tester.getCenter(find.byType(SelectionArea).last));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await _frames(tester);
      expect(find.textContaining('LATEST'), findsOneWidget);
      final kept = position.pixels;
      await longReply(tester, shell, 4);
      expect(position.pixels, kept);
    });

    testWidgets('scrolled up, a long reply leaves the reader where they are',
        (tester) async {
      final shell = await watchingOnScreen(tester);
      for (var n = 1; n <= 3; n++) {
        await longReply(tester, shell, n);
      }
      final position = _conversationAt(tester);
      // Up well past where a new entry would still be followed.
      await wheel(tester, -900);
      final kept = position.pixels;
      await longReply(tester, shell, 4);
      expect(position.pixels, kept);
      expect(position.maxScrollExtent - position.pixels, greaterThan(1000));
    });

    testWidgets('hidden while following, the chat is at its end when shown '
        'again, however much was written meanwhile', (tester) async {
      final shell = _Shell()
        ..history = _nightlyHistory
        ..listing = jsonEncode([row()]);
      final session = LiveSession(host: _host, transport: (_, _) => shell);
      addTearDown(session.dispose);
      await session.connect(secrets: _NoSecrets());
      // What the tab strip does to a page it is not showing.
      final shown = ValueNotifier(true);
      addTearDown(shown.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: shown,
              builder: (context, on, child) =>
                  TickerMode(enabled: on, child: child!),
              child: ChatPage(session: session),
            ),
          ),
        ),
      );
      await _frames(tester);
      await tester.tap(find.text('SESSIONS ON THIS HOST'));
      await _settlePickUp(tester);
      await tester.tap(find.text('the nightly build'));
      await _settlePickUp(tester);

      shown.value = false;
      await tester.pump();
      // Claude writes several screens while the terminal tab is in front.
      for (var reply = 0; reply < 12; reply++) {
        shell.adds({
          'type': 'assistant',
          'message': {
            'id': 'msg_$reply',
            'stop_reason': 'end_turn',
            'content': [
              {
                'type': 'text',
                'text': List.filled(8, 'Reply $reply goes on.').join('\n\n'),
              },
            ],
          },
        });
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await _frames(tester);
      }

      shown.value = true;
      await _frames(tester);
      final position = _conversationAt(tester);
      expect(position.maxScrollExtent, greaterThan(1000));
      expect(position.maxScrollExtent - position.pixels, lessThan(2));
    });
  });

  group('a chat takes what is typed or pasted without the box clicked', () {
    /// A finished session continued here, with one answer to select from.
    /// Returns the host, to see what was sent into it.
    Future<_Shell> pumpChat(
      WidgetTester tester, {
      String answer = 'hello world answer',
    }) async {
      final shell = _Shell()
        ..listing = jsonEncode([_finished('cf58d27a', 'Notes')])
        ..history = _history([
          {
            'type': 'assistant',
            'message': {
              'role': 'assistant',
              'content': [
                {'type': 'text', 'text': answer},
              ],
            },
          },
        ]);
      final session = LiveSession(host: _host, transport: (_, _) => shell);
      addTearDown(session.dispose);
      await session.connect(secrets: _NoSecrets());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ChatPage(session: session)),
        ),
      );
      await tester.pump();
      await _continue(tester, 'Notes');
      return shell;
    }

    TextField box(WidgetTester tester) =>
        tester.widget<TextField>(find.byType(TextField));
    String typed(WidgetTester tester) => box(tester).controller!.text;

    /// Focus on the sessions button: a control that is not a text field.
    Future<void> focusAButton(WidgetTester tester) async {
      Focus.of(tester.element(find.byIcon(Icons.view_sidebar_outlined)))
          .requestFocus();
      await tester.pump();
      expect(box(tester).focusNode!.hasFocus, isFalse);
    }

    /// Pastes [text]: what the clipboard answers to a read.
    void clipboardHolds(String text) {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return {'text': text};
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
    }

    /// A paste looks for a picture first, which is real work off the frame
    /// clock: let it run out before reading the box.
    Future<void> pasteSettles(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump();
    }

    Future<void> chord(
      WidgetTester tester,
      LogicalKeyboardKey modifier,
      LogicalKeyboardKey key,
    ) async {
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(modifier);
      await tester.pump();
      await tester.pump();
    }

    /// Drags the mouse over the answer, as a person selects it.
    Future<void> selectTheAnswer(WidgetTester tester) async {
      final answer = find.textContaining('hello world', findRichText: true);
      final gesture = await tester.startGesture(
        tester.getTopLeft(answer.first) + const Offset(2, 6),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(
        tester.getTopRight(answer.first) + const Offset(-2, 6),
      );
      await gesture.up();
      await tester.pump();
    }

    testWidgets('a letter, with focus on a button, goes into the box once', (
      tester,
    ) async {
      await pumpChat(tester);
      await focusAButton(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.pump();

      expect(typed(tester), 'h');
      expect(box(tester).focusNode!.hasFocus, isTrue);
    });

    testWidgets('Backspace and the arrows, with focus on a button, are the '
        'button\'s: the box is left alone', (tester) async {
      await pumpChat(tester);
      await tester.enterText(find.byType(TextField), 'abc');
      await tester.pump();
      await focusAButton(tester);
      final button = FocusManager.instance.primaryFocus;

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(typed(tester), 'abc');
      expect(box(tester).focusNode!.hasFocus, isFalse);

      // The arrow moves between controls, as Flutter's own does.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(typed(tester), 'abc');
      expect(box(tester).focusNode!.hasFocus, isFalse);
      expect(FocusManager.instance.primaryFocus, isNot(same(button)));
    });

    testWidgets('Backspace and an arrow, from a selection in a reply, go to '
        'the box', (tester) async {
      await pumpChat(tester);
      await tester.enterText(find.byType(TextField), 'abc');
      await tester.pump();
      await selectTheAnswer(tester);
      expect(box(tester).focusNode!.hasFocus, isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(typed(tester), 'ab');
      expect(box(tester).focusNode!.hasFocus, isTrue);

      await selectTheAnswer(tester);
      expect(box(tester).focusNode!.hasFocus, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(box(tester).focusNode!.hasFocus, isTrue);
      expect(
        box(tester).controller!.selection.baseOffset,
        lessThan(2),
        reason: 'the arrow moved the caret',
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('Enter, with focus on a button, presses it and is not the '
        'box\'s', (tester) async {
      final shell = await pumpChat(tester);
      await tester.enterText(find.byType(TextField), 'one');
      await tester.pump();
      await focusAButton(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();

      // The button's: it opened the sessions drawer, and the box was left.
      expect(typed(tester), 'one');
      expect(shell.written, isEmpty);
      expect(box(tester).focusNode!.hasFocus, isFalse);
    });

    testWidgets('Enter, from a selection in a reply, is the box\'s: a new '
        'line by default, a send where Settings says so', (tester) async {
      final shell = await pumpChat(tester);
      await tester.enterText(find.byType(TextField), 'one');
      await tester.pump();
      await selectTheAnswer(tester);
      expect(box(tester).focusNode!.hasFocus, isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(typed(tester), 'one\n');
      expect(shell.written, isEmpty);

      chatEnterSends.value = true;
      addTearDown(() => chatEnterSends.value = false);
      await selectTheAnswer(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(shell.written, hasLength(1));
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('Enter from a selection into an empty box only focuses it', (
      tester,
    ) async {
      await pumpChat(tester);
      await selectTheAnswer(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(typed(tester), isEmpty);
      expect(box(tester).focusNode!.hasFocus, isTrue);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('Enter on a reply\'s Copy button, inside its selection area, '
        'presses it and is not the box\'s', (tester) async {
      final copied = _useFakeClipboard();
      await pumpChat(tester, answer: 'Run:\n\n```sh\necho hi\n```\n');
      Focus.of(tester.element(find.byIcon(Icons.content_copy))).requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();

      expect(copied, ['echo hi']);
      expect(typed(tester), isEmpty);
      expect(box(tester).focusNode!.hasFocus, isFalse);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('Ctrl+V of text, with the box unfocused, pastes into it', (
      tester,
    ) async {
      await pumpChat(tester);
      clipboardHolds('pasted text');
      await focusAButton(tester);

      await chord(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.keyV,
      );
      await pasteSettles(tester);

      expect(typed(tester), 'pasted text');
      expect(box(tester).focusNode!.hasFocus, isTrue);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('Shift+Insert pastes too, on Linux', (tester) async {
      await pumpChat(tester);
      clipboardHolds('pasted text');
      await focusAButton(tester);

      await chord(
        tester,
        LogicalKeyboardKey.shiftLeft,
        LogicalKeyboardKey.insert,
      );
      await pasteSettles(tester);

      expect(typed(tester), 'pasted text');
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('⌘V of text, with the box unfocused, pastes into it', (
      tester,
    ) async {
      await pumpChat(tester);
      clipboardHolds('pasted text');
      // The Mac's native half answers that no picture is there.
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('sshbox/share'),
        (call) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('sshbox/share'),
          null,
        ),
      );
      await focusAButton(tester);

      await chord(tester, LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.keyV);
      await pasteSettles(tester);

      expect(typed(tester), 'pasted text');
      expect(box(tester).focusNode!.hasFocus, isTrue);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('the first key after selecting text in a reply goes into '
        'the box', (tester) async {
      await pumpChat(tester);
      await selectTheAnswer(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.pump();

      expect(typed(tester), 'h');
      expect(box(tester).focusNode!.hasFocus, isTrue);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('Space after selecting text in a reply goes into the box '
        'too', (tester) async {
      await pumpChat(tester);
      await selectTheAnswer(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();

      expect(typed(tester), ' ');
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('Ctrl+C on a selected reply still copies it', (tester) async {
      final copied = _useFakeClipboard();
      await pumpChat(tester);
      await selectTheAnswer(tester);

      await chord(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.keyC,
      );

      expect(copied, isNotEmpty);
      expect(copied.last, contains('hello'));
      expect(typed(tester), isEmpty);
      expect(box(tester).focusNode!.hasFocus, isFalse);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('⌘, is left to the app, not typed', (tester) async {
      await pumpChat(tester);
      await focusAButton(tester);

      await chord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.comma,
      );

      expect(typed(tester), isEmpty);
      expect(box(tester).focusNode!.hasFocus, isFalse);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('Escape and Tab are left alone', (tester) async {
      await pumpChat(tester);
      await focusAButton(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyEvent(LogicalKeyboardKey.f5);
      await tester.pump();

      expect(box(tester).focusNode!.hasFocus, isFalse);
      expect(typed(tester), isEmpty);
    });

    /// Sends [text] by [how] and says the turn is over, so the next send is
    /// open.
    Future<void> sendAndFinish(
      WidgetTester tester,
      _Shell shell,
      String text,
      Future<void> Function() how,
    ) async {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump();
      await how();
      await tester.pump();
      await tester.pump();
      expect(typed(tester), isEmpty, reason: '$text was sent');
      shell.event({'type': 'result', 'subtype': 'success'});
      await tester.pump();
      await tester.pump();
    }

    testWidgets('a click on Send, which takes the focus off the box on a '
        'desktop, gives it back', (tester) async {
      final shell = await pumpChat(tester);
      final focus = box(tester).focusNode!;

      await sendAndFinish(
        tester,
        shell,
        'first',
        () => tester.tap(find.byIcon(Icons.send)),
      );

      expect(focus.hasFocus, isTrue);
      // And what is typed next reaches it through the platform's text input,
      // as on a desktop, with no click on the box.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'n',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      await tester.pump();
      expect(typed(tester), 'n');
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('Ctrl+Enter leaves the focus in the box', (tester) async {
      final shell = await pumpChat(tester);
      final focus = box(tester).focusNode!;

      await sendAndFinish(
        tester,
        shell,
        'first',
        () => chord(
          tester,
          LogicalKeyboardKey.controlLeft,
          LogicalKeyboardKey.enter,
        ),
      );

      expect(focus.hasFocus, isTrue);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('on a phone a send from the box keeps the focus, and one '
        'from outside it does not take it', (tester) async {
      final shell = await pumpChat(tester);
      final focus = box(tester).focusNode!;
      await sendAndFinish(
        tester,
        shell,
        'first',
        () => tester.tap(find.byIcon(Icons.send)),
      );
      expect(focus.hasFocus, isTrue);

      // The box let go, as when the keyboard was put away: a send from
      // elsewhere must not bring Gboard back.
      await tester.enterText(find.byType(TextField), 'second');
      await tester.pump();
      focus.unfocus();
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      await tester.pump();
      expect(focus.hasFocus, isFalse);
    });
  });

  testWidgets('the Send button reads in every theme, light and dark: its '
      'arrow on its fill, and its fill on the composer', (tester) async {
    final shell = _Shell();
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());
    final failures = <String>[];
    for (final scheme in terminalSchemes) {
      for (final brightness in Brightness.values) {
        final palette = scheme.palette(brightness);
        await tester.pumpWidget(
          MaterialApp(
            key: ValueKey('${scheme.name} $brightness'),
            theme: jeanshTheme(palette),
            home: Scaffold(body: ChatPage(session: session)),
          ),
        );
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'hi');
        // The button eases into its enabled colours.
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        final send = find.widgetWithIcon(IconButton, Icons.send);
        expect(tester.widget<IconButton>(send).onPressed, isNotNull);
        final fill = tester
            .widget<Material>(
              find.descendant(of: send, matching: find.byType(Material)),
            )
            .color!;
        final arrow = tester
            .widget<RichText>(
              find.descendant(of: send, matching: find.byType(RichText)),
            )
            .text
            .style!
            .color!;
        final ground = jeanshTheme(palette).scaffoldBackgroundColor;
        final onFill = tuiContrast(arrow, fill);
        final onGround = tuiContrast(fill, ground);
        if (onFill < 3 || onGround < 3) {
          failures.add(
            '${scheme.name} $brightness: arrow ${onFill.toStringAsFixed(2)}, '
            'fill ${onGround.toStringAsFixed(2)}',
          );
        }
      }
    }
    expect(failures, isEmpty);
  });

  group('each session\'s mark in the sidebar', () {
    // A pinned background session, as `claude agents --json --all` lists it
    // at each point of a turn: working, at a permission prompt, then done.
    String listed({
      required String status,
      required String state,
      String? waitingFor,
    }) =>
        '${jsonEncode([
          {
            'pid': 4079548,
            'id': '81badf4a',
            'cwd': '/srv/app',
            'kind': 'background',
            'sessionId': '81badf4a-7e9f-4f01-b098-6968dbe5f070',
            'name': 'the nightly build',
            'status': status,
            'state': state,
            'waitingFor': ?waitingFor,
          },
          {
            'pid': 4079549,
            'id': 'cccc3333',
            'cwd': '/srv/app',
            'kind': 'background',
            'sessionId': 'cccc3333-0000-4000-8000-000000000000',
            'name': 'the other one',
            'status': 'idle',
            'state': 'done',
          },
        ])}\n--- pins\n["81badf4a"]\n';

    Finder mark(String label) => find.bySemanticsLabel(label);

    testWidgets('moves while it works, asks for attention while it waits, '
        'and is checked with a dot once done until it is opened', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(1280, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      final shell = _Shell()
        ..history = _nightlyHistory
        ..listing = listed(status: 'busy', state: 'working');
      final session = LiveSession(host: _host, transport: (_, _) => shell);
      addTearDown(session.dispose);
      await session.connect(secrets: _NoSecrets());
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: ChatPage(session: session))),
      );
      await _frames(tester);

      // Pinned, and working: the pin kept, and a mark that moves.
      expect(find.text('★'), findsOneWidget);
      expect(mark('Working'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(TuiChatSessionList),
          matching: find.byType(TuiSpinner),
        ),
        findsOneWidget,
      );

      // At a permission prompt, by the next look, with nothing tapped.
      shell.listing = listed(
        status: 'waiting',
        state: 'blocked',
        waitingFor: 'permission prompt',
      );
      await tester.pump(const Duration(seconds: 6));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await _frames(tester);
      expect(mark('Waiting for permission prompt'), findsOneWidget);
      expect(mark('Working'), findsNothing);

      // Done while nobody had it open: checked, with the dot.
      shell.listing = listed(status: 'idle', state: 'done');
      await tester.pump(const Duration(seconds: 6));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await _frames(tester);
      expect(mark('Done, idle, not opened since'), findsOneWidget);
      // The other one was never seen working: no dot.
      expect(mark('Done, idle'), findsOneWidget);

      // Opened: the dot goes.
      await tester.tap(find.text('the nightly build'));
      await _settlePickUp(tester);
      expect(mark('Done, idle, not opened since'), findsNothing);
      expect(mark('Done, idle'), findsNWidgets(2));      semantics.dispose();
    });

    testWidgets('nothing is asked for while the tab is hidden', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(1280, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final shell = _Shell()..listing = listed(status: 'busy', state: 'working');
      final session = LiveSession(host: _host, transport: (_, _) => shell);
      addTearDown(session.dispose);
      await session.connect(secrets: _NoSecrets());
      final shown = ValueNotifier(true);
      addTearDown(shown.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: shown,
              builder: (context, on, child) =>
                  TickerMode(enabled: on, child: child!),
              child: ChatPage(session: session),
            ),
          ),
        ),
      );
      await _frames(tester);
      int asked() =>
          shell.commands.where((c) => c.contains('agents --json')).length;

      // On show, asked again every few seconds.
      final before = asked();
      await tester.pump(const Duration(seconds: 6));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await _frames(tester);
      expect(asked(), greaterThan(before));

      // Hidden: not once, however long.
      shown.value = false;
      await _frames(tester);
      final hidden = asked();
      for (var look = 0; look < 4; look++) {
        await tester.pump(const Duration(seconds: 6));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      expect(asked(), hidden);
    });
  });

  group('the checklist under the working line', () {
    Map<String, Object?> call(
      String id,
      String name,
      Map<String, Object?> input,
    ) => {
      'type': 'assistant',
      'message': {
        'id': 'msg_$id',
        'stop_reason': 'tool_use',
        'content': [
          {'type': 'tool_use', 'id': id, 'name': name, 'input': input},
        ],
      },
    };

    Map<String, Object?> created(String id, int n) => {
      'type': 'user',
      'message': {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': id,
            'content': 'Task #$n created successfully: x',
          },
        ],
      },
    };

    /// A TaskUpdate, and its result: it takes effect when that says it did.
    void update(_Shell shell, String id, Map<String, Object?> input) {
      shell
        ..adds(call(id, 'TaskUpdate', input))
        ..adds({
          'type': 'user',
          'message': {
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': id,
                'content': 'Updated task #${input['taskId']} status',
              },
            ],
          },
        });
    }

    Future<_Shell> watching(WidgetTester tester, {String tasks = ''}) async {
      tester.view
        ..physicalSize = const Size(1280, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final shell = _Shell()
        ..tasksOut = tasks
        ..history = _nightlyHistory
        ..listing = jsonEncode([
          {
            'pid': 4079548,
            'id': '81badf4a',
            'cwd': '/srv/app',
            'kind': 'background',
            'sessionId': '81badf4a-7e9f-4f01-b098-6968dbe5f070',
            'name': 'the nightly build',
            'status': 'busy',
            'state': 'working',
          },
        ]);
      final session = LiveSession(host: _host, transport: (_, _) => shell);
      addTearDown(session.dispose);
      await session.connect(secrets: _NoSecrets());
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: ChatPage(session: session))),
      );
      await _frames(tester);
      await tester.tap(find.text('the nightly build'));
      await _settlePickUp(tester);
      return shell;
    }

    Future<void> make(WidgetTester tester, _Shell shell, int n) async {
      shell
        ..adds(
          call('c$n', 'TaskCreate', {
            'subject': 'Task $n',
            'description': 'd',
            'activeForm': 'Doing $n',
          }),
        )
        ..adds(created('c$n', n));
      await _settlePickUp(tester);
    }

    testWidgets('lists what is open, bold in progress with ■ and pending '
        'with □, and follows each update', (tester) async {
      final shell = await watching(tester);
      expect(find.textContaining('□'), findsNothing);

      await make(tester, shell, 1);
      await make(tester, shell, 2);
      expect(find.text('⎿ □ Task 1'), findsOneWidget);
      expect(find.text('  □ Task 2'), findsOneWidget);

      // Live: one becomes in progress, and reads as its active form.
      update(shell, 'u1', {'taskId': '1', 'status': 'in_progress'});
      await _settlePickUp(tester);
      expect(find.text('⎿ ■ Doing 1'), findsOneWidget);
      expect(find.text('  □ Task 2'), findsOneWidget);
      expect(
        tester.widget<TuiText>(find.widgetWithText(TuiText, '⎿ ■ Doing 1')).bold,
        isTrue,
      );

      // Completed ones are counted, not listed.
      update(shell, 'u2', {'taskId': '1', 'status': 'completed'});
      await _settlePickUp(tester);
      expect(find.textContaining('Doing 1'), findsNothing);
      expect(find.text('  … 1 completed'), findsOneWidget);

      // All done: nothing left to show.
      update(shell, 'u3', {'taskId': '2', 'status': 'completed'});
      await _settlePickUp(tester);
      expect(find.text('  … 2 completed'), findsNothing);
      expect(find.textContaining('□'), findsNothing);
    });

    testWidgets('past a few lines it counts the rest, as Claude Code does', (
      tester,
    ) async {
      final shell = await watching(tester);
      for (var n = 1; n <= 10; n++) {
        await make(tester, shell, n);
      }
      update(shell, 'u1', {'taskId': '1', 'status': 'completed'});
      await _settlePickUp(tester);
      // 9 open, 6 shown, 3 more, 1 done.
      expect(find.text('  … +3 pending, 1 completed'), findsOneWidget);
      expect(find.text('⎿ □ Task 2'), findsOneWidget);
      expect(find.text('  □ Task 7'), findsOneWidget);
      expect(find.textContaining('Task 8'), findsNothing);
    });

    testWidgets('hidden rows are counted for what they are', (tester) async {
      final shell = await watching(tester);
      for (var n = 1; n <= 8; n++) {
        await make(tester, shell, n);
        update(shell, 'ip$n', {'taskId': '$n', 'status': 'in_progress'});
      }
      await _settlePickUp(tester);
      // 8 in progress, 6 shown: the 2 more are not called pending.
      expect(find.text('  … +2 in progress'), findsOneWidget);
    });

    testWidgets('lists the session\'s whole store under a header counting it, '
        'tasks the transcript never carried among them', (tester) async {
      String task(int n, String subject, String status) => jsonEncode({
        'id': '$n',
        'subject': subject,
        'description': 'd',
        'activeForm': 'Doing $subject',
        'status': status,
        'blocks': <String>[],
        'blockedBy': <String>[],
      });
      // Eight tasks, none of them in the transcript the chat read.
      final shell = await watching(
        tester,
        tasks: [
          task(1, 'early a', 'completed'),
          task(2, 'early b', 'completed'),
          task(3, 'early c', 'in_progress'),
          for (var n = 4; n <= 8; n++) task(n, 'early $n', 'pending'),
        ].join('\n'),
      );
      await _settlePickUp(tester);
      expect(shell.commands.any((c) => c.contains('/tasks')), isTrue);
      expect(find.text('8 tasks (2 done, 1 in progress, 5 open)'), findsOneWidget);
      expect(find.text('⎿ ■ Doing early c'), findsOneWidget);
      expect(find.text('  □ early 4'), findsOneWidget);
      expect(find.text('  … 2 completed'), findsOneWidget);
    });

    testWidgets('its text is drawn as text, never read as anything else', (
      tester,
    ) async {
      final shell = await watching(tester);
      shell
        ..adds(
          call('c1', 'TaskCreate', {
            'subject': '[x](javascript:alert(1)) **b** <b>',
            'description': 'd',
          }),
        )
        ..adds(created('c1', 1));
      await _settlePickUp(tester);
      expect(
        find.text('⎿ □ [x](javascript:alert(1)) **b** <b>'),
        findsOneWidget,
      );
    });
  });

  group('pictures', () {
    /// A real picture, one pixel, so it decodes as one.
    final pixel = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
      '60e6kgAAAABJRU5ErkJggg==',
    );
    late Directory dir;
    setUp(
      () => dir = Directory.systemTemp.createTempSync('chat-pictures-test'),
    );
    tearDown(() => dir.deleteSync(recursive: true));

    /// What the clipboard holds next, as MainActivity hands a picture over:
    /// a file of the app's own, and its name. Null holds none.
    List<String?> clipboard(WidgetTester tester) {
      final next = <String?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('sshbox/share'),
        (call) async {
          if (call.method != 'clipboardImage' || next.isEmpty) return null;
          final name = next.removeAt(0);
          if (name == null) return null;
          final file = File('${dir.path}/$name')..writeAsBytesSync(pixel);
          return {'path': file.path, 'name': name};
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('sshbox/share'),
          null,
        ),
      );
      return next;
    }

    /// Ctrl+V in the box, its file work let run.
    Future<void> paste(WidgetTester tester) async {
      await tester.runAsync(() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
    }

    String box(WidgetTester tester) =>
        tester.widget<TextField>(find.byType(TextField)).controller!.text;

    Future<_Shell> continued(WidgetTester tester, {String? history}) async {
      final shell = _Shell()
        ..listing = jsonEncode([_finished('cf58d27a', 'Zsh config fix')]);
      if (history != null) shell.history = history;
      final session = LiveSession(host: _host, transport: (_, _) => shell);
      addTearDown(session.dispose);
      await session.connect(secrets: _NoSecrets());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ChatPage(session: session)),
        ),
      );
      await tester.pump();
      await _continue(tester, 'Zsh config fix');
      await tester.tap(find.byType(TextField));
      await tester.pump();
      return shell;
    }

    testWidgets('Ctrl+V with the box unfocused and a picture on the '
        'clipboard focuses the box and makes the card', (tester) async {
      final next = clipboard(tester);
      await continued(tester);
      // The box let go: the focus on a button, as after a tab or a click.
      Focus.of(
        tester.element(find.byIcon(Icons.view_sidebar_outlined)),
      ).requestFocus();
      await tester.pump();
      expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
          isFalse);

      next.add('shot.png');
      await paste(tester);

      expect(box(tester), '[Image #1] ');
      expect(find.text('[Image #1] shot.png'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );
    });

    testWidgets('a picture pasted becomes a card and an [Image #N] at the '
        'caret, and goes with the message as a picture', (tester) async {
      final next = clipboard(tester);
      final shell = await continued(tester);

      next.add('shot.png');
      await paste(tester);
      expect(box(tester), '[Image #1] ');
      expect(find.text('[Image #1] shot.png'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '[Image #1] what is it?');
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.byIcon(Icons.send));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      final content =
          ((jsonDecode(shell.written.single.trim()) as Map)['message']
                  as Map)['content']
              as List;
      expect(content.first, {'type': 'text', 'text': '[Image #1] what is it?'});
      expect((content.last as Map)['source'], {
        'type': 'base64',
        'media_type': 'image/png',
        'data': base64Encode(pixel),
      });
      // The card went with it, and the bubble holds the picture.
      expect(find.text('[Image #1] shot.png'), findsNothing);
      expect(find.bySemanticsLabel('View shot.png'), findsOneWidget);
    });

    testWidgets('Ctrl+Enter in the box sends the message with its pictures', (
      tester,
    ) async {
      final next = clipboard(tester);
      final shell = await continued(tester);

      next.add('shot.png');
      await paste(tester);
      await tester.enterText(find.byType(TextField), '[Image #1] look');
      await tester.pump();
      await tester.runAsync(() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      final content =
          ((jsonDecode(shell.written.single.trim()) as Map)['message']
                  as Map)['content']
              as List;
      expect(content.first, {'type': 'text', 'text': '[Image #1] look'});
      expect((content.last as Map)['type'], 'image');
      expect(box(tester), isEmpty);
      expect(find.text('[Image #1] shot.png'), findsNothing);
    });

    testWidgets('an [Image #N] whose number no int holds draws, and is sent, '
        'as text', (tester) async {
      final shell = await continued(tester);
      await tester.enterText(
        find.byType(TextField),
        'see [Image #99999999999999999999]',
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(box(tester), 'see [Image #99999999999999999999]');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      final content =
          ((jsonDecode(shell.written.single.trim()) as Map)['message']
                  as Map)['content']
              as List;
      expect(content, [
        {'type': 'text', 'text': 'see [Image #99999999999999999999]'},
      ]);
    });

    testWidgets(
      'a picture dropped before the chat is ready becomes a card, and '
      'Send turns on once it is',
      (tester) async {
        final shell = _Shell();
        final session = LiveSession(host: _host, transport: (_, _) => shell);
        addTearDown(session.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: ChatPage(session: session)),
          ),
        );
        await tester.pump();
        final shot = File('${dir.path}/early.png')..writeAsBytesSync(pixel);

        // Not connected: nothing to send to yet, but the picture is kept.
        await tester.runAsync(() async {
          await dropOnTerminal(tester, [shot.path], on: find.byType(TextField));
          await Future<void>.delayed(const Duration(milliseconds: 200));
        });
        await tester.pump();
        expect(find.text('[Image #1] early.png'), findsOneWidget);
        IconButton send() => tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.send),
        );
        expect(send().onPressed, isNull);

        await tester.runAsync(() => session.connect(secrets: _NoSecrets()));
        await tester.pump();
        await tester.pump();
        expect(find.text('[Image #1] early.png'), findsOneWidget);
        expect(send().onPressed, isNotNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );

    testWidgets('a session that is read-only from here refuses a picture, '
        'saying why', (tester) async {
      final shell = _Shell()
        ..history = _nightlyHistory
        ..listing = jsonEncode([
          {
            'pid': 1259765,
            'cwd': '/home/me',
            'kind': 'interactive',
            'sessionId': '456d3c0e-2a17-4943-a2f4-6cdd25893a19',
            'name': 'dev-e0',
            'status': 'idle',
          },
        ]);
      final session = LiveSession(host: _host, transport: (_, _) => shell);
      addTearDown(session.dispose);
      await session.connect(secrets: _NoSecrets());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ChatPage(session: session)),
        ),
      );
      await tester.pump();
      await _continue(tester, 'dev-e0');
      final shot = File('${dir.path}/ro.png')..writeAsBytesSync(pixel);

      await tester.runAsync(() async {
        await dropOnTerminal(tester, [shot.path], on: find.byType(TextField));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
      // A drop target is off there, so the refusal is the + button's route:
      // no card either way.
      expect(find.text('[Image #1] ro.png'), findsNothing);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(
                IconButton,
                Icons.add_photo_alternate_outlined,
              ),
            )
            .onPressed,
        isNull,
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('removing a card takes its token out, and deleting a token '
        'takes its card', (tester) async {
      final next = clipboard(tester);
      await continued(tester);

      next.addAll(['a.png', 'b.png']);
      await paste(tester);
      await paste(tester);
      expect(box(tester), '[Image #1] [Image #2] ');

      await tester.tap(find.byTooltip('Remove a.png'));
      await tester.pump();
      expect(box(tester), '[Image #1] ');
      expect(find.text('[Image #1] b.png'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'no picture now');
      await tester.pump();
      expect(find.textContaining('b.png'), findsNothing);
    });

    testWidgets('a card opens its picture large, and text on the clipboard is '
        'pasted as text', (tester) async {
      final next = clipboard(tester);
      await continued(tester);

      next.add('shot.png');
      await paste(tester);
      await tester.tap(find.bySemanticsLabel('View shot.png'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // Its size read from the file before anything is drawn.
      for (var turn = 0; turn < 10; turn++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.byType(PictureView), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      // No picture: the field's own paste, which asks for text.
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return {'text': 'plain words'};
        if (call.method == 'Clipboard.hasStrings') return {'value': true};
        return null;
      });
      await paste(tester);
      await tester.pump();
      expect(box(tester), '[Image #1] plain words');
    });

    testWidgets('the selection menu offers Paste with only a picture on the '
        'clipboard, and it takes the picture', (tester) async {
      final next = clipboard(tester);
      await continued(tester);

      next.add('shot.png');
      tester
          .state<EditableTextState>(
            find.descendant(
              of: find.byType(TextField),
              matching: find.byType(EditableText),
            ),
          )
          .showToolbar();
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Paste'));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
      expect(box(tester), '[Image #1] ');
      expect(find.text('[Image #1] shot.png'), findsOneWidget);
    });

    testWidgets('a transcript\'s picture that claims too many pixels is not '
        'drawn in its bubble, and one that does not is, decoded small', (
      tester,
    ) async {
      // 68 bytes of PNG that say they are 30000 × 30000.
      final huge = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAdTAAAHUwCAYAAABmJ/i6AAAAC0lEQVR4nGNgQAUAABAA'
        'ATm9j2UAAAAASUVORK5CYII=',
      );
      Map<String, Object?> said(String text, List<int> bytes) => {
        'type': 'user',
        'imagePasteIds': [1],
        'message': {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': text},
            {
              'type': 'image',
              'source': {'type': 'base64', 'data': base64Encode(bytes)},
            },
          ],
        },
      };
      await continued(
        tester,
        history: _history([
          said('[Image #1] the bomb', huge),
          said('[Image #1] a pixel', pixel),
        ]),
      );
      for (var turn = 0; turn < 10; turn++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }

      expect(find.text('[Image #1] the bomb'), findsOneWidget);
      final drawn = tester
          .widgetList<Image>(find.byType(Image))
          .map((image) => image.image)
          .whereType<ResizeImage>()
          .map((resized) => (resized.imageProvider as MemoryImage).bytes)
          .toList();
      expect(drawn, [pixel]);
      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    });

    testWidgets('a file that is not a picture is refused, saying why', (
      tester,
    ) async {
      final next = clipboard(tester);
      await continued(tester);

      next.add('notes.txt');
      await paste(tester);
      await tester.pump();
      expect(
        find.textContaining('Not a picture Claude can read: notes.txt'),
        findsOneWidget,
      );
      expect(box(tester), isEmpty);
      // Long enough to read and act on, not the second a notice gets.
      await tester.pump(const Duration(seconds: 2));
      expect(
        find.textContaining('Not a picture Claude can read: notes.txt'),
        findsOneWidget,
      );
      await tester.pumpAndSettle(const Duration(seconds: 6));
    });

    testWidgets('files dropped on a desktop chat become cards, a folder '
        'refused', (tester) async {
      await continued(tester);
      final shot = File('${dir.path}/drop.png')..writeAsBytesSync(pixel);
      final folder = Directory('${dir.path}/pics')..createSync();

      await tester.runAsync(() async {
        await dropOnTerminal(tester, [
          shot.path,
          folder.path,
        ], on: find.byType(TextField));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
      expect(box(tester), '[Image #1] ');
      expect(find.text('[Image #1] drop.png'), findsOneWidget);
      expect(
        find.textContaining('A folder is not a picture: pics'),
        findsOneWidget,
      );
      await tester.pumpAndSettle(const Duration(seconds: 6));
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  });
}
