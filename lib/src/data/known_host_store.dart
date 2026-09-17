import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/host_profile.dart';

/// A host key the user has to rule on.
///
/// [address] is the address that actually answered — the alternative one when
/// that is what came up — and is what the key is pinned under, so the prompt
/// can name the machine it is really talking about. [pinned] is null the
/// first time that address is met, and otherwise the key it had before this
/// one. [otherAddress] is set only when [pinned] is null and another address
/// of the same host is pinned to a *different* key, which is the one case a
/// first connection deserves a warning rather than a plain question.
typedef HostKeyCheck = ({
  HostProfile host,
  String address,
  String fingerprint,
  String? pinned,
  ({String address, String fingerprint})? otherAddress,
});

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

  /// Whether [fingerprint] may stand for [host] at [address], the address
  /// that answered: it is the key pinned for that address, or [confirm]
  /// accepts it and it is pinned in place of whatever was there. With nobody
  /// to ask, a key that is not pinned is refused.
  ///
  /// A key is pinned per address, as OpenSSH's `known_hosts` is, and never
  /// per profile: a prompt has to name the machine that answered, and pinning
  /// the alternative address's key under the saved one would ask the user to
  /// trust a key under the name of a machine that was never reached.
  ///
  /// The cost of that — a second prompt the first time the alternative
  /// address answers — is paid only when the two addresses show *different*
  /// keys. The same key already trusted at the host's other address is
  /// pinned here silently: only the machine holding that key can sign the
  /// exchange, so it is the one already trusted, under another name.
  ///
  /// [fingerprint] is the OpenSSH-style `SHA256:<base64>` string.
  Future<bool> trust(
    HostProfile host,
    String address,
    String fingerprint,
    Future<bool> Function(HostKeyCheck check)? confirm,
  ) async {
    final pinned = await pinnedKey(address, host.port);
    if (pinned == fingerprint) return true;

    final other = await _otherAddress(host, address);
    if (pinned == null && other?.fingerprint == fingerprint) {
      await _pin(address, host.port, fingerprint);
      return true;
    }

    final check = (
      host: host,
      address: address,
      fingerprint: fingerprint,
      pinned: pinned,
      // With a key pinned for this very address and a new one showing, the
      // changed-key warning says it all; the other address is noise there.
      otherAddress: pinned == null ? other : null,
    );
    if (!(await confirm?.call(check) ?? false)) return false;

    await _pin(address, host.port, fingerprint);
    return true;
  }

  /// The first of [host]'s other addresses that has a key pinned, if any:
  /// the same machine under another name, or somebody sitting on the address
  /// this connection reached — which is what makes it worth showing.
  Future<({String address, String fingerprint})?> _otherAddress(
    HostProfile host,
    String dialled,
  ) async {
    final known = await _load();
    for (final address in host.addresses) {
      if (address == dialled) continue;
      final pin = known[_entryKey(address, host.port)];
      if (pin != null) return (address: address, fingerprint: pin);
    }
    return null;
  }

  Future<void> _pin(String address, int port, String fingerprint) =>
      _update((known) => known[_entryKey(address, port)] = fingerprint);

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
