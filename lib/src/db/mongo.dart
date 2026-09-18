import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../session/terminal_session.dart' show Tunnel;
import 'wire.dart';

/// MongoDB's protocol, OP_MSG (MongoDB 3.6 and later): every request a
/// database command. Documents go both ways as Extended JSON values, see
/// [bsonEncode], so what the browser shows can be typed back into a command.
class MongoClient {
  MongoClient._(this._wire);

  final Wire _wire;
  var _requestId = 0;

  /// Signed in as [user] on [authSource] with SCRAM-SHA-256, or SCRAM-SHA-1
  /// for a user that has only that; no sign-in when [user] is blank.
  static Future<MongoClient> connect(
    Tunnel tunnel, {
    String user = '',
    String password = '',
    String authSource = 'admin',
  }) async {
    final client = MongoClient._(Wire(tunnel));
    try {
      final ask = {if (user.isNotEmpty) 'saslSupportedMechs': '$authSource.$user'};
      var hello = await client._run({'hello': 1, ...ask, r'$db': 'admin'});
      // Before 4.4.2, hello was isMaster.
      if (hello['ok'] != 1) {
        hello = await client.command('admin', {'isMaster': 1, ...ask});
      }
      if (user.isNotEmpty) {
        await client._signIn(hello, user, password, authSource);
      }
      return client;
    } catch (_) {
      await client.close();
      rethrow;
    }
  }

  Future<void> _signIn(
    Map<String, Object?> hello,
    String user,
    String password,
    String authSource,
  ) async {
    final mechanisms = hello['saslSupportedMechs'] as List? ?? const [];
    final sha256Too = mechanisms.contains('SCRAM-SHA-256');
    final scram = sha256Too
        ? Scram(sha256, user, password)
        : Scram(
            sha1,
            user,
            md5.convert(utf8.encode('$user:mongo:$password')).toString(),
          );
    Map<String, Object?> binary(String text) => {
      r'$binary': {'base64': base64.encode(utf8.encode(text)), 'subType': '00'},
    };
    String payload(Map<String, Object?> reply) => switch (reply['payload']) {
      {r'$binary': {'base64': final String data}} => utf8.decode(
        base64.decode(data),
      ),
      _ => '',
    };

    var reply = await command(authSource, {
      'saslStart': 1,
      'mechanism': sha256Too ? 'SCRAM-SHA-256' : 'SCRAM-SHA-1',
      'payload': binary(scram.first),
      'autoAuthorize': 1,
      'options': {'skipEmptyExchange': true},
    });
    reply = await command(authSource, {
      'saslContinue': 1,
      'conversationId': reply['conversationId'],
      'payload': binary(scram.reply(payload(reply))),
    });
    scram.verify(payload(reply));
    while (reply['done'] != true) {
      reply = await command(authSource, {
        'saslContinue': 1,
        'conversationId': reply['conversationId'],
        'payload': binary(''),
      });
    }
  }

  /// Runs [command] on [db], or on the one its own `$db` names: the reply,
  /// or the server's error thrown.
  Future<Map<String, Object?>> command(
    String db,
    Map<String, Object?> command,
  ) async {
    final reply = await _run({...command, r'$db': command[r'$db'] ?? db});
    if (reply['ok'] != 1) {
      final name = reply['codeName'];
      throw DbException(
        '${reply['errmsg'] ?? 'The command failed.'}'
        '${name == null ? '' : ' ($name)'}',
      );
    }
    return reply;
  }

  Future<void> close() => _wire.close();

  Future<Map<String, Object?>> _run(Map<String, Object?> document) =>
      _wire.serial(() async {
        final body = bsonEncode(document);
        final header = ByteData(21)
          ..setInt32(0, 21 + body.length, Endian.little)
          ..setInt32(4, ++_requestId, Endian.little)
          ..setInt32(12, 2013, Endian.little);
        _wire.write([...header.buffer.asUint8List(), ...body]);
        final head = ByteData.sublistView(await _wire.read(16));
        final message = await _wire.read(head.getInt32(0, Endian.little) - 16);
        // Flags, then one section of kind 0: the reply. A checksum may
        // follow it, and is left unread.
        if (head.getInt32(12, Endian.little) != 2013 || message[4] != 0) {
          throw const DbException('MongoDB answered in a way this app does '
              'not read.');
        }
        return bsonDecode(Uint8List.sublistView(message, 5));
      });
}

