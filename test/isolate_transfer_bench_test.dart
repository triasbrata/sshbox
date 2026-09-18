import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/data/known_host_store.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/dartssh2_transport.dart';
import 'package:sshbox/src/session/isolate_transport.dart';
import 'package:sshbox/src/session/terminal_session.dart';

// What a download costs the isolate the app draws on, measured on the app's
// own transports rather than a copy of them — and, against the same host,
// the rest of what a session carries over the wire: a command, a channel and
// a forwarded connection, which is what tmux, the databases and port
// forwarding are made of.
//
// `tool/transfer_bench.dart` cannot do this: it runs on a plain Dart VM,
// which cannot load Flutter, and the transports are Flutter-bound. It keeps
// the "before" — the pacing the app shipped, whose ceiling is 32 KB times the
// frame rate — and this keeps the "after".
//
// Opt in with SSHBOX_BENCH_KEY (an unencrypted private key) and
// SSHBOX_BENCH_FILE (a file on the host, the bigger the better). The host is
// 127.0.0.1:22 as $USER unless SSHBOX_BENCH_HOST, SSHBOX_BENCH_PORT and
// SSHBOX_BENCH_USER say otherwise; it trusts whatever key the host offers, so
// point it only at an sshd of your own.
//
//   flutter test test/isolate_transfer_bench_test.dart
//
// Each transport is measured twice: with a frame's worth of work running on
// this isolate every 16.7 ms, and without it. The number that matters is how
// much the frame load costs each one.
//
//   Dartssh2Transport  the client on this isolate, as the app ran it. The
//                      frame load and the transfer take turns, and the
//                      "stall" column is how long a frame would have waited
//                      for a packet to be decrypted and framed.
//   IsolateTransport   the client on an isolate of its own, as the app runs
//                      it now. Nothing of the transfer happens here, so the
//                      frame load costs it nothing and this isolate stalls
//                      only for the progress counts.
//
// A caveat worth stating plainly: a test binds no frames, so the frame load
// below is a timer doing real work rather than the engine's task runner.
// That makes it the wrong tool for measuring the old ceiling — which is what
// tool/transfer_bench.dart's frame clock is for — and the right one for this
// question, which is whether the transfer is still on this isolate at all.
// Neither is a device. The tablet is the coordinator's to measure.

String get _host => Platform.environment['SSHBOX_BENCH_HOST'] ?? '127.0.0.1';
int get _port =>
    int.tryParse(Platform.environment['SSHBOX_BENCH_PORT'] ?? '') ?? 22;
