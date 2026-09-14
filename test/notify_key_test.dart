import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/prime256v1.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/notifications/notify_key.dart';

import 'fake_relay.dart';

/// RFC 6979's P-256 key (A.2.5) as OpenSSL writes it in PKCS#8, and the
/// SubjectPublicKeyInfo and key id OpenSSL gives for it.
const _vectorPkcs8 =
    'MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgya+p2EW6dRZrXCFXZ7HWk05Q'
    'w9s26JsSe4piKxIPZyGhRANCAARg/tS6JVqdMclh63TGNW1owEm4kjth+mzmaWIuYPKftnkD'
    '/hAIuLyZpBrp6VYovGTy8bIMLX6fUXejwpTURiKZ';
const _vectorSpki =
    '3059301306072a8648ce3d020106082a8648ce3d0301070342000460fed4ba255a9d31c9'
    '61eb74c6356d68c049b8923b61fa6ce669622e60f29fb67903fe1008b8bc99a41ae9e956'
    '28bc64f2f1b20c2d7e9f5177a3c294d4462299';
const _vectorId = 'jnk_Wnp4zKSg9CDZvGK7Zpw8J1njn3I9OuEN';

/// The SHA-256 of no bytes at all: a DELETE's body.
const _emptyHash =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

final _hasOpenssl =
    Process.runSync('sh', ['-c', 'command -v openssl']).exitCode == 0;

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

BigInt _unsigned(List<int> bytes) => BigInt.parse(_hex(bytes), radix: 16);

/// Whether [signature], DER, signs [text] for the key in [spki]: checked as
/// the relay checks it, from the SubjectPublicKeyInfo alone.
bool _verifies(List<int> spki, String text, List<int> signature) {
  final p256 = ECCurve_prime256v1();
  // The point, after the SPKI's 26 bytes of head.
  final q = p256.curve.decodePoint(spki.sublist(26))!;
  // SEQUENCE { INTEGER r, INTEGER s }.
  expect(signature[0], 0x30);
  expect(signature[1], signature.length - 2);
  final rEnd = 4 + signature[3];
  expect([signature[2], signature[rEnd]], [0x02, 0x02]);
  expect(signature[rEnd + 1], signature.length - rEnd - 2);
  final r = signature.sublist(4, rEnd);
  final s = signature.sublist(rEnd + 2);
  // DER's integers are minimal and positive: a 0x00 only before a high bit.
  for (final integer in [r, s]) {
    expect(integer.first, lessThan(0x80));
    if (integer.first == 0) expect(integer[1], greaterThanOrEqualTo(0x80));
  }
  final verifier = ECDSASigner(SHA256Digest())
    ..init(false, PublicKeyParameter<ECPublicKey>(ECPublicKey(q, p256)));
  return verifier.verifySignature(
    utf8.encode(text),
    ECSignature(_unsigned(r), _unsigned(s)),
  );
}

/// A key's id, from its `LC_SSHBOX_KEY` value.
String _id(String? value) => value!.split(':').first;

