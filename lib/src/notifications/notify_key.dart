import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/prime256v1.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';

import '../data/secret_store.dart';

/// The relay servers send a push through: jeansh-notify, a Cloudflare Worker
/// (github.com/triasbrata/jeansh-notify) that alone holds the Firebase
/// credentials. The one place its address is written.
const notifyRelay = 'https://jeansh-notify.brata.cloud';

final _p256 = ECCurve_prime256v1();

/// A P-256 public key's SubjectPublicKeyInfo DER up to its 65-byte point:
/// the ecPublicKey and prime256v1 OIDs, then the BIT STRING's head.
final _spkiHead = _unhex('3059301306072a8648ce3d020106082a8648ce3d030107034200');

/// A P-256 private key's PKCS#8 DER up to its 32-byte scalar, as OpenSSL
/// writes one: version 0, the same two OIDs, and an RFC 5915 ECPrivateKey
/// (version 1, the scalar, then [_pkcs8Tail] and the public point).
final _pkcs8Head = _unhex(
  '308187020100301306072a8648ce3d020106082a8648ce3d030107046d306b0201010420',
);
final _pkcs8Tail = _unhex('a144034200');

/// One host's relay key: a P-256 key pair. The host's servers sign
/// `POST /v1/send` with the private half, and the relay checks it with the
/// public half, which is all it is given.
class RelayKey {
  RelayKey._(this._d);

  /// A new key, from the platform's secure random source.
  factory RelayKey.generate() {
    final random = Random.secure();
    while (true) {
      final d = _unsigned([for (var i = 0; i < 32; i++) random.nextInt(256)]);
      // Out of range about once in 2^32 draws: draw again.
      if (d > BigInt.zero && d < _p256.n) return RelayKey._(d);
    }
  }

  /// The key in [der], PKCS#8 as [pkcs8] writes it.
  factory RelayKey.fromPkcs8(List<int> der) {
    const scalarAt = 36;
    if (der.length == 138) {
      final key = RelayKey._(_unsigned(der.sublist(scalarAt, scalarAt + 32)));
      // Read back whole: the rest must be what this key writes, public point
      // included.
      if (listEquals(key.pkcs8, der)) return key;
    }
    throw const FormatException('Not a P-256 PKCS#8 key as Jeansh writes one');
  }

  /// The private scalar.
  final BigInt _d;

  /// The public point.
  late final ECPoint _q = (_p256.G * _d)!;

  /// The public key, SubjectPublicKeyInfo DER: what the relay is given.
  Uint8List get spki =>
      Uint8List.fromList([..._spkiHead, ..._q.getEncoded(false)]);

  /// The private key, PKCS#8 DER: what a server signs with, and what OpenSSL
  /// reads as `-----BEGIN PRIVATE KEY-----`.
  Uint8List get pkcs8 => Uint8List.fromList([
    ..._pkcs8Head,
    ..._bytes(_d, 32),
    ..._pkcs8Tail,
    ..._q.getEncoded(false),
  ]);

  /// The relay's name for this key, worked out on both sides from [spki]:
  /// `jnk_` and the first 32 characters of its SHA-256, base64url.
  late final String id =
      'jnk_${base64Url.encode(_sha256(spki)).substring(0, 32)}';

  /// What a host's shells get as `LC_SSHBOX_KEY`: [id], a colon, and
  /// [pkcs8] in standard base64.
  String get value => '$id:${base64.encode(pkcs8)}';

  /// [text]'s ECDSA SHA-256 signature, DER. Deterministic (RFC 6979), so it
  /// takes no random source.
  Uint8List sign(String text) {
    final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
      ..init(true, PrivateKeyParameter<ECPrivateKey>(ECPrivateKey(_d, _p256)));
    final signature =
        signer.generateSignature(utf8.encode(text)) as ECSignature;
    List<int> integer(BigInt value) {
      final bytes = _bytes(value);
      // Positive: a leading bit set would read as a sign.
      final body = bytes.first >= 0x80 ? [0, ...bytes] : bytes;
      return [0x02, body.length, ...body];
    }

    final body = [...integer(signature.r), ...integer(signature.s)];
    return Uint8List.fromList([0x30, body.length, ...body]);
  }
}

