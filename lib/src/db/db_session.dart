import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../data/host_repository.dart';
import '../data/known_host_store.dart' show HostKeyCheck;
import '../data/secret_store.dart';
import '../models/host_profile.dart';
import '../session/isolate_transport.dart';
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

/// What a connection URI says, for the database editor's Import URI:
/// `postgresql://user:password@host:5432/app`,
/// `mongodb://user:password@host:27017/app?authSource=admin` or
/// `redis://:password@host:6379/0`. [password] is null when it names none.
typedef DbUri = ({
  DbKind kind,
  String address,
  int port,
  String user,
  String? password,
  String database,
});

/// [text] as a [DbUri]. Throws a [FormatException] saying why, for one it
/// cannot read.
DbUri parseDbUri(String text) {
  var uri = text.trim();
  final kind = switch (uri.split('://').first.toLowerCase()) {
    'postgres' || 'postgresql' => DbKind.postgres,
    'mongodb' => DbKind.mongo,
    'redis' => DbKind.redis,
    'mongodb+srv' => throw const FormatException(
      'mongodb+srv:// needs a DNS lookup this app does not make. Use the '
      'mongodb:// form, with one host.',
    ),
    'rediss' => throw const FormatException(
      'rediss:// is Redis over TLS, which this app does not speak: it '
      'reaches Redis through SSH instead. Use redis://.',
    ),
    _ => throw const FormatException(
      'Not a database URI this app reads: it starts postgresql://, '
      'mongodb:// or redis://.',
    ),
  };
  if (kind == DbKind.mongo) {
    // A replica set names each member. The first is the one reached.
    final start = uri.indexOf('://') + 3;
    final end = uri.indexOf(RegExp(r'[/?#]'), start);
    final authority = uri.substring(start, end < 0 ? uri.length : end);
    final hosts = authority.lastIndexOf('@') + 1;
    uri = uri.replaceRange(
      start + hosts,
      start + authority.length,
      authority.substring(hosts).split(',').first,
    );
  }
  final parsed = Uri.tryParse(uri);
  if (parsed == null) {
    throw const FormatException('That URI could not be read.');
  }
  final info = parsed.userInfo;
  final colon = info.indexOf(':');
  final path = parsed.pathSegments.firstOrNull ?? '';
  return (
    kind: kind,
    // No host is PostgreSQL's own socket: the host itself.
    address: parsed.host.isEmpty ? 'localhost' : parsed.host,
    port: parsed.hasPort ? parsed.port : kind.port,
    user: Uri.decodeComponent(colon < 0 ? info : info.substring(0, colon)),
    password: colon < 0
        ? null
        : Uri.decodeComponent(info.substring(colon + 1)),
    database: kind == DbKind.mongo
        ? parsed.queryParameters['authSource'] ?? path
        : path,
  );
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
    this.edit,
  });

  final List<String> columns;
  final List<List<String?>> rows;

  /// `SELECT 3`, `50 documents`, `OK`.
  final String note;

  /// Each row's document, as indented JSON: MongoDB's.
  final List<String>? details;

  /// How its rows are changed, when they can be.
  final DbEdit? edit;

  /// Row [index] as indented JSON: its document, or its columns and values
  /// as the database gave them.
  ///
  /// ponytail: JSON has one key per name, so of two columns with the same
  /// name only the last shows.
  String json(int index) =>
      details?[index] ??
      const JsonEncoder.withIndent('  ').convert({
        for (var c = 0; c < columns.length; c++) columns[c]: rows[index][c],
      });
}

/// How a result's rows are changed: what saves the changes, and what the
/// grid lets be changed.
class DbEdit {
  const DbEdit(
    this.save, {
    this.locked = const {},
    this.nulls = true,
    this.adds = true,
    this.unset = 'DEFAULT',
  });

  /// Makes the changes: null once all are made, or why one was not after
  /// others were. Throws, with none made, when the first is refused.
  final Future<String?> Function(DbChanges changes) save;

  /// Columns a tap does not edit: MongoDB's _id, a Redis list's place.
  final Set<int> locked;

  /// Whether a value can be NULL: not in Redis.
  final bool nulls;

