import 'dart:async';
import 'dart:math' as math;

import 'terminal_session.dart';

/// One port on the host, put on the tailnet by `tailscale serve`.
class PortForward {
  PortForward(this.port, this.publicPort);

  /// Where the server listens on the host — vite's 3000.
  final int port;

  /// Where the tailnet reaches it: the first free port above [port], so 3001.
  final int publicPort;

  /// `<name>:<publicPort>` once tailscale says it is serving. The name is the
  /// host's MagicDNS name when the tailnet has MagicDNS on, else its address.
  String? address;

  /// Why it is not being served, in tailscale's words.
  String? error;

  StreamSubscription<String>? _serve;

  /// What runs on the host for it, and, matched whole, what ends it there.
  String get _command =>
      'tailscale serve --tcp $publicPort tcp://localhost:$port';
}

/// A listening TCP socket on the host, as the watch reports it.
typedef ListeningSocket = ({int port, int uid, bool local});

/// Watches the host for servers started during the session, and puts each on
/// the tailnet with `tailscale serve` — vite on localhost:3000 becomes
/// `<host>.<tailnet>.ts.net:3001`.
///
/// Only the user's own servers count, only ones on loopback or every address,
/// and only ones that were not already up when the session connected: a
/// session forwards what it started, not everything the box happens to run.
class TailnetForwarder {
  TailnetForwarder({required this.onChanged, this.forwardedElsewhere});

  final void Function() onChanged;

  /// Whether another session on the same host already forwards a port, so two
  /// tabs on one box do not put the same server on the tailnet twice.
  final bool Function(int port)? forwardedElsewhere;

  final _forwards = <int, PortForward>{};

  /// The public port each host port was given, kept across reconnects: after
  /// a dropped connection a server that was forwarded counts as new again,
  /// and gets its old address back.
  final _remembered = <int, int>{};

  CommandCapable? _host;
  StreamSubscription<String>? _watch;
  int? _uid;
  Set<int>? _baseline;
  var _sweep = <String>[];
  String? _remark;

  /// Why nothing is being forwarded at all, when this host cannot do it.
  String? problem;

  List<PortForward> get forwards => List.unmodifiable(_forwards.values);

  bool isForwarding(int port) => _forwards.containsKey(port);

  /// Starts watching. A no-op while already watching — or after the watch
  /// gave up on this host, until [stop] clears that.
  void start(CommandCapable host) {
    if (_watch != null) return;
    _host = host;
    _uid = null;
    _baseline = null;
    _sweep = [];
    _remark = null;
    problem = null;
    // Through `sh`, because the login shell may be fish.
    _watch = host.run("sh -c '${_watchScript.replaceAll("'", r"'\''")}'").listen(
      _onWatchLine,
      onError: (Object error) => problem = '$error',
      onDone: () {
        // Ending once it is watching means the connection went, which is the
        // session's news to break: a dropped connection closes the channel
        // without an error. An error, or ending before it is watching, is the
        // host's problem — and otherwise forwarding would stop unsaid.
        if (_uid != null && problem == null) return;
        problem ??= _remark ?? 'Could not watch the host for servers.';
        onChanged();
      },
    );
  }

  /// Takes every forward down with the watch — the tab closing, the
  /// connection going, or forwarding switched off. Tailscale forgets a
  /// foreground `serve` the moment its process goes, so once [_release] has
  /// ended it nothing is left on the host.
  void stop() {
    _watch?.cancel();
    _watch = null;
    _forwards.values.forEach(_release);
    _forwards.clear();
    _host = null;
    problem = null;
  }

  /// Ends [forward]'s `tailscale serve`, and with it the port on the tailnet.
  ///
  /// Closing its channel is what hangs it up under OpenSSH, but Tailscale SSH
  /// leaves a process that is not writing running for as long as the
  /// connection lasts: still serving, and still holding its public port, so
  /// each restart of `bun dev` put vite one port further up — 3002, 3003,
  /// 3004 — beside the forwards that never went. So it is also killed by its
  /// command line, on a channel of its own. With the connection gone there is
  /// nothing to send that on, and no need: the host ends what it was running.
  void _release(PortForward forward) {
    forward._serve?.cancel();
    _host
        ?.run("pkill -xf '${forward._command}'")
        .listen(null, onError: (_) {});
  }