void main() {
  group('a relay key', () {
    test('matches what OpenSSL makes of a known key: its SPKI, its PKCS#8 '
        'and the id both sides work out', () {
      final key = RelayKey.fromPkcs8(base64.decode(_vectorPkcs8));
      expect(_hex(key.spki), _vectorSpki);
      expect(base64.encode(key.pkcs8), _vectorPkcs8);
      expect(key.id, _vectorId);
      expect(key.value, '$_vectorId:$_vectorPkcs8');
    });

    test('a new one reads back from its PKCS#8, and what that signs its SPKI '
        'verifies', () {
      final key = RelayKey.generate();
      expect(key.id, matches(RegExp(r'^jnk_[A-Za-z0-9_-]{32}$')));
      expect(RelayKey.generate().id, isNot(key.id));
      expect(key.value, '${key.id}:${base64.encode(key.pkcs8)}');

      final back = RelayKey.fromPkcs8(base64.decode(key.value.split(':')[1]));
      expect(back.id, key.id);
      expect(back.spki, key.spki);
      const text = 'POST:/v1/send:$_emptyHash:2026-09-14T08:15:30+07:00:abc';
      expect(_verifies(key.spki, text, back.sign(text)), isTrue);
      expect(_verifies(key.spki, '$text.', back.sign(text)), isFalse);

      // A key whose public point is not its own is no key of ours.
      final mangled = key.pkcs8..last ^= 1;
      expect(() => RelayKey.fromPkcs8(mangled), throwsFormatException);
    });

    test('OpenSSL signs with its PKCS#8, as a server does, and verifies what '
        'the app signs', () async {
      final dir = await Directory.systemTemp.createTemp('jnk');
      addTearDown(() => dir.delete(recursive: true));
      final key = RelayKey.generate();
      String pem(String label, List<int> der) =>
          '-----BEGIN $label-----\n'
          '${base64.encode(der).replaceAllMapped(RegExp('.{1,64}'), (m) => '${m[0]}\n')}'
          '-----END $label-----\n';
      final private = File('${dir.path}/key.pem')
        ..writeAsStringSync(pem('PRIVATE KEY', key.pkcs8));
      final public = File('${dir.path}/pub.pem')
        ..writeAsStringSync(pem('PUBLIC KEY', key.spki));
      const text = 'DELETE:/v1/key:$_emptyHash:2026-09-14T01:15:30+00:00:abc';
      final message = File('${dir.path}/text')..writeAsStringSync(text);

      final byOpenssl = await Process.run('openssl', [
        'dgst', '-sha256', '-sign', private.path, message.path, //
      ], stdoutEncoding: null);
      expect(byOpenssl.exitCode, 0, reason: '${byOpenssl.stderr}');
      expect(_verifies(key.spki, text, byOpenssl.stdout as List<int>), isTrue);

      final signature = File('${dir.path}/sig')..writeAsBytesSync(key.sign(text));
      final checked = await Process.run('openssl', [
        'dgst', '-sha256', '-verify', public.path, //
        '-signature', signature.path, message.path,
      ]);
      expect(checked.stdout, contains('Verified OK'));
    }, skip: _hasOpenssl ? false : 'openssl is not installed here');
  });

  group('the relay, over HTTP', () {
    late HttpServer server;
    late List<({String method, String path, HttpHeaders headers, List<int> body})>
    requests;

    /// What it answers every request with.
    late int status;
    late String reply;

    setUp(() async {
      requests = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final body = await request.expand((chunk) => chunk).toList();
        requests.add((
          method: request.method,
          path: request.uri.path,
          headers: request.headers,
          body: body,
        ));
        request.response
          ..statusCode = status
          ..write(reply);
        await request.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    RelayClient relay() => RelayClient('http://127.0.0.1:${server.port}');

    test('registers the FCM token, the SPKI and the host, and wants its own '
        'key id back', () async {
      final key = RelayKey.generate();
      status = 200;
      reply = jsonEncode({'keyId': key.id});
      await relay().register(token: 'fcm-1', key: key, host: 'host-1');

      final request = requests.single;
      expect('${request.method} ${request.path}', 'POST /v1/register');
      expect(request.headers.contentType?.mimeType, 'application/json');
      expect(jsonDecode(utf8.decode(request.body)), {
        'token': 'fcm-1',
        'publicKey': base64.encode(key.spki),
        'host': 'host-1',
      });

      reply = jsonEncode({'keyId': 'jnk_someone-else'});
      await expectLater(
        relay().register(token: 'fcm-1', key: key, host: 'host-1'),
        throwsA(isA<HttpException>()),
      );
      status = 429;
      await expectLater(
        relay().register(token: 'fcm-1', key: key, host: 'host-1'),
        throwsA(isA<HttpException>()),
      );
    });

    test('revokes in a DELETE the key signs, SNAP style', () async {
      final key = RelayKey.generate();
      status = 204;
      reply = '';
      await relay().revoke(key);
      await relay().revoke(key);

      for (final request in requests) {
        expect('${request.method} ${request.path}', 'DELETE /v1/key');
        expect(request.body, isEmpty);
        String header(String name) => request.headers.value(name)!;
        expect(header('X-PARTNER-ID'), key.id);
        final timestamp = header('X-TIMESTAMP');
        expect(
          timestamp,
          matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d$')),
        );
        expect(
          DateTime.parse(timestamp).difference(DateTime.now()).abs(),
          lessThan(const Duration(minutes: 1)),
        );
        final externalId = header('X-EXTERNAL-ID');
        expect(externalId, matches(RegExp(r'^[A-Za-z0-9-]{16,64}$')));
        expect(
          _verifies(
            key.spki,
            'DELETE:/v1/key:$_emptyHash:$timestamp:$externalId',
            base64.decode(header('X-SIGNATURE')),
          ),
          isTrue,
        );
      }
      // Unique to each request.
      expect(
        requests.map((r) => r.headers.value('X-EXTERNAL-ID')).toSet(),
        hasLength(2),
      );
    });

    test('a key the relay no longer knows is revoked all the same; a relay '
        'that fails is an error', () async {
      final key = RelayKey.generate();
      reply = '';
      for (status in [401, 404]) {
        await relay().revoke(key);
      }
      for (status in [429, 500]) {
        await expectLater(relay().revoke(key), throwsA(isA<HttpException>()));
      }
    });
  });

  group('a key for each host', () {
    late FakeRelay relay;
    late InMemorySecretStore secrets;
    late NotifyKeys keys;

    /// What the keystore holds.
    Future<Map<String, Object?>> stored() async =>
        jsonDecode(await secrets.read(NotifyKeys.storageKey) ?? '{}')
            as Map<String, Object?>;

    setUp(() {
      relay = FakeRelay();
      secrets = InMemorySecretStore();
      keys = NotifyKeys(secrets, relay: relay);
    });

    test("a host's first connect registers a key of its own, kept with the "
        'token', () async {
      await keys.useFcmToken('fcm-1');

      final one = await keys.forConnect('host-1');
      final [id, pkcs8] = one!.split(':');
      expect(relay.registered, [(token: 'fcm-1', keyId: id, host: 'host-1')]);
      expect(await stored(), {
        'host-1': {'keyId': id, 'privateKey': pkcs8, 'fcmToken': 'fcm-1'},
      });

      expect(_id(await keys.forConnect('host-2')), isNot(id));
      // The same host again: the same key, registered once.
      expect(await keys.forConnect('host-1'), one);
      expect(relay.registered, hasLength(2));
    });

    test('the next launch keeps each key rather than register again', () async {
      await keys.useFcmToken('fcm-1');
      final one = await keys.forConnect('host-1');

      final relaunched = NotifyKeys(secrets, relay: relay);
      await relaunched.useFcmToken('fcm-1');
      expect(await relaunched.forConnect('host-1'), one);
      expect(relay.registered, hasLength(1));
    });

    test('a new FCM token registers every key again, each keeping its id', () async {
      await keys.useFcmToken('fcm-1');
      final one = await keys.forConnect('host-1');
      final two = await keys.forConnect('host-2');

      await keys.useFcmToken('fcm-2');
      expect(relay.registered.skip(2), [
        (token: 'fcm-2', keyId: _id(one), host: 'host-1'),
        (token: 'fcm-2', keyId: _id(two), host: 'host-2'),
      ]);
      expect(await keys.valueFor('host-1'), one);
      expect((await stored())['host-2'], containsPair('fcmToken', 'fcm-2'));

      // Replaced while the app was closed, too.
      final relaunched = NotifyKeys(secrets, relay: relay);
      await relaunched.useFcmToken('fcm-3');
      expect(relay.registered.skip(4).map((r) => r.token), ['fcm-3', 'fcm-3']);
      expect(relay.revoked, isEmpty);
    });

    test('a token the relay missed is registered at the next connect, the key '
        'handed out meanwhile', () async {
      await keys.useFcmToken('fcm-1');
      final one = await keys.forConnect('host-1');
      relay.down = true;
      await keys.useFcmToken('fcm-2');
      expect(await keys.valueFor('host-1'), one);

      relay.down = false;
      expect(await keys.forConnect('host-1'), one);
      expect(relay.registered.last, (
        token: 'fcm-2',
        keyId: _id(one),
        host: 'host-1',
      ));
    });

    test('with the relay out of reach a connect goes without, and the next '
        'one tries again', () async {
      await keys.useFcmToken('fcm-1');
      relay.down = true;
      expect(await keys.forConnect('host-1'), isNull);
      expect(await stored(), isEmpty);

      relay.down = false;
      expect(await keys.forConnect('host-1'), startsWith('jnk_'));
    });

    test('without an FCM token nothing is registered', () async {
      expect(await keys.forConnect('host-1'), isNull);
      expect(relay.registered, isEmpty);
    });

    test("a deleted host's key is revoked and dropped, dropped even with the "
        'relay out of reach', () async {
      await keys.useFcmToken('fcm-1');
      final one = await keys.forConnect('host-1');
      await keys.forConnect('host-2');

      await keys.revoke('host-1');
      expect(relay.revoked, [_id(one)]);
      expect(await keys.valueFor('host-1'), isNull);
      expect((await stored()).keys, ['host-2']);

      relay.down = true;
      await keys.revoke('host-2');
      expect(await keys.valueFor('host-2'), isNull);
      expect(await stored(), isEmpty);
    });

    test('reset revokes and drops every key, and each host registers a new '
        'one at its next connect', () async {
      await keys.useFcmToken('fcm-1');
      final one = await keys.forConnect('host-1');
      final two = await keys.forConnect('host-2');

      await keys.reset();
      expect(relay.revoked, [_id(one), _id(two)]);
      expect(await keys.valueFor('host-1'), isNull);
      expect(await stored(), isEmpty);

      expect(_id(await keys.forConnect('host-1')), isNot(_id(one)));
    });

    test('a reset the relay cannot take keeps the keys, which still work', () async {
      await keys.useFcmToken('fcm-1');
      final one = await keys.forConnect('host-1');
      relay.down = true;

      await expectLater(keys.reset(), throwsA(isA<SocketException>()));
      expect(await keys.valueFor('host-1'), one);
      expect((await stored()).keys, ['host-1']);
    });

    test('the bearer key an earlier version kept is dropped', () async {
      await secrets.write('sshbox.notify.key', '{"key":"jnk_1"}');
      await keys.useFcmToken('fcm-1');
      expect(await secrets.read('sshbox.notify.key'), isNull);
    });
  });
}
