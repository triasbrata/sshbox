import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/host_profile.dart';

/// A host key the user has to rule on: [pinned] is null the first time
/// [host] is met, and otherwise the key it had before this one.
typedef HostKeyCheck = ({HostProfile host, String fingerprint, String? pinned});

/// A pinned key and the host and port it stands for, as Settings lists them.
typedef KnownHost = ({String host, int port, String fingerprint});

/// Pinning of SSH host keys, the mobile equivalent of `~/.ssh/known_hosts`.
///
/// Without this a client silently accepts any key a server offers, which is
/// exactly what a man-in-the-middle needs. As OpenSSH does, a key is pinned
/// only once the user has accepted it, and a different key afterwards is
/// refused unless the user replaces the pin — see [trust].
class KnownHostStore {
  static const _storageKey = 'sshbox.knownhosts.v1';

  /// Every change, from every store: each connect makes a store of its own,
  /// and two read-modify-writes interleaved would drop one of the pins.
  static Future<void> _writes = Future.value();

  String _entryKey(String host, int port) => '$host:$port';

  Future<Map<String, String>> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) return {};

    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((key, value) => MapEntry(key, value as String));
    } on FormatException {
      return {};
    }
  }

  Future<void> _update(void Function(Map<String, String> known) change) {
    final write = _writes.then((_) async {
      final known = await _load();
      change(known);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, jsonEncode(known));
    });
    _writes = write.catchError((Object _) {});
    return write;
  }

  /// Whether [fingerprint] may stand for [host]: it is the key pinned for
  /// the host, or [confirm] accepts it and it is pinned in place of whatever
  /// was there. With nobody to ask, a key that is not pinned is refused.
  ///
  /// [fingerprint] is the OpenSSH-style `SHA256:<base64>` string.
  Future<bool> trust(
    HostProfile host,
    String fingerprint,
    Future<bool> Function(HostKeyCheck check)? confirm,
  ) async {
    final pinned = await pinnedKey(host.host, host.port);
    if (pinned == fingerprint) return true;

    final check = (host: host, fingerprint: fingerprint, pinned: pinned);
    if (!(await confirm?.call(check) ?? false)) return false;

    await _update((known) => known[_entryKey(host.host, host.port)] = fingerprint);
    return true;
  }

  Future<String?> pinnedKey(String host, int port) async {
    final known = await _load();
    return known[_entryKey(host, port)];
  }

  /// Every pinned key, in the order the hosts were first trusted.
  Future<List<KnownHost>> pins() async {
    final known = await _load();
    return [
      for (final MapEntry(:key, :value) in known.entries)
        (
          // The port follows the last colon: an IPv6 host is full of them.
          host: key.substring(0, key.lastIndexOf(':')),
          port: int.parse(key.substring(key.lastIndexOf(':') + 1)),
          fingerprint: value,
        ),
    ];
  }

  /// Drops the pin for [host] on [port], so the next connection there asks
  /// the user as a first one does. Forgetting a key never trusts another.
  Future<void> forget(String host, int port) =>
      _update((known) => known.remove(_entryKey(host, port)));
}
