import 'dart:async';
import 'dart:isolate';

/// Calls and streams over a pair of isolate ports, either way round.
///
/// No Flutter and no SSH here on purpose: this is the postal service the
/// session transport runs over, and a fault in it should be readable without
/// either.
///
/// A **call** is a method name, its arguments and one reply. A **stream** is
/// the same call whose answer is a [Stream]: its items come over one at a
/// time, its end and its failure come over too, and the listener here
/// pausing pauses the source there — so a forwarded port whose reader has
/// stopped stops the host rather than filling this isolate's heap.
///
/// Both sides may call. A reply is matched against the caller's own numbers,
/// so the two sides' numbering never has to agree.
class IsolateWire {
  IsolateWire(this.serve);

  /// Answers the other side's calls.
  ///
  /// A [Stream] is pumped over as a stream and anything else — a value or a
  /// [Future] of one — is sent as one reply. [id] is the call's own number,
  /// so a method that opens something lasting can file it under that number
  /// and later calls can name it.
  final FutureOr<Object?> Function(String method, List<Object?> args, int id)
      serve;

  final inbox = ReceivePort();

  SendPort? _out;

  /// Sent as soon as the far side's port is known. The proxy listens for
  /// events before the isolate has said hello.
  final _queued = <Object?>[];

  var _nextId = 1;
  final _replies = <int, Completer<Object?>>{};

  /// Streams arriving here, by the number of the call that asked for them.
  final _incoming = <int, StreamController<Object?>>{};

  /// Streams going out, by the number of the call that asked.
  final _sending = <int, StreamSubscription<Object?>>{};

  /// Why nothing more can be sent — the other isolate is gone.
  Object? _dead;

  void listen() => inbox.listen(handle);

  /// Where to send to. A bare [SendPort] arriving on [inbox] means the same.
  void bind(SendPort out) {
    _out = out;
    for (final message in _queued) {
      out.send(message);
    }
    _queued.clear();
  }

  Future<Object?> call(String method, List<Object?> args) {
    final dead = _dead;
    if (dead != null) return Future.error(dead);
    final id = _nextId++;
    final waiting = Completer<Object?>();
    _replies[id] = waiting;
    _send(('call', id, method, args, false));
    return waiting.future;
  }

  /// The stream [method] answers with. Cancelling it cancels the source on
  /// the other side; pausing it pauses that source too.
  Stream<Object?> stream(String method, List<Object?> args) {
    final dead = _dead;
    if (dead != null) return Stream<Object?>.error(dead);
    final id = _nextId++;
    late StreamController<Object?> out;
    out = StreamController<Object?>(
      onListen: () => _send(('call', id, method, args, true)),
      onPause: () => _send(('pause', id, true)),
      onResume: () => _send(('pause', id, false)),
      onCancel: () {
        _incoming.remove(id);
        _send(('cancel', id));
      },
    );
    _incoming[id] = out;
    return out.stream;
  }

  void handle(Object? message) {
    if (message is SendPort) {
      bind(message);
      return;
    }
    switch (message) {
      case ('call', final int id, final String method, final List<Object?> args,
            final bool streaming):
        _answer(id, method, args, streaming);
      case ('ret', final int id, final Object? value, final Object? error):
        final waiting = _replies.remove(id);
        if (waiting == null) return;
        if (error == null) {
          waiting.complete(value);
        } else {
          waiting.completeError(error);
        }
      case ('item', final int id, final Object? item):
        final out = _incoming[id];
        if (out != null && !out.isClosed) out.add(item);
      case ('end', final int id, final Object? error):
        final out = _incoming.remove(id);
        if (out == null || out.isClosed) return;
        if (error != null) out.addError(error);
        out.close();
      case ('cancel', final int id):
        _sending.remove(id)?.cancel();
      case ('pause', final int id, final bool paused):
        final sending = _sending[id];
        if (sending == null) return;
        if (paused) {
          if (!sending.isPaused) sending.pause();
        } else {
          while (sending.isPaused) {
            sending.resume();
          }
        }
    }
  }

  Future<void> _answer(
    int id,
    String method,
    List<Object?> args,
    bool streaming,
  ) async {
    try {
      // `await` on anything that is not a future hands it straight back, so
      // this covers a method that answers with a value, a future or a stream.
      final answer = await serve(method, args, id);
      if (!streaming) {
        _send(('ret', id, answer, null), orElse: () => ('ret', id, null, _text(answer)));
        return;
      }
      _sending[id] = (answer! as Stream<Object?>).listen(
        (item) => _send(('item', id, item), orElse: () => null),
        onError: (Object error) {
          _sending.remove(id);
          _send(('end', id, error), orElse: () => ('end', id, _text(error)));
        },
        onDone: () {
          _sending.remove(id);
          _send(('end', id, null));
        },
        cancelOnError: true,
      );
    } catch (error) {
      final failed = streaming ? ('end', id, error) : ('ret', id, null, error);
      final plain = streaming
          ? ('end', id, _text(error))
          : ('ret', id, null, _text(error));
      _send(failed, orElse: () => plain);
    }
  }

  /// Everything this app puts on the wire is plain data and crosses as it is,
  /// which is what lets `on FileBrowserException` on the far side keep
  /// working. A stray object from a package — one holding a socket, a port or
  /// a closure — would throw here instead, and losing the failure altogether
  /// is worse than losing its type, so [orElse] goes in its place.
  void _send(Object? message, {Object? Function()? orElse}) {
    final out = _out;
    if (out == null) {
      _queued.add(message);
      return;
    }
    try {
      out.send(message);
    } on Object {
      final second = orElse?.call();
      if (second != null) out.send(second);
    }
  }

  static IsolateWireFailure _text(Object? value) =>
      IsolateWireFailure('$value');

  /// The other isolate is gone: everything waiting on it fails with [error],
  /// and nothing more is accepted.
  void die(Object error) {
    if (_dead != null) return;
    _dead = error;
    for (final waiting in _replies.values.toList()) {
      if (!waiting.isCompleted) waiting.completeError(error);
    }
    _replies.clear();
    for (final out in _incoming.values.toList()) {
      if (out.isClosed) continue;
      out.addError(error);
      out.close();
    }
    _incoming.clear();
    for (final sending in _sending.values.toList()) {
      sending.cancel();
    }
    _sending.clear();
    inbox.close();
  }
}

/// A failure that could not cross the isolate boundary as itself, so it
/// crossed as its own text.
class IsolateWireFailure implements Exception {
  const IsolateWireFailure(this.message);

  final String message;

  @override
  String toString() => message;
}