/// The headers that sign a request to the relay, the way Indonesia's SNAP
/// payment API signs one: [key]'s id, the time, an id of the request's own,
/// and [key]'s signature over
/// `<METHOD>:<PATH>:<hex SHA-256 of the body>:<X-TIMESTAMP>:<X-EXTERNAL-ID>`.
Map<String, String> _signed(
  RelayKey key,
  String method,
  String path,
  List<int> body,
) {
  // yyyy-MM-ddTHH:mm:ss and the zone, UTC's.
  final timestamp =
      '${DateTime.now().toUtc().toIso8601String().substring(0, 19)}+00:00';
  final random = Random.secure();
  final externalId = _hex([for (var i = 0; i < 16; i++) random.nextInt(256)]);
  final signature = key.sign(
    '$method:$path:${_hex(_sha256(body))}:$timestamp:$externalId',
  );
  return {
    'X-PARTNER-ID': key.id,
    'X-TIMESTAMP': timestamp,
    'X-EXTERNAL-ID': externalId,
    'X-SIGNATURE': base64.encode(signature),
  };
}

/// The relay's two calls the app makes, each signed with the key it is about.
/// Its `POST /v1/send` is the servers'.
class RelayClient {
  const RelayClient([this._base = notifyRelay]);

  /// Where the relay is: [notifyRelay], or a test's own server.
  final String _base;

  /// Has the relay send what [key] signs to [token], as [host]'s. [key] signs
  /// this request too, so only its holder can point it at a phone. Again with
  /// a new token, it moves the key there.
  Future<void> register({
    required String token,
    required RelayKey key,
    required String host,
  }) async {
    final (status, reply) = await _call(
      key,
      'POST',
      '/v1/register',
      utf8.encode(
        jsonEncode({
          'token': token,
          'publicKey': base64.encode(key.spki),
          'host': host,
        }),
      ),
    );
    if (status != 200) throw HttpException('The relay answered $status');
    // A name of its own would mean the two sides disagree, and no server's
    // send would ever be matched to this key.
    if ((jsonDecode(reply) as Map)['keyId'] != key.id) {
      throw const HttpException('The relay named the key differently');
    }
  }

  /// Stops [key] from sending, in a request [key] signs. Done only when the
  /// relay says so: 204, or 401 `unknown key` for a key it has no more (never
  /// registered, revoked before, or deleted after FCM's 410). Anything else
  /// throws, the key still working: a relay out of reach, say, or 401
  /// `stale or bad timestamp` from a phone clock more than 5 minutes off.
  Future<void> revoke(RelayKey key) async {
    final (status, reply) = await _call(key, 'DELETE', '/v1/key');
    final gone =
        status == 401 &&
        switch (jsonDecode(reply)) {
          {'error': 'unknown key'} => true,
          _ => false,
        };
    if (status != 204 && !gone) {
      throw HttpException('The relay answered $status');
    }
  }

  /// [method] [path] with [body], signed with [key]: the relay's status and
  /// reply.
  Future<(int, String)> _call(
    RelayKey key,
    String method,
    String path, [
    List<int> body = const [],
  ]) => exchange(method, path, _signed(key, method, path, body), body);

  /// Sends one request to the relay, and gives back its status and reply:
  /// where a test's fake relay answers instead.
  @visibleForTesting
  Future<(int, String)> exchange(
    String method,
    String path,
    Map<String, String> headers,
    List<int> body,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.openUrl(method, Uri.parse('$_base$path'));
      headers.forEach(request.headers.set);
      if (body.isNotEmpty) request.headers.contentType = ContentType.json;
      request
        ..contentLength = body.length
        ..add(body);
      const wait = Duration(seconds: 15);
      final response = await request.close().timeout(wait);
      final reply = await utf8.decodeStream(response).timeout(wait);
      return (response.statusCode, reply);
    } finally {
      client.close(force: true);
    }
  }
}

