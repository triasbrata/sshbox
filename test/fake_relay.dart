import 'dart:io';

import 'package:sshbox/src/notifications/notify_key.dart';

/// The relay with no network: it keeps every key registered and every key
/// revoked.
class FakeRelay implements RelayClient {
  final registered = <({String token, String keyId, String host})>[];
  final revoked = <String>[];

  /// Out of reach while set, as when the phone is offline.
  bool down = false;

  @override
  Future<void> register({
    required String token,
    required RelayKey key,
    required String host,
  }) async {
    if (down) throw const SocketException('Network is unreachable');
    registered.add((token: token, keyId: key.id, host: host));
  }

  @override
  Future<void> revoke(RelayKey key) async {
    if (down) throw const SocketException('Network is unreachable');
    revoked.add(key.id);
  }
}
