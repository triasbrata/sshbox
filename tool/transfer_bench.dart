// What a file transfer costs the isolate dartssh2 runs on, which in the app
// is the UI isolate: every byte is decrypted, framed and handed on there.
//
// Always: the cipher alone, one 32 KB packet at a time, and what that same
// packet costs opened on a worker isolate instead of this one. With
// SSHBOX_BENCH_KEY (an unencrypted key) and SSHBOX_BENCH_FILE (a file on the
// host): downloads and uploads of that file, each way the app could run them.
// The host is 127.0.0.1:22 as $USER unless SSHBOX_BENCH_HOST,
// SSHBOX_BENCH_PORT and SSHBOX_BENCH_USER say otherwise. It trusts the host's
// key, so point it only at a host you trust, such as an sshd of your own on
// 127.0.0.1.
//
//   JIT with asserts, as the tablet's debug build runs:
//     dart run --enable-asserts tool/transfer_bench.dart
//   AOT, as a release build runs:
//     dart compile exe tool/transfer_bench.dart -o /tmp/transfer_bench
//     /tmp/transfer_bench
//
// Every transfer runs under both event-loop models:
//
//   headless    this Dart VM as it is, which turns a zero-delay timer over
//               175000 times a second.
//   frame-bound a Flutter app, where a timer is not serviced until the
//               engine's task runner next runs, about once a 16.7 ms frame.
//
// The second model exists because the first hid a bug. Pacing that hands
// dartssh2 a fixed 32 KB per turn is free headless and a hard ceiling of
// 32 KB x 60 = 1.9 MB/s in the app, which is what the tablet measured at
// 1.5-1.6 MB/s while this benchmark reported 22 MB/s. "KB a turn" below is
// the number that ceiling is made of.
//
// Both pacings below are now frozen baselines: the app paces nothing any
// more, because its whole SSH transport moved to a worker isolate, where no
// frame is waiting on it — see lib/src/session/isolate_transport.dart. They
// are kept here as the numbers that change is measured against. The "after"
// number cannot be taken here: the transport is bound to Flutter, which a
// plain Dart VM cannot load, so it is measured frame-bound by
// test/isolate_transfer_bench_test.dart instead.
//
// "stall" is the longest the event loop went without running a 1 ms timer,
// which is how long a frame would have waited; "janky" is how many of those
// waits passed 16 ms, a frame missed at 60 Hz.

// ignore_for_file: avoid_print, implementation_imports

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:dartssh2/src/utils/openssh_chacha20_poly1305.dart';

/// A turn of the event loop.
///
/// A timer, not a microtask: microtasks all run before the loop gets back to
/// anything else, so standing aside through one stands aside from nothing.
Future<void> nextTurn() => Future<void>.delayed(Duration.zero);

/// The budget the app dialled while it paced its socket on the UI isolate.
const pacingBudget = Duration(milliseconds: 4);

/// One full SSH packet, the most a host sends in one.
const _piece = 32 * 1024;

/// The time-budget pacing the app shipped and has now dropped, kept here as a
/// baseline: [source]'s bytes in pieces, spending at most [budget] of any one
/// event-loop turn on them before standing aside through [yieldTurn].
///
/// Frame-bound, this is what a Flutter app measured: however long the turn
/// is, the transfer moves what the device can decrypt in [budget] and then
/// waits for the next frame, so the rate is that times 60. Raising the budget
/// trades frames for speed with no knee to sit on, which is why the fix was
/// to take the transport off the isolate the frame is on instead.
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

String get _host => Platform.environment['SSHBOX_BENCH_HOST'] ?? '127.0.0.1';
int get _port =>
    int.tryParse(Platform.environment['SSHBOX_BENCH_PORT'] ?? '') ?? 22;
String get _user =>
    Platform.environment['SSHBOX_BENCH_USER'] ??
    Platform.environment['USER'] ??
    'root';

/// How a socket read is handed to dartssh2.
enum _Pacing {
  /// Straight through, as it was before any pacing: fastest, and it holds the
  /// isolate for as long as the whole read takes to decrypt and frame.
  none('as is  '),

  /// A fixed 32 KB per event-loop turn — the pacing that shipped and capped
  /// the tablet at 1.6 MB/s. Kept here as the number to beat.
  fixed('32 KB  '),

