import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'open_command.dart' show openLongestPath, openMostFiles;

/// The private OSC code `jeansh <file>` writes: `ESC ] 7733 ; open ; secret ;
/// epoch ; nonce ; base64-of-path BEL`. xterm2 hands an OSC it does not know
/// to `Terminal.onPrivateOSC`, so nothing here reads the stream itself.
const openOscCode = '7733';

/// The newest few secrets a host's connections have put in its
/// `~/.config/jeansh/open-secret`, shared by every tab on that host. Each
/// connect makes a new one and the file holds the last, which a pane reads
/// every time it runs `jeansh`: so a tab whose connect was not the latest is
/// still honoured, and one that has fallen [keep] connections behind is not.
class OpenSecretRing {
  OpenSecretRing([Iterable<String> secrets = const []]) {
    secrets.forEach(add);
  }

  /// How many connections' secrets count.
  static const keep = 4;
  final _items = <String>[];

  /// Makes a secret, keeps it and gives it back.
  String issue() {
    final value = OpenRequests.newSecret();
    add(value);
    return value;
  }

  void add(String value) {
    _items.remove(value);
    _items.add(value);
    while (_items.length > keep) {
      _items.removeAt(0);
    }
  }

  bool get isEmpty => _items.isEmpty;

  void clear() => _items.clear();

  /// The latest, what a new pane will read.
  String? get newest => _items.isEmpty ? null : _items.last;

  /// The nonces of requests already honoured on this host, the newest
  /// [_maxNonces], so a sequence opens once whichever tab shows it.
  static const _maxNonces = 512;
  final _seen = <String>{};

  /// Records [nonce]; false when this host has already honoured it.
  bool firstUse(String nonce) {
    if (!_seen.add(nonce)) return false;
    if (_seen.length > _maxNonces) _seen.remove(_seen.first);
    return true;
  }

  /// Whether [candidate] is one of them. Every one is compared, whole, so
  /// the time says nothing of which matched or how far.
  bool accepts(String candidate) {
    var found = false;
    for (final item in _items) {
      if (OpenRequests.constantTimeEquals(candidate, item)) found = true;
    }
    return found;
  }
}

/// What a `jeansh <file>` typed in a terminal asks of the app, and the one
/// check that it is the command asking: a program's output, a file shown with
/// `cat` or a remote program can print the same bytes, so the sequence
/// carries a secret, which only the host's own `~/.config/jeansh` holds: see
/// [OpenSecretRing].
///
/// The sequence is plain text in the pane's output: a record, a typescript or
/// a saved log of it could replay the call. So each request also carries the
/// time it was made and a nonce, and is honoured only within [window] of the
/// host's clock — [clockOffset] being how far that is from this device's —
/// and only once.
///
/// The secret is never logged. [onOpen] gets an absolute path with no
/// control character in it, and nothing else is ever done for a request.
class OpenRequests {
  OpenRequests({
    required this.onOpen,
    this.onRefused,
    this.onDropped,
    String? secret,
    OpenSecretRing? ring,
    this.clockOffset,
    DateTime Function()? now,
  }) : ring = ring ?? OpenSecretRing(),
       _now = now ?? DateTime.now {
    if (secret != null) this.ring.add(secret);
  }

  final void Function(String path) onOpen;

  /// A request that carried the command's shape and failed a check, at most
  /// once every [refusedEvery]. Never says which check.
  final void Function()? onRefused;

  /// A request that passed every check and was still not opened, with how
  /// many and why, at most once every [droppedEvery]: the command sent
  /// something the app could not take, and the user is told.
  final void Function(int count, String reason)? onDropped;

  /// The secrets this host's connections made; until one is, nothing is
  /// honoured.
  final OpenSecretRing ring;

  /// Adds [value] to [ring]; null empties it, and nothing is honoured.
  set secret(String? value) {
    if (value == null) {
      ring.clear();
    } else {
      ring.add(value);
    }
  }

  /// Seconds the host's clock is ahead of this device's; null until measured,
  /// when only the nonce guards against a replay.
  int? clockOffset;
  final DateTime Function() _now;

  /// At most [burst] opens in [burstWindow]: a loop printing the sequence,
  /// even with the right secret, does not fill the strip with tabs.
  static const burst = openMostFiles;
  static const burstWindow = Duration(seconds: 2);

