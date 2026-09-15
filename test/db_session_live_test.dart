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
    expect((await session.run('SELECT * FROM jeansh_nokey')).table, isNull);
    expect(
      (await session.run(
        'SELECT e.id, k.x FROM "Jeansh Edit" e, jeansh_nokey k',
      )).table,
      isNull,
    );

    // An alias still edits its own column.
    final shown = await session.run(
      'SELECT id, "Name" AS who FROM "Jeansh Edit" ORDER BY id',
    );
    expect(shown.table?.name, 'public."Jeansh Edit"');
    expect(shown.table?.columns, ['id', '"Name"']);
    expect(shown.table?.key, [0]);

    final changes = DbChanges()
      ..set(shown.rows, 0, 1, r"it's a \ back\slash")
      ..set(shown.rows, 1, 1, null)
      ..deleted.add(2)
      ..added.add({1: 'dee'})
      ..added.add({});
    await session.run(changes.sql(shown));
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
    await expectLater(
      session.run(refused.sql(again)),
      throwsA(isA<Exception>()),
    );
    expect((await session.run(all)).rows, saved);
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
