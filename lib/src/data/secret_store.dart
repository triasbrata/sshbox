import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The keychain access group a Developer ID signed macOS build was given,
/// `<team id>.<bundle id>`, baked in by tools/build_apple.sh when the
/// repository's MACOS_DEVELOPER_ID is on. Empty for every other build, which
/// keeps the login keychain: see docs/macos-developer-id.md.
const macosKeychainGroup = String.fromEnvironment('MACOS_KEYCHAIN_GROUP');

/// What the secret store has to tell the user, at most once a key a run: a
/// secret it could not move, or one that was moved where this build cannot
/// reach. Never a key or a value, only what to do. The app shell toasts it.
final secretNotice = ValueNotifier<SecretNotice?>(null);

/// One thing for [secretNotice] to say. A new object each time, so that the
/// same words for a second key still notify.
class SecretNotice {
  SecretNotice(this.message);

  final String message;

  /// A secret the signed build could not move from the login keychain.
  static const notMoved =
      "A saved secret could not be moved to this build's keychain. The old "
      'copy is kept and used, and moving it is tried again next run.';

  /// A secret a signed build moved, read by a build that cannot reach it.
  static const movedAway =
      "This secret was moved to the signed build's keychain; enter it again, "
      'or install the signed build.';
}

/// Which keys a Developer ID signed build moved into the data protection
/// keychain. Key names only, never a value: a key names a host id, no more.
/// Kept so that a build without the signature, which cannot read that
/// keychain, says why a secret is missing rather than showing an empty field.
abstract class MovedSecrets {
  Future<bool> contains(String key);
  Future<void> add(String key);
  Future<void> remove(String key);
}

/// [MovedSecrets] in the app's preferences.
class PrefsMovedSecrets implements MovedSecrets {
  static const _key = 'sshbox.secrets.movedToDataProtectionKeychain';

  Future<List<String>> _all() async =>
      (await SharedPreferences.getInstance()).getStringList(_key) ?? const [];

  Future<void> _put(List<String> keys) async =>
      (await SharedPreferences.getInstance()).setStringList(_key, keys);

  @override
  Future<bool> contains(String key) async => (await _all()).contains(key);

  @override
  Future<void> add(String key) async {
    final keys = await _all();
    if (!keys.contains(key)) await _put([...keys, key]);
  }

  @override
  Future<void> remove(String key) async {
    final keys = await _all();
    if (keys.contains(key)) await _put([...keys]..remove(key));
  }
}

/// Storage keys for the three per-host secrets. Kept in one place so a host
/// deletion can reliably purge everything belonging to it.
class SecretKeys {
  const SecretKeys._();

  static String password(String hostId) => 'sshbox.password.$hostId';
  static String privateKey(String hostId) => 'sshbox.pem.$hostId';
  static String passphrase(String hostId) => 'sshbox.passphrase.$hostId';

  /// What a `jeansh <file>` is signed with: see `OpenRequests`.
  static String openSecret(String hostId) => 'sshbox.opensecret.$hostId';

  static List<String> allFor(String hostId) => [
    openSecret(hostId),
    password(hostId),
    privateKey(hostId),
    passphrase(hostId),
  ];
}

/// Secrets go here and nowhere else. Deliberately an interface so tests can
/// swap in an in-memory store, and so nothing else in the app is tempted to
/// reach for SharedPreferences to hold a private key.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String? value);
  Future<void> purgeHost(String hostId);
}

