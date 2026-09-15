// What a file transfer costs the isolate dartssh2 runs on, which in the app
// is the UI isolate: every byte is decrypted, framed and handed on there.
//
// Always: the cipher alone, one 32 KB packet at a time, and what that same
// packet costs opened on a worker isolate instead of this one. With
// SSHBOX_BENCH_KEY (an unencrypted key) and SSHBOX_BENCH_FILE (a file on the
// host, 70 MB is the size the lag was seen with): downloads and uploads of
// that file, each way the app could run them. The host is 127.0.0.1:22 as
// $USER unless SSHBOX_BENCH_HOST, SSHBOX_BENCH_PORT and SSHBOX_BENCH_USER say
// otherwise. It trusts the host's key, so point it only at a host you trust,
// such as an sshd of your own on 127.0.0.1.
//
//   JIT with asserts, as the tablet's debug build runs:
//     dart run --enable-asserts tool/transfer_bench.dart
//   AOT, as a release build runs:
//     dart compile exe tool/transfer_bench.dart -o /tmp/transfer_bench
//     /tmp/transfer_bench
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

String get _host => Platform.environment['SSHBOX_BENCH_HOST'] ?? '127.0.0.1';
int get _port =>
    int.tryParse(Platform.environment['SSHBOX_BENCH_PORT'] ?? '') ?? 22;
String get _user =>
    Platform.environment['SSHBOX_BENCH_USER'] ??
    Platform.environment['USER'] ??
    'root';

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

  print('\ndownloads (read size x reads in flight):');
  for (final rtt in [0, 30]) {
    for (final (chunk, pending) in [
      (32768, 16),
      (32755, 16),
      (32755, 8),
      (32755, 4),
    ]) {
      for (final paced in [false, true]) {
        await _download(
          pem,
          remote,
          chunk: chunk,
          pending: pending,
          paced: paced,
          rtt: rtt,
        );
      }
    }
  }

  print('\nuploads:');
  final local = await _fetch(pem, remote);
  try {
    for (final rtt in [0, 30]) {
      await _upload(pem, local, remote, streamed: false, paced: false, rtt: rtt);
      for (final pending in [16, 8]) {
        await _upload(
          pem,
          local,
          remote,
          streamed: true,
          pending: pending,
          paced: true,
          rtt: rtt,
        );
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
    for (var i = 0; i < 4; i++) OpenSSHChaCha20Poly1305(key).encryptPacket(plain, i),
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
  required int chunk,
  required int pending,
  required bool paced,
  required int rtt,
}) async {
  final client = await _connect(pem, paced: paced, rtt: rtt);
  final target = File('${Directory.systemTemp.path}/sshbox-bench-$pid');
  try {
    final sftp = await client.sftp();
    final file = await sftp.open(remote);
    final sink = target.openWrite();
    final stalls = _Stalls()..start();
    final clock = Stopwatch()..start();
    final size = await file.downloadTo(
      sink,
      chunkSize: chunk,
      maxPendingRequests: pending,
    );
    await sink.close();
    final took = clock.elapsedMicroseconds;
    print(
      '  rtt ${rtt}ms ${chunk}x$pending ${paced ? 'paced ' : 'as is '} '
      '${_rate(size, took)}  ${stalls.stop(took)}',
    );
    await file.close();
    sftp.close();
  } finally {
    client.close();
    if (target.existsSync()) target.deleteSync();
  }
}

/// A copy of [remote] on this machine, to upload.
Future<String> _fetch(String pem, String remote) async {
  final client = await _connect(pem, paced: false, rtt: 0);
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

/// [streamed] false is what the app did before: 256 KB read at a time and
/// handed to writeBytes, whose defaults put 64 writes of 16 KB in flight.
Future<void> _upload(
  String pem,
  String local,
  String remote, {
  required bool streamed,
  int pending = 64,
  required bool paced,
  required int rtt,
}) async {
  final client = await _connect(pem, paced: paced, rtt: rtt);
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
    if (streamed) {
      await file.write(
        File(local).openRead().cast<Uint8List>(),
        chunkSize: 32 * 1024 - 64,
        maxPendingRequests: pending,
      );
    } else {
      final handle = await File(local).open();
      var offset = 0;
      while (true) {
        final chunk = await handle.read(256 * 1024);
        if (chunk.isEmpty) break;
        await file.writeBytes(chunk, offset: offset);
        offset += chunk.length;
      }
      await handle.close();
    }
    final took = clock.elapsedMicroseconds;
    print(
      '  rtt ${rtt}ms ${streamed ? 'streamed x$pending' : '256 KB writeBytes'}'
      '${paced ? ' paced' : ''}  ${_rate(size, took)}  ${stalls.stop(took)}',
    );
    await file.close();
    await sftp.remove(target);
    sftp.close();
  } finally {
    client.close();
  }
}

Future<SSHClient> _connect(
  String pem, {
  required bool paced,
  required int rtt,
}) async {
  final socket = await SSHSocket.connect(_host, _port);
  var stream = _late(socket.stream, Duration(milliseconds: rtt));
  if (paced) stream = _pace(stream);
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

/// What arrives, handed on no more than 32 KB at a time, each piece in an
/// event-loop turn of its own.
Stream<Uint8List> _pace(Stream<Uint8List> source) async* {
  await for (final data in source) {
    for (var at = 0; at < data.length; at += 32 * 1024) {
      yield Uint8List.sublistView(data, at, min(at + 32 * 1024, data.length));
      await Future<void>.delayed(Duration.zero);
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

String _rate(int bytes, num micros) =>
    '${(bytes / micros).toStringAsFixed(1)} MB/s';
