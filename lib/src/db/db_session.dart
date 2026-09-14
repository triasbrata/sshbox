import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../data/host_repository.dart';
import '../data/known_host_store.dart' show HostKeyCheck;
import '../data/secret_store.dart';
import '../models/host_profile.dart';
import '../session/dartssh2_transport.dart';
import '../session/session_manager.dart' show LiveSession;
import '../session/terminal_session.dart';
import 'mongo.dart';
import 'postgres.dart';
import 'redis.dart';
import 'wire.dart';

enum DbKind {
  postgres('PostgreSQL', 5432, 'postgres', 'postgres'),
  mongo('MongoDB', 27017, '', 'admin'),
  redis('Redis', 6379, '', '0');

  const DbKind(this.label, this.port, this.user, this.database);

  final String label;
  final int port;

  /// What a blank User and a blank Database mean.
  final String user;
  final String database;
}

/// A database the browser opens, through a saved host's SSH connection as
/// `ssh -L` would reach it. Its password is kept in the [SecretStore], under
/// [passwordKey].
class DbConnection {
  const DbConnection({
    required this.id,
    required this.kind,
    required this.hostId,
    this.name = '',
    this.address = 'localhost',
    required this.port,
    this.user = '',
    this.database = '',
  });

  final String id;
  final DbKind kind;
  final String hostId;

  /// Optional; blank shows the kind and the host's name.
  final String name;

  /// As the host reaches it: localhost is the host itself.
  final String address;
  final int port;
  final String user;

  /// PostgreSQL's database, MongoDB's authentication database, Redis's
  /// database number.
  final String database;

  static String passwordKey(String id) => 'sshbox.db.password.$id';

  /// [name], or `PostgreSQL on db box`.
  String displayName(HostProfile? host) => name.trim().isNotEmpty
      ? name.trim()
      : '${kind.label} on ${host?.displayName ?? 'a deleted host'}';

  /// `postgres@localhost:5432/app`.
  String get summary =>
      '${user.isEmpty ? '' : '$user@'}$address:$port'
      '${database.isEmpty ? '' : '/$database'}';

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'hostId': hostId,
    'name': name,
    'address': address,
    'port': port,
    'user': user,
    'database': database,
  };

  factory DbConnection.fromJson(Map<String, dynamic> json) {
    final kind = DbKind.values.firstWhere(
      (kind) => kind.name == json['kind'],
      orElse: () => DbKind.postgres,
    );
    return DbConnection(
      id: json['id'] as String,
      kind: kind,
      hostId: json['hostId'] as String? ?? '',
      name: json['name'] as String? ?? '',
      address: json['address'] as String? ?? 'localhost',
      port: json['port'] as int? ?? kind.port,
      user: json['user'] as String? ?? '',
      database: json['database'] as String? ?? '',
    );
  }
}

const _storageKey = 'sshbox.databases.v1';

/// The saved databases, in the order they were added.
Future<List<DbConnection>> loadDatabases() async {
  final raw = (await SharedPreferences.getInstance()).getString(_storageKey);
  try {
    return [
      for (final json in jsonDecode(raw ?? '[]') as List)
        DbConnection.fromJson(json as Map<String, dynamic>),
    ];
  } catch (_) {
    // A corrupt list costs its databases, not the page.
    return [];
  }
}

Future<void> saveDatabases(List<DbConnection> databases) async {
  await (await SharedPreferences.getInstance()).setString(
    _storageKey,
    jsonEncode([for (final db in databases) db.toJson()]),
  );
}

/// What a run shows: a grid, a line about it, and for a row a cell cannot
/// show whole, the row in full.
class DbResult {
  const DbResult({
    this.columns = const [],
    this.rows = const [],
    this.note = '',
    this.details,
  });

  final List<String> columns;
  final List<List<String?>> rows;

  /// `SELECT 3`, `50 documents`, `OK`.
  final String note;

  /// Each row's document, as indented JSON: MongoDB's.
  final List<String>? details;
}