  /// [pacingBudget] of each turn spent handing pieces over, however many that
  /// takes: what the app does now.
  budget('budget ');

  const _Pacing(this.label);
  final String label;
}

/// A Flutter app's event loop, where a zero-delay timer waits for the
/// engine's task runner and so is serviced about once a frame.
class _FrameClock {
  _FrameClock() {
    _timer = Timer.periodic(const Duration(microseconds: 16667), (_) {
      final due = _waiting;
      _waiting = [];
      for (final one in due) {
        one.complete();
      }
    });
  }

  late final Timer _timer;
  var _waiting = <Completer<void>>[];

  Future<void> next() {
    final waiter = Completer<void>();
    _waiting.add(waiter);
    return waiter.future;
  }

  void stop() {
    _timer.cancel();
    for (final one in _waiting) {
      one.complete();
    }
    _waiting = [];
  }
}

/// Counts the turns a transfer stood aside for, so the bytes moved per turn
/// can be read off against the ceiling that number sets.
class _Turns {
  var count = 0;
}

Future<void> main() async {
  _cipher();
  await _isolates();
  final key = Platform.environment['SSHBOX_BENCH_KEY'];
  final remote = Platform.environment['SSHBOX_BENCH_FILE'];
  if (key == null || remote == null) {
    print('Set SSHBOX_BENCH_KEY and SSHBOX_BENCH_FILE for the transfers.');
    return;
  }
  final pem = File(key).readAsStringSync();

  for (final framed in [false, true]) {
    final model = framed ? 'frame-bound (a Flutter app)' : 'headless (this VM)';
    print('\ndownloads, $model:');
    for (final rtt in [0, 30]) {
      for (final pacing in _Pacing.values) {
        await _download(pem, remote, pacing: pacing, rtt: rtt, framed: framed);
      }
    }
  }

  // What the budget buys and what it costs. Throughput follows it and so do
  // the stalls, so this is the one number the whole change turns on.
  print('\nthe budget to dial (frame-bound, rtt 0 ms):');
  for (final ms in [2, 3, 4, 5, 8]) {
    await _download(
      pem,
      remote,
      pacing: _Pacing.budget,
      rtt: 0,
      framed: true,
      budget: Duration(milliseconds: ms),
    );
  }

  // Downloads ask for 16 reads at once. Uploads turned out to want far more
  // than that on a link with any latency, so the same question is worth
  // asking here.
  print('\ndownload reads in flight (frame-bound, rtt 30 ms):');
  for (final pending in [16, 32, 64]) {
    await _download(
      pem,
      remote,
      pacing: _Pacing.budget,
      rtt: 30,
      framed: true,
      pending: pending,
    );
  }

  final local = await _fetch(pem, remote);
  try {
    for (final framed in [false, true]) {
      final model = framed ? 'frame-bound (a Flutter app)' : 'headless (this VM)';
      print('\nuploads, $model (writes in flight):');
      for (final rtt in [0, 30]) {
        for (final pending in [16, 32, 64]) {
          await _upload(
            pem,
            local,
            remote,
            pending: pending,
            rtt: rtt,
            framed: framed,
          );
        }
      }
    }
  } finally {
    File(local).deleteSync();
  }
}

/// One 32 KB channel-data packet as a host sends it, sealed and opened.
void _cipher() {
  final cipher = OpenSSHChaCha20Poly1305(Uint8List(64));
  // 32 KB of data plus the channel and SSH headers, padded to a multiple of 8.
  const body = 32784;
  final packet = Uint8List(4 + body);
  ByteData.sublistView(packet).setUint32(0, body);
  packet[4] = 8;
  final sealed = [for (var i = 0; i < 4; i++) cipher.encryptPacket(packet, i)];
  void open(int i) {
    cipher.decryptPacketLength(sealed[i % 4], i % 4);
    cipher.decryptPacket(sealed[i % 4], i % 4);
  }

  for (var i = 0; i < 300; i++) {
    open(i);
  }
  const rounds = 2000;
  var clock = Stopwatch()..start();
  for (var i = 0; i < rounds; i++) {
    open(i);
  }
  final opened = clock.elapsedMicroseconds / rounds;
  clock = Stopwatch()..start();
  for (var i = 0; i < rounds; i++) {
    cipher.encryptPacket(packet, i);
  }
  final sealedIn = clock.elapsedMicroseconds / rounds;
  print(
    'chacha20-poly1305, one 32 KB packet: open ${opened.round()} µs '
    '(${_rate(32768, opened)}), seal ${sealedIn.round()} µs '
    '(${_rate(32768, sealedIn)})',
  );
}