/// The keys servers send a push with through the relay, one per saved host,
/// each registered for this device's FCM token. A host's shells get its key
/// as `LC_SSHBOX_KEY` (see `LiveSession.connect`); the FCM token goes to the
/// relay and to no server.
///
/// A host gets its key at its first connect once FCM has given a token. Each
/// key is registered again when FCM replaces the token, keeping its id, so
/// servers holding it carry on. A relay out of reach is tried again at the
/// next connect or token, never in a loop of its own.
///
/// A key dropped, with its host or by a reset, goes to no host from then on.
/// Until the relay confirms its revoke it waits in [pendingKey], tried again
/// at each launch (FCM's first token), host delete and reset.
class NotifyKeys {
  NotifyKeys(this._secrets, {this._relay = const RelayClient()});

  /// Where the keys are kept: JSON, from host id to its key's id, PKCS#8 and
  /// the FCM token it was registered for.
  static const storageKey = 'sshbox.notify.keys';

  /// Where dropped keys wait for their revoke: JSON, from key id to PKCS#8.
  static const pendingKey = 'sshbox.notify.revoke';

  final SecretStore _secrets;
  final RelayClient _relay;

  /// FCM's token for this device, once it has given one.
  String? _fcmToken;

  /// Every registered key, by host id, with the FCM token it was registered
  /// for.
  final _held = <String, ({RelayKey key, String fcmToken})>{};

  /// Keys dropped and not revoked yet, by id.
  final _pending = <String, RelayKey>{};

  late final Future<void> _loaded = _load();

  /// Registrations under way, by host id.
  final _syncing = <String, Future<void>>{};

  /// `LC_SSHBOX_KEY` for [hostId], or null while it has no key.
  Future<String?> valueFor(String hostId) async {
    await _loaded;
    return _held[hostId]?.key.value;
  }

  /// [valueFor], once a key is registered for [hostId] if it had none, or
  /// registered again if FCM has replaced the token since.
  Future<String?> forConnect(String hostId) async {
    await _sync(hostId);
    return valueFor(hostId);
  }

  /// FCM's token at launch, and each one it replaces it with: every key is
  /// registered for it, and every key waiting is revoked.
  Future<void> useFcmToken(String token) async {
    _fcmToken = token;
    await _loaded;
    await Future.wait([
      _retryRevokes(),
      for (final hostId in _held.keys.toList()) _sync(hostId),
    ]);
  }

  /// Registers [hostId]'s key for FCM's current token, making one when it
  /// has none. One at a time per host, and never throws: a failure waits for
  /// the next connect or token.
  Future<void> _sync(String hostId) => _syncing[hostId] ??= _register(hostId)
      .catchError((Object error) {
        // The kind of failure only: never a key or a token.
        debugPrint(
          'sshbox: a notification key did not register, trying again at the '
          'next connect (${error is HttpException ? error.message : error.runtimeType})',
        );
      })
      // A block: the future removed is this one, and returned it would be
      // waited for by itself.
      .whenComplete(() {
        _syncing.remove(hostId);
      });

  Future<void> _register(String hostId) async {
    await _loaded;
    // Round again when FCM replaced the token meanwhile.
    while (true) {
      final token = _fcmToken;
      final held = _held[hostId];
      if (token == null || held?.fcmToken == token) return;
      final key = held?.key ?? RelayKey.generate();
      await _relay.register(token: token, key: key, host: hostId);
      _held[hostId] = (key: key, fcmToken: token);
      await _save();
    }
  }

