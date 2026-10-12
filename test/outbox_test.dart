import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/chat/outbox.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';

OutboxEntry _entry(String id, String text, DateTime at, {bool failed = false}) =>
    OutboxEntry(id: id, text: text, createdAt: at.toUtc(), failed: failed);

String _turn(String uuid, String text, DateTime at) => jsonEncode({
  'type': 'user',
  'uuid': uuid,
  'timestamp': at.toUtc().toIso8601String(),
  'message': {'role': 'user', 'content': text},
});

String? _plain(Object? content) => content is String ? content : null;

void main() {
  late Directory dir;
  late OutboxStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('outbox-test');
    store = OutboxStore(() async => Directory('${dir.path}/chat_outbox'));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  final t0 = DateTime.utc(2026, 10, 10, 12);

  group('the store', () {
    test('keeps what was saved, in order, across a new store over the same '
        'folder', () async {
      final key = OutboxStore.keyOf('host-1', 'sess-1');
      final box = OutboxBox()
        ..entries.addAll([
          _entry('a', 'first', t0),
          _entry('b', 'second', t0.add(const Duration(seconds: 1)), failed: true)
            ..why = 'no route'
            ..attempts = 2,
        ])
        ..consumed.add('turn-1');
      await store.save(key, box);

      final again = OutboxStore(() async => Directory('${dir.path}/chat_outbox'));
      final read = await again.load(key);
      expect([for (final e in read.entries) e.text], ['first', 'second']);
      expect(read.entries[1].failed, isTrue);
      expect(read.entries[1].why, 'no route');
      expect(read.entries[1].attempts, 2);
      expect(read.entries[0].createdAt, t0);
      expect(read.consumed, ['turn-1']);
    });

    test('an empty box deletes the file, so nothing of a delivered message '
        'stays on disk', () async {
      final key = OutboxStore.keyOf('h', 's');
      await store.save(key, OutboxBox(entries: [_entry('a', 'secret words', t0)]));
      final file = File('${dir.path}/chat_outbox/$key.json');
      expect(file.existsSync(), isTrue);
      expect(file.readAsStringSync(), contains('secret words'));
      await store.save(key, OutboxBox());
      expect(file.existsSync(), isFalse);
    });

    test('a file that cannot be read is set aside, said, and does not take '
        'the chat down', () async {
      final key = OutboxStore.keyOf('h', 's');
      await store.save(key, OutboxBox(entries: [_entry('a', 'x', t0)]));
      final file = File('${dir.path}/chat_outbox/$key.json')
        ..writeAsStringSync('{ not json');
      var said = 0;
      final box = await store.load(key, onCorrupt: () => said++);
      expect(box.entries, isEmpty);
      expect(said, 1);
      expect(File('${file.path}.bad').existsSync(), isTrue);
    });

    test('a write that cannot be made throws, so the message is never '
        'accepted', () async {
      // The folder's place is a file: nothing can be created there.
      File('${dir.path}/blocked').writeAsStringSync('x');
      final blocked = OutboxStore(
        () async => Directory('${dir.path}/blocked/chat_outbox'),
      );
      await expectLater(
        blocked.save('k', OutboxBox(entries: [_entry('a', 'x', t0)])),
        throwsA(isA<OutboxException>()),
      );
    });

    test('writes to one file are made in the order asked', () async {
      final key = OutboxStore.keyOf('h', 's');
      final writes = [
        for (var i = 0; i < 20; i++)
          store.save(key, OutboxBox(entries: [_entry('e$i', 'v$i', t0)])),
      ];
      await Future.wait(writes);
      final read = await store.load(key);
      expect(read.entries.single.text, 'v19');
    });

    test('only the newest proofs are kept, so the file never grows without '
        'end', () async {
      final key = OutboxStore.keyOf('h', 's');
      await store.save(
        key,
        OutboxBox(consumed: [for (var i = 0; i < 300; i++) 't$i']),
      );
      final read = await store.load(key);
      expect(read.consumed, hasLength(OutboxBox.consumedCap));
      expect(read.consumed.last, 't299');
      expect(read.consumed.first, 't100');
    });

    test('a picture that cannot be copied is a visible failure', () async {
      await expectLater(
        store.copyPicture('e', 'x.png', '${dir.path}/absent.png'),
        throwsA(isA<OutboxException>()),
      );
    });

    test('file names hold only what a name can: a host or session id with '
        'a slash cannot leave the folder', () {
      expect(OutboxStore.keyOf('../../x', 'a/b'), isNot(contains('/')));
      expect(OutboxStore.keyOf('../../x', 'a/b'), isNot(contains('..')));
    });

    test('deleting a host deletes its files and picture copies, and no one '
        'else\'s', () async {
      final mine = OutboxStore.keyOf('gone', 's1');
      final other = OutboxStore.keyOf('kept', 's1');
      final source = File('${dir.path}/pic.png')..writeAsBytesSync([1, 2, 3]);
      final copy = await store.copyPicture('a', 'pic.png', source.path);
      await store.save(
        mine,
        OutboxBox(
          entries: [
            OutboxEntry(
              id: 'a',
              text: 'x',
              createdAt: t0,
              pictures: [OutboxPicture(name: 'pic.png', path: copy, number: 1)],
            ),
          ],
        ),
      );
      await store.save(other, OutboxBox(entries: [_entry('b', 'y', t0)]));
      await store.deleteHost('gone');
      expect(File('${dir.path}/chat_outbox/$mine.json').existsSync(), isFalse);
      expect(File(copy).existsSync(), isFalse);
      expect(File('${dir.path}/chat_outbox/$other.json').existsSync(), isTrue);
    });

    test('a sweep removes what belongs to hosts no longer saved, keeps this '
        'machine\'s own shells, and removes picture copies nothing refers to',
        () async {
      await store.save(OutboxStore.keyOf('h1', 's'), OutboxBox(entries: [_entry('a', 'x', t0)]));
      await store.save(OutboxStore.keyOf('h2', 's'), OutboxBox(entries: [_entry('b', 'x', t0)]));
      await store.save(OutboxStore.keyOf('local', 's'), OutboxBox(entries: [_entry('c', 'x', t0)]));
      await store.save(OutboxStore.keyOf('wsl:Ubuntu', 's'), OutboxBox(entries: [_entry('d', 'x', t0)]));
      final source = File('${dir.path}/pic.png')..writeAsBytesSync([1]);
      final orphan = await store.copyPicture('zzz', 'pic.png', source.path);
      await store.sweep({'h1'});
      final names = Directory('${dir.path}/chat_outbox')
          .listSync()
          .map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last)
          .toSet();
      expect(names.any((n) => n.startsWith('h1__')), isTrue);
      expect(names.any((n) => n.startsWith('h2__')), isFalse);
      expect(names.any((n) => n.startsWith('local__')), isTrue);
      expect(names.any((n) => n.startsWith('wsl_Ubuntu__')), isTrue);
      expect(File(orphan).existsSync(), isFalse);
    });
  });

  group('which messages a transcript already holds', () {
    test('two identical messages need two turns: one turn proves one', () {
      final entries = [
        _entry('a', 'ok', t0),
        _entry('b', 'ok', t0.add(const Duration(seconds: 1))),
      ];
      final one = OutboxMatch.turnsIn(
        _turn('u1', 'ok', t0.add(const Duration(seconds: 2))),
        _plain,
      );
      var hit = OutboxMatch.matched(entries, one, const []);
      expect(hit, {'a': 'u1'});

      final two = OutboxMatch.turnsIn(
        '${_turn('u1', 'ok', t0.add(const Duration(seconds: 2)))}\n'
        '${_turn('u2', 'ok', t0.add(const Duration(seconds: 3)))}',
        _plain,
      );
      hit = OutboxMatch.matched(entries, two, const []);
      expect(hit, {'a': 'u1', 'b': 'u2'});
    });

    test('a turn already owned by a delivered message proves nothing', () {
      final turns = OutboxMatch.turnsIn(
        _turn('u1', 'ok', t0.add(const Duration(seconds: 2))),
        _plain,
      );
      // The first "ok" was delivered live and u1 was its proof; the second,
      // failed, must not be called delivered by the same turn.
      final hit = OutboxMatch.matched(
        [_entry('b', 'ok', t0.add(const Duration(seconds: 1)))],
        turns,
        ['u1'],
      );
      expect(hit, isEmpty);
    });

    test('an earlier message takes the turn first, so the later one stays '
        'unproven', () {
      final turns = OutboxMatch.turnsIn(
        _turn('u1', 'ok', t0.add(const Duration(seconds: 2))),
        _plain,
      );
      final hit = OutboxMatch.matched(
        [_entry('a', 'ok', t0), _entry('b', 'ok', t0.add(const Duration(seconds: 1)))],
        turns,
        const [],
      );
      expect(hit.keys, ['a']);
    });

    test('a turn older than the message does not prove it (beyond the clock '
        'skew)', () {
      final old = OutboxMatch.turnsIn(
        _turn('u1', 'hello', t0.subtract(const Duration(minutes: 10))),
        _plain,
      );
      expect(OutboxMatch.matched([_entry('a', 'hello', t0)], old, const []), isEmpty);
      final skewed = OutboxMatch.turnsIn(
        _turn('u1', 'hello', t0.subtract(const Duration(seconds: 30))),
        _plain,
      );
      expect(OutboxMatch.matched([_entry('a', 'hello', t0)], skewed, const []), {
        'a': 'u1',
      });
    });

    test('different words, and a picture\'s number, are compared as Claude '
        'records them', () {
      final turns = OutboxMatch.turnsIn(
        '${_turn('u1', 'look at [Image #7] please', t0)}\n'
        '${_turn('u2', 'something else', t0)}',
        _plain,
      );
      final hit = OutboxMatch.matched(
        [_entry('a', 'look at [Image #1] please', t0), _entry('b', 'other', t0)],
        turns,
        const [],
      );
      expect(hit, {'a': 'u1'});
    });

    test('queued commands count as turns; side chains, meta lines and bad '
        'lines do not', () {
      final queued = jsonEncode({
        'type': 'attachment',
        'uuid': 'q1',
        'timestamp': t0.toIso8601String(),
        'attachment': {'type': 'queued_command', 'prompt': 'later'},
      });
      final side = jsonEncode({
        'type': 'user',
        'uuid': 's1',
        'isSidechain': true,
        'timestamp': t0.toIso8601String(),
        'message': {'content': 'hidden'},
      });
      final meta = jsonEncode({
        'type': 'user',
        'uuid': 'm1',
        'isMeta': true,
        'timestamp': t0.toIso8601String(),
        'message': {'content': 'meta'},
      });
      final turns = OutboxMatch.turnsIn(
        '$queued\n$side\n$meta\nnot json\n{"type":"user"}\n',
        _plain,
      );
      expect([for (final t in turns) t.text], ['later']);
      expect(turns.single.key, 'q1');
    });
  });

  test('the automatic retry waits 2 s, 5 s, 15 s, 45 s, 2 min, then gives up',
      () {
    expect([for (var i = 0; i < 6; i++) outboxBackoff(i)], [
      const Duration(seconds: 2),
      const Duration(seconds: 5),
      const Duration(seconds: 15),
      const Duration(seconds: 45),
      const Duration(minutes: 2),
      null,
    ]);
  });

  test('deleting a host from the repository deletes what was kept unsent '
      'for its chats, and not another host\'s', () async {
    SharedPreferences.setMockInitialValues({});
    final shared = OutboxStore.shared = OutboxStore.memory();
    final gone = OutboxStore.keyOf('gone', 's');
    final kept = OutboxStore.keyOf('kept', 's');
    await shared.save(gone, OutboxBox(entries: [_entry('a', 'x', t0)]));
    await shared.save(kept, OutboxBox(entries: [_entry('b', 'y', t0)]));

    await HostRepository(InMemorySecretStore()).delete('gone');

    expect((await shared.load(gone)).entries, isEmpty);
    expect((await shared.load(kept)).entries, hasLength(1));
  });
}
