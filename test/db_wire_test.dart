import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/db/mongo.dart';
import 'package:sshbox/src/db/redis.dart';
import 'package:sshbox/src/db/wire.dart';

void main() {
  test('SCRAM matches the RFCs\' worked examples', () {
    // RFC 5802, section 5.
    final sha1Scram = Scram(sha1, 'user', 'pencil',
        nonce: 'fyko+d2lbbFgONRv9qkxdawL');
    expect(sha1Scram.first, 'n,,n=user,r=fyko+d2lbbFgONRv9qkxdawL');
    expect(
      sha1Scram.reply('r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,'
          's=QSXCR+Q6sek8bf92,i=4096'),
      'c=biws,r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,'
      'p=v0X8v3Bz2T0CJGbJQyF0X+HI4Ts=',
    );
    sha1Scram.verify('v=rmF9pqV8S7suAoZWja4dJRkFsKQ=');

    // RFC 7677, section 3.
    final sha256Scram = Scram(sha256, 'user', 'pencil',
        nonce: 'rOprNGfwEbeRWgbNEkqO');
    expect(
      sha256Scram.reply('r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF\$k0,'
          's=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096'),
      'c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF\$k0,'
      'p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=',
    );
    sha256Scram.verify('v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=');
    expect(
      () => sha256Scram.verify('v=AAAA'),
      throwsA(isA<DbException>()),
    );
  });

  test('Redis replies come apart right however the bytes arrive', () async {
    final reply = StreamController<Uint8List>();
    final sent = StreamController<List<int>>();
    final written = <int>[];
    sent.stream.listen(written.addAll);
    final client = await RedisClient.connect((
      output: reply.stream,
      input: sent.sink,
    ));
    final answer = client.command(['HGETALL', 'a key']);
    // A CRLF split across chunks, a bulk string holding one, and nesting.
    for (final chunk in [
      '*4\r\n\$5\r\nfie',
      'ld\r\n\$4\r\na\r\nb\r\n*2\r\n:-3\r',
      '\n\$-1\r\n+OK\r\n',
    ]) {
      reply.add(utf8.encode(chunk));
    }
    expect(await answer, [
      'field',
      'a\r\nb',
      [-3, null],
      'OK',
    ]);
    expect(
      utf8.decode(written),
      '*2\r\n\$7\r\nHGETALL\r\n\$5\r\na key\r\n',
    );

    final refused = client.command(['NOPE']);
    reply.add(utf8.encode('-ERR unknown command\r\n'));
    await expectLater(
      refused,
      throwsA(isA<DbException>().having(
        (error) => error.message,
        'message',
        'ERR unknown command',
      )),
    );
  });

  test('a Redis command line splits as redis-cli splits it', () {
    expect(redisArgs(r'SET "a key" '"'it''s'"' "x\ny"'), [
      'SET',
      'a key',
      'its',
      'x\ny',
    ]);
    expect(redisArgs('  GET   k  '), ['GET', 'k']);
    expect(redisArgs('SET k ""'), ['SET', 'k', '']);
    expect(() => redisArgs('GET "k'), throwsA(isA<DbException>()));
  });

  test('BSON goes both ways as Extended JSON', () {
    final document = <String, Object?>{
      'find': 'things',
      'small': 5,
      'big': 1 << 40,
      'real': 1.5,
      'yes': true,
      'none': null,
      'list': [1, 'two', {'three': 3}],
      'id': {r'$oid': '5f1d7f0c9d1e8a0a1c2b3d4e'},
      'when': {r'$date': '2024-01-02T03:04:05.678Z'},
      'long': 7,
      'bytes': {
        r'$binary': {'base64': 'AQID', 'subType': '04'},
      },
      'pattern': {
        r'$regularExpression': {'pattern': '^a', 'options': 'i'},
      },
      'stamp': {
        r'$timestamp': {'t': 1700000000, 'i': 3},
      },
      'nan': {r'$numberDouble': 'NaN'},
      'low': {r'$minKey': 1},
    };
    expect(bsonDecode(bsonEncode(document)), document);
    expect(
      bsonDecode(bsonEncode({'n': {r'$numberLong': '12'}})),
      {'n': 12},
    );
  });

  test('a Decimal128 reads as MongoDB writes it', () {
    String read(int low, int high) {
      final bytes = BytesBuilder()
        ..add([24, 0, 0, 0, 0x13, 0x64, 0])
        ..add((ByteData(16)
              ..setUint64(0, low, Endian.little)
              ..setUint64(8, high, Endian.little))
            .buffer
            .asUint8List())
        ..addByte(0);
      return (bsonDecode(bytes.takeBytes())['d']
          as Map)[r'$numberDecimal'] as String;
    }

    // The exponent is biased by 6176, and sits at bit 49 of the high half.
    int high(int exponent) => (exponent + 6176) << 49;
    expect(read(15, high(-1)), '1.5');
    expect(read(1, high(-3)), '0.001');
    expect(read(1, high(2)), '1E+2');
    expect(read(12345, high(0) | (1 << 63)), '-12345');
    expect(read(0, 0x7C00000000000000), 'NaN');
  });
}