/// [document] as BSON. Its values are JSON's, with Extended JSON's wrappers
/// for the rest: `{"$oid": …}`, `{"$date": …}`, `{"$numberLong": …}`,
/// `{"$binary": …}` and the others [bsonDecode] makes. An int goes as int32
/// when it fits.
Uint8List bsonEncode(Map<String, Object?> document) {
  final out = BytesBuilder(copy: false);
  _document(out, document);
  return out.takeBytes();
}

void _document(BytesBuilder out, Map<Object?, Object?> document) {
  final body = BytesBuilder(copy: false);
  document.forEach((key, value) => _element(body, '$key', value));
  out
    ..add(_int32(body.length + 5))
    ..add(body.takeBytes())
    ..addByte(0);
}

void _element(BytesBuilder out, String key, Object? value) {
  void head(int type) => out
    ..addByte(type)
    ..add(utf8.encode(key))
    ..addByte(0);
  void cstring(String text) => out
    ..add(utf8.encode(text))
    ..addByte(0);

  switch (value) {
    case null:
      head(0x0A);
    case bool value:
      head(0x08);
      out.addByte(value ? 1 : 0);
    case int value when value >= -0x80000000 && value <= 0x7FFFFFFF:
      head(0x10);
      out.add(_int32(value));
    case int value:
      head(0x12);
      out.add(_int64(value));
    case double value:
      head(0x01);
      out.add((ByteData(8)..setFloat64(0, value, Endian.little)).buffer.asUint8List());
    case String value:
      head(0x02);
      final bytes = utf8.encode(value);
      out
        ..add(_int32(bytes.length + 1))
        ..add(bytes)
        ..addByte(0);
    case List value:
      head(0x04);
      _document(out, value.asMap());
    case {r'$oid': String hex} when hex.length == 24:
      head(0x07);
      out.add([
        for (var i = 0; i < 24; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
      ]);
    case {r'$date': final date}:
      head(0x09);
      out.add(_int64(switch (date) {
        String iso => DateTime.parse(iso).millisecondsSinceEpoch,
        int millis => millis,
        {r'$numberLong': String millis} => int.parse(millis),
        _ => throw DbException('Cannot read $date as a date.'),
      }));
    case {r'$numberLong': String number}:
      head(0x12);
      out.add(_int64(int.parse(number)));
    case {r'$numberInt': String number}:
      head(0x10);
      out.add(_int32(int.parse(number)));
    case {r'$numberDouble': String number}:
      _element(out, key, double.parse(number));
    case {r'$binary': {'base64': String data, 'subType': String type}}:
      head(0x05);
      final bytes = base64.decode(data);
      out
        ..add(_int32(bytes.length))
        ..addByte(int.parse(type, radix: 16))
        ..add(bytes);
    case {
      r'$regularExpression': {'pattern': String pattern, 'options': String options},
    }:
      head(0x0B);
      cstring(pattern);
      cstring(options);
    case {r'$timestamp': {'t': int seconds, 'i': int increment}}:
      head(0x11);
      out
        ..add(_int32(increment))
        ..add(_int32(seconds));
    case {r'$minKey': 1}:
      head(0xFF);
    case {r'$maxKey': 1}:
      head(0x7F);
    case Map value:
      head(0x03);
      _document(out, value);
    default:
      throw DbException('Cannot send ${value.runtimeType} to MongoDB.');
  }
}

Uint8List _int32(int value) =>
    (ByteData(4)..setInt32(0, value, Endian.little)).buffer.asUint8List();

Uint8List _int64(int value) =>
    (ByteData(8)..setInt64(0, value, Endian.little)).buffer.asUint8List();

/// A BSON document as Extended JSON's relaxed values: numbers, strings and
/// the like as they are, and `{"$oid": …}`, `{"$date": "2024-…Z"}`,
/// `{"$numberDecimal": "1.5"}` and so on for the rest.
Map<String, Object?> bsonDecode(Uint8List bytes) => _BsonReader(bytes).document();

class _BsonReader {
  _BsonReader(this.bytes) : view = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData view;
  var at = 0;

  Map<String, Object?> document() {
    // Where its closing NUL is: past the length, and all of what it counts.
    final length = int32();
    final end = at + length - 5;
    final out = <String, Object?>{};
    while (at < end) {
      final type = bytes[at++];
      out[cstring()] = value(type);
    }
    at = end + 1;
    return out;
  }

  int int32() => view.getInt32((at += 4) - 4, Endian.little);
  int int64() => view.getInt64((at += 8) - 8, Endian.little);

  String cstring() {
    final end = bytes.indexOf(0, at);
    final text = utf8.decode(bytes.sublist(at, end), allowMalformed: true);
    at = end + 1;
    return text;
  }

  String string() {
    final length = int32();
    final text = utf8.decode(
      bytes.sublist(at, at + length - 1),
      allowMalformed: true,
    );
    at += length;
    return text;
  }

  String hex(int count) => [
    for (final byte in bytes.sublist(at, at += count))
      byte.toRadixString(16).padLeft(2, '0'),
  ].join();

  Object? value(int type) => switch (type) {
    0x01 => switch (view.getFloat64((at += 8) - 8, Endian.little)) {
      final number when number.isFinite => number,
      final number => {
        r'$numberDouble': number.isNaN
            ? 'NaN'
            : number > 0
            ? 'Infinity'
            : '-Infinity',
      },
    },
    0x02 => string(),
    0x03 => document(),
    0x04 => document().values.toList(),
    0x05 => () {
      final length = int32();
      final type = bytes[at++];
      return {
        r'$binary': {
          'base64': base64.encode(bytes.sublist(at, at += length)),
          'subType': type.toRadixString(16).padLeft(2, '0'),
        },
      };
    }(),
    0x06 => {r'$undefined': true},
    0x07 => {r'$oid': hex(12)},
    0x08 => bytes[at++] != 0,
    0x09 => switch (int64()) {
      final millis when millis.abs() <= 8640000000000000 => {
        r'$date': DateTime.fromMillisecondsSinceEpoch(
          millis,
          isUtc: true,
        ).toIso8601String(),
      },
      final millis => {
        r'$date': {r'$numberLong': '$millis'},
      },
    },
    0x0A => null,
    0x0B => {
      r'$regularExpression': {'pattern': cstring(), 'options': cstring()},
    },
    0x0C => {
      r'$dbPointer': {
        r'$ref': string(),
        r'$id': {r'$oid': hex(12)},
      },
    },
    0x0D => {r'$code': string()},
    0x0E => {r'$symbol': string()},
    0x0F => {r'$code': (at += 4, string()).$2, r'$scope': document()},
    0x10 => int32(),
    0x11 => () {
      final increment = view.getUint32(at, Endian.little);
      final seconds = view.getUint32(at + 4, Endian.little);
      at += 8;
      return {
        r'$timestamp': {'t': seconds, 'i': increment},
      };
    }(),
    0x12 => int64(),
    0x13 => {r'$numberDecimal': decimal128()},
    0xFF => {r'$minKey': 1},
    0x7F => {r'$maxKey': 1},
    _ => throw DbException('MongoDB sent a BSON type this app cannot read '
        '($type).'),
  };

  /// A Decimal128 as MongoDB writes it: `1.5`, `0.001`, `1E+2`.
  String decimal128() {
    var bits = BigInt.zero;
    for (var i = 15; i >= 0; i--) {
      bits = (bits << 8) | BigInt.from(bytes[at + i]);
    }
    at += 16;
    int field(int shift, int mask) => ((bits >> shift) & BigInt.from(mask)).toInt();
    final negative = field(127, 1) == 1;
    final combination = field(122, 0x1F);
    if (combination == 0x1F) return 'NaN';
    if (combination == 0x1E) return negative ? '-Infinity' : 'Infinity';
    // A coefficient in the "11" form is past 34 digits: Decimal128 reads it
    // as zero.
    final large = field(125, 3) == 3;
    final exponent = (large ? field(111, 0x3FFF) : field(113, 0x3FFF)) - 6176;
    final digits = large
        ? '0'
        : (bits & ((BigInt.one << 113) - BigInt.one)).toString();
    final adjusted = exponent + digits.length - 1;
    final String text;
    if (exponent > 0 || adjusted < -6) {
      text =
          '${digits[0]}${digits.length > 1 ? '.${digits.substring(1)}' : ''}'
          'E${adjusted < 0 ? '' : '+'}$adjusted';
    } else if (exponent == 0) {
      text = digits;
    } else {
      final point = digits.length + exponent;
      text = point > 0
          ? '${digits.substring(0, point)}.${digits.substring(point)}'
          : '0.${'0' * -point}$digits';
    }
    return negative ? '-$text' : text;
  }
}
