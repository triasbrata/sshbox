import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/chat/aggregator.dart';
import 'package:sshbox/src/chat/claude_chat.dart';
import 'package:sshbox/src/chat/outbox.dart';
import 'package:sshbox/src/session/terminal_session.dart';

const _agent = ClaudeAgent(
  sessionId: '3cae97ea-5874-4a0b-b8bd-6ad88edf0e2f',
  name: 'nginx look',
  cwd: '/srv/app',
  kind: 'background',
  id: '3cae97ea',
  status: 'idle',
  state: 'done',
  pid: 1241689,
);

CommandChannel _says(String text) => (
  output: Stream.value(Uint8List.fromList(utf8.encode(text))),
  write: (Uint8List data) {},
  close: () {},
);

/// The arguments one call of the helper was made with, from the command line
/// the app sent: each is quoted as a word of its own inside `sh -c`.
List<String> _args(String command) => [
  for (final m in RegExp(r"'\\''([^']*)'\\''").allMatches(command)) m[1]!,
];

/// A host with one live session, whose `jeansh-agg.py` says what the test
/// tells it to and whose terminals record what is typed into them.
class _Host {
  final commands = <String>[];

  /// Every call of the helper: its arguments.
  final calls = <List<String>>[];

  /// What the install answers, or that it cannot be reached at all.
  String install = 'ok';
  bool installUnreachable = false;
  int installs = 0;

  /// What the version call answers.
  Map<String, Object?> hello = {'ok': true, 'version': 1};

  /// What `status` answers, one reply per call; the last repeats.
  final statuses = <Map<String, Object?>>[
    {'ok': true, 'state': 'delivered'},
  ];
  var _status = 0;

  /// What `deliver` answers, or that the host cannot be reached.
  Map<String, Object?> deliverReply = {'ok': true, 'state': 'accepted'};
  bool deliverUnreachable = false;
  bool statusUnreachable = false;

  /// What each terminal opened had typed into it.
  final terminals = <List<String>>[];

  StreamController<Uint8List>? follow;

  /// The transcript the host reads back: a size, then its lines.
  String history = '0\n';

