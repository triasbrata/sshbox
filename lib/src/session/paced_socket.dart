import 'dart:async';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// No Flutter here on purpose: tool/transfer_bench.dart runs on a plain Dart
/// VM and imports this file, so the benchmark measures the pacing the app
/// actually ships rather than a copy of it kept in step by hand. The copy is
/// how the ceiling below went unnoticed.

/// A turn of the event loop.
///
/// A timer, not a microtask: microtasks all run before the loop gets back to
/// anything else, so standing aside through one stands aside from nothing.
Future<void> nextTurn() => Future<void>.delayed(Duration.zero);

/// The socket a connection is dialled on, handing dartssh2 what arrives in
/// pieces with a turn of the event loop between them.
///
/// dartssh2 decrypts and frames everything a socket hands it in one go, on
/// the UI isolate, and a transfer keeps half a megabyte in flight: a read
/// that brought much of it held every frame back until it was through — up to
/// 16 ms on a desktop in JIT, 24 ms in AOT, and several times that on the
/// tablet.
///
/// The hosts behind a jump host are reached through this one socket, so
/// pacing it paces them too.
class PacedSocket implements SSHSocket {
  PacedSocket(this._socket);

  final SSHSocket _socket;

  @override
  late final Stream<Uint8List> stream = paceReads(_socket.stream);

  @override
  StreamSink<List<int>> get sink => _socket.sink;

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> close() => _socket.close();

  @override
  void destroy() => _socket.destroy();

  @override
  Future<void> flush() => _socket.flush();
}

/// The most of one event-loop turn that handing pieces over may take.
///
/// About a quarter of a 60 Hz frame, which leaves the other 12 ms to the
/// app's own frame — the margin that matters most in a debug build, where
/// that frame is dearest and where the tablet runs.
///
/// What a turn moves is this budget times whatever the device can do in it,
/// so speed and stall both follow the number roughly in step and there is no
/// knee to sit on. Measured frame-bound, 16 MB over a local link: 2 ms gives
/// 6.7 MB/s at a 4.2 ms p99 stall, 3 ms 9.7 at 5.6, 4 ms 12.2 at 6.9, 5 ms
/// 14.9 at 8.2 and 8 ms 24.8 at 12.4. The line is drawn at frames instead:
/// every budget to 5 ms missed none across three runs, while 8 ms began to,
/// stalling 17.9 ms against a 16.7 ms frame. 4 ms takes the safer side of
/// that, the tablet's dearer frames in mind.
///
/// The fixed 32 KB a turn this replaced ran at 2.1 MB/s in every run,
/// however long the turn was — that is the ceiling being lifted.
const pacingBudget = Duration(milliseconds: 4);

/// One full SSH packet, the most a host sends in one, and the granularity the
/// budget below is checked at.
const _piece = 32 * 1024;

/// [source]'s bytes in pieces, spending at most [budget] of any one
/// event-loop turn on them before standing aside through [yieldTurn].
///
/// The first version of this handed over a fixed 32 KB a turn, which caps a
/// transfer at 32 KB times however many turns a second the loop manages. That
/// is no cap at all on a plain Dart VM, which turns a zero-delay timer over
/// 175000 times a second — so tool/transfer_bench.dart measured 22 MB/s and
/// saw nothing wrong. A Flutter app's timers are serviced by the engine's
/// task runner at about frame rate instead, which put the same code at
/// roughly 32 KB x 60 = 1.9 MB/s, and the tablet measured 1.5-1.6 MB/s.
///
/// A time budget has no such ceiling: pieces keep going over until the turn
/// has spent [budget] on them, so how much moves in a turn follows what the
/// device can actually do, while the turn still ends in time for the frame.
/// The clock is only read between pieces, so the longest a turn can run over
/// is [budget] plus the one piece that was in progress.
///
/// Only the listener's own time is counted. Waiting for the next read is not
/// this turn's doing, and a yield in an `async*` stream runs the listener
/// synchronously, so the stopwatch below measures dartssh2 decrypting and
/// framing and nothing else.
Stream<Uint8List> paceReads(
  Stream<Uint8List> source, {
  Duration budget = pacingBudget,
  Future<void> Function() yieldTurn = nextTurn,
}) async* {
  final spent = Stopwatch();
  await for (final data in source) {
    for (var at = 0; at < data.length; at += _piece) {
      if (spent.elapsed >= budget) {
        spent.reset();
        await yieldTurn();
      }
      spent.start();
      yield Uint8List.sublistView(data, at, min(at + _piece, data.length));
      spent.stop();
    }
  }
}
