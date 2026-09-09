import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Outcome of comparing a server's host key against what we saw last time.
enum HostKeyVerdict {
  /// First time we have met this host — the key is now pinned.
  trustedOnFirstUse,

  /// Same key as last time.
  matched,

  /// Different key than the one we pinned. Treated as hostile.
  changed,
}

/// Trust-on-first-use pinning of SSH host keys, the mobile equivalent of
/// `~/.ssh/known_hosts`.
///
/// Without this a client silently accepts any key a server offers, which is
/// exactly what a man-in-the-middle needs. Pinning on first connect and
/// refusing a changed key afterwards closes that.
class KnownHostStore {
  static const _storageKey = 'sshbox.knownhosts.v1';

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

  Future<void> _persist(Map<String, String> known) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(known));
  }

  /// Pins on first sight, then compares. [fingerprint] is the OpenSSH-style
  /// `SHA256:<base64>` string.
  Future<HostKeyVerdict> verify({
    required String host,
    required int port,
    required String fingerprint,
  }) async {
    final known = await _load();
    final key = _entryKey(host, port);
    final pinned = known[key];

    if (pinned == null) {
      known[key] = fingerprint;
      await _persist(known);
      return HostKeyVerdict.trustedOnFirstUse;
    }

    return pinned == fingerprint
        ? HostKeyVerdict.matched
        : HostKeyVerdict.changed;
  }

  Future<String?> pinnedKey(String host, int port) async {
    final known = await _load();
    return known[_entryKey(host, port)];
  }

  /// Drops the pin so the next connect re-pins. This is what a user needs
  /// after legitimately rebuilding a server.
  Future<void> forget(String host, int port) async {
    final known = await _load();
    known.remove(_entryKey(host, port));
    await _persist(known);
  }
}
