import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/host_profile.dart';
import 'secret_store.dart';

/// Persists the non-secret half of a host profile. The matching secrets live
/// in [SecretStore]; deleting a host clears both.
class HostRepository {
  HostRepository(this._secrets);

  static const _storageKey = 'sshbox.hosts.v1';

  final SecretStore _secrets;

  Future<List<HostProfile>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) return [];

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(HostProfile.fromJson)
          .toList();
    } on FormatException {
      // A corrupt blob should cost the user their host list, not the app.
      return [];
    }
  }

  Future<void> _persist(List<HostProfile> hosts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _storageKey,
      jsonEncode(hosts.map((host) => host.toJson()).toList()),
    );
  }

  /// Inserts, or replaces in place so the list order stays stable while editing.
  Future<List<HostProfile>> upsert(HostProfile host) async {
    final hosts = await load();
    final index = hosts.indexWhere((existing) => existing.id == host.id);
    if (index >= 0) {
      hosts[index] = host;
    } else {
      hosts.add(host);
    }
    await _persist(hosts);
    return hosts;
  }

  Future<List<HostProfile>> delete(String hostId) async {
    final hosts = await load();
    hosts.removeWhere((host) => host.id == hostId);
    await _persist(hosts);
    await _secrets.purgeHost(hostId);
    return hosts;
  }
}
