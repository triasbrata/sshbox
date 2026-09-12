import 'host_profile.dart';

/// Ports on this tablet tunnelled to a saved host, as `ssh -L` does, over a
/// connection of their own with no terminal — see `PortForwards`. The Port
/// forwarding page lists them, and switches each on and off.
class ForwardSetting {
  const ForwardSetting({
    required this.id,
    required this.hostId,
    this.name = '',
    this.mappings = const [],
  });

  final String id;

  /// The saved host the ports go to, reached as a terminal session reaches
  /// it: through its jump host, when it has one.
  final String hostId;

  /// Optional; blank shows the host's name — see [displayName].
  final String name;

  final List<LocalForward> mappings;

  /// [name], or else [host]'s: the setting of a deleted host says so.
  String displayName(HostProfile? host) {
    final name = this.name.trim();
    if (name.isNotEmpty) return name;
    return host?.displayName ?? 'Deleted host';
  }

  /// `5432 → localhost:5432 · 6379 → localhost:6379`.
  String get summary => mappings.map((mapping) => mapping.label).join(' · ');

  Map<String, dynamic> toJson() => {
    'id': id,
    'hostId': hostId,
    'name': name,
    'mappings': [for (final mapping in mappings) mapping.toJson()],
  };

  factory ForwardSetting.fromJson(Map<String, dynamic> json) => ForwardSetting(
    id: json['id'] as String,
    hostId: json['hostId'] as String? ?? '',
    name: json['name'] as String? ?? '',
    mappings: _mappings(json['mappings']),
  );

  /// The port forwards hosts kept themselves before this page, from [hosts]
  /// as saved: one setting per host that had any, with the same ports.
  /// [HostProfile] no longer reads them.
  static List<ForwardSetting> migrate(List<Object?> hosts) => [
    for (final host in hosts)
      if (host case {'id': final String id, 'localForwards': final List rules}
          when rules.isNotEmpty)
        ForwardSetting(id: 'host-$id', hostId: id, mappings: _mappings(rules)),
  ];

  static List<LocalForward> _mappings(Object? json) => [
    for (final mapping in json as List? ?? const [])
      if (mapping is Map<String, dynamic>) LocalForward.fromJson(mapping),
  ];
}

/// One `ssh -L`: [localPort] on this tablet's loopback, tunnelled to
/// [destHost]:[destPort] as the host reaches it — 5432 to its own postgres.
class LocalForward {
  const LocalForward({
    required this.localPort,
    this.destHost = 'localhost',
    required this.destPort,
  });

  final int localPort;
  final String destHost;
  final int destPort;

  /// `5432 → localhost:5432`.
  String get label => '$localPort → $destHost:$destPort';

  Map<String, dynamic> toJson() => {
    'localPort': localPort,
    'destHost': destHost,
    'destPort': destPort,
  };

  factory LocalForward.fromJson(Map<String, dynamic> json) => LocalForward(
    localPort: json['localPort'] as int? ?? 0,
    destHost: json['destHost'] as String? ?? 'localhost',
    destPort: json['destPort'] as int? ?? 0,
  );

  /// Why [text] cannot be a forward's port, or null when it can. The
  /// tablet's end, [local], cannot be below 1024: Android keeps those from
  /// apps.
  static String? portError(String? text, {bool local = false}) {
    final port = int.tryParse(text?.trim() ?? '');
    if (port == null || port < 1 || port > 65535) {
      return 'Port must be between 1 and 65535';
    }
    if (local && port < 1024) {
      return 'Android apps cannot open ports below 1024. Use 1024 or above, '
          'like 15432 for 5432.';
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is LocalForward &&
      other.localPort == localPort &&
      other.destHost == destHost &&
      other.destPort == destPort;

  @override
  int get hashCode => Object.hash(localPort, destHost, destPort);
}
