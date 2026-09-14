import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/prime256v1.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';
import 'package:sshbox/src/notifications/notify_key.dart';

/// The relay with no network. Like the real one, it takes a register or a
/// revoke only when the key it is about signs it, SNAP-style, and answers a
/// revoke of a key it has no more with 401 `unknown key`. It keeps every key
/// registered and every key revoked.
class FakeRelay extends RelayClient {
  FakeRelay() : super('http://relay.invalid');

  final registered = <({String token, String keyId, String host})>[];
  final revoked = <String>[];

  /// Out of reach while set, as when the phone is offline.
  bool down = false;

  /// While set, every request is refused as one from a phone whose clock is
  /// more than 5 minutes off.
  bool clockOff = false;

  /// Each key registered and not revoked: its SPKI, by id.
  final _keys = <String, List<int>>{};

  @override
  Future<(int, String)> exchange(
    String method,
    String path,
    Map<String, String> headers,
    List<int> body,
  ) async {
    if (down) throw const SocketException('Network is unreachable');
    (int, String) error(int status, String text) =>
        (status, jsonEncode({'error': text}));
    if (clockOff) return error(401, 'stale or bad timestamp');
    final id = headers['X-PARTNER-ID'];
    bool signedBy(List<int> spki) {
      final signature = headers['X-SIGNATURE'];
      final text =
          '$method:$path:${_hex(_sha256(body))}:'
          '${headers['X-TIMESTAMP']}:${headers['X-EXTERNAL-ID']}';
      return signature != null &&
          verifies(spki, text, base64.decode(signature));
    }

    switch ('$method $path') {
      case 'POST /v1/register':
        final fields = jsonDecode(utf8.decode(body)) as Map;
        final spki = base64.decode(fields['publicKey'] as String);
        if (id != 'jnk_${base64Url.encode(_sha256(spki)).substring(0, 32)}') {
          return error(401, "X-PARTNER-ID is not publicKey's key id");
        }
        if (!signedBy(spki)) return error(401, 'bad signature');
        _keys[id!] = spki;
        registered.add((
          token: fields['token'] as String,
          keyId: id,
          host: fields['host'] as String,
        ));
        return (200, jsonEncode({'keyId': id}));
      case 'DELETE /v1/key':
        final spki = _keys[id];
        if (spki == null) return error(401, 'unknown key');
        if (!signedBy(spki)) return error(401, 'bad signature');
        _keys.remove(id);
        revoked.add(id!);
        return (204, '');
      default:
        return error(404, 'not found');
    }
  }
}

/// Whether [signature], DER, signs [text] for the key in [spki]: checked as
/// the relay checks it, from the SubjectPublicKeyInfo alone.
bool verifies(List<int> spki, String text, List<int> signature) {
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

Uint8List _sha256(List<int> bytes) =>
    SHA256Digest().process(Uint8List.fromList(bytes));

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

BigInt _unsigned(List<int> bytes) => BigInt.parse(_hex(bytes), radix: 16);
