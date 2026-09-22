import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/chat/claude_chat.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/chat_page.dart';
import 'package:sshbox/src/ui/code_languages.dart';
import 'package:sshbox/src/ui/toast.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

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
    scheduleMicrotask(
      () => screen.add(Uint8List.fromList(utf8.encode(' ❯ '))),
    );
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
  void adds(Map<String, Object?> line) => follow!.add(
    Uint8List.fromList(utf8.encode('${jsonEncode(line)}\n')),
  );

  @override
  Future<CommandChannel> open(String command) async {
    commands.add(command);
    // Before the rest: tmux's finder has a ` -f ` of its own.
    if (command.contains('list-panes')) {
      final typing = command.contains('load-buffer');
      return (
        output: Stream.value(
          Uint8List.fromList(
            utf8.encode(
              typing ? 'sshbox:pasted\nsshbox:typed %4\n' : pane,
            ),
          ),
        ),
        write: (Uint8List data) => paneTyped.add(utf8.decode(data)),
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
]);

/// Where the conversation is scrolled to: its list, not the sidebar's.
ScrollPosition _conversationAt(WidgetTester tester) =>
    tester.widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!
        .position;

/// Lets a pick-up run out. Closing the drawer, reading the history and
/// starting Claude are futures, not frames, so settling the frames alone
/// returns while they are in flight; this takes turns between the two until
/// both are quiet.
Future<void> _settlePickUp(WidgetTester tester) async {
  for (var turn = 0; turn < 8; turn++) {
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  await tester.pump();
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
  await tester.tap(find.text('Sessions on this host'));
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
      MaterialApp(home: Scaffold(body: ChatPage(session: session))),
    );
    await _settlePickUp(tester);

    // Only the list is asked for: no Claude of its own, no session.
    expect(
      shell.commands.where((c) => !c.contains('agents --json')),
      isEmpty,
    );
    // Nothing said yet, so the tab says where Claude will run, and how.
    expect(find.textContaining('/srv/app'), findsOneWidget);
    expect(find.textContaining('starts a new session'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).decoration!.hintText,
      'Start a new chat…',
    );

    await tester.enterText(find.byType(TextField), 'why is nginx slow?');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
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
      MaterialApp(home: Scaffold(body: ChatPage(session: session))),
    );
    await tester.pump();
    await _continue(tester, 'Zsh config fix');
    // Continued in place by a Claude of this chat's own, resumed.
    expect(shell.commands.last, contains('--resume'));

    await tester.enterText(find.byType(TextField), 'check the nginx log');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();

    expect(
      jsonDecode(shell.written.single.trim()),
      containsPair('type', 'user'),
    );
    // The user's own words, on screen, and the field cleared for the next.
    expect(find.text('check the nginx log'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    // A turn is running: nothing else may be sent until it ends.
    expect(find.text('Claude is working…'), findsOneWidget);

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

    shell.event({'type': 'result', 'subtype': 'success'});
    await tester.pump();
    await tester.pump();
    expect(find.text('Claude is working…'), findsNothing);
  });

  testWidgets('an unconnected session says so rather than starting anything', (
    tester,
  ) async {
    final shell = _Shell();
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ChatPage(session: session))),
    );
    await tester.pump();

    expect(shell.commands, isEmpty);
    expect(find.text('Connect this session first'), findsOneWidget);
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
      MaterialApp(home: Scaffold(body: ChatPage(session: session))),
    );
    await tester.pump();

    await tester.tap(find.text('Sessions on this host'));
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

  testWidgets('a host that cannot list its sessions says what it said',
      (tester) async {
    final shell = _Shell()..listing = "error: unknown command 'agents'";
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ChatPage(session: session))),
    );
    await tester.pump();

    await tester.tap(find.text('Sessions on this host'));
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
      MaterialApp(home: Scaffold(body: ChatPage(session: session))),
    );
    await tester.pumpAndSettle();

    // In view without asking: no sheet, no drawer, and no button in the empty
    // tab to show what is already showing.
    expect(find.text('the nightly build'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Sessions on this host'),
        findsNothing);

    await tester.tap(find.text('the nightly build'));
    await _settlePickUp(tester);

    // Still beside the chat, with the one picked marked, and its
    // conversation drawn next to it.
    final row = tester.widget<ListTile>(
      find.ancestor(
        of: find.text('the nightly build'),
        matching: find.byType(ListTile),
      ),
    );
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
      MaterialApp(home: Scaffold(body: ChatPage(session: session))),
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
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    expect(find.text('Sending…'), findsOneWidget);

    for (var turn = 0; turn < 12; turn++) {
      await tester.pump(const Duration(milliseconds: 250));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    // Into the running session itself, through its attach.
    expect(shell.commands.any((command) => command.contains('attach')),
        isTrue);
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
        MaterialApp(home: Scaffold(body: ChatPage(session: session))),
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
      final asked = shell.commands.where((c) => c.contains('agents')).length;

      await hide();
      expect(find.text('the nightly build'), findsNothing);
      await show();

      expect(find.text('the nightly build'), findsOneWidget);
      expect(
        shell.commands.where((c) => c.contains('agents')).length,
        asked,
      );
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
      MaterialApp(home: Scaffold(body: ChatPage(session: session))),
    );
    await tester.pumpAndSettle();

    final rows = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((tile) => (tile.title! as Text).data)
        .toList();
    expect(rows, ['pinned', 'not pinned']);
    expect(find.byIcon(Icons.push_pin), findsOneWidget);
  });

  testWidgets('a tool row opens to its input and its result', (tester) async {
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
    await tester.enterText(find.byType(TextField), 'check the nginx log');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
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

  group('an opened tool row', () {
    /// Picks a finished session up, has Claude call [name] with [input] and
    /// get [result] back, and opens the row.
    Future<void> opened(
      WidgetTester tester,
      String name,
      Map<String, Object?> input, {
      Object result = 'done',
    }) async {
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
      await tester.enterText(find.byType(TextField), 'go on');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward));
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
      await tester.tap(find.text(name));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
    }

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
      expect(find.byIcon(Icons.indeterminate_check_box_outlined),
          findsOneWidget);
      expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);
    });

    testWidgets('a tool it does not know: each field a line, text as it '
        'reads', (tester) async {
      await opened(tester, 'mcp__tracker__file_issue', {
        'title': 'Nightly is red',
        'body': 'Lint fails.\nSee the log.',
        'labels': ['ci'],
      });
      noJson(tester);
      expect(
        shown(
          'title: Nightly is red\n'
          'body:\nLint fails.\nSee the log.\n'
          'labels: [\n  "ci"\n]',
        ),
        findsOneWidget,
      );
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
      await opened(
        tester,
        'Bash',
        {'command': 'cat notes'},
        result: jsonEncode('first line\nsecond line'),
      );
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
            {
              'pid': 1,
              'id': 'bbbb0002',
              'cwd': '/srv',
              'kind': 'background',
              'startedAt': 200,
              'sessionId': 'bbbb0002-0000-4000-8000-000000000000',
              'name': 'running',
              'status': 'idle',
              'state': 'done',
            },
            _finished('cccc0003', 'finished lately', started: 300),
            _finished('dddd0004', 'pinned and finished', started: 50),
          ])}'
          '\n--- pins\n["dddd0004"]\n';
    final session = LiveSession(host: _host, transport: (_, _) => shell);
    addTearDown(session.dispose);
    await session.connect(secrets: _NoSecrets());

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ChatPage(session: session))),
    );
    await _settlePickUp(tester);

    expect(shell.commands.first, contains('agents --json --all'));
    final order = [
      for (final text in tester.widgetList<Text>(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Text),
        ),
      ))
        if (const {
          'Pinned',
          'Running',
          'Finished (2)',
          'pinned and finished',
          'running',
          'finished lately',
          'finished long ago',
        }.contains(text.data))
          text.data,
    ];
    expect(order, [
      'Pinned',
      'pinned and finished',
      'Running',
      'running',
      'Finished (2)',
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
      MaterialApp(home: Scaffold(body: ChatPage(session: session))),
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
      MaterialApp(home: Scaffold(body: ChatPage(session: session))),
    );
    await _settlePickUp(tester);
    await tester.tap(find.text('the nightly build'));
    await _settlePickUp(tester);
    expect(find.text('It failed at the lint step.'), findsOneWidget);

    await tester.tap(find.byTooltip('New chat'));
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
    final row = tester.widget<ListTile>(
      find.ancestor(
        of: find.text('the nightly build'),
        matching: find.byType(ListTile),
      ),
    );
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
      MaterialApp(home: Scaffold(body: ChatPage(session: session))),
    );
    await tester.pump();
    await _continue(tester, 'dev-e0');

    // Followed live, like any running session, and its turns drawn.
    expect(shell.commands.last, contains(' -f '));
    expect(find.text('It failed at the lint step.'), findsOneWidget);
    // Said to be read-only, why, and nowhere said to take what is sent.
    expect(
      find.textContaining('live, read-only: it runs in a terminal outside '
          'tmux'),
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
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.arrow_upward))
          .onPressed,
      isNull,
    );
    expect(shell.typed, isEmpty);
  });

  testWidgets('a session started at a terminal in a tmux pane takes what is '
      'sent, typed into that pane, and shows it sent once recorded',
      (tester) async {
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
      MaterialApp(home: Scaffold(body: ChatPage(session: session))),
    );
    await tester.pump();
    await _continue(tester, 'dev-e0');

    expect(find.textContaining('in tmux pane %4'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isTrue);
    expect(field.decoration!.hintText, 'Message “dev-e0”…');

    await tester.enterText(find.byType(TextField), 'and the lint?');
    await tester.pump();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.arrow_upward));
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
      MaterialApp(home: Scaffold(body: ChatPage(session: session))),
    );
    await _settlePickUp(tester);
    await tester.tap(find.text('long one'));
    await _settlePickUp(tester);

    // Up at the top of what the first read brought, the offer of more.
    final at = _conversationAt(tester);
    at.jumpTo(at.minScrollExtent);
    await tester.pump();
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
    expect(
      tester.getTopLeft(find.text('turn ${first - 1}')).dy,
      lessThan(y),
    );
    at.jumpTo(at.minScrollExtent);
    await tester.pump();
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
        MaterialApp(home: Scaffold(body: ChatPage(session: session))),
      );
      await _settlePickUp(tester);
      // The conversation's list, not the sidebar's: the one with a
      // controller of its own.
      ScrollPosition at() => _conversationAt(tester);
      return (shell: shell, at: at);
    }

    Future<void> pick(WidgetTester tester, _Shell shell, String name,
        String history) async {
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
      await tester.drag(
        find.byType(CustomScrollView),
        const Offset(0, 120),
      );
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
          MaterialApp(home: Scaffold(body: ChatPage(session: session))),
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
          of: find.byType(ToastCard),
          matching: find.text('Copy'),
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
          of: find.byType(ToastCard),
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
}