/// What opening the packets somewhere other than this isolate would cost.
///
/// A connection's cipher is one running state, and every packet on it — the
/// terminal's as much as a transfer's — has to pass through in order, so
/// nothing can open just the transfer's share: a worker would have to hold
/// the whole transport, with every packet crossing to it and back. These are
/// the three ways, each given one packet an event-loop turn, as the paced
/// socket hands them over.
Future<void> _isolates() async {
  const rounds = 600;
  const moved = rounds * 32768;
  final key = Uint8List(64);
  const body = 32784;
  final plain = Uint8List(4 + body);
  ByteData.sublistView(plain).setUint32(0, body);
  plain[4] = 8;
  final sealed = [
    for (var i = 0; i < 4; i++)
      OpenSSHChaCha20Poly1305(key).encryptPacket(plain, i),
  ];
  // Its own copy each turn, as a socket read hands one over.
  Uint8List fresh(int i) => Uint8List.fromList(sealed[i % 4]);

  print('\nthe cipher off this isolate (one packet an event-loop turn):');

  // Here, as the app opens them now.
  final here = OpenSSHChaCha20Poly1305(key);
  var stalls = _Stalls()..start();
  var clock = Stopwatch()..start();
  for (var i = 0; i < rounds; i++) {
    final data = fresh(i);
    here.decryptPacketLength(data, i % 4);
    here.decryptPacket(data, i % 4);
    await Future<void>.delayed(Duration.zero);
  }
  var took = clock.elapsedMicroseconds;
  print('  on this isolate      ${_rate(moved, took)}  ${stalls.stop(took)}');

  // Handed to a worker holding the cipher, which hands the plaintext back.
  final inbox = ReceivePort();
  final worker = await Isolate.spawn(_openOnWorker, inbox.sendPort);
  final ready = Completer<SendPort>();
  Completer<Uint8List>? waiting;
  inbox.listen((message) {
    if (message is SendPort) {
      ready.complete(message);
      return;
    }
    final done = waiting!;
    waiting = null;
    done.complete(
      (message as TransferableTypedData).materialize().asUint8List(),
    );
  });
  final toWorker = await ready.future;
  stalls = _Stalls()..start();
  clock = Stopwatch()..start();
  for (var i = 0; i < rounds; i++) {
    waiting = Completer<Uint8List>();
    toWorker.send((i % 4, TransferableTypedData.fromList([fresh(i)])));
    await waiting!.future;
  }
  took = clock.elapsedMicroseconds;
  print('  through a worker     ${_rate(moved, took)}  ${stalls.stop(took)}');
  toWorker.send(null);
  inbox.close();
  worker.kill();

  // An Isolate.run of its own for each, the cheapest thing to write.
  await _runEach([for (var i = 0; i < rounds ~/ 20; i++) fresh(i)]);
}

/// The same packets, each opened by an [Isolate.run] of its own.
///
/// Its own function: a closure handed to another isolate carries everything
/// the scope around it holds, and [_isolates] holds completers, which cannot
/// cross. The key is made on the far side for the same reason.
Future<void> _runEach(List<Uint8List> packets) async {
  final stalls = _Stalls()..start();
  final clock = Stopwatch()..start();
  for (final (i, data) in packets.indexed) {
    final sequence = i % 4;
    await Isolate.run(() {
      final cipher = OpenSSHChaCha20Poly1305(Uint8List(64));
      cipher.decryptPacketLength(data, sequence);
      return cipher.decryptPacket(data, sequence);
    });
  }
  final took = clock.elapsedMicroseconds;
  print(
    '  an Isolate.run each  ${_rate(packets.length * 32768, took)}  '
    '${stalls.stop(took)}',
  );
}