  /// How far from the host's now a request's time may be, either way, in
  /// seconds.
  static const window = 120;

  /// The same, while the host's clock has not been measured.
  static const unmeasuredWindow = 24 * 60 * 60;

  /// The most an offset can be, either way: about ten years, in seconds.
  static const maxOffset = 315360000;
  static const refusedEvery = Duration(seconds: 10);
  static const droppedEvery = Duration(seconds: 2);

  /// The longest path, in bytes.
  static const maxPath = openLongestPath;
  static final _hex = RegExp(r'^[0-9a-f]{8,64}$');
  final _recent = <DateTime>[];
  DateTime? _refusedAt;
  DateTime? _droppedAt;
  int _droppedSince = 0;
  String _droppedWhy = '';
  Timer? _droppedTimer;

  static final _random = Random.secure();
  static String newSecret() => base64Url
      .encode([for (var i = 0; i < 24; i++) _random.nextInt(256)])
      .replaceAll('=', '');

  /// Terminal.onPrivateOSC. True when it opened something.
  bool handle(String code, List<String> args) {
    if (code != openOscCode || args.length != 5 || args[0] != 'open') {
      return false;
    }
    final now = _now();
    final at = int.tryParse(args[2]);
    final offset = clockOffset;
    // With no offset measured, only a day's slack: the host's clock cannot
    // be told from a wrong one, but a year-old sequence still can.
    final nowSeconds = now.millisecondsSinceEpoch ~/ 1000;
    final good =
        ring.accepts(args[1]) &&
        at != null &&
        (offset == null
            ? (at - nowSeconds).abs() <= unmeasuredWindow
            : (at - (nowSeconds + offset)).abs() <= window) &&
        _hex.hasMatch(args[3]) &&
        ring.firstUse(args[3]);
    if (!good) return _refuse(now);
    final (:path, :why) = decode(args[4]);
    if (path == null) return _drop(now, why!);
    _recent.removeWhere((t) => now.difference(t) >= burstWindow);
    if (_recent.length >= burst) {
      return _drop(now, 'more than $burst files at a time');
    }
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

  /// Counts a request that was right and not opened, and says so at most
  /// once every [droppedEvery], with the count since. What is held back is
  /// said when that time is up, with no later drop needed.
  bool _drop(DateTime now, String why) {
    _droppedSince++;
    _droppedWhy = why;
    final last = _droppedAt;
    if (last == null || now.difference(last) >= droppedEvery) {
      _sayDropped(now);
    } else {
      _droppedTimer ??= Timer(droppedEvery - now.difference(last), () {
        _droppedTimer = null;
        _sayDropped(_now());
      });
    }
    return false;
  }

  void _sayDropped(DateTime now) {
    _droppedTimer?.cancel();
    _droppedTimer = null;
    if (_droppedSince == 0) return;
    _droppedAt = now;
    final count = _droppedSince;
    _droppedSince = 0;
    onDropped?.call(count, _droppedWhy);
  }

  /// Stops a held drop from being said later.
  void dispose() {
    _droppedTimer?.cancel();
    _droppedTimer = null;
  }

  /// [encoded] as an absolute path, or null: see [decode].
  static String? decodePath(String encoded) => decode(encoded).path;

  /// [encoded] as an absolute path, or no path and why not: not base64 of
  /// UTF-8, relative, too long, or holding a control character (C0, DEL or
  /// C1) or a bidi one, which can make a name read as another.
  static ({String? path, String? why}) decode(String encoded) {
    try {
      final bytes = base64.decode(encoded);
      final path = utf8.decode(bytes);
      if (path.isEmpty || !path.startsWith('/')) {
        return (path: null, why: 'the path is not absolute');
      }
      if (bytes.length > maxPath) {
        return (path: null, why: 'the path is longer than $maxPath bytes');
      }
      for (final unit in path.runes) {
        if (unit < 0x20 ||
            (unit >= 0x7f && unit <= 0x9f) ||
            unit == 0x200e ||
            unit == 0x200f ||
            (unit >= 0x202a && unit <= 0x202e) ||
            (unit >= 0x2066 && unit <= 0x2069)) {
          return (path: null, why: 'the name holds a control character');
        }
      }
      return (path: path, why: null);
    } on FormatException {
      return (path: null, why: 'the name is not valid UTF-8');
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