  /// Says why and stops when the host cannot do this. Otherwise prints the
  /// user's uid, then every listening TCP socket as `address:port uid` with a
  /// blank line after each sweep, every two seconds — until the channel
  /// closes, and writing into a closed channel is what ends the loop.
  ///
  /// `/proc` rather than `ss`: every Linux box has the one, not the other.
  /// Only LISTEN rows (state 0A) cross the wire, so a busy server's thousands
  /// of connections stay off a phone's data plan.
  static const _watchScript = r'''
command -v tailscale >/dev/null || { echo "tailscale is not installed on this host"; exit; }
[ -r /proc/net/tcp ] || { echo "no /proc/net/tcp: forwarding ports needs a Linux host"; exit; }
id -u
while :; do
  awk '$4 == "0A" { print $2, $8 }' /proc/net/tcp /proc/net/tcp6 2>/dev/null
  echo
  sleep 2
done''';

  void _onWatchLine(String line) {
    if (_uid == null) {
      // Anything before the uid is the login shell's own chatter, or the
      // script saying why it gave up.
      final text = line.trim();
      _uid = int.tryParse(text);
      if (_uid == null && text.isNotEmpty) _remark = text;
      return;
    }
    if (line.isNotEmpty) {
      _sweep.add(line);
      return;
    }
    _onSweep(_sweep.map(parseListener).nonNulls.toList());
    _sweep = [];
  }

  /// At and above this is the kernel's ephemeral range — debuggers and
  /// language servers, which nobody wants on the tailnet.
  // ponytail: Linux's default range, not the host's ip_local_port_range;
  // read that if a host moves it.
  static const _ephemeral = 32768;

  /// Never forwarded, whoever started them: debuggers' and dev tools' own
  /// ports, which come up beside a dev server rather than being one. `vite
  /// dev` with Cloudflare's plugin opens workerd's inspector on 9229 next to
  /// vite's 3001, and both are below the ephemeral range. An inspector runs
  /// whatever code whoever connects sends it, so putting one on the tailnet
  /// is remote code execution on the host, for every device the tailnet lets
  /// in.
  static const _debuggers = {
    // V8's inspector: `node --inspect`, deno, and workerd under miniflare,
    // wrangler and vite's Cloudflare plugin. A second inspector takes 9230,
    // and so on up.
    9229, 9230, 9231, 9232, 9233, 9234, 9235, 9236, 9237, 9238, 9239,
    9222, // Chrome's DevTools, `--remote-debugging-port`: a browser's.
    6499, // Bun's inspector, `bun --inspect`.
    5858, // node's old `--debug`, from before the inspector.
    24678, // vite's HMR websocket, from when it had a port of its own.
  };

  void _onSweep(List<ListeningSocket> sockets) {
    // Anything listening, on any address and for anyone, is a port a forward
    // cannot take — tailscale's own listeners included.
    final taken = {
      for (final socket in sockets) socket.port,
      for (final forward in _forwards.values) forward.publicPort,
    };
    // A set of ports, so a server on both IPv4 and IPv6 — a row in
    // /proc/net/tcp and another in tcp6 — is one forward.
    final mine = {
      for (final socket in sockets)
        if (socket.uid == _uid &&
            socket.local &&
            socket.port < _ephemeral &&
            !_debuggers.contains(socket.port))
          socket.port,
    };
    // A port that closes leaves the baseline, so restarting a server that
    // was up before the session counts as starting it.
    final baseline = _baseline ??= mine.difference(_remembered.keys.toSet());
    baseline.retainAll(mine);

    var changed = false;
    for (final port in _forwards.keys.toList()) {
      if (mine.contains(port)) continue;
      // ponytail: a server back within one sweep of the kill can still find
      // the old public port listening and move one up; a longer wait would
      // need the kill's completion tracked.
      _release(_forwards.remove(port)!);
      changed = true;
    }
    for (final port in mine) {
      if (baseline.contains(port) || _forwards.containsKey(port)) continue;
      if (forwardedElsewhere?.call(port) ?? false) continue;
      _open(port, taken);
      changed = true;
    }
    if (changed) onChanged();
  }

