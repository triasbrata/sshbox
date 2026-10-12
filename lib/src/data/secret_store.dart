import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
  KeystoreSecretStore.over(this._storage, {bool? keepReads})
    : _keepReads = keepReads ?? defaultTargetPlatform == TargetPlatform.macOS;

  static final _shared = KeystoreSecretStore.over(
    const FlutterSecureStorage(
      aOptions: AndroidOptions(),
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
      mOptions: MacOsOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
        usesDataProtectionKeychain: false,
      ),
    ),
  );

  final FlutterSecureStorage _storage;
  final bool _keepReads;

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

  Future<String?> _readKeychain(String key) {
    keychainReads++;
    return _storage.read(key: key);
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
        await _storage.delete(key: key);
      } else {
        await _storage.write(key: key, value: wanted);
      }
    } finally {
      // Read afresh next time: what the keychain holds is its to say.
      _forget(key);
    }
  }

  @override
  Future<void> purgeHost(String hostId) async {
    for (final key in SecretKeys.allFor(hostId)) {
      _forget(key);
      keychainWrites++;
      try {
        await _storage.delete(key: key);
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