/// Backed by Android Keystore and the iOS Keychain.
///
/// On flutter_secure_storage 11 the Android defaults are already
/// AES-GCM data encryption with RSA-OAEP key wrapping, so we do not override
/// the ciphers. To gate reads behind a fingerprint later, swap the Android
/// options for `AndroidOptions.biometric()` — that is the whole change.
///
/// `first_unlock_this_device` on iOS keeps keys off iCloud Keychain and makes
/// them unavailable until the device has been unlocked once after boot.
///
/// macOS uses the login keychain rather than the data protection keychain,
/// which is the plugin's default. The data protection keychain only answers an
/// app signed with a provisioning profile that grants it a keychain access
/// group; the macOS build from tools/build_apple.sh is signed ad hoc, so every
/// read and write there would fail with errSecMissingEntitlement.
///
/// A Developer ID signed macOS build, one with [macosKeychainGroup], is the
/// exception: it has the access group, so it uses the data protection
/// keychain, and moves each secret across from the login keychain the first
/// time it is read. The old item goes only once the new one reads back the
/// same; anything short of that keeps it, uses it, and says so. Each key moved
/// is noted in [MovedSecrets], and a build without the group that finds a
/// noted key missing says where it went.
///
/// On macOS a read is also kept for the rest of the run. The login keychain
/// checks every read that returns a secret against the item's access list,
/// and for this ad-hoc signed app the user's "Always Allow" did not hold:
/// each reconnect read the host's password, key and open secret again, and
/// asked again. Kept, a reconnect reads nothing, so an item asks at most once
/// a run. A kept value goes as soon as its item is written or deleted, and a
/// read that failed, a Deny among them, is never kept. Android and iOS keep
/// no copy: nothing asks there.
class KeystoreSecretStore implements SecretStore {
  /// The store the app uses: one, so that every part of it shares one copy.
  factory KeystoreSecretStore() => _shared;

  /// Over [storage], keeping reads when [keepReads], by default on macOS.
  ///
  /// With [legacy], [storage] is the data protection keychain and [legacy]
  /// the login keychain its secrets are moved from. [moved] notes what was
  /// moved; without [legacy] it is asked only about a missing secret.
  KeystoreSecretStore.over(
    this._storage, {
    bool? keepReads,
    this._legacy,
    this._moved,
  }) : _keepReads = keepReads ?? defaultTargetPlatform == TargetPlatform.macOS;

  static final _shared = forPlatform(
    group: macosKeychainGroup,
    macOS: defaultTargetPlatform == TargetPlatform.macOS,
  );