/// [_isolates]' worker: holds the connection's cipher, opens what it is sent
/// and hands the plaintext back.
void _openOnWorker(SendPort toMain) {
  final inbox = ReceivePort();
  toMain.send(inbox.sendPort);
  final cipher = OpenSSHChaCha20Poly1305(Uint8List(64));
  inbox.listen((message) {
    if (message == null) {
      inbox.close();
      return;
    }
    final (sequence, sent) = message as (int, TransferableTypedData);
    final data = sent.materialize().asUint8List();
    cipher.decryptPacketLength(data, sequence);
    toMain.send(
      TransferableTypedData.fromList([cipher.decryptPacket(data, sequence)]),
    );
  });
}

Future<void> _download(
  String pem,
  String remote, {
  required _Pacing pacing,
  required int rtt,
  required bool framed,
  Duration budget = pacingBudget,
  int pending = 64,
}) async {
  final frames = framed ? _FrameClock() : null;
  final turns = _Turns();
  final client = await _connect(
    pem,
    pacing: pacing,
    rtt: rtt,
    frames: frames,
    turns: turns,
    budget: budget,
  );
  final target = File('${Directory.systemTemp.path}/sshbox-bench-$pid');
  try {
    final sftp = await client.sftp();
    final file = await sftp.open(remote);
    final sink = target.openWrite();
    final stalls = _Stalls()..start();
    final clock = Stopwatch()..start();
    // What the app asks for: see SftpFileBrowser.download.
    final size = await file.downloadTo(
      sink,
      chunkSize: 32 * 1024,
      maxPendingRequests: pending,
    );
    await sink.close();
    final took = clock.elapsedMicroseconds;
    final dialled = pacing == _Pacing.budget
        ? '${budget.inMilliseconds}ms x$pending'
        : '${pacing.label}x$pending';
    print(
      '  rtt ${rtt}ms ${dialled.padRight(11)} ${_rate(size, took)}  '
      '${_perTurn(size, turns.count)}  ${stalls.stop(took)}',
    );
    await file.close();
    sftp.close();
  } finally {
    client.close();
    frames?.stop();
    if (target.existsSync()) target.deleteSync();
  }
}

/// A copy of [remote] on this machine, to upload.
Future<String> _fetch(String pem, String remote) async {
  final client = await _connect(pem, pacing: _Pacing.none, rtt: 0);
  final target = File('${Directory.systemTemp.path}/sshbox-bench-up-$pid');
  try {
    final sftp = await client.sftp();
    final file = await sftp.open(remote);
    final sink = target.openWrite();
    await file.downloadTo(sink);
    await sink.close();
    await file.close();
    sftp.close();
  } finally {
    client.close();
  }
  return target.path;
}

/// The app's upload: dartssh2's streaming writer, the local file read 64 KB
/// at a time and cut into packets that fit the 32 KB a host takes.
///
/// Always under the budget pacing, because that is what the app dials now.
/// The interesting number here is [pending]: the acknowledgements that free
/// the next write come back through the paced socket, so if an upload is
/// gated by turns rather than by the link, more writes in flight is what
/// moves it.
Future<void> _upload(
  String pem,
  String local,
  String remote, {
  required int pending,
  required int rtt,
  required bool framed,
}) async {
  final frames = framed ? _FrameClock() : null;
  final turns = _Turns();
  final client = await _connect(
    pem,
    pacing: _Pacing.budget,
    rtt: rtt,
    frames: frames,
    turns: turns,
  );
  final target = '$remote.bench-upload-$pid';
  try {
    final sftp = await client.sftp();
    final file = await sftp.open(
      target,
      mode: SftpFileOpenMode.create |
          SftpFileOpenMode.exclusive |
          SftpFileOpenMode.write,
    );
    final size = File(local).lengthSync();
    final stalls = _Stalls()..start();
    final clock = Stopwatch()..start();
    await file.write(
      File(local).openRead().cast<Uint8List>(),
      chunkSize: 32 * 1024 - 64,
      maxPendingRequests: pending,
    );
    final took = clock.elapsedMicroseconds;
    print(
      '  rtt ${rtt}ms x$pending${pending < 100 ? ' ' : ''}    '
      '${_rate(size, took)}  ${_perTurn(size, turns.count)}  '
      '${stalls.stop(took)}',
    );
    await file.close();
    await sftp.remove(target);
    sftp.close();
  } finally {
    client.close();
    frames?.stop();
  }
}