/// An open database, and the SSH connection it goes through: what the
/// database browser lists, and runs what the user types on.
abstract class DbSession {
  TerminalSession? _ssh;

  /// What the side list shows, by group: tables by schema, collections by
  /// database, and Redis's keys under one blank group. [filter] narrows it.
  Future<Map<String, List<String>>> objects(String filter);

  /// What a tap on [name] under [group] runs.
  Future<String> queryFor(String group, String name);

  Future<DbResult> run(String query);

  /// The query box's hint.
  String get hint;

  /// Lets go of the database's own connection. A test's has none.
  Future<void> _closeClient() async {}

  Future<void> close() async {
    await _closeClient().catchError((_) {});
    await _ssh?.dispose();
  }

  /// Opens [db]: its host's SSH connection, with the same host key check,
  /// credentials and jump hosts as a terminal's, a channel through it to
  /// the database, and the database's sign-in. [onSignIn] hears of a
  /// Tailscale check to finish. [transport] is a test's.
  static Future<DbSession> open(
    DbConnection db, {
    required SecretStore secrets,
    Future<bool> Function(HostKeyCheck check)? confirmHostKey,
    void Function(Uri url)? onSignIn,
    SessionTransport? transport,
  }) async {
    final host = (await HostRepository(secrets).load())
        .where((host) => host.id == db.hostId)
        .firstOrNull;
    if (host == null) {
      throw const DbException('Its host was deleted. Edit it and pick another.');
    }
    final ssh =
        await (transport ??
                Dartssh2Transport(
                  confirmHostKey: confirmHostKey,
                  onAuthBanner: (banner) {
                    final url = LiveSession.extractAuthUrl(banner);
                    if (url != null) onSignIn?.call(url);
                  },
                ))
            .connect(
              host: host,
              secrets: secrets,
              columns: 80,
              rows: 24,
              shell: false,
            );
    try {
      if (ssh is! ForwardCapable) {
        throw const DbException('This connection cannot forward.');
      }
      final Tunnel tunnel;
      try {
        tunnel = await (ssh as ForwardCapable).forward(db.address, db.port);
      } on SshSessionException catch (error) {
        throw DbException(
          '${host.displayName} cannot reach ${db.address}:${db.port}: '
          '${error.message}',
        );
      }
      final password = await secrets.read(DbConnection.passwordKey(db.id));
      return (await over(tunnel, db, password ?? '')).._ssh = ssh;
    } catch (_) {
      await ssh.dispose();
      rethrow;
    }
  }

  /// [db] over [tunnel], signed in with [password]: [open]'s last step, and
  /// a test's way in with a socket.
  static Future<DbSession> over(
    Tunnel tunnel,
    DbConnection db,
    String password,
  ) async {
    final user = db.user.isEmpty ? db.kind.user : db.user;
    final database = db.database.isEmpty ? db.kind.database : db.database;
    return switch (db.kind) {
      DbKind.postgres => _PostgresSession(
        await PostgresClient.connect(
          tunnel,
          user: user,
          password: password,
          database: database,
        ),
      ),
      DbKind.mongo => _MongoSession(
        await MongoClient.connect(
          tunnel,
          user: user,
          password: password,
          authSource: database,
        ),
        database,
      ),
      DbKind.redis => _RedisSession(
        await RedisClient.connect(
          tunnel,
          user: user,
          password: password,
          db: int.tryParse(database) ?? 0,
        ),
      ),
    };
  }
}

/// [names] under [group], with only those holding [filter] when the group's
/// own name does not.
void _addGroup(
  Map<String, List<String>> groups,
  String group,
  Iterable<String> names,
  String filter,
) {
  final wanted = filter.trim().toLowerCase();
  final kept = group.toLowerCase().contains(wanted)
      ? names.toList()
      : [
          for (final name in names)
            if (name.toLowerCase().contains(wanted)) name,
        ];
  if (kept.isNotEmpty) groups[group] = kept..sort();
}

/// A JSON value as a cell shows it: a string as itself.
String? _cell(Object? value) => switch (value) {
  null => null,
  String text => text,
  _ => jsonEncode(value),
};

