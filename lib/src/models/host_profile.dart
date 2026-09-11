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
    this.authMethod = SshAuthMethod.password,
    this.fileRoot = '',
    this.forwardPorts = false,
    this.useTmux = false,
  });

  final String id;
  final String label;
  final String host;
  final String username;
  final int port;
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

  /// What we show under the label, e.g. `root@10.0.2.2` or `me@box:2222`.
  String get target =>
      '$username@$host${port == 22 ? '' : ':$port'}';

  /// Falls back to the target so a profile always has something to show.
  String get displayName => label.trim().isEmpty ? target : label.trim();

  HostProfile copyWith({
    String? label,
    String? host,
    String? username,
    int? port,
    SshAuthMethod? authMethod,
    String? fileRoot,
    bool? forwardPorts,
    bool? useTmux,
  }) {
    return HostProfile(
      id: id,
      label: label ?? this.label,
      host: host ?? this.host,
      username: username ?? this.username,
      port: port ?? this.port,
      authMethod: authMethod ?? this.authMethod,
      fileRoot: fileRoot ?? this.fileRoot,
      forwardPorts: forwardPorts ?? this.forwardPorts,
      useTmux: useTmux ?? this.useTmux,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'host': host,
        'username': username,
        'port': port,
        'authMethod': authMethod.name,
        'fileRoot': fileRoot,
        'forwardPorts': forwardPorts,
        'useTmux': useTmux,
      };

  factory HostProfile.fromJson(Map<String, dynamic> json) {
    return HostProfile(
      id: json['id'] as String,
      label: json['label'] as String? ?? '',
      host: json['host'] as String? ?? '',
      username: json['username'] as String? ?? '',
      port: json['port'] as int? ?? 22,
      authMethod: SshAuthMethod.values.firstWhere(
        (method) => method.name == json['authMethod'],
        orElse: () => SshAuthMethod.password,
      ),
      fileRoot: json['fileRoot'] as String? ?? '',
      forwardPorts: json['forwardPorts'] as bool? ?? false,
      useTmux: json['useTmux'] as bool? ?? false,
    );
  }
}
