import 'host_profile.dart';
import 'port_snippets.dart';

/// Ports tunnelled between this tablet and a saved host, over a connection of
/// their own with no terminal — see `PortForwards`: ports on the tablet that
/// lead to the host, as `ssh -L` opens them, and ports on the host that lead
/// to the tablet, as `ssh -R` does. The Port forwarding page lists them, and
/// switches each on and off.
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

  final List<PortMapping> mappings;

  /// [name], or else [host]'s: the setting of a deleted host says so.
  String displayName(HostProfile? host) {
    final name = this.name.trim();
    if (name.isNotEmpty) return name;
    return host?.displayName ?? 'Deleted host';
  }

  /// A line per port: `PostgreSQL · Tablet 5432 → Remote 5432`.
  String get summary => mappings.map((mapping) => mapping.label).join('\n');

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

  static List<PortMapping> _mappings(Object? json) => [
    for (final mapping in json as List? ?? const [])
      if (mapping is Map<String, dynamic>) PortMapping.fromJson(mapping),
  ];
}

/// One port of a [ForwardSetting], either way: [LocalForward] or
/// [RemoteForward].
sealed class PortMapping {
  const PortMapping();

  /// Saved without a direction, it is a [LocalForward]: every one saved
  /// before [RemoteForward] was.
  factory PortMapping.fromJson(Map<String, dynamic> json) =>
      json['direction'] == RemoteForward.direction
          ? RemoteForward.fromJson(json)
          : LocalForward.fromJson(json);

  /// Where it listens, and so where connections start: `Tablet 5432` or
  /// `Remote 3000`. No two in a setting can share one.
  String get side;

  /// The port the service itself is on, at the far end.
  int get targetPort;

  /// [targetPort]'s service, when it is a snippet's: PostgreSQL.
  String? get service => serviceOn(targetPort);

  /// `Tablet 5432 → Remote 5432`, with a host only where it is not the
  /// default.
  String get route;

  /// [route], after its [service]: `PostgreSQL · Tablet 5432 → Remote 5432`.
  String get label => service == null ? route : '$service · $route';

  /// What it does, in words, through the host called [host].
  String sentence(String host);

  /// ` (PostgreSQL)`, for [sentence], or nothing.
  String get _named => service == null ? '' : ' ($service)';

  Map<String, dynamic> toJson();

  /// Why [text] cannot be a port, or null when it can. One that opens on
  /// the [tablet] cannot be below 1024: Android keeps those from apps.
  static String? portError(String? text, {bool tablet = false}) {
    final port = int.tryParse(text?.trim() ?? '');
    if (port == null || port < 1 || port > 65535) {
      return 'Port must be between 1 and 65535';
    }
    if (tablet && port < 1024) {
      return 'Android apps cannot open ports below 1024. Use 1024 or above, '
          'like 15432 for 5432.';
    }
    return null;
  }
}

/// One `ssh -L`: [localPort] on this tablet's loopback, tunnelled to
/// [destHost]:[destPort] as the host reaches it — 5432 to its own postgres.
class LocalForward extends PortMapping {
  const LocalForward({
    required this.localPort,
    this.destHost = 'localhost',
    required this.destPort,
  });

  final int localPort;

  /// As the host reaches it: localhost is the host itself.
  final String destHost;
  final int destPort;

  @override
  String get side => 'Tablet $localPort';

  @override
  int get targetPort => destPort;

  @override
  String get route =>
      'Tablet $localPort → Remote '
      '${destHost == 'localhost' ? '' : '$destHost:'}$destPort';

  @override
  String sentence(String host) =>
      'Apps on this tablet open 127.0.0.1:$localPort$_named to reach '
      '${destHost == 'localhost' ? 'port $destPort on' : '$destHost:$destPort through'} '
      '$host.';

  @override
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

  @override
  bool operator ==(Object other) =>
      other is LocalForward &&
      other.localPort == localPort &&
      other.destHost == destHost &&
      other.destPort == destPort;

  @override
  int get hashCode => Object.hash(localPort, destHost, destPort);
}

/// One `ssh -R`: the host listens on [remoteHost]:[remotePort] — its own
/// loopback unless the user says otherwise — and each connection made there
/// comes back over the setting's connection to [tabletHost]:[tabletPort],
/// reached from this tablet. A dev server on the tablet, reached with
/// `curl localhost:3000` on the host.
class RemoteForward extends PortMapping {
  const RemoteForward({
    this.remoteHost = 'localhost',
    required this.remotePort,
    this.tabletHost = '127.0.0.1',
    required this.tabletPort,
  });

  /// What [PortMapping.fromJson] tells one apart by.
  static const direction = 'remoteToTablet';

  /// The address the host listens on.
  final String remoteHost;
  final int remotePort;
  final String tabletHost;
  final int tabletPort;

  /// Whether listening on [host] keeps a port to the machine itself. Any
  /// other address opens it to the host's network, which sshd allows only
  /// with `GatewayPorts`.
  static bool loopback(String host) =>
      const {'localhost', '127.0.0.1', '::1'}.contains(host);

  @override
  String get side => 'Remote $remotePort';

  @override
  int get targetPort => tabletPort;

  @override
  String get route =>
      'Remote ${remoteHost == 'localhost' ? '' : '$remoteHost:'}$remotePort '
      '→ Tablet ${tabletHost == '127.0.0.1' ? '' : '$tabletHost:'}$tabletPort';

  @override
  String sentence(String host) {
    final to = tabletHost == '127.0.0.1'
        ? 'port $tabletPort on this tablet'
        : '$tabletHost:$tabletPort through this tablet';
    return loopback(remoteHost)
        ? 'Programs on $host open $remoteHost:$remotePort$_named to reach $to.'
        : 'Programs on $host, and machines that reach it, open port '
              '$remotePort$_named on it to reach $to.';
  }

  @override
  Map<String, dynamic> toJson() => {
    'direction': direction,
    'remoteHost': remoteHost,
    'remotePort': remotePort,
    'tabletHost': tabletHost,
    'tabletPort': tabletPort,
  };

  factory RemoteForward.fromJson(Map<String, dynamic> json) => RemoteForward(
    remoteHost: json['remoteHost'] as String? ?? 'localhost',
    remotePort: json['remotePort'] as int? ?? 0,
    tabletHost: json['tabletHost'] as String? ?? '127.0.0.1',
    tabletPort: json['tabletPort'] as int? ?? 0,
  );

  @override
  bool operator ==(Object other) =>
      other is RemoteForward &&
      other.remoteHost == remoteHost &&
      other.remotePort == remotePort &&
      other.tabletHost == tabletHost &&
      other.tabletPort == tabletPort;

  @override
  int get hashCode => Object.hash(remoteHost, remotePort, tabletHost, tabletPort);
}
