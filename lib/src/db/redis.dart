import 'dart:convert';
import 'dart:typed_data';

import '../session/terminal_session.dart' show Tunnel;
import 'wire.dart';

/// An error reply: kept as a value inside an array, as EXEC's, and thrown as
/// a [DbException] when it is the whole reply.
class RedisError {
  const RedisError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Redis's protocol, RESP2: each command an array of strings, each reply a
/// String, int, null, [RedisError], or a List of those.
///
/// ponytail: values are read as UTF-8, so binary ones show replacement
/// characters. Keep the bytes if a hex view is ever wanted.
class RedisClient {
  RedisClient._(this._wire);

  final Wire _wire;

  /// Signed in, with [user] when Redis 6's ACLs name one, and on [db].
  static Future<RedisClient> connect(
    Tunnel tunnel, {
    String user = '',
    String password = '',
    int db = 0,
  }) async {
    final client = RedisClient._(Wire(tunnel));
    try {
      if (password.isNotEmpty) {
        await client.command(['AUTH', if (user.isNotEmpty) user, password]);
      }
      if (db != 0) await client.command(['SELECT', '$db']);
      return client;
    } catch (_) {
      await client.close();
      rethrow;
    }
  }

  Future<Object?> command(List<String> args) => _wire.serial(() async {
    _wire.write(encode(args));
    final reply = await _reply();
    if (reply is RedisError) throw DbException(reply.message);
    return reply;
  });

  /// Runs [commands] between MULTI and EXEC, sent at once so nothing else
  /// on this connection lands among them: EXEC's replies, a [RedisError]
  /// for each that failed as it ran. Throws, with none run, when Redis
  /// refuses one as it is queued.
  Future<List<Object?>> transaction(List<List<String>> commands) =>
      _wire.serial(() async {
        _wire.write([
          for (final args in [
            ['MULTI'],
            ...commands,
            ['EXEC'],
          ])
            ...encode(args),
        ]);
        // MULTI's OK, then QUEUED, or why not, for each command.
        final queued = [
          for (var i = 0; i <= commands.length; i++) await _reply(),
        ];
        final replies = await _reply();
        if (replies is List) return replies;
        throw DbException(
          '${queued.whereType<RedisError>().firstOrNull ?? replies ?? 'Redis ran none of them.'}',
        );
      });

  Future<void> close() => _wire.close();

  static Uint8List encode(List<String> args) {
    final out = BytesBuilder(copy: false)..add(utf8.encode('*${args.length}\r\n'));
    for (final arg in args) {
      final bytes = utf8.encode(arg);
      out
        ..add(utf8.encode('\$${bytes.length}\r\n'))
        ..add(bytes)
        ..add(const [13, 10]);
    }
    return out.takeBytes();
  }

  Future<Object?> _reply() async {
    final line = utf8.decode(await _wire.readLine(), allowMalformed: true);
    final rest = line.isEmpty ? '' : line.substring(1);
    return switch (line.isEmpty ? '' : line[0]) {
      '+' => rest,
      '-' => RedisError(rest),
      ':' => int.parse(rest),
      r'$' => switch (int.parse(rest)) {
        < 0 => null,
        final length => utf8.decode(
          Uint8List.sublistView(await _wire.read(length + 2), 0, length),
          allowMalformed: true,
        ),
      },
      '*' => switch (int.parse(rest)) {
        < 0 => null,
        final count => [for (var i = 0; i < count; i++) await _reply()],
      },
      _ => throw DbException('Redis sent something unexpected: $line'),
    };
  }
}

/// A command line as redis-cli splits it: on spaces, with "double" or
/// 'single' quotes around an argument that has some, and \n, \t, \" or \\
/// inside double quotes.
List<String> redisArgs(String line) {
  final args = <String>[];
  final arg = StringBuffer();
  String? quote;
  var inArg = false;
  for (var i = 0; i < line.length; i++) {
    final char = line[i];
    if (quote != null) {
      if (char == quote) {
        quote = null;
      } else if (char == r'\' && quote == '"' && i + 1 < line.length) {
        final next = line[++i];
        arg.write(switch (next) {
          'n' => '\n',
          't' => '\t',
          'r' => '\r',
          _ => next,
        });
      } else {
        arg.write(char);
      }
    } else if (char == '"' || char == "'") {
      quote = char;
      inArg = true;
    } else if (char.trim().isEmpty) {
      if (inArg) args.add(arg.toString());
      arg.clear();
      inArg = false;
    } else {
      arg.write(char);
      inArg = true;
    }
  }
  if (quote != null) throw const DbException('A quote is not closed.');
  if (inArg) args.add(arg.toString());
  return args;
}
