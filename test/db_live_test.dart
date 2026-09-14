import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/db/mongo.dart';
import 'package:sshbox/src/db/postgres.dart';
import 'package:sshbox/src/db/redis.dart';
import 'package:sshbox/src/db/wire.dart';
import 'package:sshbox/src/session/terminal_session.dart';

/// Talks to real servers on this machine, as the database browser does
/// through a host, each test skipping itself when nothing listens on its
/// port:
///
/// - PostgreSQL on 55432, user `postgres`, password `pgsecret`, with
///   `--auth=scram-sha-256`;
/// - Redis on 56379, `--requirepass redsecret`;
/// - MongoDB on 57017 with `--auth` and no users yet, or with the users
///   this test makes.
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
  test('PostgreSQL: signs in with SCRAM, runs statements, says why not', () async {
    final tunnel = await _dial(55432);
    if (tunnel == null) return printOnFailure('skipped: no server on 55432');
    final client = await PostgresClient.connect(
      tunnel,
      user: 'postgres',
      password: 'pgsecret',
    );
    addTearDown(client.close);

    final results = await client.query(
      "select 1 as one, null as nothing, 'héllo' as t; "
      'create temp table t (x int); insert into t values (1), (2); '
      'select * from t',
    );
    expect([for (final result in results) result.tag], [
      'SELECT 1',
      'CREATE TABLE',
      'INSERT 0 2',
      'SELECT 2',
    ]);
    expect(results.first.columns, ['one', 'nothing', 't']);
    expect(results.first.rows, [
      ['1', null, 'héllo'],
    ]);
    expect(results.last.rows, [
      ['1'],
      ['2'],
    ]);

    await expectLater(
      client.query('select nope'),
      throwsA(isA<DbException>().having(
        (error) => error.message,
        'message',
        contains('column "nope" does not exist'),
      )),
    );
    // Still usable after an error.
    expect((await client.query('select 2')).single.rows, [
      ['2'],
    ]);

    final wrong = await _dial(55432);
    await expectLater(
      PostgresClient.connect(wrong!, user: 'postgres', password: 'nope'),
      throwsA(isA<DbException>().having(
        (error) => error.message,
        'message',
        contains('password authentication failed'),
      )),
    );
  });

  test('Redis: signs in and runs commands', () async {
    final tunnel = await _dial(56379);
    if (tunnel == null) return printOnFailure('skipped: no server on 56379');
    final client = await RedisClient.connect(tunnel, password: 'redsecret');
    addTearDown(client.close);

    await client.command(['DEL', 'jeansh:test', 'jeansh:hash']);
    expect(await client.command(['SET', 'jeansh:test', 'héllo']), 'OK');
    expect(await client.command(['GET', 'jeansh:test']), 'héllo');
    await client.command(['HSET', 'jeansh:hash', 'a', '1', 'b', '2']);
    expect(await client.command(['HGETALL', 'jeansh:hash']), [
      'a',
      '1',
      'b',
      '2',
    ]);
    await expectLater(
      client.command(['LPUSH', 'jeansh:hash', 'x']),
      throwsA(isA<DbException>()),
    );

    final wrong = await _dial(56379);
    await expectLater(
      RedisClient.connect(wrong!, password: 'nope'),
      throwsA(isA<DbException>()),
    );
  });

  test('MongoDB: signs in with SCRAM-SHA-256 and -1, finds what it '
      'inserted', () async {
    final first = await _dial(57017);
    if (first == null) return printOnFailure('skipped: no server on 57017');
    // The first user, through the localhost exception: refused once there
    // is one.
    final anonymous = await MongoClient.connect(first);
    try {
      await anonymous.command('admin', {
        'createUser': 'jeansh',
        'pwd': 'mongosecret',
        'roles': ['root'],
      });
    } on DbException {
      // Made on an earlier run.
    }
    await anonymous.close();

    final client = await MongoClient.connect(
      (await _dial(57017))!,
      user: 'jeansh',
      password: 'mongosecret',
    );
    addTearDown(client.close);
    try {
      await client.command('admin', {
        'createUser': 'old',
        'pwd': 'oldsecret',
        'roles': [
          {'role': 'read', 'db': 'jeansh'},
        ],
        'mechanisms': ['SCRAM-SHA-1'],
      });
    } on DbException {
      // Made on an earlier run.
    }

    await client.command('jeansh', {'drop': 'things'}).catchError(
      (_) => <String, Object?>{},
    );
    final documents = [
      {
        '_id': {r'$oid': '5f1d7f0c9d1e8a0a1c2b3d4e'},
        'name': 'héllo',
        'when': {r'$date': '2024-01-02T03:04:05.678Z'},
        'n': 1 << 40,
        'tags': ['a', 'b'],
      },
    ];
    final inserted = await client.command('jeansh', {
      'insert': 'things',
      'documents': documents,
    });
    expect(inserted['n'], 1);
    final found = await client.command('jeansh', {
      'find': 'things',
      'filter': {'name': 'héllo'},
    });
    expect((found['cursor'] as Map)['firstBatch'], documents);

    final names = await client.command('admin', {
      'listDatabases': 1,
      'nameOnly': true,
    });
    expect(
      [for (final db in names['databases'] as List) (db as Map)['name']],
      contains('jeansh'),
    );
    await expectLater(
      client.command('jeansh', {'nope': 1}),
      throwsA(isA<DbException>().having(
        (error) => error.message,
        'message',
        contains('no such command'),
      )),
    );

    final old = await MongoClient.connect(
      (await _dial(57017))!,
      user: 'old',
      password: 'oldsecret',
    );
    addTearDown(old.close);
    expect(
      ((await old.command('jeansh', {'count': 'things'}))['n']),
      1,
    );
    await expectLater(
      MongoClient.connect(
        (await _dial(57017))!,
        user: 'jeansh',
        password: 'nope',
      ),
      throwsA(isA<DbException>()),
    );
  });
}