class _PostgresSession extends DbSession {
  _PostgresSession(this._client);

  final PostgresClient _client;

  @override
  String get hint => 'SQL, like SELECT * FROM users LIMIT 10;';

  @override
  Future<Map<String, List<String>>> objects(String filter) async {
    final rows = (await _client.query(
      'SELECT table_schema, table_name FROM information_schema.tables '
      "WHERE table_schema NOT IN ('pg_catalog', 'information_schema') "
      'ORDER BY 1, 2',
    )).single.rows;
    final bySchema = <String, List<String>>{};
    for (final [schema, table] in rows) {
      (bySchema[schema!] ??= []).add(table!);
    }
    final groups = <String, List<String>>{};
    bySchema.forEach(
      (schema, tables) => _addGroup(groups, schema, tables, filter),
    );
    return groups;
  }

  /// Bare when it would read back the same, in double quotes otherwise.
  static String _identifier(String name) =>
      RegExp(r'^[a-z_][a-z0-9_]*$').hasMatch(name)
      ? name
      : '"${name.replaceAll('"', '""')}"';

  @override
  Future<String> queryFor(String group, String name) async =>
      'SELECT * FROM ${_identifier(group)}.${_identifier(name)} LIMIT 100;';

  @override
  Future<DbResult> run(String query) async {
    final results = await _client.query(query);
    if (results.isEmpty) return const DbResult(note: 'Nothing to run.');
    final shown = results.lastWhere(
      (result) => result.columns.isNotEmpty,
      orElse: () => results.last,
    );
    return DbResult(
      columns: shown.columns,
      rows: shown.rows,
      note: [
        for (final result in results) result.tag,
        if (shown.truncated) 'first ${PostgresClient.maxRows} rows shown',
      ].join(' · '),
    );
  }

  @override
  Future<void> _closeClient() => _client.close();
}

class _MongoSession extends DbSession {
  _MongoSession(this._client, this._authSource);

  final MongoClient _client;

  /// Where commands without a `$db` of their own run, and whose
  /// collections are listed when the user may not list databases.
  final String _authSource;

  @override
  String get hint =>
      'A database command, as JSON: {"find": "users", "filter": {}, '
      '"limit": 10, "\$db": "app"}';

  @override
  Future<Map<String, List<String>>> objects(String filter) async {
    List<String> names(Map<String, Object?> reply, String field) => [
      for (final item in reply[field] as List? ?? const [])
        if (item case {'name': final String name}) name,
    ];

    var databases = [_authSource];
    try {
      databases = names(
        await _client.command('admin', {
          'listDatabases': 1,
          'nameOnly': true,
          'authorizedDatabases': true,
        }),
        'databases',
      );
    } on DbException {
      // Not allowed to: the one signed in to.
    }
    final groups = <String, List<String>>{};
    for (final db in databases) {
      final reply = await _client.command(db, {
        'listCollections': 1,
        'nameOnly': true,
        'authorizedCollections': true,
      });
      // ponytail: the first batch only, 101 collections by default; add
      // getMore when a database has more.
      _addGroup(
        groups,
        db,
        names(reply['cursor'] as Map<String, Object?>? ?? const {}, 'firstBatch'),
        filter,
      );
    }
    return groups;
  }

  @override
  Future<String> queryFor(String group, String name) async =>
      const JsonEncoder.withIndent('  ').convert({
        'find': name,
        'filter': <String, Object?>{},
        'limit': 50,
        r'$db': group,
      });