  Future<CommandChannel> open(String command) async {
    commands.add(command);
    if (command.contains('jeansh-agg')) {
      if (command.contains('base64 -d')) {
        installs++;
        if (installUnreachable) throw StateError('Not connected.');
        return _says('$install\n');
      }
      final args = _args(command);
      calls.add(args);
      switch (args.first) {
        case 'hello':
          return _says('${jsonEncode(hello)}\n');
        case 'deliver':
          if (deliverUnreachable) throw StateError('Not connected.');
          return _says('${jsonEncode(deliverReply)}\n');
        case 'status':
          if (statusUnreachable) throw StateError('Not connected.');
          final reply = statuses[_status.clamp(0, statuses.length - 1)];
          _status++;
          return _says('${jsonEncode(reply)}\n');
      }
    }
    if (command.contains('agents --json')) {
      return _says(
        jsonEncode([
          {
            'pid': _agent.pid,
            'id': _agent.id,
            'cwd': _agent.cwd,
            'kind': 'background',
            'sessionId': _agent.sessionId,
            'name': _agent.name,
            'status': 'idle',
            'state': 'done',
          },
        ]),
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
    if (command.contains('.jsonl')) return _says(history);
    return _says('');
  }

  Future<CommandChannel> openTerminal(String command) async {
    final typed = <String>[];
    terminals.add(typed);
    final screen = StreamController<Uint8List>();
    scheduleMicrotask(
      () => screen.add(Uint8List.fromList(utf8.encode('\x1b[2J ❯ '))),
    );
    var line = '';
    return (
      output: screen.stream,
      write: (Uint8List data) {
        final keys = utf8.decode(data);
        typed.add(keys);
        if (keys != '\r') {
          line += keys;
          screen.add(Uint8List.fromList(utf8.encode('\r\n❯ $line')));
        }
      },
      close: () => unawaited(screen.close()),
    );
  }

  void adds(Object line) =>
      follow!.add(Uint8List.fromList(utf8.encode('${jsonEncode(line)}\n')));

  List<List<String>> called(String sub) =>
      calls.where((c) => c[0] == sub).toList();
}

Future<void> _until(bool Function() ok, {int seconds = 6}) async {
  final watch = Stopwatch()..start();
  while (!ok()) {
    if (watch.elapsed > Duration(seconds: seconds)) fail('never happened');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Map<String, Object?> _assistant(String text) => {
  'type': 'assistant',
  'message': {
    'role': 'assistant',
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
};

/// A transcript as the host reads it back: its size, then its lines.
String _history(List<Map<String, dynamic>> lines) {
  final body = '${lines.map(jsonEncode).join('\n')}\n';
  return '${utf8.encode(body).length}\n$body';
}

String _b64(String text) => base64Encode(utf8.encode(text));

void main() {
  late _Host host;
  late ClaudeChat chat;

  setUp(() async {
    host = _Host();
    chat = ClaudeChat(
      open: host.open,
      openTerminal: host.openTerminal,
      deliveryTimeout: const Duration(seconds: 2),
      hostKey: 'h1',
      outbox: OutboxStore.shared,
      backoff: (attempt) => const Duration(milliseconds: 60),
    )..useAggregator = true;
    chat.aggregatorPoll = const Duration(milliseconds: 5);
    chat.aggregatorHeldAfter = const Duration(milliseconds: 80);
    addTearDown(chat.dispose);
    await chat.continueFrom(_agent);
  });

  ChatSaid mine() =>
      chat.entries.whereType<ChatSaid>().firstWhere((e) => e.mine);

  List<String> notices() => [
    for (final e in chat.entries.whereType<ChatNotice>()) e.text,
  ];

  group('a message goes to the helper, and nothing is typed', () {
    test('handed over under its outbox id, queued once written, sent once '
        'the transcript has it', () async {
      host.statuses
        ..clear()
        ..addAll([
          {'ok': true, 'state': 'accepted'},
          {'ok': true, 'state': 'sent', 'sessionStatus': 'busy'},
          {'ok': true, 'state': 'delivered'},
        ]);
      final seen = <Delivery?>[];
      chat.addListener(() {
        final said = chat.entries.whereType<ChatSaid>().where((e) => e.mine);
        if (said.isNotEmpty) seen.add(said.first.delivery);
      });
      await chat.send('is the build green?\nand “quoted”');
      await _until(() => host.called('deliver').isNotEmpty);
      final deliver = host.called('deliver').single;
      expect(deliver[2], _agent.sessionId);
      expect(deliver[3], '--text-b64');
      expect(
        utf8.decode(base64Decode(deliver[4])),
        'is the build green?\nand “quoted”',
      );
      expect(deliver[1], mine().outboxId);
      expect(deliver[1], matches(RegExp(r'^[A-Za-z0-9_-]{8,64}$')));
      await _until(() => mine().delivery == null);
      expect(seen, contains(Delivery.queued));
      // The helper was put on the host once, and no terminal was opened.
      expect(host.installs, 1);
      expect(host.terminals, isEmpty);
      expect(
        host.commands.any((c) => c.contains(' attach ') || c.contains('tmux')),
        isFalse,
      );
    });

    test('the helper is installed once for several messages', () async {
      await chat.send('one');
      await _until(() => mine().delivery == null);
      await chat.send('two');
      await _until(() => host.called('deliver').length == 2);
      expect(host.installs, 1);
      expect(host.called('hello'), hasLength(1));
    });

    test('a picture goes in as its path on the host', () async {
      final dir = Directory.systemTemp.createTempSync('agg-pic');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/a.png')
        ..writeAsBytesSync([0x89, 0x50, 0x4e, 0x47, 1]);
      await chat.send(
        'see [Image #1] and [Image #4]',
        pictures: [ChatPicture(path: file.path, name: 'a.png', number: 1)],
        upload: (picture) async => '/tmp/up-${picture.name}',
      );
      await _until(() => host.called('deliver').isNotEmpty);
      expect(
        utf8.decode(base64Decode(host.called('deliver').single[4])),
        'see /tmp/up-a.png and [Image #4]',
      );
    });

    test(
      'a picture that could not be put on the host fails the message',
      () async {
        final dir = Directory.systemTemp.createTempSync('agg-pic');
        addTearDown(() => dir.deleteSync(recursive: true));
        final file = File('${dir.path}/a.png')
          ..writeAsBytesSync([0x89, 0x50, 0x4e, 0x47, 1]);
        await chat.send(
          'see [Image #1]',
          pictures: [ChatPicture(path: file.path, name: 'a.png', number: 1)],
          upload: (picture) async => throw StateError('disk full'),
        );
        await _until(() => mine().delivery == Delivery.failed);
        expect(host.called('deliver'), isEmpty);
      },
    );
  });

  group('what the helper delivered, read from the transcript', () {
    String? text(Object? content) => content is String ? content : null;

    Map<String, dynamic> idle(String id, String said) => {
      'type': 'user',
      'isMeta': true,
      'uuid': 'u-$id',
      'timestamp': '2026-11-27T06:00:00.000Z',
      'origin': {'kind': 'peer', 'from': 'jeansh-$id', 'verifiedPeerPid': 9},
      'message': {
        'role': 'user',
        'content':
            'Another Claude session sent a message:\n$said\n\nThis came from '
            'another Claude session — not typed by your user.',
      },
    };

    Map<String, dynamic> midTurn(String id, String said) => {
      'type': 'attachment',
      'uuid': 'a-$id',
      'timestamp': '2026-11-27T06:00:01.000Z',
      'attachment': {
        'type': 'queued_command',
        'prompt': said,
        'origin': {'kind': 'peer', 'from': 'jeansh-$id'},
        'isMeta': true,
      },
    };

    test('both shapes are read, the wrapper taken off', () {
      final a = peerMessageIn(idle('msg-aaaa', 'two\n\nlines'), text)!;
      expect(a.id, 'msg-aaaa');
      expect(a.text, 'two\n\nlines');
      final b = peerMessageIn(midTurn('msg-bbbb', 'bare words'), text)!;
      expect((b.id, b.text), ('msg-bbbb', 'bare words'));
    });

    test('anything else is not one', () {
      expect(
        peerMessageIn({
          ...idle('x', 'y'),
          'origin': {'kind': 'peer', 'from': 'someone'},
        }, text),
        isNull,
      );
      expect(
        peerMessageIn({
          ...idle('x', 'y'),
          'origin': {'kind': 'human', 'from': 'jeansh-x'},
        }, text),
        isNull,
      );
      expect(
        peerMessageIn({
          ...idle('x', 'y'),
          'origin': {'kind': 'peer', 'from': 'jeansh-'},
        }, text),
        isNull,
      );
      expect(peerMessageIn({...idle('x', 'y'), 'isMeta': false}, text), isNull);
      expect(
        peerMessageIn({
          'type': 'user',
          'isMeta': true,
          'origin': {'kind': 'peer', 'from': 'jeansh-x'},
          'message': {'content': <Object>[]},
        }, text),
        isNull,
      );
      expect(peerMessageIn({'type': 'assistant'}, text), isNull);
      expect(
        peerMessageIn({
          'type': 'attachment',
          'attachment': {'type': 'other'},
        }, text),
        isNull,
      );
    });

    test('words in a wrapper this app does not know are kept whole', () {
      expect(unwrapPeer('plain'), 'plain');
      expect(
        unwrapPeer('Another Claude session sent a message:\nno end'),
        'Another Claude session sent a message:\nno end',
      );
    });

    test('opened on a session, they are the user\'s messages', () async {
      host.history = _history([
        idle('msg-0001-aaaa', 'is the build green?'),
        midTurn('msg-0002-bbbb', 'and the tests?'),
        _assistant('Yes.'),
      ]);
      await chat.continueFrom(_agent);
      final said = [
        for (final e in chat.entries.whereType<ChatSaid>()) (e.mine, e.text),
      ];
      expect(said, [
        (true, 'is the build green?'),
        (true, 'and the tests?'),
        (false, 'Yes.'),
      ]);
    });

    test('a live line for a bubble this chat shows settles it, once', () async {
      host.statuses
        ..clear()
        ..add({'ok': true, 'state': 'sent', 'sessionStatus': 'busy'});
      await chat.send('hello');
      await _until(() => mine().delivery == Delivery.queued);
      final id = mine().outboxId!;
      host.adds(midTurn(id, 'hello'));
      await _until(() => mine().delivery == null);
      expect(
        chat.entries.whereType<ChatSaid>().where((e) => e.mine),
        hasLength(1),
      );
      // The same line again changes nothing.
      host.adds(midTurn(id, 'hello'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        chat.entries.whereType<ChatSaid>().where((e) => e.mine),
        hasLength(1),
      );
      // An empty one draws nothing.
      host.adds(midTurn('msg-9999-zzzz', '   '));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        chat.entries.whereType<ChatSaid>().where((e) => e.mine),
        hasLength(1),
      );
    });

    test('the outbox proves a message by its id and by nothing else', () {
      final at = DateTime.utc(2026, 11, 27, 6);
      OutboxEntry entry(String id, String text) =>
          OutboxEntry(id: id, text: text, createdAt: at);
      final turns = OutboxMatch.turnsIn(
        [
          jsonEncode(idle('second-id-0002', 'same words')),
          jsonEncode(midTurn('other-id-0003', 'unrelated')),
          jsonEncode({
            'type': 'user',
            'uuid': 'u-typed',
            'timestamp': '2026-11-27T06:00:02.000Z',
            'message': {'content': 'typed words'},
          }),
        ].join('\n'),
        text,
      );
      expect(turns.map((t) => t.helperId), [
        'second-id-0002',
        'other-id-0003',
        null,
      ]);
      final matched = OutboxMatch.matched(
        [
          entry('first-id-0001', 'same words'),
          entry('second-id-0002', 'same words'),
        ],
        turns,
        const [],
      );
      // Only the one the helper delivered; the one with the same words, which
      // nobody delivered, is not proved by it.
      expect(matched.keys, ['second-id-0002']);
      expect(matched['second-id-0002'], 'u-second-id-0002');
      // A turn already used proves nothing.
      expect(
        OutboxMatch.matched(
          [entry('second-id-0002', 'same words')],
          turns,
          ['u-second-id-0002'],
        ),
        isEmpty,
      );
    });
  });

  group('a message that waits for its picture', () {
    test('is not given to the helper once the chat has moved to another '
        'session', () async {
      final dir = Directory.systemTemp.createTempSync('agg-pic');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/a.png')
        ..writeAsBytesSync([0x89, 0x50, 0x4e, 0x47, 1]);
      final gate = Completer<String>();
      await chat.send(
        'see [Image #1]',
        pictures: [ChatPicture(path: file.path, name: 'a.png', number: 1)],
        upload: (picture) => gate.future,
      );
      await _until(() => host.installs == 1);
      await chat.continueFrom(
        const ClaudeAgent(
          sessionId: '0f0f0f0f-5874-4a0b-b8bd-6ad88edf0e2f',
          name: 'other',
          cwd: '/srv/other',
          kind: 'background',
          id: '0f0f0f0f',
          status: 'idle',
          state: 'done',
          pid: 7,
        ),
      );
      gate.complete('/tmp/up.png');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.called('deliver'), isEmpty);
    });
  });

  group('without an outbox', () {
    test('a message still gets an id of its own to be looked up by', () async {
      final plain = ClaudeChat(open: host.open, openTerminal: host.openTerminal)
        ..useAggregator = true;
      plain.aggregatorPoll = const Duration(milliseconds: 5);
      addTearDown(plain.dispose);
      await plain.continueFrom(_agent);
      host
        ..deliverUnreachable = true
        ..statuses.clear();
      host.statuses.add({'ok': true, 'state': 'unknown', 'reason': 'x'});
      await plain.send('hello');
      final said = plain.entries.whereType<ChatSaid>().firstWhere(
        (e) => e.mine,
      );
      await _until(
        () => said.why?.contains('could not reach the host') ?? false,
      );
      expect(said.outboxId, isNull);
      expect(
        host.called('deliver').single[1],
        matches(RegExp(r'^[A-Za-z0-9_-]{8,64}$')),
      );
    });
  });

  group('the older way is used, and said once, when the helper cannot', () {
    test('a host with no python3', () async {
      host.install = 'nopython';
      await chat.send('one');
      await _until(() => host.terminals.isNotEmpty);
      await chat.send('two');
      await _until(() => notices().any((n) => n.contains('no python3')));
      expect(notices().where((n) => n.contains('older way')), [
        'Messages go in the older way: this host has no python3.',
      ]);
      expect(host.called('deliver'), isEmpty);
    });

    test('an install that was refused', () async {
      host.install = 'refused';
      await chat.send('one');
      await _until(() => notices().any((n) => n.contains('could not be put')));
      expect(host.called('deliver'), isEmpty);
    });

    test('a helper that does not answer hello', () async {
      host.hello = {'ok': false};
      await chat.send('one');
      await _until(() => notices().any((n) => n.contains('did not answer')));
    });

    test('a host that cannot be reached is tried again by itself, and the '
        'next try asks again', () async {
      host.installUnreachable = true;
      await chat.send('one');
      await _until(
        () =>
            mine().why?.contains('Could not check on the host first') ?? false,
      );
      expect(host.terminals, isEmpty);
      host.installUnreachable = false;
      await _until(() => host.called('deliver').isNotEmpty);
      expect(host.installs, greaterThanOrEqualTo(2));
      expect(host.terminals, isEmpty);
    });

    test('the session holds messages from others: never written, typed '
        'instead with the reason', () async {
      host.statuses
        ..clear()
        ..add({
          'ok': true,
          'state': 'refused',
          'reason': 'crossSessionInbound is hold',
        });
      await chat.send('one');
      await _until(() => host.terminals.isNotEmpty);
      await _until(
        () => notices().any((n) => n.contains('crossSessionInbound is hold')),
      );
      expect(host.called('deliver'), hasLength(1));
      await _until(() => host.terminals.single.contains('\r'));
      expect(host.terminals.single, ['one', '\r']);
    });

    test('a refusal with no reason still says so', () async {
      host.statuses
        ..clear()
        ..add({'ok': true, 'state': 'refused'});
      await chat.send('one');
      await _until(
        () => notices().any((n) => n.contains('holds messages from others')),
      );
    });
  });

  group('a message the helper may have written is never typed', () {
    test('delivering that fails to reach the host: tried again by itself '
        'under the same id', () async {
      host.deliverUnreachable = true;
      await chat.send('hello');
      await _until(
        () => mine().why?.contains('could not reach the host') ?? false,
      );
      final id = mine().outboxId;
      expect(id, isNotNull);
      host.deliverUnreachable = false;
      await _until(() => host.called('deliver').isNotEmpty);
      expect(host.called('deliver').single[1], id);
      expect(host.terminals, isEmpty);
    });

    test('the helper refusing the call fails it with its words', () async {
      host.deliverReply = {
        'ok': false,
        'error': 'the journal folder is not ours',
      };
      await chat.send('hello');
      await _until(() => mine().delivery == Delivery.failed);
      expect(mine().why, contains('the journal folder is not ours'));
      host.deliverReply = {'ok': false};
      expect(chat.retry(mine()), isNull);
      await _until(
        () => mine().why?.contains('the helper refused it') ?? false,
      );
    });

    test('the helper going away after the message was given to it: failed '
        'with no typing', () async {
      host.statusUnreachable = true;
      await chat.send('hello');
      await _until(() => mine().delivery == Delivery.failed);
      expect(mine().why, contains('Retry looks it up again'));
      expect(host.terminals, isEmpty);
    });

    test('an install that fails for a message already given still never '
        'types', () async {
      // Given first, then the host answers that it has no python any more.
      host.statuses
        ..clear()
        ..add({'ok': true, 'state': 'unknown', 'reason': 'x'});
      await chat.send('hello');
      await _until(() => mine().delivery == Delivery.failed);
      // The cached readiness is what a retry meets: a new chat on the same
      // host would install again; here the helper answers, so a retry types.
      expect(chat.retry(mine()), isNull);
      await _until(() => host.terminals.isNotEmpty);
    });
  });

  group('what the helper says about a message in the session', () {
    test('written, the session idle, and not taken: failed with Retry typing '
        'it in, never sent a second time by itself', () async {
      host.statuses
        ..clear()
        ..add({'ok': true, 'state': 'sent', 'sessionStatus': 'idle'});
      await chat.send('hello');
      await _until(() => mine().delivery == Delivery.failed);
      expect(mine().why, contains('Not taken'));
      expect(mine().why, contains('arrives twice'));
      expect(host.terminals, isEmpty);
      expect(chat.retry(mine()), isNull);
      await _until(() => host.terminals.isNotEmpty);
      expect(host.called('deliver'), hasLength(1));
    });

    test('a busy session is waited for as long as it takes', () async {
      host.statuses
        ..clear()
        ..addAll([
          {'ok': true, 'state': 'sent', 'sessionStatus': 'busy'},
          {'ok': true, 'state': 'sent', 'sessionStatus': 'busy'},
          {'ok': true, 'state': 'sent', 'sessionStatus': 'idle'},
          // Busy again before the idle time is up: the clock starts over.
          {'ok': true, 'state': 'sent', 'sessionStatus': 'busy'},
          {'ok': true, 'state': 'delivered'},
        ]);
      await chat.send('hello');
      await _until(() => mine().delivery == null);
      expect(mine().why, isNull);
    });

    test('not running on the host', () async {
      host.statuses
        ..clear()
        ..add({
          'ok': true,
          'state': 'undeliverable',
          'reason': 'the session is not running on this host',
        });
      await chat.send('hello');
      await _until(() => mine().delivery == Delivery.failed);
      expect(mine().why, 'the session is not running on this host.');
    });

    test('undeliverable with no reason', () async {
      host.statuses
        ..clear()
        ..add({'ok': true, 'state': 'undeliverable'});
      await chat.send('hello');
      await _until(() => mine().delivery == Delivery.failed);
      expect(mine().why, 'Not delivered.');
    });

    test(
      'the helper could not say if it wrote it: failed, and Retry types',
      () async {
        host.statuses
          ..clear()
          ..add({'ok': true, 'state': 'unknown', 'reason': 'the write ended'});
        await chat.send('hello');
        await _until(() => mine().delivery == Delivery.failed);
        expect(mine().why, contains('could not say whether it was written'));
        expect(mine().why, contains('the write ended'));
        expect(host.terminals, isEmpty);
      },
    );

    test('an id the journal never saw', () async {
      host.statuses
        ..clear()
        ..add({'ok': true, 'state': 'unknown-id'});
      await chat.send('hello');
      await _until(() => mine().delivery == Delivery.failed);
      expect(mine().why, contains('no reason'));
    });
  });

  group('Claude refusing to change its own configuration', () {
    test('is explained once, with the terminal as the way to ask', () async {
      await chat.send('append a line to CLAUDE.md');
      await _until(() => mine().delivery == null);
      host.adds(
        _assistant(
          "I didn't append it: a peer session asked, and I don't edit "
          'CLAUDE.md on a peer\'s request.',
        ),
      );
      await _until(() => notices().any((n) => n.contains('Open the terminal')));
      host.adds(_assistant('A peer asked me not to edit settings. I refuse.'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        notices().where((n) => n.contains('Open the terminal')),
        hasLength(1),
      );
    });

    test('an ordinary answer is left alone', () async {
      await chat.send('hello');
      await _until(() => mine().delivery == null);
      host.adds(_assistant('Hello. A peer would say the same.'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(notices().where((n) => n.contains('Open the terminal')), isEmpty);
    });

    test(
      'nothing is said of a refusal unconnected to a message sent here',
      () async {
        host.adds(
          _assistant(
            "A peer asked; I don't edit CLAUDE.md on a peer's request.",
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          notices().where((n) => n.contains('Open the terminal')),
          isEmpty,
        );
      },
    );
  });

  group('the client', () {
    test('reads the first JSON line and ignores noise', () async {
      final aggregator = Aggregator(
        (command) async => _says('warning\n{broken\n{"ok":true,"state":"x"}\n'),
      );
      final reply = await aggregator.call(const ['status', 'abcdefgh']);
      expect(reply.ok, isTrue);
      expect(reply.state, 'x');
      expect(reply.reason, isNull);
      expect(reply.duplicate, isFalse);
      expect(reply.error, isNull);
      expect(reply.sessionStatus, isNull);
    });

    test('throws what the host said when it was no JSON', () async {
      final aggregator = Aggregator((command) async => _says('boom\n'));
      await expectLater(
        aggregator.call(const ['hello']),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('boom'),
          ),
        ),
      );
      final silent = Aggregator((command) async => _says(''));
      await expectLater(
        silent.call(const ['hello']),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('nothing'),
          ),
        ),
      );
    });

    test('a host that never answers is given up on', () async {
      final aggregator = Aggregator(
        (command) async => (
          output: StreamController<Uint8List>().stream,
          write: (Uint8List data) {},
          close: () {},
        ),
        timeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        aggregator.call(const ['hello']),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('deliver sends the text as base64', () async {
      String? sent;
      final aggregator = Aggregator((command) async {
        sent = command;
        return _says('{"ok":true,"state":"accepted"}\n');
      });
      final reply = await aggregator.deliver('abcdefgh', 'sid', "it's “x”");
      expect(reply.state, 'accepted');
      expect(sent, contains(_b64("it's “x”")));
      expect(sent, startsWith('sh -c '));
    });
  });
}
