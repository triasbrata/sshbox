import 'dart:io';

import 'package:sshbox/src/notifications/notify_key.dart';

/// The relay with no network: the keys it gives are `jnk_1`, `jnk_2`… and it
/// keeps every token registered and every key revoked.
class FakeRelay implements RelayClient {
  final registered = <String>[];
  final revoked = <String>[];

  /// Out of reach while set, as when the phone is offline.
  bool down = false;

  @override
  Future<String> register(String fcmToken) async {
    if (down) throw const SocketException('Network is unreachable');
    registered.add(fcmToken);
    return 'jnk_${registered.length}';
  }

  @override
  Future<void> revoke(String key) async {
    if (down) throw const SocketException('Network is unreachable');
    revoked.add(key);
  }
}