  @override
  Future<DbResult> run(String query) async {
    final Object? command;
    try {
      command = jsonDecode(query);
    } on FormatException catch (error) {
      throw DbException('That is not JSON: ${error.message}');
    }
    if (command is! Map<String, Object?> || command.isEmpty) {
      throw const DbException(
        'A command is a JSON object, like {"find": "users"}.',
      );
    }
    final reply = await _client.command(_authSource, command);
    final List<Object?> documents;
    final String note;
    if (reply['cursor'] case {'id': final id} && final Map cursor) {
      documents = (cursor['firstBatch'] ?? cursor['nextBatch']) as List? ?? [];
      note =
          '${documents.length} document${documents.length == 1 ? '' : 's'}'
          '${id == 0 ? '' : ', more on the server'}';
    } else {
      documents = [reply];
      note = 'OK';
    }
    final columns = <String>{
      for (final document in documents)
        if (document is Map) ...document.keys.cast<String>(),
    }.toList();
    const pretty = JsonEncoder.withIndent('  ');
    return DbResult(
      columns: columns,
      rows: [
        for (final document in documents)
          if (document is Map)
            [for (final column in columns) _cell(document[column])],
      ],
      note: note,
      details: [
        for (final document in documents)
          if (document is Map) pretty.convert(document),
      ],
    );
  }

  @override
  Future<void> _closeClient() => _client.close();
}

class _RedisSession extends DbSession {
  _RedisSession(this._client);

  final RedisClient _client;

  /// How many keys the side list scans for at most.
  static const maxKeys = 2000;

  @override
  String get hint => 'A command, like GET key or HGETALL key';

  @override
  Future<Map<String, List<String>>> objects(String filter) async {
    // Glob characters in the filter match themselves.
    final pattern =
        '*${filter.trim().replaceAllMapped(RegExp(r'[*?\[\]\\]'), (m) => '\\${m[0]}')}*';
    final keys = <String>{};
    var cursor = '0';
    do {
      final reply = await _client.command([
        'SCAN',
        cursor,
        'MATCH',
        pattern,
        'COUNT',
        '500',
      ]);
      if (reply case [final String next, final List batch]) {
        cursor = next;
        keys.addAll(batch.cast<String>());
      } else {
        break;
      }
    } while (cursor != '0' && keys.length < maxKeys);
    return keys.isEmpty ? {} : {'': keys.toList()..sort()};
  }

  /// As [redisArgs] reads it back.
  static String _quote(String arg) => RegExp(r'''^[^\s"'\\]+$''').hasMatch(arg)
      ? arg
      : '"${arg.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n').replaceAll('\r', r'\r').replaceAll('\t', r'\t')}"';

  @override
  Future<String> queryFor(String group, String name) async {
    final key = _quote(name);
    return switch (await _client.command(['TYPE', name])) {
      'hash' => 'HGETALL $key',
      'list' => 'LRANGE $key 0 99',
      'set' => 'SMEMBERS $key',
      'zset' => 'ZRANGE $key 0 99 WITHSCORES',
      'stream' => 'XRANGE $key - + COUNT 100',
      'ReJSON-RL' => 'JSON.GET $key',
      _ => 'GET $key',
    };
  }

  @override
  Future<DbResult> run(String query) async {
    final args = redisArgs(query);
    if (args.isEmpty) {
      throw const DbException('Type a command, like GET key.');
    }
    final reply = await _client.command(args);
    if (reply is! List) {
      return DbResult(
        columns: const ['value'],
        rows: [
          [reply?.toString()],
        ],
        note: reply == null ? '(nil)' : '',
      );
    }
    final name = args.first.toUpperCase();
    final scores = args.any((arg) => arg.toUpperCase() == 'WITHSCORES');
    String? cell(Object? value) => value is RedisError ? '$value' : _cell(value);
    if (name == 'HGETALL' || name == 'CONFIG' || scores) {
      return DbResult(
        columns: scores ? const ['member', 'score'] : const ['field', 'value'],
        rows: [
          for (var i = 0; i + 1 < reply.length; i += 2)
            [cell(reply[i]), cell(reply[i + 1])],
        ],
        note: '${reply.length ~/ 2} pairs',
      );
    }
    return DbResult(
      columns: const ['#', 'value'],
      rows: [
        for (var i = 0; i < reply.length; i++) ['${i + 1}', cell(reply[i])],
      ],
      note: '${reply.length} item${reply.length == 1 ? '' : 's'}',
    );
  }

  @override
  Future<void> _closeClient() => _client.close();
}
