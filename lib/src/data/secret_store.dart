import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Storage keys for the three per-host secrets. Kept in one place so a host
/// deletion can reliably purge everything belonging to it.
class SecretKeys {
  const SecretKeys._();

  static String password(String hostId) => 'sshbox.password.$hostId';
  static String privateKey(String hostId) => 'sshbox.pem.$hostId';
  static String passphrase(String hostId) => 'sshbox.passphrase.$hostId';

  static List<String> allFor(String hostId) => [
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
class KeystoreSecretStore implements SecretStore {
  KeystoreSecretStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  /// Writing null or empty deletes the entry rather than storing a blank,
  /// so "user cleared the password field" cannot leave a stale secret behind.
  @override
  Future<void> write(String key, String? value) async {
    if (value == null || value.isEmpty) {
      await _storage.delete(key: key);
      return;
    }
    await _storage.write(key: key, value: value);
  }

  @override
  Future<void> purgeHost(String hostId) async {
    for (final key in SecretKeys.allFor(hostId)) {
      await _storage.delete(key: key);
    }
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
