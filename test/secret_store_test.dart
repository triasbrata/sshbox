import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  bool failDelete = false;

  /// Set, what every read answers instead of what is there.
  String? garble;
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
    return value == null ? null : garble ?? value;
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
    if (failDelete) throw PlatformException(code: 'delete refused');
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

  group('a Developer ID signed macOS build', () {
    late _Keychain login;
    late _Keychain protected;
    late _Moved moved;
    late KeystoreSecretStore signed;
    final notices = <String>[];

    void listen() => notices.add(secretNotice.value!.message);

    setUp(() {
      login = _Keychain()..values[password] = 'hunter2-secret';
      protected = _Keychain();
      moved = _Moved();
      signed = KeystoreSecretStore.over(
        protected,
        keepReads: true,
        legacy: login,
        moved: moved,
      );
      notices.clear();
      secretNotice.addListener(listen);
    });

    tearDown(() => secretNotice.removeListener(listen));

    test('moves a secret on its first read, and deletes the old one only '
        'after the new one reads back the same', () async {
      expect(await signed.read(password), 'hunter2-secret');
      expect(protected.values[password], 'hunter2-secret');
      // Written, then read back to compare: the first read found nothing.
      expect(protected.writes, 1);
      expect(protected.reads, 2);
      expect(login.values, isEmpty);
      expect(login.deletes, 1);
      expect(moved.keys, {password});
      expect(notices, isEmpty);
      // Kept for the run, as before: a reconnect reads nothing.
      expect(await signed.read(password), 'hunter2-secret');
      expect(protected.reads, 2);
    });

    test('a secret already moved never touches the login keychain', () async {
      login.values.clear();
      protected.values[password] = 'hunter2-secret';
      expect(await signed.read(password), 'hunter2-secret');
      expect(login.reads, 0);
      expect(login.deletes, 0);
      expect(protected.writes, 0);
    });

    test('no secret anywhere is no secret, and says nothing', () async {
      login.values.clear();
      expect(await signed.read(password), isNull);
      expect(login.reads, 1);
      expect(protected.writes, 0);
      expect(moved.keys, isEmpty);
      expect(notices, isEmpty);
    });

    test('a refused write keeps the old item, uses it, and says so', () async {
      protected.failWrites = true;
      expect(await signed.read(password), 'hunter2-secret');
      expect(login.values[password], 'hunter2-secret');
      expect(login.deletes, 0);
      expect(moved.keys, isEmpty);
      expect(notices, [SecretNotice.notMoved]);
    });

    test('a copy that reads back different keeps the old item', () async {
      protected.garble = 'something else';
      expect(await signed.read(password), 'hunter2-secret');
      expect(login.values[password], 'hunter2-secret');
      expect(login.deletes, 0);
      expect(moved.keys, isEmpty);
      expect(notices, [SecretNotice.notMoved]);
    });

    test(
      'a refused delete of the old item is said, and nothing is lost',
      () async {
        login.failDelete = true;
        expect(await signed.read(password), 'hunter2-secret');
        expect(login.values[password], 'hunter2-secret');
        expect(protected.values[password], 'hunter2-secret');
        expect(moved.keys, isEmpty);
        expect(notices, [SecretNotice.notMoved]);
      },
    );

    test(
      'a failure is said once a key a run, however often it is read',
      () async {
        protected.failWrites = true;
        final passphrase = SecretKeys.passphrase('h1');
        login.values[passphrase] = 'words';
        final uncached = KeystoreSecretStore.over(
          protected,
          keepReads: false,
          legacy: login,
          moved: moved,
        );
        for (var i = 0; i < 3; i++) {
          expect(await uncached.read(password), 'hunter2-secret');
          expect(await uncached.read(passphrase), 'words');
        }
        expect(notices, [SecretNotice.notMoved, SecretNotice.notMoved]);
      },
    );

    test('a write lands in the new keychain and drops the old copy', () async {
      await signed.write(password, 'changed');
      expect(protected.values[password], 'changed');
      expect(login.values, isEmpty);
    });

    test('a written secret is kept: the old copy deleted does not drop it, '
        'and nothing reads it back', () async {
      await signed.write(password, 'changed');
      // The write's own read moved the old copy first, so it is gone twice.
      expect(login.values, isEmpty);
      expect(login.deletes, 2);
      final reads = protected.reads + login.reads;
      expect(await signed.read(password), 'changed');
      expect(await signed.read(password), 'changed');
      expect(protected.reads + login.reads, reads);
    });

    test('a moved secret then written is kept as written', () async {
      expect(await signed.read(password), 'hunter2-secret');
      await signed.write(password, 'changed');
      final reads = protected.reads + login.reads;
      expect(await signed.read(password), 'changed');
      expect(protected.reads + login.reads, reads);
      expect(protected.values[password], 'changed');
      expect(login.values, isEmpty);
    });

    test('a refused delete of the old copy keeps nothing stale', () async {
      login.failDelete = true;
      await expectLater(
        signed.write(password, 'changed'),
        throwsA(isA<PlatformException>()),
      );
      login.failDelete = false;
      // Not kept: the next read asks the keychain, which has the new value.
      expect(await signed.read(password), 'changed');
      expect(protected.values[password], 'changed');
    });

    test(
      'clearing or deleting a host removes every copy and the note',
      () async {
        await signed.read(password);
        expect(moved.keys, {password});
        await signed.write(password, null);
        expect(protected.values, isEmpty);
        expect(moved.keys, isEmpty);

        login.values[password] = 'again';
        protected.values[SecretKeys.privateKey('h1')] = 'pem';
        moved.keys.add(SecretKeys.privateKey('h1'));
        await signed.purgeHost('h1');
        expect(login.values, isEmpty);
        expect(protected.values, isEmpty);
        expect(moved.keys, isEmpty);
      },
    );
  });

  group('a build without the signature, after a signed one', () {
    late _Keychain login;
    late _Moved moved;
    late KeystoreSecretStore unsigned;
    final notices = <String>[];

    void listen() => notices.add(secretNotice.value!.message);

    setUp(() {
      login = _Keychain();
      moved = _Moved()..keys.add(password);
      unsigned = KeystoreSecretStore.over(
        login,
        keepReads: false,
        moved: moved,
      );
      notices.clear();
      secretNotice.addListener(listen);
    });

    tearDown(() => secretNotice.removeListener(listen));

    test('says where a moved secret went, once a run', () async {
      expect(await unsigned.read(password), isNull);
      expect(await unsigned.read(password), isNull);
      expect(notices, [SecretNotice.movedAway]);
    });

    test('forgetting what was kept makes the next read ask again, and the '
        'notice be said again', () async {
      final kept = KeystoreSecretStore.over(
        login,
        keepReads: true,
        moved: moved,
      );
      expect(await kept.read(password), isNull);
      expect(await kept.read(password), isNull);
      expect(login.reads, 1, reason: 'the null answer is kept');
      expect(notices, [SecretNotice.movedAway]);

      kept.forgetKept();
      expect(await kept.read(password), isNull);
      expect(login.reads, 2, reason: 'a cold read reaches the keychain');
      expect(notices, [SecretNotice.movedAway, SecretNotice.movedAway]);
    });

    test('a missing secret never moved says nothing', () async {
      expect(await unsigned.read(SecretKeys.passphrase('h1')), isNull);
      expect(notices, isEmpty);
    });

    test('a secret entered again is no longer noted as moved', () async {
      await unsigned.write(password, 'entered again');
      expect(moved.keys, isEmpty);
      expect(await unsigned.read(password), 'entered again');
      expect(notices, isEmpty);
    });
  });

  group('which store the app gets', () {
    test('a macOS build with no group keeps the login keychain', () {
      final store = KeystoreSecretStore.forPlatform(group: '', macOS: true);
      expect(store.moves, isFalse);
      expect(store.tracksMoves, isTrue);
    });

    test(
      'a macOS build with a group moves to the data protection keychain',
      () {
        final store = KeystoreSecretStore.forPlatform(
          group: 'TEAMID.example.app',
          macOS: true,
        );
        expect(store.moves, isTrue);
        expect(store.tracksMoves, isTrue);
      },
    );

    test('elsewhere neither moves nor notes', () {
      final store = KeystoreSecretStore.forPlatform(
        group: 'TEAMID.example.app',
        macOS: false,
      );
      expect(store.moves, isFalse);
      expect(store.tracksMoves, isFalse);
    });

    test('the build carries no group unless the build script gave one', () {
      expect(macosKeychainGroup, isEmpty);
    });
  });

  group('the note of moved keys, in preferences', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('adds, finds and removes a key, once each', () async {
      final note = PrefsMovedSecrets();
      expect(await note.contains(password), isFalse);
      await note.add(password);
      await note.add(password);
      expect(await note.contains(password), isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getStringList('sshbox.secrets.movedToDataProtectionKeychain'),
        [password],
      );
      await note.remove(password);
      await note.remove(password);
      expect(await note.contains(password), isFalse);
    });
  });
}

class _Moved implements MovedSecrets {
  final keys = <String>{};

  @override
  Future<bool> contains(String key) async => keys.contains(key);

  @override
  Future<void> add(String key) async => keys.add(key);

  @override
  Future<void> remove(String key) async => keys.remove(key);
}
