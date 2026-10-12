import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/data/secret_store.dart';

/// A keychain that counts what reaches it, and can be made to refuse a read
/// as macOS does when the user presses Deny, or to hold one open.
class _Keychain implements FlutterSecureStorage {
  final values = <String, String>{};
  int reads = 0;
  int writes = 0;
  int deletes = 0;
  bool deny = false;
  bool failWrites = false;
  Completer<void>? hold;
  Completer<void>? writeHold;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    reads++;
    final value = values[key];
    await hold?.future;
    if (deny) {
      throw PlatformException(code: 'Unexpected security result code');
    }
    return value;
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    writes++;
    await writeHold?.future;
    if (failWrites) throw PlatformException(code: 'write refused');
    values[key] = value!;
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    deletes++;
    values.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Keychain keychain;
  late KeystoreSecretStore store;
  final password = SecretKeys.password('h1');

  setUp(() {
    keychain = _Keychain()..values[password] = 'hunter2-secret';
    store = KeystoreSecretStore.over(keychain, keepReads: true);
  });

  test('a reconnect reads nothing from the keychain', () async {
    expect(await store.read(password), 'hunter2-secret');
    expect(await store.read(password), 'hunter2-secret');
    expect(await store.read(password), 'hunter2-secret');
    expect(keychain.reads, 1);
  });

  test('two reads at once, as a tmux fallback opens twice, are one', () async {
    keychain.hold = Completer();
    final a = store.read(password);
    final b = store.read(password);
    keychain.hold!.complete();
    expect(await Future.wait([a, b]), ['hunter2-secret', 'hunter2-secret']);
    expect(keychain.reads, 1);
  });

  test('no item is kept too, and asks nothing again', () async {
    final missing = SecretKeys.passphrase('h1');
    expect(await store.read(missing), isNull);
    expect(await store.read(missing), isNull);
    expect(keychain.reads, 1);
  });

  test('a host edited then connected uses the value just written', () async {
    await store.read(password);
    await store.write(password, 'changed');
    expect(keychain.writes, 1);
    expect(await store.read(password), 'changed');
    expect(await store.read(password), 'changed');
    expect(keychain.reads, 1);
  });

  test('a secret a first connect makes and writes is not read back', () async {
    final key = SecretKeys.openSecret('h1');
    // First connect: none yet, so one is made and written.
    expect(await store.read(key), isNull);
    await store.write(key, 'made-on-first-connect');
    expect(keychain.reads, 1);
    expect(keychain.writes, 1);
    // Reconnects: the same secret, from no keychain call at all.
    expect(await store.read(key), 'made-on-first-connect');
    expect(await store.read(key), 'made-on-first-connect');
    expect(keychain.reads, 1);
    expect(keychain.writes, 1);
  });

  test('a write that fails keeps nothing, and is read afresh', () async {
    await store.read(password);
    keychain.failWrites = true;
    await expectLater(
      store.write(password, 'changed'),
      throwsA(isA<PlatformException>()),
    );
    keychain.failWrites = false;
    expect(await store.read(password), 'hunter2-secret');
    expect(keychain.reads, 2);
  });

  test('a read started during a write cannot put the old value back', () async {
    await store.read(password);
    final writeHold = keychain.writeHold = Completer();
    final writing = store.write(password, 'changed');
    await Future<void>.delayed(Duration.zero);
    // The keychain still holds the old value as this read starts, and
    // answers only after the write is done.
    final readHold = keychain.hold = Completer();
    final during = store.read(password);
    keychain.hold = null;
    keychain.writeHold = null;
    writeHold.complete();
    await writing;
    readHold.complete();
    expect(await during, 'hunter2-secret');
    expect(await store.read(password), 'changed');
    expect(keychain.reads, 2);
  });

  test('an unchanged secret is never written', () async {
    await store.write(password, 'hunter2-secret');
    await store.write(password, 'hunter2-secret');
    await store.write(SecretKeys.passphrase('h1'), '');
    await store.write(SecretKeys.passphrase('h1'), null);
    expect(keychain.writes, 0);
    expect(keychain.deletes, 0);
    expect(keychain.reads, 2);
  });

  test('clearing a secret deletes it and reads afresh', () async {
    await store.read(password);
    await store.write(password, '');
    expect(keychain.deletes, 1);
    expect(await store.read(password), isNull);
    expect(keychain.reads, 2);
  });

  test(
    'a denied read is never kept, and the next connect asks again',
    () async {
      keychain.deny = true;
      await expectLater(
        store.read(password),
        throwsA(isA<PlatformException>()),
      );
      keychain.deny = false;
      expect(await store.read(password), 'hunter2-secret');
      expect(keychain.reads, 2);
    },
  );

  test('a write over an unreadable item still goes to the keychain', () async {
    keychain.deny = true;
    await store.write(password, 'new');
    keychain.deny = false;
    expect(keychain.writes, 1);
    expect(await store.read(password), 'new');
  });

  test('a read under way when the item is deleted is not kept', () async {
    keychain.hold = Completer();
    final stale = store.read(password);
    final purging = store.purgeHost('h1');
    keychain.hold!.complete();
    keychain.hold = null;
    expect(await stale, 'hunter2-secret');
    await purging;
    expect(await store.read(password), isNull);
    expect(keychain.reads, 2);
  });

  test('deleting a host drops what was kept for it', () async {
    await store.read(password);
    await store.purgeHost('h1');
    expect(keychain.deletes, SecretKeys.allFor('h1').length);
    expect(await store.read(password), isNull);
    expect(keychain.reads, 2);
  });

  test(
    'without keeping, as on Android, every read goes to the keychain',
    () async {
      final plain = KeystoreSecretStore.over(keychain, keepReads: false);
      await plain.read(password);
      await plain.read(password);
      await plain.write(password, 'hunter2-secret');
      expect(keychain.reads, 2);
      expect(keychain.writes, 1);
    },
  );

  test('keeping is on by default on macOS alone', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final mac = KeystoreSecretStore.over(keychain);
      await mac.read(password);
      await mac.read(password);
      expect(keychain.reads, 1);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    keychain.reads = 0;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final android = KeystoreSecretStore.over(keychain);
      await android.read(password);
      await android.read(password);
      expect(keychain.reads, 2);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('the app shares one store, port forwarding included', () {
    expect(identical(KeystoreSecretStore(), KeystoreSecretStore()), isTrue);
  });

  test('the counters count calls that reach the keychain', () async {
    final reads = KeystoreSecretStore.keychainReads;
    final writes = KeystoreSecretStore.keychainWrites;
    await store.read(password);
    await store.read(password);
    await store.write(password, 'other');
    await store.purgeHost('h2');
    expect(KeystoreSecretStore.keychainReads - reads, 1);
    expect(
      KeystoreSecretStore.keychainWrites - writes,
      1 + SecretKeys.allFor('h2').length,
    );
  });

  test('a kept value never reaches the log', () async {
    final logged = <String>[];
    final before = debugPrint;
    debugPrint = (message, {wrapWidth}) => logged.add(message ?? '');
    try {
      await store.read(password);
      await store.read(password);
      await store.write(password, 'hunter2-secret');
      keychain.deny = true;
      await store.purgeHost('h1');
      await expectLater(
        store.read(password),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.toString(),
            'text',
            isNot(contains('hunter2')),
          ),
        ),
      );
    } finally {
      debugPrint = before;
    }
    expect(logged.where((line) => line.contains('hunter2')), isEmpty);
  });
}
