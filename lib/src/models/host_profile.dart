import 'os_info.dart';

/// How we authenticate to a host. The secret itself never lives here — only
/// the choice of method. See [SecretStore] for where the secret goes.
enum SshAuthMethod {
  password,
  privateKey,

  /// Tailscale SSH. The app sends no credential at all — tailscaled decides,
  /// and when its policy calls for a check it hands back a URL to open. Once
  /// that check passes, later sessions go straight through until it expires.
  tailscale,
}

/// A saved SSH destination. This object is safe to persist in plain storage:
/// it deliberately holds no password, private key or passphrase.
class HostProfile {
  const HostProfile({
    required this.id,
    required this.label,
    required this.host,
    required this.username,
    this.port = 22,
    this.altHost = '',
    this.authMethod = SshAuthMethod.password,
    this.fileRoot = '',
    this.forwardPorts = false,
    this.useTmux = false,
    this.jumpHostId = '',
    this.os,
  });

  final String id;
  final String label;
  final String host;
  final String username;
  final int port;

  /// A second address for the same machine, tried alongside [host] and used
  /// if it answers first: the LAN address of a host normally reached over a
  /// tailnet, so a tailnet that is down costs no edit. Blank means there is
  /// only [host]. It shares [port], [username] and the credentials, being the
  /// same sshd — see [addresses].
  final String altHost;

  final SshAuthMethod authMethod;

  /// Where the file tree opens on this host. Blank means the login home, and
  /// a path that is not absolute is taken from there — see `RemotePath.resolve`.
  final String fileRoot;

  /// Whether a server started in a session goes on the tailnet by itself —
  /// see `TailnetForwarder`. Off by default: it opens a port to every device
  /// the tailnet lets in.
  final bool forwardPorts;

  /// Whether a tab on this host runs in tmux, with tmux's panes drawn as the
  /// app's own — see `TmuxSession`. Off by default: it needs tmux on the
  /// host, and changes what a tab is.
  final bool useTmux;

  /// The saved host this one is reached through, as OpenSSH's ProxyJump does:
  /// the app signs in there with that host's own login, and tunnels on from
  /// it. Blank connects directly. A jump host may have one of its own.
  final String jumpHostId;

  /// What the host said it runs at its last connect, for the host list's
  /// badge. Null until it first connects — see `LiveSession`.
  final OsInfo? os;

  /// Where this host may be dialled, the saved address first. One address
  /// unless [altHost] holds another — see `firstToAnswer`, which races them.
  List<String> get addresses => [
        host,
        if (altHost.trim().isNotEmpty && altHost.trim() != host) altHost.trim(),
      ];

  /// What we show under the label, e.g. `root@10.0.2.2` or `me@box:2222`.
  String get target =>
      '$username@$host${port == 22 ? '' : ':$port'}';

  /// Falls back to the target so a profile always has something to show.
  String get displayName => label.trim().isEmpty ? target : label.trim();

  /// A copy with the fields given changed. A new [id] makes it a separate
  /// saved host — what Home's Duplicate does — and every other field comes
  /// along, so a field added here travels with a duplicate by itself.
  HostProfile copyWith({
    String? id,
    String? label,
    String? host,
    String? username,
    int? port,
    String? altHost,
    SshAuthMethod? authMethod,
    String? fileRoot,
    bool? forwardPorts,
    bool? useTmux,
    String? jumpHostId,
    OsInfo? os,
  }) {
    return HostProfile(
      id: id ?? this.id,
      label: label ?? this.label,
      host: host ?? this.host,
      username: username ?? this.username,
      port: port ?? this.port,
      altHost: altHost ?? this.altHost,
      authMethod: authMethod ?? this.authMethod,
      fileRoot: fileRoot ?? this.fileRoot,
      forwardPorts: forwardPorts ?? this.forwardPorts,
      useTmux: useTmux ?? this.useTmux,
      jumpHostId: jumpHostId ?? this.jumpHostId,
      os: os ?? this.os,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'host': host,
        'username': username,
        'port': port,
        'altHost': altHost,
        'authMethod': authMethod.name,
        'fileRoot': fileRoot,
        'forwardPorts': forwardPorts,
        'useTmux': useTmux,
        'jumpHostId': jumpHostId,
        'os': ?os?.toJson(),
      };

  /// A host saved with `localForwards`, from before the Port forwarding page,
  /// loads as it was: those are read once, by `ForwardSetting.migrate`, and
  /// go at the host's next save.
  factory HostProfile.fromJson(Map<String, dynamic> json) {
    return HostProfile(
      id: json['id'] as String,
      label: json['label'] as String? ?? '',
      host: json['host'] as String? ?? '',
      username: json['username'] as String? ?? '',
      port: json['port'] as int? ?? 22,
      altHost: json['altHost'] as String? ?? '',
      authMethod: SshAuthMethod.values.firstWhere(
        (method) => method.name == json['authMethod'],
        orElse: () => SshAuthMethod.password,
      ),
      fileRoot: json['fileRoot'] as String? ?? '',
      forwardPorts: json['forwardPorts'] as bool? ?? false,
      useTmux: json['useTmux'] as bool? ?? false,
      jumpHostId: json['jumpHostId'] as String? ?? '',
      os: switch (json['os']) {
        final Map<String, dynamic> os => OsInfo.fromJson(os),
        _ => null,
      },
    );
  }
}