Future<SSHClient> _connect(
  String pem, {
  required _Pacing pacing,
  required int rtt,
  _FrameClock? frames,
  _Turns? turns,
  Duration budget = pacingBudget,
}) async {
  final socket = await SSHSocket.connect(_host, _port);
  var stream = _late(socket.stream, Duration(milliseconds: rtt));
  Future<void> yieldTurn() {
    turns?.count++;
    return frames == null ? nextTurn() : frames.next();
  }

  stream = switch (pacing) {
    _Pacing.none => stream,
    _Pacing.fixed => _fixedPace(stream, yieldTurn),
    _Pacing.budget =>
      paceReads(stream, budget: budget, yieldTurn: yieldTurn),
  };
  final client = SSHClient(
    _Socket(socket, stream),
    username: _user,
    identities: SSHKeyPair.fromPem(pem),
    onVerifyHostKey: (_, _) => true,
    algorithms: const SSHAlgorithms(cipher: [SSHCipherType.chacha20poly1305]),
  );
  await client.authenticated;
  return client;
}

/// The pacing that shipped and capped the tablet at 1.6 MB/s: a fixed 32 KB
/// handed over per event-loop turn.
///
/// One of the two copies of old code kept here on purpose — it is a baseline
/// the numbers above are measured against, and it no longer exists in the
/// app.
Stream<Uint8List> _fixedPace(
  Stream<Uint8List> source,
  Future<void> Function() yieldTurn,
) async* {
  await for (final data in source) {
    for (var at = 0; at < data.length; at += _piece) {
      if (at > 0) await yieldTurn();
      yield Uint8List.sublistView(data, at, min(at + _piece, data.length));
    }
  }
}

/// What arrives, [rtt] later, in order: a link that far away.
Stream<Uint8List> _late(Stream<Uint8List> source, Duration rtt) {
  if (rtt == Duration.zero) return source;
  final out = StreamController<Uint8List>();
  final clock = Stopwatch()..start();
  var last = Future<void>.value();
  source.listen(
    (data) {
      final due = clock.elapsed + rtt;
      last = last.then((_) async {
        final wait = due - clock.elapsed;
        if (wait > Duration.zero) await Future<void>.delayed(wait);
        out.add(data);
      });
    },
    onError: out.addError,
    onDone: () => last.then((_) => out.close()),
  );
  return out.stream;
}

class _Socket implements SSHSocket {
  _Socket(this._inner, this.stream);

  final SSHSocket _inner;

  @override
  final Stream<Uint8List> stream;

  @override
  StreamSink<List<int>> get sink => _inner.sink;

  @override
  Future<void> get done => _inner.done;

  @override
  Future<void> close() => _inner.close();

  @override
  void destroy() => _inner.destroy();

  @override
  Future<void> flush() => _inner.flush();
}

/// How long the event loop went without a turn for anything else.
class _Stalls {
  final _clock = Stopwatch();
  final _gaps = <int>[];
  Timer? _timer;
  var _last = 0;

  void start() {
    _clock.start();
    _timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      final now = _clock.elapsedMicroseconds;
      _gaps.add(now - _last);
      _last = now;
    });
  }

  String stop(int took) {
    _timer?.cancel();
    final gaps = _gaps..sort();
    if (gaps.isEmpty) return 'no turns at all';
    final janky = gaps.where((gap) => gap > 16000);
    final lost = janky.fold<int>(0, (sum, gap) => sum + gap);
    String ms(int us) => (us / 1000).toStringAsFixed(1);
    return 'stall max ${ms(gaps.last)} ms, p99 '
        '${ms(gaps[(gaps.length * 0.99).floor()])} ms, janky ${janky.length}'
        ' (${(lost * 100 / took).round()}% of the time)';
  }
}

/// The bytes a transfer moved for each turn it stood aside for: the ceiling
/// that pacing sets, before the event loop's own rate is applied to it.
String _perTurn(int bytes, int turns) {
  if (turns == 0) return 'no turns given up';
  return '${(bytes / turns / 1024).toStringAsFixed(0)} KB a turn '
      '($turns turns)';
}

String _rate(int bytes, num micros) =>
    '${(bytes / micros).toStringAsFixed(1)} MB/s';