  /// Drops [hostId]'s key, for a host being deleted, and revokes it. The key
  /// goes to no host from now on, and waits until the relay confirms. Never
  /// throws.
  Future<void> revoke(String hostId) async {
    await _loaded;
    await _syncing[hostId];
    final held = _held.remove(hostId);
    if (held == null) return;
    _pending[held.key.id] = held.key;
    await _save();
    await _retryRevokes();
  }

  /// Drops every host's key and revokes it, with every key still waiting:
  /// each host registers a new one at its next connect. Throws when the
  /// relay does not confirm them all; those left wait.
  Future<void> reset() async {
    await _loaded;
    await Future.wait(_syncing.values.toList());
    for (final held in _held.values) {
      _pending[held.key.id] = held.key;
    }
    _held.clear();
    await _save();
    await _revokePending();
  }

  /// Revokes the keys waiting, one at a time, forgetting each the relay
  /// confirms. Throws at the first it does not, which waits with the rest.
  Future<void> _revokePending() async {
    if (_pending.isEmpty) return;
    try {
      for (final key in _pending.values.toList()) {
        await _relay.revoke(key);
        _pending.remove(key.id);
      }
    } finally {
      await _save();
    }
  }

  /// [_revokePending], a failure logged by its kind only, never a key.
  Future<void> _retryRevokes() => _revokePending().catchError((Object error) {
    debugPrint(
      'sshbox: a notification key is not revoked yet, trying again at the '
      'next launch (${error is HttpException ? error.message : error.runtimeType})',
    );
  });

  Future<void> _save() async {
    // The waiting keys first: stopped between the two writes, a key just
    // dropped is in both, and [_load] keeps it waiting.
    await _secrets.write(
      pendingKey,
      _pending.isEmpty
          ? null
          : jsonEncode({
              for (final key in _pending.values)
                key.id: base64.encode(key.pkcs8),
            }),
    );
    await _secrets.write(
      storageKey,
      _held.isEmpty
          ? null
          : jsonEncode({
              for (final MapEntry(key: hostId, value: held) in _held.entries)
                hostId: {
                  'keyId': held.key.id,
                  'privateKey': base64.encode(held.key.pkcs8),
                  'fcmToken': held.fcmToken,
                },
            }),
    );
  }

  Future<void> _load() async {
    try {
      // The one device-wide bearer key an earlier version kept, which the
      // relay takes no more.
      await _secrets.write('sshbox.notify.key', null);
    } catch (_) {
      // A keyring that fails, as a Linux desktop with no Secret Service
      // does: tried again at the next launch.
    }
    try {
      final waiting =
          jsonDecode(await _secrets.read(pendingKey) ?? '{}') as Map;
      for (final der in waiting.values) {
        final key = RelayKey.fromPkcs8(base64.decode(der as String));
        _pending[key.id] = key;
      }
    } catch (_) {
      // Unreadable, so lost: such a key works until FCM retires this
      // phone's token.
    }
    try {
      final saved = jsonDecode(await _secrets.read(storageKey) ?? '{}') as Map;
      for (final MapEntry(key: hostId, :value) in saved.entries) {
        if (value case {
          'privateKey': final String der,
          'fcmToken': final String fcmToken,
        }) {
          final key = RelayKey.fromPkcs8(base64.decode(der));
          // Dropped, and stopped before this side was saved.
          if (_pending.containsKey(key.id)) continue;
          _held[hostId as String] = (key: key, fcmToken: fcmToken);
        }
      }
    } catch (_) {
      // Unreadable, so none: each host registers a new one.
    }
  }
}

Uint8List _sha256(List<int> bytes) =>
    SHA256Digest().process(Uint8List.fromList(bytes));

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

List<int> _unhex(String hex) => [
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];

/// [value] big-endian, in [length] bytes, or in as few as it takes.
List<int> _bytes(BigInt value, [int length = 1]) {
  final hex = value.toRadixString(16);
  return _unhex(hex.padLeft(max(length * 2, hex.length + hex.length % 2), '0'));
}

BigInt _unsigned(List<int> bytes) => BigInt.parse(_hex(bytes), radix: 16);