  /// The app's store: the data protection keychain, moving from the login
  /// keychain, only for a macOS build with a [group]; the login keychain as
  /// before for every other macOS build; the platform's own elsewhere.
  @visibleForTesting
  static KeystoreSecretStore forPlatform({
    required String group,
    required bool macOS,
  }) {
    const login = FlutterSecureStorage(
      aOptions: AndroidOptions(),
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
      mOptions: MacOsOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
        usesDataProtectionKeychain: false,
      ),
    );
    if (!macOS) return KeystoreSecretStore.over(login);
    if (group.isEmpty) {
      return KeystoreSecretStore.over(login, moved: PrefsMovedSecrets());
    }
    return KeystoreSecretStore.over(
      FlutterSecureStorage(
        mOptions: MacOsOptions(
          accessibility: KeychainAccessibility.first_unlock_this_device,
          usesDataProtectionKeychain: true,
          groupId: group,
        ),
      ),
      legacy: login,
      moved: PrefsMovedSecrets(),
    );
  }

  final FlutterSecureStorage _storage;
  final bool _keepReads;

  /// The login keychain a signed build moves secrets out of, or null.
  final FlutterSecureStorage? _legacy;
  final MovedSecrets? _moved;

  /// Keys [secretNotice] has spoken for this run, so that a reconnect loop
  /// says it once.
  final _said = <String>{};

  /// Whether this store moves secrets out of the login keychain.
  @visibleForTesting
  bool get moves => _legacy != null;

  /// Whether this store notes or looks for moved secrets.
  @visibleForTesting
  bool get tracksMoves => _moved != null;

  /// What the keychain answered, null for no item, by key.
  final _kept = <String, String?>{};

  /// Reads under way, so that two at once put up one prompt, not two.
  final _reading = <String, Future<String?>>{};

  /// Calls that reached the keychain this run, by every store: counts only,
  /// never a key or a value, for tests and the desktop e2e.
  @visibleForTesting
  static int keychainReads = 0;
  @visibleForTesting
  static int keychainWrites = 0;

  @override
  Future<String?> read(String key) {
    if (!_keepReads) return _readKeychain(key);
    if (_kept.containsKey(key)) return Future.value(_kept[key]);
    final reading = _reading[key];
    if (reading != null) return reading;
    late final Future<String?> started;
    started = _readKeychain(key)
        .then((value) {
          // Not kept when a write or delete came meanwhile.
          if (identical(_reading[key], started)) _kept[key] = value;
          return value;
        })
        .whenComplete(() {
          if (identical(_reading[key], started)) _reading.remove(key);
        });
    return _reading[key] = started;
  }

  Future<String?> _readKeychain(String key) async {
    keychainReads++;
    final value = await _storage.read(key: key);
    if (value != null) return value;
    final legacy = _legacy;
    if (legacy != null) return _moveFrom(legacy, key);
    final moved = _moved;
    if (moved != null && await moved.contains(key)) {
    }
    return null;
  }

  /// [key] from the login keychain into this one: written, read back, and
  /// only when it reads back the same is the old item deleted. Any step
  /// failing keeps the old item and answers with it, so nothing is lost and
  /// the app goes on working, and says so once.
  Future<String?> _moveFrom(FlutterSecureStorage legacy, String key) async {
    final old = await legacy.read(key: key);
    if (old == null) return null;
    try {
      await _storage.write(key: key, value: old);
      final copy = await _storage.read(key: key);
      if (copy != old) throw StateError('the moved copy read back different');
      await legacy.delete(key: key);
      await _moved?.add(key);
    } catch (_) {
      _say(key, SecretNotice.notMoved);
    }
    return old;
  }

  void _say(String key, String message) {
    if (_said.add(key)) secretNotice.value = SecretNotice(message);
  }

  /// Deletes [key] wherever it may be: here, in the login keychain a signed
  /// build moves from, and from the note of moved keys.
  Future<void> _delete(String key) async {
    await _storage.delete(key: key);
    await _legacy?.delete(key: key);
    await _moved?.remove(key);
  }

  /// Writing null or empty deletes the entry rather than storing a blank,
  /// so "user cleared the password field" cannot leave a stale secret behind.
  /// Where reads are kept, a value the keychain already holds is not written
  /// again: a rewrite is a change to the item for the keychain to check.
  @override
  Future<void> write(String key, String? value) async {
    final wanted = value == null || value.isEmpty ? null : value;
    if (_keepReads) {
      bool same;
      try {
        same = await read(key) == wanted;
      } catch (_) {
        // Unreadable: the write says for itself whether it can be done.
        same = false;
      }
      if (same) return;
      _forget(key);
    }
    keychainWrites++;
    try {
      if (wanted == null) {
        await _delete(key);
      } else {
        await _storage.write(key: key, value: wanted);
        // A signed build's write supersedes the login keychain's copy; an
        // unsigned build's means the secret lives in the login keychain again.
        await _legacy?.delete(key: key);
        if (_legacy == null) await _moved?.remove(key);
      }
    } finally {
      // A delete, or a write that failed, is read afresh next time: what
      // the keychain holds is its to say. A read started meanwhile is
      // dropped too, so it cannot put back what was there before.
      _forget(key);
    }
    // Written, so kept: it cannot be stale, and the open secret made on a
    // first connect is not read back at the next.
    if (_keepReads && wanted != null) _kept[key] = wanted;
  }

  @override
  Future<void> purgeHost(String hostId) async {
    for (final key in SecretKeys.allFor(hostId)) {
      _forget(key);
      keychainWrites++;
      try {
        await _delete(key);
      } finally {
        _forget(key);
      }
    }
  }

  void _forget(String key) {
    _kept.remove(key);
    _reading.remove(key);
  }
}

/// Used by tests and previews; never persists anything.
class InMemorySecretStore implements SecretStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null || value.isEmpty) {
      _values.remove(key);
      return;
    }
    _values[key] = value;
  }

  @override
  Future<void> purgeHost(String hostId) async {
    SecretKeys.allFor(hostId).forEach(_values.remove);
  }
}
