import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/data/known_host_store.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/dartssh2_transport.dart';
import 'package:sshbox/src/session/isolate_transport.dart';
import 'package:sshbox/src/session/terminal_session.dart';

// What a download costs the isolate the app draws on, measured on the app's
// own transports rather than a copy of them.
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
    final host = HostProfile(
      id: 'bench',
      label: 'bench',
      host: _host,
      port: _port,
      username: _user,
      authMethod: SshAuthMethod.privateKey,
    );

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
}

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
    String fingerprint,
    Future<bool> Function(HostKeyCheck check)? confirm,
  ) async =>
      true;

  @override
  Future<String?> pinnedKey(String host, int port) async => null;
}
