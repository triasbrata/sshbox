import 'dart:convert';
import 'dart:math';

import '../data/secret_store.dart';

/// The private OSC code `jeansh <file>` writes: `ESC ] 7733 ; open ; secret
/// ; base64-of-path BEL`. xterm2 hands an OSC it does not know to
/// `Terminal.onPrivateOSC`, so nothing here reads the stream itself.
const openOscCode = '7733';

/// The variable that carries [OpenRequests.secret] to the shell, and from
/// there to the script. `LC_` for the reason `LC_SSHBOX_KEY` is: sshd takes
/// only what `AcceptEnv` names, and `LC_*` is in Debian's, Ubuntu's and
/// macOS's.
const openSecretVariable = 'LC_SSHBOX_OPEN_SECRET';

/// What a `jeansh <file>` typed in a terminal asks of the app, and the one
/// check that it is the command asking: a program's output, a file shown with
/// `cat` or a remote program can print the same bytes, so the sequence
/// carries [secret], which only the shell's environment holds.
///
/// The secret is never logged. [onOpen] gets an absolute path with no
/// control character in it, and nothing else is ever done for a request.
class OpenRequests {
  OpenRequests({required this.onOpen, this.secret, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final void Function(String path) onOpen;

  /// The host's secret, set by [load] when the session connects; until then
  /// nothing is honoured.
  String? secret;
  final DateTime Function() _now;

  /// At most [burst] opens in [window]: a loop printing the sequence, even
  /// with the right secret, does not fill the strip with tabs.
  static const burst = 5;
  static const window = Duration(seconds: 2);
  static const maxPath = 4096;
  final _recent = <DateTime>[];

  /// Reads [hostId]'s secret from [secrets], making it the first time. One
  /// per host, kept and not made per connection: a tmux pane keeps the
  /// environment its shell started with, through reconnects and restarts of
  /// the app, so a secret that changed would break `jeansh` in every pane
  /// older than the last connect. It is deleted with the host.
  Future<String> load(SecretStore secrets, String hostId) async {
    final key = SecretKeys.openSecret(hostId);
    var value = await secrets.read(key);
    if (value == null || value.isEmpty) {
      value = newSecret();
      await secrets.write(key, value);
    }
    return secret = value;
  }

  static final _random = Random.secure();
  static String newSecret() => base64Url
      .encode([for (var i = 0; i < 24; i++) _random.nextInt(256)])
      .replaceAll('=', '');

  /// Terminal.onPrivateOSC. True when it opened something.
  bool handle(String code, List<String> args) {
    if (code != openOscCode || args.length != 3 || args[0] != 'open') {
      return false;
    }
    final secret = this.secret;
    if (secret == null || !constantTimeEquals(args[1], secret)) return false;
    final path = decodePath(args[2]);
    if (path == null) return false;
    final now = _now();
    _recent.removeWhere((t) => now.difference(t) >= window);
    if (_recent.length >= burst) return false;
    _recent.add(now);
    onOpen(path);
    return true;
  }

  /// [encoded] as an absolute path, or null: not base64 of UTF-8, relative,
  /// too long, or holding a control character (C0, DEL or C1).
  static String? decodePath(String encoded) {
    try {
      final path = utf8.decode(base64.decode(encoded));
      if (path.isEmpty || path.length > maxPath || !path.startsWith('/')) {
        return null;
      }
      for (final unit in path.runes) {
        if (unit < 0x20 || (unit >= 0x7f && unit <= 0x9f)) return null;
      }
      return path;
    } on FormatException {
      return null;
    }
  }

  /// Compares every byte of [a], against [b] wrapped round, so the time
  /// depends on the lengths and not on where the two first differ.
  static bool constantTimeEquals(String a, String b) {
    final x = utf8.encode(a), y = utf8.encode(b);
    if (y.isEmpty) return x.isEmpty;
    var diff = x.length ^ y.length;
    for (var i = 0; i < x.length; i++) {
      diff |= x[i] ^ y[i % y.length];
    }
    return diff == 0;
  }
}
