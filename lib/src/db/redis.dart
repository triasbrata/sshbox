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

  /// Sends [commands] at once and reads their replies in order, a
  /// [RedisError] for each that failed: one round trip, where [command]
  /// makes one each.
  Future<List<Object?>> pipeline(List<List<String>> commands) =>
      _wire.serial(() async {
        _wire.write([for (final args in commands) ...encode(args)]);
        return [for (var i = 0; i < commands.length; i++) await _reply()];
      });

  /// Runs [commands] between MULTI and EXEC, sent at once so nothing else
  /// on this connection lands among them: EXEC's replies, a [RedisError]
  /// for each that failed as it ran. Throws, with none run, when Redis
  /// refuses one as it is queued.
  Future<List<Object?>> transaction(List<List<String>> commands) async {
    // MULTI's OK, then QUEUED, or why not, for each command, then EXEC's.
    final replies = await pipeline([
      ['MULTI'],
      ...commands,
      ['EXEC'],
    ]);
    final exec = replies.last;
    if (exec is List) return exec;
    throw DbException(
      '${replies.whereType<RedisError>().firstOrNull ?? exec ?? 'Redis ran none of them.'}',
    );
  }

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

/// What the side list's filter asks SCAN to MATCH: what was typed, as a
/// pattern, when it holds one of Redis's glob characters (`user:*`,
/// `session:??:*`, `[ab]*`, `\*`), and otherwise any key holding it.
String redisPattern(String filter) {
  final text = filter.trim();
  if (text.isEmpty) return '*';
  return text.contains(RegExp(r'[*?[\\]')) ? text : '*$text*';
}

/// Whether [key] matches [pattern] as Redis's own SCAN MATCH decides it:
/// stringmatchlen() in its util.c, byte for byte on the UTF-8 of both, so
/// what the side list narrows in memory is what the server would send.
bool redisMatch(String pattern, String key) {
  // As SCAN does, which skips matching for this one.
  if (pattern == '*') return true;
  final p = utf8.encode(pattern);
  final s = utf8.encode(key);
  // Once the rest of a pattern matches nowhere after a star, a longer
  // match for an earlier star cannot help: Redis's own cut-off.
  var skipLonger = false;
  const star = 0x2a, question = 0x3f, open = 0x5b, close = 0x5d;
  const caret = 0x5e, dash = 0x2d, backslash = 0x5c;

  bool match(int pi, int si, int nesting) {
    if (nesting > 1000) return false;
    while (pi < p.length && si < s.length) {
      switch (p[pi]) {
        case star:
          while (pi + 1 < p.length && p[pi + 1] == star) {
            pi++;
          }
          if (pi + 1 == p.length) return true;
          for (; si < s.length; si++) {
            if (match(pi + 1, si, nesting + 1)) return true;
            if (skipLonger) return false;
          }
          skipLonger = true;
          return false;
        case question:
          si++;
        case open:
          pi++;
          final not = pi < p.length && p[pi] == caret;
          if (not) pi++;
          var found = false;
          while (true) {
            if (pi + 1 < p.length && p[pi] == backslash) {
              pi++;
              if (p[pi] == s[si]) found = true;
            } else if (pi < p.length && p[pi] == close) {
              break;
            } else if (pi >= p.length) {
              // Never closed: the class ends with the pattern.
              pi--;
              break;
            } else if (pi + 2 < p.length && p[pi + 1] == dash) {
              final (a, b) = (p[pi], p[pi + 2]);
              final c = s[si];
              if (c >= (a < b ? a : b) && c <= (a < b ? b : a)) found = true;
              pi += 2;
            } else if (p[pi] == s[si]) {
              found = true;
            }
            pi++;
          }
          if (found == not) return false;
          si++;
        case backslash when pi + 1 < p.length:
          pi++;
          if (p[pi] != s[si]) return false;
          si++;
        default:
          if (p[pi] != s[si]) return false;
          si++;
      }
      pi++;
      if (si == s.length) {
        while (pi < p.length && p[pi] == star) {
          pi++;
        }
        break;
      }
    }
    return pi == p.length && si == s.length;
  }

  return match(0, 0, 0);
}