  /// Whether rows can be added: not to a Redis string.
  final bool adds;

  /// What a new row's cell shows until it is given a value.
  final String unset;
}

/// A table a result's rows can be edited in: PostgreSQL's, when every
/// column is the table's and its primary key is among them.
class DbTable {
  const DbTable({required this.name, required this.columns, required this.key});

  /// With its schema, and quoted: `public."Jeansh People"`.
  final String name;

  /// Each result column's own name in the table, quoted: an alias's too.
  final List<String> columns;

  /// Which result columns hold the primary key.
  final List<int> key;
}

/// What the grid has changed in a [DbResult] and not saved yet. It goes with
/// the result: a run, or a tap on a table, reads the rows afresh.
class DbChanges {
  /// Row, then column, then its new value: null for NULL.
  final edits = <int, Map<int, String?>>{};
  final deleted = <int>{};

  /// Each new row's columns given a value. The rest take their default.
  final added = <Map<int, String?>>[];

  int get count => {...edits.keys, ...deleted}.length + added.length;

  bool get isEmpty => count == 0;

  /// The rows edited and not deleted.
  Iterable<int> get updated => edits.keys.where((r) => !deleted.contains(r));

  /// Column [c] of row [r] as a save leaves it: its edit, or what [rows]
  /// hold.
  String? value(List<List<String?>> rows, int r, int c) {
    final cells = edits[r];
    return cells != null && cells.containsKey(c) ? cells[c] : rows[r][c];
  }

  /// Column [c] of row [r] set to [value]: no change when [rows] hold it.
  void set(List<List<String?>> rows, int r, int c, String? value) {
    final cells = edits[r] ??= {};
    if (value == rows[r][c]) {
      cells.remove(c);
      if (cells.isEmpty) edits.remove(r);
    } else {
      cells[c] = value;
    }
  }

  /// The statements that make these changes to [rows] in [table], to run
  /// as one transaction: deletes, updates, then inserts, each row found by
  /// its primary key as it was read.
  String sql(DbTable table, List<List<String?>> rows) {
    String where(int r) => [
      for (final c in table.key)
        '${table.columns[c]} = ${_literal(rows[r][c])}',
    ].join(' AND ');
    return [
      for (final r in deleted) 'DELETE FROM ${table.name} WHERE ${where(r)};',
      for (final r in updated)
        'UPDATE ${table.name} SET ${[
          for (final MapEntry(key: c, :value) in edits[r]!.entries)
            '${table.columns[c]} = ${_literal(value)}',
        ].join(', ')} WHERE ${where(r)};',
      for (final cells in added)
        cells.isEmpty
            ? 'INSERT INTO ${table.name} DEFAULT VALUES;'
            : 'INSERT INTO ${table.name} '
                  '(${[for (final c in cells.keys) table.columns[c]].join(', ')}) '
                  'VALUES (${cells.values.map(_literal).join(', ')});',
    ].join('\n');
  }

  /// [value] as an escape string, which reads the same whatever
  /// standard_conforming_strings says.
  static String _literal(String? value) => value == null
      ? 'NULL'
      : "E'${value.replaceAll(r'\', r'\\').replaceAll("'", "''")}'";
}

/// A table, collection or key the side list shows, and its [type] as the
/// database reports it: information_schema's table_type (`BASE TABLE`,
/// `VIEW`) or `MATERIALIZED VIEW`, listCollections' type (`collection`,
/// `view`, `timeseries`), or what Redis's TYPE says (`hash`, `zset`).
typedef DbObject = ({String name, String type});

/// An open database, and the SSH connection it goes through: what the
/// database browser lists, and runs what the user types on.
abstract class DbSession {
  TerminalSession? _ssh;

  /// What the side list shows, by group: tables by schema, collections by
  /// database, and Redis's keys under one blank group, each group's in name
  /// order. [filter] and [type] narrow it, as [filterObjects] does.
  Future<Map<String, List<DbObject>>> objects(String filter, {String? type});

