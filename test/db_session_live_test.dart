import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/db/db_session.dart';
import 'package:sshbox/src/session/terminal_session.dart';

/// What the database browser does with each kind — its side list, what a
/// tap on an entry runs, and the grid a run gives — against the real
/// servers `db_live_test.dart` names, skipping itself where one is not up.
/// Run that test first: it makes the MongoDB user.
Future<Tunnel?> _dial(int port) async {
  try {
    final socket = await Socket.connect(
      '127.0.0.1',
      port,
      timeout: const Duration(seconds: 2),
    );
    return (output: socket, input: socket);
  } on SocketException {
    return null;
  }
}

void main() {
  test('PostgreSQL: lists tables by schema and shows one', () async {
    final tunnel = await _dial(55432);
    if (tunnel == null) return printOnFailure('skipped: no server on 55432');
    final session = await DbSession.over(
      tunnel,
      const DbConnection(
        id: 'pg',
        kind: DbKind.postgres,
        hostId: 'box',
        port: 55432,
      ),
      'pgsecret',
    );
    addTearDown(session.close);

    final made = await session.run(
      'CREATE TABLE IF NOT EXISTS "Jeansh People" (id int, name text); '
      'TRUNCATE "Jeansh People"; '
      "INSERT INTO \"Jeansh People\" VALUES (1, 'ann'), (2, NULL)",
    );
    expect(made.note, 'CREATE TABLE · TRUNCATE TABLE · INSERT 0 2');
    addTearDown(() => session.run('DROP TABLE "Jeansh People"'));

    expect(await session.objects('people'), {
      'public': ['Jeansh People'],
    });
    final query = await session.queryFor('public', 'Jeansh People');
    expect(query, 'SELECT * FROM public."Jeansh People" LIMIT 100;');
    final shown = await session.run(query);
    expect(shown.columns, ['id', 'name']);
    expect(shown.rows, [
      ['1', 'ann'],
      ['2', null],
    ]);
    expect(shown.note, 'SELECT 2');
  });

  test('PostgreSQL: saves what the grid changed, all or nothing', () async {
    final tunnel = await _dial(55432);
    if (tunnel == null) return printOnFailure('skipped: no server on 55432');
    final session = await DbSession.over(
      tunnel,
      const DbConnection(
        id: 'pg',
        kind: DbKind.postgres,
        hostId: 'box',
        port: 55432,
      ),
      'pgsecret',
    );
    addTearDown(session.close);

    await session.run(
      'DROP TABLE IF EXISTS "Jeansh Edit", jeansh_nokey; '
      'CREATE TABLE "Jeansh Edit" '
      '(id serial PRIMARY KEY, "Name" text, n int DEFAULT 7); '
      "INSERT INTO \"Jeansh Edit\" (\"Name\") VALUES ('ann'), ('bob'), ('cy'); "
      'CREATE TABLE jeansh_nokey (x int)',
    );
    addTearDown(() => session.run('DROP TABLE "Jeansh Edit", jeansh_nokey'));

    // No primary key, or two tables: nothing to edit.
    expect((await session.run('SELECT * FROM jeansh_nokey')).edit, isNull);
    expect(
      (await session.run(
        'SELECT e.id, k.x FROM "Jeansh Edit" e, jeansh_nokey k',
      )).edit,
      isNull,
    );

    // An alias still edits its own column.
    final shown = await session.run(
      'SELECT id, "Name" AS who FROM "Jeansh Edit" ORDER BY id',
    );
    final changes = DbChanges()
      ..set(shown.rows, 0, 1, r"it's a \ back\slash")
      ..set(shown.rows, 1, 1, null)
      ..deleted.add(2)
      ..added.add({1: 'dee'})
      ..added.add({});
    expect(await shown.edit!.save(changes), isNull);
    final all = 'SELECT id, "Name", n FROM "Jeansh Edit" ORDER BY id';
    final saved = [
      ['1', r"it's a \ back\slash", '7'],
      ['2', null, '7'],
      ['4', 'dee', '7'],
      ['5', null, '7'],
    ];
    expect((await session.run(all)).rows, saved);

    // One change refused makes none of them.
    final again = await session.run('SELECT * FROM "Jeansh Edit" ORDER BY id');
    final refused = DbChanges()
      ..set(again.rows, 0, 1, 'not kept')
      ..set(again.rows, 1, 2, 'not a number');
    await expectLater(again.edit!.save(refused), throwsA(isA<Exception>()));
    expect((await session.run(all)).rows, saved);
  });

  test('MongoDB: saves what the grid changed, a write at a time', () async {
    final tunnel = await _dial(57017);
    if (tunnel == null) return printOnFailure('skipped: no server on 57017');
    final session = await DbSession.over(
      tunnel,
      const DbConnection(
        id: 'mongo',
        kind: DbKind.mongo,
        hostId: 'box',
        port: 57017,
        user: 'jeansh',
      ),
      'mongosecret',
    );
    addTearDown(session.close);

    await session
        .run('{"drop": "edits", "\$db": "jeansh"}')
        .catchError((_) => const DbResult());
    await session.run(
      '{"insert": "edits", "documents": [{"_id": 1, "name": "ann", '
      '"age": 30}, {"_id": 2, "name": "bob", "age": 2.5}, '
      '{"_id": 3, "name": "cy"}], "\$db": "jeansh"}',
    );
    await session.run(
      '{"createIndexes": "edits", "indexes": [{"key": {"name": 1}, '
      '"name": "name", "unique": true}], "\$db": "jeansh"}',
    );
    addTearDown(() => session.run('{"drop": "edits", "\$db": "jeansh"}'));

    const find = '{"find": "edits", "sort": {"_id": 1}, "\$db": "jeansh"}';
    Future<List<Map<String, Object?>>> documents() async => [
      for (final json in (await session.run(find)).details!)
        jsonDecode(json) as Map<String, Object?>,
    ];

    // Only what a find reads is edited, and never its _id.
    expect(
      (await session.run('{"count": "edits", "\$db": "jeansh"}')).edit,
      isNull,
    );
    final shown = await session.run(find);
    expect(shown.columns, ['_id', 'name', 'age']);
    expect(shown.edit!.locked, {0});

    // A string stays a string, a number a number and a double a double.
    final changes = DbChanges()
      ..set(shown.rows, 0, 1, '42')
      ..set(shown.rows, 0, 2, '31')
      ..set(shown.rows, 1, 1, null)
      ..set(shown.rows, 1, 2, '3')
      ..deleted.add(2)
      ..added.add({1: 'dee', 2: '40'});
    expect(await shown.edit!.save(changes), isNull);
    final [ann, bob, dee] = await documents();
    expect(ann, {'_id': 1, 'name': '42', 'age': 31});
    expect(bob, {'_id': 2, 'name': null, 'age': 3});
    expect(bob['age'], isA<double>());
    expect(dee['name'], 'dee');
    expect(dee['age'], 40);
    expect(dee['_id'], contains(r'$oid'));

    // The first write refused: none made, and it says why.
    final again = await session.run(find);
    await expectLater(
      again.edit!.save(DbChanges()..added.add({1: 'dee'})),
      throwsA(isA<Exception>()),
    );
    // One refused after another was made: it is said, and the other stays.
    expect(
      await again.edit!.save(
        DbChanges()
          ..set(again.rows, 0, 1, 'zed')
          ..added.add({1: 'dee'}),
      ),
      contains('duplicate key'),
    );
    expect((await documents()).first['name'], 'zed');
  });

  test('Redis: saves what the grid changed in one MULTI', () async {
    final tunnel = await _dial(56379);
    if (tunnel == null) return printOnFailure('skipped: no server on 56379');
    final session = await DbSession.over(
      tunnel,
      const DbConnection(
        id: 'redis',
        kind: DbKind.redis,
        hostId: 'box',
        port: 56379,
      ),
      'redsecret',
    );
    addTearDown(session.close);

    const keys = 'je:h je:l je:s je:z je:str';
    await session.run('DEL $keys');
    addTearDown(() => session.run('DEL $keys'));
    await session.run('HSET je:h a 1 b 2 c 3');
    await session.run('RPUSH je:l x y z w');
    await session.run('SADD je:s p q r');
    await session.run('ZADD je:z 1 m1 2 m2 3 m3');
    await session.run('SET je:str old EX 1000');

    // A hash: a field renamed, a value changed, one deleted, one added.
    var shown = await session.run('HGETALL je:h');
    expect(
      await shown.edit!.save(
        DbChanges()
          ..set(shown.rows, 0, 0, 'a2')
          ..set(shown.rows, 1, 1, '20')
          ..deleted.add(2)
          ..added.add({0: 'd', 1: '4'}),
      ),
      isNull,
    );
    expect(
      {
        for (final [field, value] in (await session.run('HGETALL je:h')).rows)
          field: value,
      },
      {'a2': '1', 'b': '20', 'd': '4'},
    );

    // A list: its place is no value; one set, two taken out, one pushed.
    shown = await session.run('LRANGE je:l 0 99');
    expect(shown.edit!.locked, {0});
    expect(
      await shown.edit!.save(
        DbChanges()
          ..set(shown.rows, 1, 1, 'Y')
          ..deleted.addAll([0, 2])
          ..added.add({1: 'v'}),
      ),
      isNull,
    );
    expect(
      [
        for (final [_, value] in (await session.run('LRANGE je:l 0 99')).rows)
          value,
      ],
      ['Y', 'w', 'v'],
    );

    // A set: a member renamed, one removed, one added.
    shown = await session.run('SMEMBERS je:s');
    final members = [for (final [_, member] in shown.rows) member];
    expect(
      await shown.edit!.save(
        DbChanges()
          ..set(shown.rows, members.indexOf('q'), 1, 'Q')
          ..deleted.add(members.indexOf('r'))
          ..added.add({1: 's'}),
      ),
      isNull,
    );
    expect(
      {
        for (final [_, member] in (await session.run('SMEMBERS je:s')).rows)
          member,
      },
      {'p', 'Q', 's'},
    );

    // A sorted set: a member renamed, a score changed, one removed, one
    // added.
    const zrange = 'ZRANGE je:z 0 -1 WITHSCORES';
    shown = await session.run(zrange);
    expect(
      await shown.edit!.save(
        DbChanges()
          ..set(shown.rows, 0, 0, 'n1')
          ..set(shown.rows, 1, 1, '20')
          ..deleted.add(2)
          ..added.add({0: 'm4', 1: '4'}),
      ),
      isNull,
    );
    final ranked = [
      ['n1', '1'],
      ['m4', '4'],
      ['m2', '20'],
    ];
    expect((await session.run(zrange)).rows, ranked);
    // A score that is no number is refused before anything is sent.
    shown = await session.run(zrange);
    await expectLater(
      shown.edit!.save(
        DbChanges()
          ..set(shown.rows, 0, 0, 'lost')
          ..set(shown.rows, 0, 1, 'high'),
      ),
      throwsA(isA<Exception>()),
    );
    expect((await session.run(zrange)).rows, ranked);

    // A string keeps its time to live, and takes no new row.
    shown = await session.run('GET je:str');
    expect(shown.edit!.adds, isFalse);
    expect(
      await shown.edit!.save(DbChanges()..set(shown.rows, 0, 0, 'new')),
      isNull,
    );
    expect((await session.run('GET je:str')).rows, [
      ['new'],
    ]);
    expect(
      int.parse((await session.run('TTL je:str')).rows.single.single!),
      greaterThan(0),
    );

    // A key whose type changed under it: what failed is said, not thrown.
    shown = await session.run('HGETALL je:h');
    await session.run('DEL je:h');
    await session.run('SET je:h x');
    expect(
      await shown.edit!.save(DbChanges()..set(shown.rows, 0, 1, 'y')),
      contains('WRONGTYPE'),
    );
  });

  test('MongoDB: lists collections by database and finds in one', () async {
    final tunnel = await _dial(57017);
    if (tunnel == null) return printOnFailure('skipped: no server on 57017');
    final session = await DbSession.over(
      tunnel,
      const DbConnection(
        id: 'mongo',
        kind: DbKind.mongo,
        hostId: 'box',
        port: 57017,
        user: 'jeansh',
      ),
      'mongosecret',
    );
    addTearDown(session.close);

    await session
        .run('{"drop": "people", "\$db": "jeansh"}')
        .catchError((_) => const DbResult());
    final inserted = await session.run(
      '{"insert": "people", "documents": [{"name": "ann", "age": 30}, '
      '{"name": "bob"}], "\$db": "jeansh"}',
    );
    expect(inserted.note, 'OK');
    expect(inserted.columns, containsAll(['n', 'ok']));

    expect((await session.objects('people'))['jeansh'], ['people']);
    final query = await session.queryFor('jeansh', 'people');
    expect(query, contains('"find": "people"'));
    expect(query, contains('"\$db": "jeansh"'));
    final shown = await session.run(query);
    expect(shown.note, '2 documents');
    expect(shown.columns, ['_id', 'name', 'age']);
    expect([for (final row in shown.rows) row.sublist(1)], [
      ['ann', '30'],
      ['bob', null],
    ]);
    expect(shown.details!.first, contains('"name": "ann"'));
    expect(shown.rows.first.first, startsWith('{"\$oid":'));

    await expectLater(
      session.run('db.people.find()'),
      throwsA(isA<Exception>()),
    );
  });

  test('Redis: lists keys and shows each by its type', () async {
    final tunnel = await _dial(56379);
    if (tunnel == null) return printOnFailure('skipped: no server on 56379');
    final session = await DbSession.over(
      tunnel,
      const DbConnection(
        id: 'redis',
        kind: DbKind.redis,
        hostId: 'box',
        port: 56379,
      ),
      'redsecret',
    );
    addTearDown(session.close);

    await session.run('DEL jeansh-session:h "jeansh-session:sp ace"');
    await session.run('HSET jeansh-session:h a 1 b 2');
    await session.run('SET "jeansh-session:sp ace" x');

    expect(await session.objects('jeansh-session:'), {
      '': ['jeansh-session:h', 'jeansh-session:sp ace'],
    });
    // A glob character in the filter matches only itself.
    expect(await session.objects('*'), isEmpty);

    final hash = await session.queryFor('', 'jeansh-session:h');
    expect(hash, 'HGETALL jeansh-session:h');
    final shown = await session.run(hash);
    expect(shown.columns, ['field', 'value']);
    expect(shown.rows, [
      ['a', '1'],
      ['b', '2'],
    ]);
    expect(shown.note, '2 pairs');

    final spaced = await session.queryFor('', 'jeansh-session:sp ace');
    expect(spaced, 'GET "jeansh-session:sp ace"');
    expect((await session.run(spaced)).rows, [
      ['x'],
    ]);
    expect((await session.run('GET jeansh-session:none')).note, '(nil)');
  });
}
