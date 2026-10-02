import 'dart:convert';
import 'dart:math';

import '../data/secret_store.dart';

/// The private OSC code `jeansh <file>` writes: `ESC ] 7733 ; open ; secret ;
/// epoch ; nonce ; base64-of-path BEL`. xterm2 hands an OSC it does not know
/// to `Terminal.onPrivateOSC`, so nothing here reads the stream itself.
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
/// The secret is constant, and the sequence is plain text in the pane's
/// output: a record, a typescript or a saved log of it could replay the call.
/// So each request also carries the time it was made and a nonce, and is
/// honoured only within [window] of the host's clock — [clockOffset] being
/// how far that is from this device's — and only once.
///
/// The secret is never logged. [onOpen] gets an absolute path with no
/// control character in it, and nothing else is ever done for a request.
class OpenRequests {
  OpenRequests({
    required this.onOpen,
    this.onRefused,
    this.secret,
    this.clockOffset,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final void Function(String path) onOpen;

  /// A request that carried the command's shape and failed a check, at most
  /// once every [refusedEvery]. Never says which check.
  final void Function()? onRefused;

  /// The host's secret, set by [load] when the session connects; until then
  /// nothing is honoured.
  String? secret;

  /// Seconds the host's clock is ahead of this device's; null until measured,
  /// when only the nonce guards against a replay.
  int? clockOffset;
  final DateTime Function() _now;

  /// At most [burst] opens in [burstWindow]: a loop printing the sequence,
  /// even with the right secret, does not fill the strip with tabs.
  static const burst = 5;
  static const burstWindow = Duration(seconds: 2);

  /// How far from the host's now a request's time may be, either way, in
  /// seconds.
  static const window = 120;
  static const refusedEvery = Duration(seconds: 10);
  static const maxPath = 4096;
  static const _maxNonces = 512;
  static final _hex = RegExp(r'^[0-9a-f]{8,64}$');
  final _recent = <DateTime>[];
  final _seen = <String>{};
  DateTime? _refusedAt;

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
    if (code != openOscCode || args.length != 5 || args[0] != 'open') {
      return false;
    }
    final secret = this.secret;
    final now = _now();
    final at = int.tryParse(args[2]);
    final offset = clockOffset;
    final good =
        secret != null &&
        constantTimeEquals(args[1], secret) &&
        at != null &&
        (offset == null ||
            (at - (now.millisecondsSinceEpoch ~/ 1000 + offset)).abs() <=
                window) &&
        _hex.hasMatch(args[3]) &&
        _seen.add(args[3]);
    if (!good) return _refuse(now);
    if (_seen.length > _maxNonces) _seen.remove(_seen.first);
    final path = decodePath(args[4]);
    if (path == null) return false;
    _recent.removeWhere((t) => now.difference(t) >= burstWindow);
    if (_recent.length >= burst) return false;
    _recent.add(now);
    onOpen(path);
    return true;
  }

  bool _refuse(DateTime now) {
    final last = _refusedAt;
    if (last == null || now.difference(last) >= refusedEvery) {
      _refusedAt = now;
      onRefused?.call();
    }
    return false;
  }

  /// [encoded] as an absolute path, or null: not base64 of UTF-8, relative,
  /// too long, or holding a control character (C0, DEL or C1) or a bidi one,
  /// which can make a name read as another.
  static String? decodePath(String encoded) {
    try {
      final path = utf8.decode(base64.decode(encoded));
      if (path.isEmpty || path.length > maxPath || !path.startsWith('/')) {
        return null;
      }
      for (final unit in path.runes) {
        if (unit < 0x20 ||
            (unit >= 0x7f && unit <= 0x9f) ||
            unit == 0x200e ||
            unit == 0x200f ||
            (unit >= 0x202a && unit <= 0x202e) ||
            (unit >= 0x2066 && unit <= 0x2069)) {
          return null;
        }
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