String get _user =>
    Platform.environment['SSHBOX_BENCH_USER'] ??
    Platform.environment['USER'] ??
    'root';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a transfer off this isolate stops costing it frames', () async {
    final key = Platform.environment['SSHBOX_BENCH_KEY'];
    final remote = Platform.environment['SSHBOX_BENCH_FILE'];
    if (key == null || remote == null) {
      printOnFailure('skipped: set SSHBOX_BENCH_KEY and SSHBOX_BENCH_FILE');
      return;
    }

    final secrets = _Secrets({
      SecretKeys.privateKey('bench'): File(key).readAsStringSync(),
    });
    final host = _benchHost();

    for (final framed in [false, true]) {
      // ignore: avoid_print
      print(framed
          ? '\nwith a frame\'s work every 16.7 ms on this isolate:'
          : '\nthis isolate otherwise idle:');
      for (final onItsOwnIsolate in [false, true]) {
        final transport = onItsOwnIsolate
            ? IsolateTransport(knownHosts: _TrustAll())
            : Dartssh2Transport(knownHosts: _TrustAll());
        final session = await transport.connect(
          host: host,
          secrets: secrets,
          columns: 80,
          rows: 24,
          shell: false,
        );
        try {
          final target = '${Directory.systemTemp.path}/sshbox-bench-$pid';
          final load = framed ? _FrameLoad() : null;
          final stalls = _Stalls()..start();
          final clock = Stopwatch()..start();
          var moved = 0;
          await (session as FileBrowseCapable).openFileBrowser().download(
                remote,
                target,
                onProgress: (received, _) => moved = received,
              );
          final took = clock.elapsedMicroseconds;
          load?.stop();
          // ignore: avoid_print
          print(
            '  ${onItsOwnIsolate ? 'its own isolate' : 'this isolate  '}  '
            '${(moved / took).toStringAsFixed(1)} MB/s  ${stalls.stop()}'
            '${load == null ? '' : ', ${load.ran}'}',
          );
          File(target).deleteSync();
        } finally {
          await session.dispose();
        }
      }
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('a real session carries its commands, channels and forwards', () async {
    final key = Platform.environment['SSHBOX_BENCH_KEY'];
    if (key == null) {
      printOnFailure('skipped: set SSHBOX_BENCH_KEY');
      return;
    }
    final session = await IsolateTransport(knownHosts: _TrustAll()).connect(
      host: _benchHost(),
      secrets: _Secrets({
        SecretKeys.privateKey('bench'): File(key).readAsStringSync(),
      }),
      columns: 80,
      rows: 24,
      shell: false,
    );
    try {
      // What the OS probe, the hostname and the tailnet watcher use.
      expect(
        await (session as CommandCapable).run('echo over-the-wire').first,
        'over-the-wire',
      );

      // What tmux's control mode is: bytes both ways on a channel of its own.
      final channel = await (session as ChannelCapable).open('cat');
      final said = channel.output.map(utf8.decode).take(1).toList();
      channel.write(Uint8List.fromList(utf8.encode('through a channel\n')));
      expect((await said).single.trim(), 'through a channel');
      channel.close();

      // What `ssh -L` is, and every database connection with it. The host
      // reaches its own sshd, which says hello first.
      final tunnel = await (session as ForwardCapable).forward('127.0.0.1', 22);
      expect(
        await tunnel.output.map(utf8.decode).first,
        startsWith('SSH-2.0-'),
      );
      await tunnel.input.close();

      // What `ssh -R` is, and the notification port with it: the host listens
      // and hands over what connects there.
      final port = await (session as ForwardCapable).listen('127.0.0.1', 0);
      final knock = port.connections.first;
      final socket = await Socket.connect('127.0.0.1', port.port);
      socket.add(utf8.encode('knock'));
      expect(await (await knock).output.map(utf8.decode).first, 'knock');
      socket.destroy();
      port.close();

      // And a listing, on the same connection as all of it.
      final home = (session as FileBrowseCapable).openFileBrowser();
      expect(await home.resolveHome(), startsWith('/'));
      await home.close();
    } finally {
      await session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}

HostProfile _benchHost() => HostProfile(
      id: 'bench',
      label: 'bench',
      host: _host,
      port: _port,
      username: _user,
      authMethod: SshAuthMethod.privateKey,
    );

/// A frame's worth of work on this isolate, every 16.7 ms: what the transfer
/// used to be taking its turn against.
class _FrameLoad {
  _FrameLoad() {
    _timer = Timer.periodic(const Duration(microseconds: 16667), (_) {
      final spin = Stopwatch()..start();
      while (spin.elapsedMicroseconds < 6000) {
        _burnt += spin.elapsedTicks;
      }
      _frames++;
    });
  }

  late final Timer _timer;
  var _burnt = 0;
  var _frames = 0;

  /// Printed so a run that quietly did no work cannot pass for one that did.
  String get ran => '$_frames frames, $_burnt ticks';

  void stop() => _timer.cancel();
}

/// How long this isolate's event loop went without a turn for anything else.
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

  String stop() {
    _timer?.cancel();
    final gaps = _gaps..sort();
    if (gaps.isEmpty) return 'no turns at all';
    String ms(int us) => (us / 1000).toStringAsFixed(1);
    return 'stall max ${ms(gaps.last)} ms, p99 '
        '${ms(gaps[(gaps.length * 0.99).floor()])} ms, over 16 ms: '
        '${gaps.where((gap) => gap > 16000).length}';
  }
}

class _Secrets implements SecretStore {
  _Secrets(this.values);

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async {}

  @override
  Future<void> purgeHost(String hostId) async {}
}

/// Whatever key the host offers, without shared preferences in the way: this
/// is pointed at an sshd of the runner's own.
class _TrustAll extends KnownHostStore {
  @override
  Future<bool> trust(
    HostProfile host,
    String address,
    String fingerprint,
    Future<bool> Function(HostKeyCheck check)? confirm,
  ) async =>
      true;

  @override
  Future<String?> pinnedKey(String host, int port) async => null;
}
