/// What a host said it runs, asked on every connect (see [OsInfo.detect])
/// and kept on its `HostProfile` for the host list.
///
/// Each field is the host's own text, blank where it did not say.
class OsInfo {
  const OsInfo({
    this.id = '',
    this.idLike = '',
    this.prettyName = '',
    this.versionId = '',
    this.kernel = '',
    this.arch = '',
  });

  /// os-release's `ID`, e.g. `ubuntu`; `macos` or `windows` for those.
  final String id;

  /// os-release's `ID_LIKE`: the distros [id] derives from, e.g.
  /// `rhel centos fedora`.
  final String idLike;

  /// os-release's `PRETTY_NAME`, e.g. `Ubuntu 24.04.1 LTS`.
  final String prettyName;

  /// os-release's `VERSION_ID`, e.g. `24.04`.
  final String versionId;

  /// `uname -s`, e.g. `Linux` or `Darwin`.
  final String kernel;

  /// `uname -m`, e.g. `x86_64`; Windows' `PROCESSOR_ARCHITECTURE`.
  final String arch;

  /// The version under a host's badge in the host list, e.g. `22.04.5 LTS`:
  /// [prettyName] from its first digit, as the badge already says which OS;
  /// [versionId] when the name has no digit, as a rolling release's may not.
  /// Never the OS's name, the kernel or [arch]; blank when it said none.
  String get version {
    final digit = prettyName.indexOf(RegExp(r'\d'));
    return digit < 0 ? versionId : prettyName.substring(digit);
  }

  /// Unix: os-release, which is only ever read here as data, never run; then
  /// `uname`; then `sw_vers` on macOS, which has no os-release. Through `sh`,
  /// because the login shell may be fish.
  static const _unix =
      "sh -c '"
      'cat /etc/os-release 2>/dev/null || cat /usr/lib/os-release 2>/dev/null; '
      r'echo "SSHBOX_KERNEL=$(uname -s)"; echo "SSHBOX_ARCH=$(uname -m)"; '
      r'[ "$(uname -s)" = Darwin ] && sw_vers'
      "'";

  /// Windows' OpenSSH runs cmd or PowerShell, and either can start cmd.
  static const _windows =
      'cmd /c "ver & echo SSHBOX_ARCH=%PROCESSOR_ARCHITECTURE%"';

  /// Asks the host with [run], the session's `CommandCapable.run`: an exec
  /// channel of its own for each command, on the connection the shell is on,
  /// so nothing reaches the terminal or tmux and a jump host is no obstacle.
  /// Unix first, then Windows.
  ///
  /// Null when the host cannot say. Never throws, and gives up on a command
  /// that has been silent for 5 s.
  static Future<OsInfo?> detect(
    Stream<String> Function(String command) run,
  ) async {
    for (final command in [_unix, _windows]) {
      try {
        final os = parse(
          await run(command).timeout(const Duration(seconds: 5)).toList(),
        );
        if (os != null) return os;
      } catch (_) {
        // On to the next, or the host keeps the badge it had.
      }
    }
    return null;
  }

  /// `KEY=value` from os-release and our own lines, `Key: value` from
  /// `sw_vers`.
  static final _field = RegExp(r'^([A-Za-z_]\w*)[=:]\s*(.*)$');

  /// `ver`'s banner, `Microsoft Windows [Version 10.0.22631.4602]`, with
  /// "Version" in the system's language.
  static final _ver = RegExp(r'Microsoft Windows \[\D*([\d.]+)\]');

  /// Reads what [detect]'s commands printed. A line in none of their shapes,
  /// a login shell's greeting say, is skipped. Null when nothing says what
  /// the host is.
  static OsInfo? parse(Iterable<String> lines) {
    final fields = <String, String>{};
    String? windows;
    for (final line in lines) {
      windows ??= _ver.firstMatch(line)?[1];
      final match = _field.firstMatch(line.trim());
      if (match != null) fields[match[1]!] = _unquote(match[2]!.trim());
    }
    String field(String key) => fields[key] ?? '';

    var (id, prettyName, versionId) = (
      field('ID'),
      field('PRETTY_NAME'),
      field('VERSION_ID'),
    );
    if (windows != null) {
      (id, prettyName, versionId) = ('windows', 'Windows $windows', windows);
    } else if (field('ProductName').isNotEmpty) {
      versionId = field('ProductVersion');
      (id, prettyName) = ('macos', '${field('ProductName')} $versionId');
    }
    final kernel = field('SSHBOX_KERNEL');
    if (id.isEmpty && prettyName.isEmpty && kernel.isEmpty) return null;
    return OsInfo(
      id: id,
      idLike: field('ID_LIKE'),
      prettyName: prettyName,
      versionId: versionId,
      kernel: kernel,
      arch: field('SSHBOX_ARCH'),
    );
  }

  /// os-release quotes a value as a shell would; inside double quotes, a
  /// backslash escapes `"`, `\`, `$` and `` ` ``.
  static String _unquote(String value) {
    if (value.length < 2 || value[0] != value[value.length - 1]) return value;
    final inner = value.substring(1, value.length - 1);
    return switch (value[0]) {
      "'" => inner,
      '"' => inner.replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!),
      _ => value,
    };
  }

  Map<String, String> toJson() => {
    'id': id,
    'idLike': idLike,
    'prettyName': prettyName,
    'versionId': versionId,
    'kernel': kernel,
    'arch': arch,
  };

  factory OsInfo.fromJson(Map<String, dynamic> json) {
    String field(String key) => json[key] as String? ?? '';
    return OsInfo(
      id: field('id'),
      idLike: field('idLike'),
      prettyName: field('prettyName'),
      versionId: field('versionId'),
      kernel: field('kernel'),
      arch: field('arch'),
    );
  }

  /// What a reconnect compares against, so the same machine saying the same
  /// thing writes nothing.
  @override
  bool operator ==(Object other) =>
      other is OsInfo &&
      other.id == id &&
      other.idLike == idLike &&
      other.prettyName == prettyName &&
      other.versionId == versionId &&
      other.kernel == kernel &&
      other.arch == arch;

  @override
  int get hashCode =>
      Object.hash(id, idLike, prettyName, versionId, kernel, arch);

  @override
  String toString() => 'OsInfo(${toJson()})';
}
