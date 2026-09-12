import 'dart:async';
import 'dart:io';

import '../models/forward_setting.dart';
import 'terminal_session.dart';

/// A forward setting's ports, opened the way `ssh -L` opens them: each
/// mapping's port on this tablet, piped over the setting's connection to
/// where the host reaches the mapping's destination. A database app on the
/// tablet connects to 127.0.0.1:5432 and is talking to the host's postgres.
///
/// Loopback only, never every address: that would put the host's database
/// on whatever Wi-Fi the tablet happens to be on.
class LocalForwarder {
  LocalForwarder({required this.onProblem});

  /// Why [LocalForward]'s port could not open, or why an app's connection
  /// through it could not reach its destination; null once a connection
  /// through it gets through again.
  final void Function(LocalForward rule, String? problem) onProblem;

  final _held = <int, _Listener>{};

  /// Every close still under way. A bind waits for it, so a reconnect gets
  /// back the port its last connection has only just let go of.
  Future<void> _closing = Future.value();

  /// Opens each of [rules] not open yet, through [host], and closes any port
  /// whose rule has gone. Done once each port it opens is bound, or has said
  /// why not. One that could not open is not tried again until after [stop]:
  /// the next connect.
  Future<void> sync(ForwardCapable host, List<LocalForward> rules) {
    for (final listener in _held.values.toList()) {
      if (rules.contains(listener.rule)) continue;
      _held.remove(listener.rule.localPort);
      _closing = Future.wait([_closing, _close(listener)]);
    }
    final binds = <Future<void>>[];
    for (final rule in rules) {
      if (_held.containsKey(rule.localPort)) continue;
      final listener = _held[rule.localPort] = _Listener(rule, host);
      binds.add(listener.server = _bind(listener));
    }
    return Future.wait(binds);
  }

  /// Closes every port, and every connection through them: the setting was
  /// switched off, or its connection dropped.
  Future<void> stop() {
    if (_held.isEmpty) return _closing;
    final held = _held.values.toList();
    _held.clear();
    return _closing = Future.wait([_closing, ...held.map(_close)]);
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
      return server;
    } on SocketException catch (error) {
      if (!listener.closed) {
        onProblem(rule, error.osError?.message ?? error.message);
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
        onProblem(rule, 'cannot reach ${rule.destHost}:${rule.destPort}: '
            '$error');
      }
      return;
    }
    // Let go of while the channel opened: [_close] has ended the socket.
    if (listener.closed) {
      unawaited(tunnel.input.close());
      return;
    }
    onProblem(rule, null);
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
}

/// One rule's port on the tablet, while it is held.
class _Listener {
  _Listener(this.rule, this.host);

  final LocalForward rule;

  /// The connection its channels are opened on.
  final ForwardCapable host;

  /// The bind: the port's socket, or null when it could not be opened.
  late final Future<ServerSocket?> server;

  /// Starts the bind, and hands it back.
  Future<ServerSocket?> bound(Future<ServerSocket?> Function(_Listener) bind) =>
      server = bind(this);

  /// The apps connected through it now.
  final sockets = <Socket>{};

  /// Let go of — by [LocalForwarder.stop], or its rule going.
  var closed = false;
}
