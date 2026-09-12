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
    _join(socket, tunnel, () => listener.sockets.remove(socket));
  }
}

/// A forward setting's ports on the host, opened the way `ssh -R` opens
/// them: the host listens on each mapping's port, and every connection made
/// there comes over the setting's connection to be piped to the mapping's
/// target, reached from this tablet — a dev server on the tablet, reached
/// with `curl localhost:3000` on the host.
///
/// Only that target is reached, whatever a connection asks for.
class RemoteForwarder {
  RemoteForwarder({required this.onProblem});

  /// Why [RemoteForward]'s port could not open on the host, or why a
  /// connection through it could not reach its target; null once one gets
  /// through again.
  final void Function(RemoteForward rule, String? problem) onProblem;

  final _ports = <RemotePort>[];
  final _subscriptions = <StreamSubscription<Tunnel>>[];
  final _sockets = <Socket>{};

  /// Bumped by [stop], so what finishes after it lets go instead.
  var _generation = 0;

  /// Asks [host] to listen on each of [rules]' ports: done once each is
  /// listening, or has said why not.
  Future<void> start(ForwardCapable host, List<RemoteForward> rules) {
    final generation = _generation;
    return Future.wait([
      for (final rule in rules) _listen(host, rule, generation),
    ]);
  }

  /// Stops listening on every port, and closes every connection through
  /// them: the setting was switched off, or its connection dropped.
  Future<void> stop() {
    _generation++;
    // Copies first: a socket destroyed takes itself out of [_sockets].
    final ports = [..._ports];
    final sockets = [..._sockets];
    final subscriptions = [..._subscriptions];
    _ports.clear();
    _sockets.clear();
    _subscriptions.clear();
    for (final port in ports) {
      port.close();
    }
    for (final socket in sockets) {
      socket.destroy();
    }
    return Future.wait([
      for (final subscription in subscriptions) subscription.cancel(),
    ]);
  }

  Future<void> _listen(
    ForwardCapable host,
    RemoteForward rule,
    int generation,
  ) async {
    final RemotePort port;
    try {
      port = await host.listen(rule.remoteHost, rule.remotePort);
    } catch (error) {
      if (generation == _generation) onProblem(rule, '$error');
      return;
    }
    if (generation != _generation) {
      port.close();
      return;
    }
    _ports.add(port);
    _subscriptions.add(
      port.connections.listen(
        (tunnel) => unawaited(_accept(rule, tunnel, generation)),
      ),
    );
  }

  /// One connection to the host's port: a socket to the target for it, then
  /// bytes both ways until either end closes, which closes the other. A
  /// target that refuses costs this connection, not the port.
  Future<void> _accept(RemoteForward rule, Tunnel tunnel, int generation) async {
    final Socket socket;
    try {
      socket = await Socket.connect(rule.tabletHost, rule.tabletPort);
    } catch (error) {
      unawaited(tunnel.input.close());
      if (generation == _generation) {
        final reason = error is SocketException
            ? error.osError?.message ?? error.message
            : '$error';
        onProblem(
          rule,
          'cannot reach ${rule.tabletHost}:${rule.tabletPort} on this '
          'tablet: $reason',
        );
      }
      return;
    }
    if (generation != _generation) {
      socket.destroy();
      unawaited(tunnel.input.close());
      return;
    }
    onProblem(rule, null);
    _sockets.add(socket);
    // A failed write surfaces in [_pipe]; nothing else waits on this.
    socket.done.ignore();
    _join(socket, tunnel, () => _sockets.remove(socket));
  }
}

/// Bytes both ways between [socket] and [tunnel] until either end closes,
/// which closes the other; [onClosed] once [socket] has.
void _join(Socket socket, Tunnel tunnel, void Function() onClosed) {
  socket.listen(
    tunnel.input.add,
    onError: (Object _) => socket.destroy(),
    onDone: () {
      onClosed();
      unawaited(tunnel.input.close());
    },
  );
  unawaited(_pipe(tunnel.output, socket));
}

/// The far end's bytes to [to], then its end closing when the far end's
/// does.
Future<void> _pipe(Stream<List<int>> from, Socket to) async {
  try {
    await to.addStream(from);
    await to.close();
  } catch (_) {
    to.destroy();
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
