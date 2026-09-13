import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/notifications/notify_key.dart';

import 'fake_relay.dart';

void main() {
  late FakeRelay relay;
  late InMemorySecretStore secrets;
  late NotifyKey notifyKey;

  /// What the keystore holds.
  Future<Object?> stored() async =>
      jsonDecode(await secrets.read(NotifyKey.storageKey) ?? 'null');

  setUp(() {
    relay = FakeRelay();
    secrets = InMemorySecretStore();
    notifyKey = NotifyKey(secrets, relay: relay);
  });

  test('the first token registers a key, kept with that token', () async {
    expect(notifyKey.key, isNull);

    expect(await notifyKey.useFcmToken('fcm-1'), isTrue);
    expect(relay.registered, ['fcm-1']);
    expect(notifyKey.key, 'jnk_1');
    expect(await stored(), {'key': 'jnk_1', 'fcmToken': 'fcm-1'});
  });

  test('the next launch keeps its key rather than register again', () async {
    await notifyKey.useFcmToken('fcm-1');

    final relaunched = NotifyKey(secrets, relay: relay);
    await relaunched.useFcmToken('fcm-1');
    expect(relay.registered, ['fcm-1']);
    expect(relaunched.key, 'jnk_1');
  });

  test('a refreshed token registers a new key and revokes the old', () async {
    await notifyKey.useFcmToken('fcm-1');

    await notifyKey.useFcmToken('fcm-2');
    expect(relay.registered, ['fcm-1', 'fcm-2']);
    expect(relay.revoked, ['jnk_1']);
    expect(notifyKey.key, 'jnk_2');
    expect(await stored(), {'key': 'jnk_2', 'fcmToken': 'fcm-2'});
  });

  test('so does a token refreshed while the app was closed', () async {
    await notifyKey.useFcmToken('fcm-1');

    final relaunched = NotifyKey(secrets, relay: relay);
    await relaunched.useFcmToken('fcm-2');
    expect(relay.registered, ['fcm-1', 'fcm-2']);
    expect(relay.revoked, ['jnk_1']);
    expect(relaunched.key, 'jnk_2');
  });

  test('a key registered for a replaced token is never handed out', () async {
    await notifyKey.useFcmToken('fcm-1');
    relay.down = true;

    await notifyKey.useFcmToken('fcm-2');
    expect(notifyKey.key, isNull);
  });

  test('with the relay out of reach there is no key, and a connect tries '
      'again', () async {
    relay.down = true;
    expect(await notifyKey.useFcmToken('fcm-1'), isFalse);
    expect(notifyKey.key, isNull);

    relay.down = false;
    // This connect goes without, and has the next one's key registered.
    expect(notifyKey.forConnect(), isNull);
    await pumpEventQueue();
    expect(notifyKey.forConnect(), 'jnk_1');
    expect(relay.registered, ['fcm-1']);
  });

  test('without an FCM token nothing is registered', () async {
    expect(notifyKey.forConnect(), isNull);
    await pumpEventQueue();
    expect(relay.registered, isEmpty);
  });

  test('reset revokes the key, then registers a new one', () async {
    await notifyKey.useFcmToken('fcm-1');

    await notifyKey.reset();
    expect(relay.revoked, ['jnk_1']);
    expect(relay.registered, ['fcm-1', 'fcm-1']);
    expect(notifyKey.key, 'jnk_2');
    expect(await stored(), {'key': 'jnk_2', 'fcmToken': 'fcm-1'});
  });

  test('a reset the relay cannot take keeps the old key', () async {
    await notifyKey.useFcmToken('fcm-1');
    relay.down = true;

    await expectLater(notifyKey.reset(), throwsA(isA<SocketException>()));
    expect(relay.revoked, isEmpty);
    expect(notifyKey.key, 'jnk_1');
    expect(await stored(), {'key': 'jnk_1', 'fcmToken': 'fcm-1'});
  });
}