  /// A forward that fails stays listed with its error and is not retried
  /// until its server restarts — retrying every sweep would open a channel
  /// every two seconds just to be refused again.
  void _open(int port, Set<int> taken) {
    final publicPort = publicPortFor(port, taken, previous: _remembered[port]);
    taken.add(publicPort);
    _remembered[port] = publicPort;

    final forward = _forwards[port] = PortForward(port, publicPort);
    final said = <String>[];
    // Foreground rather than --bg: tailscaled drops a foreground config the
    // moment its process goes, however it goes, so a phone that vanishes
    // mid-session leaves nothing behind. `localhost` rather than 127.0.0.1,
    // because tailscale dials it as written and so reaches a server that
    // bound only ::1.
    forward._serve = _host!
        .run(forward._command, pty: true)
        .listen(
          (line) {
            final name = servedName(line, publicPort);
            if (name != null && forward.address == null) {
              forward.address = '$name:$publicPort';
              onChanged();
            } else if (line.trim().isNotEmpty) {
              said.add(line.trim());
            }
          },
          onError: (Object error) => forward.error = '$error',
          onDone: () {
            // ponytail: the last three lines, because the login shell may
            // chatter first and tailscale's own errors run to three.
            forward.error ??= forward.address != null
                ? 'tailscale serve stopped'
                : said.isEmpty
                    ? 'tailscale serve exited'
                    : said.sublist(math.max(0, said.length - 3)).join('\n');
            forward.address = null;
            onChanged();
          },
        );
  }

  /// Where the tailnet reaches [port]: the port it had before if that is
  /// still free, else the first free one above it.
  static int publicPortFor(int port, Set<int> taken, {int? previous}) {
    if (previous != null && !taken.contains(previous)) return previous;
    var candidate = port + 1;
    while (taken.contains(candidate)) {
      candidate++;
    }
    return candidate;
  }

  /// One `address:port uid` row of the watch. /proc/net/tcp writes both in
  /// hex, the address as 32-bit words in host order — little-endian on
  /// anything a server runs on, so 127.0.0.1 is `0100007F`.
  static ListeningSocket? parseListener(String row) {
    final fields = row.trim().split(RegExp(r'\s+'));
    if (fields.length != 2) return null;
    final colon = fields[0].lastIndexOf(':');
    if (colon < 0) return null;
    final port = int.tryParse(fields[0].substring(colon + 1), radix: 16);
    final uid = int.tryParse(fields[1]);
    if (port == null || uid == null) return null;
    return (port: port, uid: uid, local: _isLocal(fields[0].substring(0, colon)));
  }

  /// Loopback or every address: where a dev server listens, and what
  /// `localhost` reaches. A socket bound to one other address — the tailnet
  /// one, where tailscale's own listeners sit — is not a server to forward.
  static bool _isLocal(String address) {
    if (RegExp(r'^0+$').hasMatch(address)) return true;
    // 127.0.0.0/8: the first octet is the last byte written.
    if (address.length == 8) return address.endsWith('7F');
    return address == '00000000000000000000000001000000' || // ::1
        // ::ffff:127.x.x.x
        (address.startsWith('0000000000000000FFFF0000') &&
            address.endsWith('7F'));
  }

  static final _servedAt = RegExp(r'tcp://([^\s/:\[\]]+):(\d+)');

  /// The name in tailscale's `|-- tcp://<name>:<port>` line for [publicPort].
  /// The first such line is the MagicDNS name when the tailnet has one.
  static String? servedName(String line, int publicPort) {
    final match = _servedAt.firstMatch(line);
    if (match == null || match.group(2) != '$publicPort') return null;
    return match.group(1);
  }
}
