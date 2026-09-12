import 'dart:async';
import 'dart:io';

import '../models/host_profile.dart';
import 'terminal_session.dart';

/// Something to tell the user, once: a port opened, or why one did not.
typedef ForwardNews = ({String message, bool failed});

/// A host's [LocalForward]s, opened the way `ssh -L` opens them: each rule's
/// port on this tablet, piped over the session's connection to where the
/// host reaches the rule's destination. A database app on the tablet
/// connects to 127.0.0.1:5432 and is talking to the host's postgres.
///
/// Loopback only, never every address: that would put the host's database
/// on whatever Wi-Fi the tablet happens to be on.
class LocalForwarder {
  LocalForwarder({required this.onChanged, this.heldElsewhere, this.onReleased});

  /// There is news to take — see [takeNews].
  final void Function() onChanged;

  /// Whether another session on the same host holds a port already. That
  /// one keeps it, and this one leaves the rule alone, saying nothing.
  final bool Function(int port)? heldElsewhere;

  /// Called once [stop] has let go of its ports, so another session still
  /// on the host can take them over.
  final void Function()? onReleased;

  final _held = <int, _Listener>{};
  final _news = <ForwardNews>[];

  /// Every close still under way. A bind waits for it, so a reconnect gets
  /// back the port its last connection has only just let go of.
  Future<void> _closing = Future.value();

  bool isHolding(int port) => _held.containsKey(port);

  /// What happened since last asked, handed over once.
  List<ForwardNews> takeNews() {
    final news = List.of(_news);
    _news.clear();
    return news;
  }

  /// Opens each of [rules] not open yet, through [host], and closes any port
  /// whose rule has gone. One that could not open is not tried again until
  /// after [stop]: the next connect.
  void sync(ForwardCapable host, List<LocalForward> rules) {
    for (final listener in _held.values.toList()) {
      if (rules.contains(listener.rule)) continue;
      _held.remove(listener.rule.localPort);
      _closing = Future.wait([_closing, _close(listener)]);
    }
    for (final rule in rules) {
      final port = rule.localPort;
      if (_held.containsKey(port) || (heldElsewhere?.call(port) ?? false)) {
        continue;
      }
      final listener = _held[port] = _Listener(rule, host);
      listener.server = _bind(listener);
    }
  }

  /// Closes every port, and every connection through them: the session
  /// ended, dropped, failed, is reconnecting, or its tab closed.
  Future<void> stop() {
    if (_held.isEmpty) return _closing;
    final held = _held.values.toList();
    _held.clear();
    return _closing = Future.wait([_closing, ...held.map(_close)])
        .then((_) => onReleased?.call());
  }

  Future<ServerSocket?> _bind(_Listener listener) async {
    await _closing;
    if (listener.closed) return null;
    final rule = listener.rule;
    try {
      final server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        rule.localPort,
      );
      // Let go of while binding: [_close] is waiting on this, to close it.
      if (listener.closed) return server;
      server.listen((socket) => unawaited(_accept(listener, socket)));
      _say('Forwarding ${rule.label}');
      return server;
    } on SocketException catch (error) {
      if (!listener.closed) {
        _say(
          'Cannot open 127.0.0.1:${rule.localPort}\n'
          '${error.osError?.message ?? error.message}',
          failed: true,
        );
      }
      return null;
    }
  }

  Future<void> _close(_Listener listener) async {
    listener.closed = true;
    for (final socket in listener.sockets.toList()) {
      socket.destroy();
    }
    await (await listener.server)?.close();
  }

  /// One app's connection to a forwarded port: a channel to the destination
  /// for it, then bytes both ways until either end closes, which closes the
  /// other. A destination that refuses costs this connection, not the port.
  Future<void> _accept(_Listener listener, Socket socket) async {
    final rule = listener.rule;
    listener.sockets.add(socket);
    // A failed write surfaces in [_pipe]; nothing else waits on this.
    socket.done.ignore();
    final Tunnel tunnel;
    try {
      tunnel = await listener.host.forward(rule.destHost, rule.destPort);
    } catch (error) {
      listener.sockets.remove(socket);
      socket.destroy();
      if (!listener.closed) {
        _say(
          'Port ${rule.localPort}: the host could not reach '
          '${rule.destHost}:${rule.destPort}\n$error',
          failed: true,
        );
      }
      return;
    }
    // Let go of while the channel opened: [_close] has ended the socket.
    if (listener.closed) {
      unawaited(tunnel.input.close());
      return;
    }
    socket.listen(
      tunnel.input.add,
      onError: (Object _) => socket.destroy(),
      onDone: () {
        listener.sockets.remove(socket);
        unawaited(tunnel.input.close());
      },
    );
    unawaited(_pipe(tunnel.output, socket));
  }

  /// The destination's bytes to the app, then its end closing when the
  /// destination's does.
  static Future<void> _pipe(Stream<List<int>> from, Socket to) async {
    try {
      await to.addStream(from);
      await to.close();
    } catch (_) {
      to.destroy();
    }
  }

  void _say(String message, {bool failed = false}) {
    _news.add((message: message, failed: failed));
    onChanged();
  }
}

/// One rule's port on the tablet, while this session holds it.
class _Listener {
  _Listener(this.rule, this.host);

  final LocalForward rule;

  /// The connection its channels are opened on.
  final ForwardCapable host;

  /// The bind: the port's socket, or null when it could not be opened.
  late final Future<ServerSocket?> server;

  /// The apps connected through it now.
  final sockets = <Socket>{};

  /// Let go of — by [LocalForwarder.stop], or its rule going.
  var closed = false;
}
