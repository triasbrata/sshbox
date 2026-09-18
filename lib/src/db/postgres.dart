import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../session/terminal_session.dart' show Tunnel;
import 'wire.dart';

/// One statement's result: its columns and rows as PostgreSQL writes them
/// in text, where each column is from (its table's oid and its number
/// there, zeros for one that is no table's), its command tag (`SELECT 3`,
/// `UPDATE 1`), and whether rows past [PostgresClient.maxRows] were dropped.
typedef PgResult = ({
  List<String> columns,
  List<(int, int)> origins,
  List<List<String?>> rows,
  String tag,
  bool truncated,
});

/// PostgreSQL's protocol, version 3, with simple queries only: every value
/// comes back as the text psql shows. No TLS: it runs inside the SSH
/// connection, to a server the host reaches.
class PostgresClient {
  PostgresClient._(this._wire);

  /// How many rows a result keeps. The rest are still read, and dropped.
  static const maxRows = 1000;

  final Wire _wire;

  /// Signed in as [user] with scram-sha-256, md5 or a plain password, as
  /// pg_hba.conf asks, to [database], or the one named after [user].
  static Future<PostgresClient> connect(
    Tunnel tunnel, {
    required String user,
    String password = '',
    String database = '',
  }) async {
    final client = PostgresClient._(Wire(tunnel));
    try {
      await client._startup(user, password, database.isEmpty ? user : database);
      return client;
    } catch (_) {
      await client.close();
      rethrow;
    }
  }

  Future<void> _startup(String user, String password, String database) async {
    final body = BytesBuilder()..add(_int32(196608));
    for (final value in [
      'user',
      user,
      'database',
      database,
      'application_name',
      'Jeansh',
      'client_encoding',
      'UTF8',
    ]) {
      body
        ..add(utf8.encode(value))
        ..addByte(0);
    }
    body.addByte(0);
    final startup = body.takeBytes();
    _wire.write([..._int32(startup.length + 4), ...startup]);

    Scram? scram;
    while (true) {
      final (type, data) = await _message();
      if (type == 'E') throw DbException(_error(data));
      if (type == 'Z') return;
      // S (a setting), K (the cancel key) and N (a notice) need nothing.
      if (type != 'R') continue;
      final code = ByteData.sublistView(data).getInt32(0);
      final rest = Uint8List.sublistView(data, 4);
      switch (code) {
        case 0:
          continue;
        case 3:
          _send('p', [...utf8.encode(password), 0]);
        case 5:
          final inner = md5.convert(utf8.encode('$password$user')).toString();
          final outer = md5.convert([...utf8.encode(inner), ...rest]);
          _send('p', [...utf8.encode('md5$outer'), 0]);
        case 10:
          final mechanisms = _strings(rest);
          if (!mechanisms.contains('SCRAM-SHA-256')) {
            throw DbException(
              'The server signs in with ${mechanisms.join(', ')}, which this '
              'app does not do.',
            );
          }
          // PostgreSQL takes the name from the startup, not from here.
          final first = utf8.encode((scram = Scram(sha256, '', password)).first);
          _send('p', [
            ...utf8.encode('SCRAM-SHA-256'),
            0,
            ..._int32(first.length),
            ...first,
          ]);
        case 11:
          _send('p', utf8.encode(scram!.reply(utf8.decode(rest))));
        case 12:
          scram!.verify(utf8.decode(rest));
        default:
          throw DbException(
            'The server signs in a way this app does not do (code $code). '
            'Use scram-sha-256 or md5 for it in pg_hba.conf.',
          );
      }
    }
  }

  /// Runs [sql], which may be several statements: a result for each that
  /// ran. Throws with the server's error when one fails, and none of them
  /// stays done unless it committed on its own.
  Future<List<PgResult>> query(String sql) => _wire.serial(() async {
    _send('Q', [...utf8.encode(sql), 0]);
    final results = <PgResult>[];
    var columns = <String>[];
    var origins = <(int, int)>[];
    var rows = <List<String?>>[];
    var truncated = false;
    String? error;
    while (true) {
      final (type, data) = await _message();
      switch (type) {
        case 'T':
          (columns, origins) = _columns(data);
          rows = [];
          truncated = false;
        case 'D':
          if (rows.length < maxRows) {
            rows.add(_row(data));
          } else {
            truncated = true;
          }
        case 'C':
          results.add((
            columns: columns,
            origins: origins,
            rows: rows,
            tag: _strings(data).firstOrNull ?? '',
            truncated: truncated,
          ));
          columns = [];
          origins = [];
          rows = [];
          truncated = false;
        case 'E':
          error = _error(data);
        case 'G':
          // COPY FROM STDIN would wait for rows there is no way to send.
          _send('f', [...utf8.encode('COPY FROM STDIN is not supported.'), 0]);
        case 'Z':
          if (error != null) throw DbException(error);
          return results;
      }
    }
  });

  Future<void> close() async {
    _send('X', const []);
    await _wire.close();
  }

  Future<(String, Uint8List)> _message() async {
    final header = await _wire.read(5);
    final length = ByteData.sublistView(header).getInt32(1);
    return (String.fromCharCode(header[0]), await _wire.read(length - 4));
  }

  void _send(String type, List<int> body) =>
      _wire.write([type.codeUnitAt(0), ..._int32(body.length + 4), ...body]);

  static Uint8List _int32(int value) =>
      (ByteData(4)..setInt32(0, value)).buffer.asUint8List();

  /// NUL-terminated strings from the start of [data], up to an empty one or
  /// its end.
  static List<String> _strings(Uint8List data) {
    final out = <String>[];
    var at = 0;
    while (at < data.length && data[at] != 0) {
      final end = data.indexOf(0, at);
      out.add(utf8.decode(data.sublist(at, end), allowMalformed: true));
      at = end + 1;
    }
    return out;
  }

  /// A RowDescription's column names, and where each is from: after its
  /// name, its table's oid and its number there, then 12 bytes of its type.
  static (List<String>, List<(int, int)>) _columns(Uint8List data) {
    final view = ByteData.sublistView(data);
    final names = <String>[];
    final origins = <(int, int)>[];
    var at = 2;
    for (var i = view.getInt16(0); i > 0; i--) {
      final end = data.indexOf(0, at);
      names.add(utf8.decode(data.sublist(at, end), allowMalformed: true));
      origins.add((view.getUint32(end + 1), view.getInt16(end + 5)));
      at = end + 1 + 18;
    }
    return (names, origins);
  }

  static List<String?> _row(Uint8List data) {
    final view = ByteData.sublistView(data);
    final values = <String?>[];
    var at = 2;
    for (var i = view.getInt16(0); i > 0; i--) {
      final length = view.getInt32(at);
      at += 4;
      if (length < 0) {
        values.add(null);
        continue;
      }
      values.add(
        utf8.decode(
          Uint8List.sublistView(data, at, at + length),
          allowMalformed: true,
        ),
      );
      at += length;
    }
    return values;
  }

  /// An ErrorResponse as psql shows it: `ERROR: …`, then its detail and
  /// hint.
  static String _error(Uint8List data) {
    final fields = <String, String>{};
    var at = 0;
    while (at < data.length && data[at] != 0) {
      final end = data.indexOf(0, at + 1);
      fields[String.fromCharCode(data[at])] = utf8.decode(
        data.sublist(at + 1, end),
        allowMalformed: true,
      );
      at = end + 1;
    }
    return [
      '${fields['S'] ?? 'ERROR'}: ${fields['M'] ?? 'unknown error'}',
      ?fields['D'],
      if (fields['H'] case final hint?) 'Hint: $hint',
    ].join('\n');
  }
}