  /// Whether [objects], read with no filter, stopped before the whole list,
  /// so a filter has to ask the database rather than narrow what came back.
  bool capped(Map<String, List<DbObject>> objects) => false;

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
                IsolateTransport(
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

/// [objects] of a [db] as [filter] and [type] narrow them, without asking
/// the database again: to the one [type], when one is picked, and to the
/// names [filter] matches. For Redis that is a key pattern, as SCAN MATCH
/// reads it ([redisPattern]); for the others, text anywhere in the name as
/// its schema or database qualifies it, ignoring case, so `aud` keeps a
/// whole schema, `peo` a table in any, and `public.peo` or `app.users` one
/// in that schema or database alone.
Map<String, List<DbObject>> filterObjects(
  DbKind db,
  Map<String, List<DbObject>> objects,
  String filter, {
  String? type,
}) {
  final pattern = redisPattern(filter);
  final wanted = filter.trim().toLowerCase();
  bool matches(String group, String name) => db == DbKind.redis
      ? redisMatch(pattern, name)
      : '$group.$name'.toLowerCase().contains(wanted);
  final groups = <String, List<DbObject>>{};
  objects.forEach((group, names) {
    final kept = [
      for (final object in names)
        if ((type == null || object.type == type) &&
            matches(group, object.name))
          object,
    ];
    if (kept.isNotEmpty) groups[group] = kept;
  });
  return groups;
}

/// [objects] by group, each group's in name order.
Map<String, List<DbObject>> _grouped(
  Iterable<(String group, DbObject object)> objects,
) {
  final groups = <String, List<DbObject>>{};
  for (final (group, object) in objects) {
    (groups[group] ??= []).add(object);
  }
  for (final names in groups.values) {
    names.sort((a, b) => a.name.compareTo(b.name));
  }
  return groups;
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
  Future<Map<String, List<DbObject>>> objects(
    String filter, {
    String? type,
  }) async {
    // Materialized views are not in information_schema, and are read as a
    // table is.
    final rows = (await _client.query(
      'SELECT table_schema::text, table_name::text, table_type::text '
      'FROM information_schema.tables '
      "WHERE table_schema NOT IN ('pg_catalog', 'information_schema') "
      'UNION ALL '
      "SELECT schemaname::text, matviewname::text, 'MATERIALIZED VIEW' "
      'FROM pg_matviews '
      "WHERE has_table_privilege(format('%I.%I', schemaname, matviewname), "
      "'SELECT') "
      'ORDER BY 1',
    )).single.rows;
    return filterObjects(
      DbKind.postgres,
      _grouped([
        for (final [schema, table, kind] in rows)
          (schema!, (name: table!, type: kind!)),
      ]),
      filter,
      type: type,
    );
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
      edit: await _edit(shown),
    );
  }

  /// The rows edited in their own table: the one every column is from,
  /// when its primary key is among them. Null otherwise, and when the
  /// catalog cannot say.
  Future<DbEdit?> _edit(PgResult result) async {
    final tables = {for (final (table, _) in result.origins) table};
    if (tables.length != 1 || tables.single == 0) return null;
    final oid = tables.single;
    try {
      final [table, attributes] = await _client.query(
        "SELECT format('%I.%I', n.nspname, c.relname) FROM pg_class c "
        'JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.oid = $oid; '
        'SELECT a.attnum, quote_ident(a.attname), a.attnum = ANY(i.indkey) '
        'FROM pg_attribute a LEFT JOIN pg_index i '
        'ON i.indrelid = a.attrelid AND i.indisprimary '
        'WHERE a.attrelid = $oid',
      );
      final name = table.rows.firstOrNull?.first;
      final names = {
        for (final [number, name, _] in attributes.rows)
          int.parse(number!): name!,
      };
      final key = {
        for (final [number, _, primary] in attributes.rows)
          if (primary == 't') int.parse(number!),
      };
      final numbers = [for (final (_, number) in result.origins) number];
      if (name == null || key.isEmpty || !numbers.toSet().containsAll(key)) {
        return null;
      }
      final target = DbTable(
        name: name,
        columns: [for (final number in numbers) names[number]!],
        key: [
          for (final (c, number) in numbers.indexed)
            if (key.contains(number)) c,
        ],
      );
      // One simple query, which PostgreSQL runs as one transaction.
      return DbEdit((changes) async {
        await _client.query(changes.sql(target, result.rows));
        return null;
      });
    } on DbException {
      return null;
    }
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
  Future<Map<String, List<DbObject>>> objects(
    String filter, {
    String? type,
  }) async {
    var databases = [_authSource];
    try {
      final reply = await _client.command('admin', {
        'listDatabases': 1,
        'nameOnly': true,
        'authorizedDatabases': true,
      });
      databases = [
        for (final item in reply['databases'] as List? ?? const [])
          if (item case {'name': final String name}) name,
      ];
    } on DbException {
      // Not allowed to: the one signed in to.
    }
    final found = <(String, DbObject)>[];
    for (final db in databases) {
      final reply = await _client.command(db, {
        'listCollections': 1,
        'nameOnly': true,
        'authorizedCollections': true,
      });
      // ponytail: the first batch only, 101 collections by default; add
      // getMore when a database has more.
      if (reply['cursor'] case {'firstBatch': final List batch}) {
        for (final item in batch) {
          // nameOnly still says which are views and time series.
          if (item case {'name': final String name}) {
            final kind = item['type'];
            found.add((db, (name: name, type: kind is String ? kind : '')));
          }
        }
      }
    }
    return filterObjects(DbKind.mongo, _grouped(found), filter, type: type);
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
    final List<Object?> found;
    final String note;
    if (reply['cursor'] case {'id': final id} && final Map cursor) {
      found = (cursor['firstBatch'] ?? cursor['nextBatch']) as List? ?? [];
      note =
          '${found.length} document${found.length == 1 ? '' : 's'}'
          '${id == 0 ? '' : ', more on the server'}';
    } else {
      found = [reply];
      note = 'OK';
    }
    final documents = [
      for (final document in found)
        if (document is Map<String, Object?>) document,
    ];
    final columns = <String>{
      for (final document in documents) ...document.keys,
    }.toList();
    const pretty = JsonEncoder.withIndent('  ');
    final collection = command['find'];
    return DbResult(
      columns: columns,
      rows: [
        for (final document in documents)
          [for (final column in columns) _cell(document[column])],
      ],
      note: note,
      details: [for (final document in documents) pretty.convert(document)],
      // What a find reads, each document found again by its _id.
      edit:
          command.keys.first == 'find' &&
              collection is String &&
              documents.every((document) => document.containsKey('_id'))
          ? _edit(
              switch (command[r'$db']) {
                final String db => db,
                _ => _authSource,
              },
              collection,
              columns,
              documents,
            )
          : null,
    );
  }

  /// The documents of [collection] in [db], changed by their _id: one
  /// update, one delete and one insert, sent one after another.
  ///
  /// ponytail: no transaction, which a server outside a replica set does
  /// not have, so a write refused after another was made leaves that one
  /// made, and says so. Run them in one where a replica set is known.
  DbEdit _edit(
    String db,
    String collection,
    List<String> columns,
    List<Map<String, Object?>> documents,
  ) => DbEdit(
    (changes) async {
      Map<String, Object?> fields(
        Map<int, String?> cells,
        Map<String, Object?> was,
      ) => {
        for (final MapEntry(key: c, value: text) in cells.entries)
          columns[c]: _typed(text, was[columns[c]]),
      };
      Map<String, Object?> id(int r) => {'_id': documents[r]['_id']};
      final writes = [
        if (changes.updated.isNotEmpty)
          {
            'update': collection,
            'updates': [
              for (final r in changes.updated)
                {
                  'q': id(r),
                  'u': {r'$set': fields(changes.edits[r]!, documents[r])},
                },
            ],
          },
        if (changes.deleted.isNotEmpty)
          {
            'delete': collection,
            'deletes': [
              for (final r in changes.deleted) {'q': id(r), 'limit': 1},
            ],
          },
        if (changes.added.isNotEmpty)
          {
            'insert': collection,
            'documents': [
              for (final cells in changes.added) fields(cells, const {}),
            ],
          },
      ];
      var made = false;
      for (final write in writes) {
        final Map<String, Object?> reply;
        try {
          reply = await _client.command(db, write);
        } on DbException catch (error) {
          if (!made) rethrow;
          return error.message;
        }
        // A write refused still comes back ok, with why in writeErrors.
        if (reply['writeErrors'] case [
          {'index': final int index, 'errmsg': final String message},
          ...
        ]) {
          if (!made && index == 0) throw DbException(message);
          return message;
        }
        made = true;
      }
      return null;
    },
    locked: {
      for (final (c, name) in columns.indexed)
        if (name == '_id') c,
    },
    unset: 'NULL',
  );

  /// What [text] typed into a field that held [was] becomes: a string stays
  /// a string, anything else is read as JSON when it can be, and a double
  /// stays a double.
  static Object? _typed(String? text, Object? was) {
    if (text == null || was is String) return text;
    try {
      final value = jsonDecode(text);
      return was is double && value is int ? value.toDouble() : value;
    } on FormatException {
      return text;
    }
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
  bool capped(Map<String, List<DbObject>> objects) =>
      (objects['']?.length ?? 0) >= maxKeys;

  /// The keys [filter] matches as a pattern ([redisPattern]), of [type]
  /// alone when one is picked, which SCAN's own MATCH and TYPE pick out
  /// (TYPE since Redis 6.0), so the cap counts only keys that match.
  @override
  Future<Map<String, List<DbObject>>> objects(
    String filter, {
    String? type,
  }) async {
    final keys = <String>{};
    var cursor = '0';
    do {
      final reply = await _client.command([
        'SCAN',
        cursor,
        'MATCH',
        redisPattern(filter),
        'COUNT',
        '500',
        if (type != null) ...['TYPE', type],
      ]);
      if (reply case [final String next, final List batch]) {
        cursor = next;
        keys.addAll(batch.cast<String>());
      } else {
        break;
      }
    } while (cursor != '0' && keys.length < maxKeys);
    final names = keys.toList()..sort();
    // Each key's type, for its tag and the type filter: TYPE for all of
    // them in one round trip, no more than the scan's cap.
    final types = type != null || names.isEmpty
        ? const []
        : await _client.pipeline([
            for (final name in names) ['TYPE', name],
          ]);
    final found = <DbObject>[];
    for (final (i, name) in names.indexed) {
      final kind = type ?? types[i];
      // Gone since the scan.
      if (kind == 'none') continue;
      found.add((name: name, type: kind is String ? kind : ''));
    }
    return found.isEmpty ? {} : {'': found};
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
    final name = args.first.toUpperCase();
    final key = args.length > 1 ? args[1] : '';
    if (reply is! List) {
      final rows = [
        [reply?.toString()],
      ];
      return DbResult(
        columns: const ['value'],
        rows: rows,
        note: reply == null ? '(nil)' : '',
        edit: name == 'GET' && args.length == 2 ? _string(key, rows) : null,
      );
    }
    final scores = args.any((arg) => arg.toUpperCase() == 'WITHSCORES');
    String? cell(Object? value) => value is RedisError ? '$value' : _cell(value);
    if (name == 'HGETALL' || name == 'CONFIG' || scores) {
      final rows = [
        for (var i = 0; i + 1 < reply.length; i += 2)
          [cell(reply[i]), cell(reply[i + 1])],
      ];
      return DbResult(
        columns: scores ? const ['member', 'score'] : const ['field', 'value'],
        rows: rows,
        note: '${reply.length ~/ 2} pairs',
        edit: name == 'HGETALL' && args.length == 2
            ? _hash(key, rows)
            : scores && _ranges.contains(name)
            ? _zset(key, rows)
            : null,
      );
    }
    final rows = [
      for (var i = 0; i < reply.length; i++) ['${i + 1}', cell(reply[i])],
    ];
    final start = args.length == 4 ? int.tryParse(args[2]) : null;
    return DbResult(
      columns: const ['#', 'value'],
      rows: rows,
      note: '${reply.length} item${reply.length == 1 ? '' : 's'}',
      edit: name == 'SMEMBERS' && args.length == 2
          ? _set(key, rows)
          : name == 'LRANGE' && start != null && start >= 0
          ? _list(key, start, rows)
          : null,
    );
  }

  /// What reads a sorted set's members with their scores.
  static const _ranges = {
    'ZRANGE',
    'ZREVRANGE',
    'ZRANGEBYSCORE',
    'ZREVRANGEBYSCORE',
  };

  /// Rows saved as the Redis commands [commands] makes of the changes, sent
  /// as one MULTI … EXEC.
  DbEdit _edit(
    List<List<String>> Function(DbChanges changes) commands, {
    Set<int> locked = const {},
    bool adds = true,
  }) => DbEdit(
    (changes) async {
      final failed = (await _client.transaction(
        commands(changes),
      )).whereType<RedisError>();
      return failed.isEmpty ? null : failed.join('\n');
    },
    locked: locked,
    nulls: false,
    adds: adds,
    unset: '',
  );

  /// GET's string: set, keeping its time to live, or deleted.
  DbEdit _string(String key, List<List<String?>> rows) => _edit(
    adds: false,
    (changes) => [
      if (changes.deleted.isNotEmpty)
        ['DEL', key]
      else
        ['SET', key, changes.value(rows, 0, 0) ?? '', 'KEEPTTL'],
    ],
  );

  /// A hash's fields and values, a field renamed too. What goes goes
  /// first, so two fields swapped both land.
  DbEdit _hash(String key, List<List<String?>> rows) => _edit((changes) {
    String now(int r, int c) => changes.value(rows, r, c) ?? '';
    final renamed = changes.updated.where(
      (r) => changes.edits[r]!.containsKey(0),
    );
    return [
      for (final r in {...changes.deleted, ...renamed})
        ['HDEL', key, rows[r][0] ?? ''],
      for (final r in changes.updated) ['HSET', key, now(r, 0), now(r, 1)],
      for (final cells in changes.added)
        ['HSET', key, cells[0] ?? '', cells[1] ?? ''],
    ];
  });

  /// A sorted set's members and scores, a member renamed too.
  DbEdit _zset(String key, List<List<String?>> rows) => _edit((changes) {
    String now(int r, int c) => changes.value(rows, r, c) ?? '';
    final renamed = changes.updated.where(
      (r) => changes.edits[r]!.containsKey(0),
    );
    return [
      for (final r in {...changes.deleted, ...renamed})
        ['ZREM', key, rows[r][0] ?? ''],
      for (final r in changes.updated)
        ['ZADD', key, _score(now(r, 1)), now(r, 0)],
      for (final cells in changes.added)
        ['ZADD', key, _score(cells[1] ?? ''), cells[0] ?? ''],
    ];
  });

  /// A set's members: one changed is the old taken out and the new put in.
  DbEdit _set(String key, List<List<String?>> rows) => _edit(
    locked: const {0},
    (changes) => [
      for (final r in {...changes.deleted, ...changes.updated})
        ['SREM', key, rows[r][1] ?? ''],
      for (final r in changes.updated)
        ['SADD', key, changes.value(rows, r, 1) ?? ''],
      for (final cells in changes.added) ['SADD', key, cells[1] ?? ''],
    ],
  );

  /// A list's items from [start], by their place. Deleted ones are marked,
  /// then all taken out at once, so none moves another's place first.
  DbEdit _list(String key, int start, List<List<String?>> rows) => _edit(
    locked: const {0},
    (changes) {
      final mark = 'jeansh:deleted:${DateTime.now().microsecondsSinceEpoch}';
      return [
        for (final r in changes.updated)
          ['LSET', key, '${start + r}', changes.value(rows, r, 1) ?? ''],
        for (final r in changes.deleted) ['LSET', key, '${start + r}', mark],
        if (changes.deleted.isNotEmpty) ['LREM', key, '0', mark],
        if (changes.added.isNotEmpty)
          ['RPUSH', key, for (final cells in changes.added) cells[1] ?? ''],
      ];
    },
  );

  /// [score] as ZADD reads it, or why not, before anything is sent: a
  /// member renamed is taken out first, and must not be lost to a typo.
  static String _score(String score) =>
      score.trim() == score &&
          (double.tryParse(score)?.isNaN == false ||
              RegExp(r'^[+-]?inf$', caseSensitive: false).hasMatch(score))
      ? score
      : throw DbException(
          '"$score" is not a score: a sorted set scores its members with '
          'numbers.',
        );

  @override
  Future<void> _closeClient() => _client.close();
}
