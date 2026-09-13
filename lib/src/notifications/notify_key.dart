import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/secret_store.dart';

/// The relay servers send a push through: jeansh-notify, a Cloudflare Worker
/// (github.com/triasbrata/jeansh-notify) that alone holds the Firebase
/// credentials. The one place its address is written.
const notifyRelay = 'https://jeansh-notify.brata.cloud';

/// The relay's two calls the app makes. Its `POST /v1/send` is the servers'.
class RelayClient {
  const RelayClient();

  /// Trades this device's FCM token for a key that sends to it.
  Future<String> register(String fcmToken) async {
    final reply = await _call('POST', '/v1/register', json: {'token': fcmToken});
    final key = (jsonDecode(reply) as Map)['key'];
    if (key is! String || key.isEmpty) {
      throw const HttpException('The relay answered with no key');
    }
    return key;
  }

  /// Stops [key] from sending. One already gone is no error.
  Future<void> revoke(String key) => _call('DELETE', '/v1/key', key: key);

  static Future<String> _call(
    String method,
    String path, {
    Object? json,
    String? key,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.openUrl(
        method,
        Uri.parse('$notifyRelay$path'),
      );
      if (key != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
      }
      if (json != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(json));
      }
      const wait = Duration(seconds: 15);
      final response = await request.close().timeout(wait);
      final body = await utf8.decodeStream(response).timeout(wait);
      if (response.statusCode >= 300) {
        throw HttpException('The relay answered ${response.statusCode}');
      }
      return body;
    } finally {
      client.close(force: true);
    }
  }
}

/// This device's relay key: what a server sends a push with, through the
/// relay, as `LC_SSHBOX_TOKEN`. It stands in for the FCM token, which goes to
/// the relay and to no server.
///
/// Registered when FCM gives a token and no key is held for it — the first
/// launch, or FCM replacing its token — and the key it replaces is revoked.
/// A relay out of reach is tried again at the next launch or connect, never
/// in a loop of its own.
class NotifyKey {
  NotifyKey(this._secrets, {this._relay = const RelayClient()});

  /// Where the key is kept, with the FCM token it was registered for.
  static const storageKey = 'sshbox.notify.key';

  final SecretStore _secrets;
  final RelayClient _relay;

  /// FCM's token for this device, once it has given one.
  String? _fcmToken;

  /// The key held, and the FCM token it was registered for.
  ({String key, String fcmToken})? _held;

  late final Future<void> _loaded = _load();
  Future<bool>? _syncing;

  /// The key for this device's current FCM token, or null while there is
  /// none: never one registered for a token FCM has since replaced.
  String? get key {
    final held = _held;
    return held != null && held.fcmToken == _fcmToken ? held.key : null;
  }

  /// [key], for a connection to hand its host. With none, registering is
  /// tried again for the next connection: this one goes without.
  String? forConnect() {
    final key = this.key;
    if (key == null) unawaited(sync());
    return key;
  }

  /// FCM's token at launch, and each one it replaces it with.
  Future<bool> useFcmToken(String token) {
    _fcmToken = token;
    return sync();
  }

  /// Registers a key for the current FCM token, unless one is held for it,
  /// and says whether there is one now. One at a time: a call while one runs
  /// waits for that one, which picks up a token that changed meanwhile.
  Future<bool> sync() => _syncing ??= _register()
      .then(
        (_) => key != null,
        onError: (Object error) {
          // The kind of failure only: a relay's reply could quote the key.
          debugPrint(
            'sshbox: no notification key yet, trying again at the next '
            'connect (${error is HttpException ? error.message : error.runtimeType})',
          );
          return false;
        },
      )
      .whenComplete(() => _syncing = null);

  Future<void> _register() async {
    await _loaded;
    while (true) {
      final token = _fcmToken;
      final old = _held;
      if (token == null || old?.fcmToken == token) return;
      final key = await _relay.register(token);
      await _hold((key: key, fcmToken: token));
      if (old == null) continue;
      try {
        await _relay.revoke(old.key);
      } catch (_) {
        // Best effort: it sends to a token FCM has replaced, so to nothing.
      }
    }
  }

  /// Revokes the key servers hold now, then registers a new one. Throws,
  /// keeping the old key, when the relay cannot be reached to revoke it; a
  /// new key the relay would not give is tried again at the next connect.
  Future<void> reset() async {
    await _syncing;
    await _loaded;
    final old = _held;
    if (old != null) {
      await _relay.revoke(old.key);
      await _hold(null);
    }
    await sync();
  }

  Future<void> _hold(({String key, String fcmToken})? value) async {
    _held = value;
    await _secrets.write(
      storageKey,
      value == null
          ? null
          : jsonEncode({'key': value.key, 'fcmToken': value.fcmToken}),
    );
  }

  Future<void> _load() async {
    try {
      final saved = jsonDecode(await _secrets.read(storageKey) ?? 'null');
      if (saved case {
        'key': final String key,
        'fcmToken': final String fcmToken,
      }) {
        _held = (key: key, fcmToken: fcmToken);
      }
    } catch (_) {
      // Unreadable, so none: a new one is registered.
    }
  }
}
