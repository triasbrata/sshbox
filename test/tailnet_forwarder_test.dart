import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/tailnet_forwarder.dart';
import 'package:sshbox/src/session/terminal_session.dart';

/// A host whose commands the test answers by hand.
class _FakeHost implements CommandCapable {
  final commands = <String>[];
  final outputs = <StreamController<String>>[];
  final cancelled = <String>[];

  @override
  Stream<String> run(String command, {bool pty = false}) {
    commands.add(command);
    final output = StreamController<String>(
      onCancel: () => cancelled.add(command),
    );
    outputs.add(output);
    return output.stream;
  }

  StreamController<String> get watch => outputs.first;

  /// The `tailscale serve` commands run so far.
  List<String> get serves =>
      commands.where((c) => c.startsWith('tailscale serve')).toList();

  StreamController<String> serveOutput(int index) => outputs[index + 1];

  /// One sweep of the watch: rows as /proc/net/tcp writes them, then the
  /// blank line that ends a sweep.
  Future<void> sweep(List<String> rows) async {
    for (final row in rows) {
      watch.add(row);
    }
    watch.add('');
    await pumpEventQueue();
  }
}

// 127.0.0.1:3000, 127.0.0.1:5432, 0.0.0.0:22 and the tailnet's 100.87.127.19:80,
// in /proc/net/tcp's hex.
const _vite = '0100007F:0BB8 1000';
const _postgres = '0100007F:1538 1000';
const _sshd = '00000000:0016 0';
const _tailscaleServe = '137F5764:0050 0';

void main() {
  group('parseListener', () {
    test('reads /proc/net/tcp addresses the way the kernel writes them', () {
      expect(TailnetForwarder.parseListener(_vite),
          (port: 3000, uid: 1000, local: true));
      expect(TailnetForwarder.parseListener(_sshd),
          (port: 22, uid: 0, local: true));
      // Bound to the tailnet address only — where tailscale's own listeners
      // sit, and not something `localhost` reaches.
      expect(TailnetForwarder.parseListener(_tailscaleServe)?.local, isFalse);
      // ::1, and ::ffff:127.0.0.1 from /proc/net/tcp6.
      expect(
        TailnetForwarder.parseListener(
          '00000000000000000000000001000000:1F90 1000',
        ),
        (port: 8080, uid: 1000, local: true),
      );
      expect(
        TailnetForwarder.parseListener(
          '0000000000000000FFFF00000100007F:429F 1000',
        )?.local,
        isTrue,
      );
      expect(TailnetForwarder.parseListener('_encode: command not found'),
          isNull);
    });
  });

  test('a public port is the first free one above, or the one it had', () {
    expect(TailnetForwarder.publicPortFor(3000, {}), 3001);
    expect(TailnetForwarder.publicPortFor(3000, {3001, 3002}), 3003);
    expect(TailnetForwarder.publicPortFor(3000, {3001}, previous: 3007), 3007);
    expect(TailnetForwarder.publicPortFor(3000, {3007}, previous: 3007), 3001);
  });

  test('servedName reads the address off tailscale serve, not the target', () {
    expect(
      TailnetForwarder.servedName('|-- tcp://a.tail1.ts.net:3001\r', 3001),
      'a.tail1.ts.net',
    );
    expect(
      TailnetForwarder.servedName('|--> tcp://localhost:3000', 3001),
      isNull,
    );
  });

  group('TailnetForwarder', () {
    late _FakeHost host;
    late TailnetForwarder forwarder;
    late int changes;

    setUp(() {
      host = _FakeHost();
      changes = 0;
      forwarder = TailnetForwarder(onChanged: () => changes++);
      forwarder.start(host);
    });

    Future<void> connect(List<String> rows) async {
      // The login shell may say things before the script does.
      host.watch.add('_encode: command not found');
      host.watch.add('1000');
      await host.sweep(rows);
    }

    test('forwards a server started in the session, and only that', () async {
      await connect([_sshd, _postgres, _tailscaleServe]);
      expect(host.serves, isEmpty, reason: 'all of these were already up');

      await host.sweep([_sshd, _postgres, _tailscaleServe, _vite]);
      expect(host.serves, ['tailscale serve --tcp 3001 tcp://localhost:3000']);
      expect(forwarder.forwards.single.address, isNull);

      host.serveOutput(0)
        ..add('Available within your tailnet:')
        ..add('|-- tcp://a.tail1.ts.net:3001')
        ..add('|--> tcp://localhost:3000');
      await pumpEventQueue();
      expect(forwarder.forwards.single.address, 'a.tail1.ts.net:3001');

      // vite stops: its forward goes with it.
      await host.sweep([_sshd, _postgres]);
      expect(forwarder.forwards, isEmpty);
      expect(host.cancelled, contains(host.serves.single));
      expect(changes, greaterThan(0));
    });

    test('skips a public port something already listens on', () async {
      await connect([]);
      // Someone else's server on 3001 (any uid, any address) takes it.
      await host.sweep([_vite, '00000000:0BB9 0']);
      expect(host.serves.single, contains('--tcp 3002 '));
    });

    test('a refused forward shows why and is not retried every sweep',
        () async {
      await connect([]);
      await host.sweep([_vite]);
      host.serveOutput(0)
        ..add('_encode: command not found')
        ..add('sending serve config: Access denied: serve config denied')
        ..add("Use 'sudo tailscale serve --tcp 3001 tcp://localhost:3000'.")
        ..add("To not require root, use 'sudo tailscale set --operator=\$USER' once.");
      await host.serveOutput(0).close();
      await pumpEventQueue();

      final forward = forwarder.forwards.single;
      expect(forward.address, isNull);
      expect(forward.error, startsWith('sending serve config: Access denied'));
      expect(forward.error, isNot(contains('_encode')));

      await host.sweep([_vite]);
      await host.sweep([_vite]);
      expect(host.serves, hasLength(1));
    });

    test('says why when the host cannot watch for servers', () async {
      host.watch.add('tailscale is not installed on this host');
      await host.watch.close();
      await pumpEventQueue();
      expect(forwarder.problem, 'tailscale is not installed on this host');
    });

    test('a dropped connection is not reported as the host\'s problem',
        () async {
      await connect([]);
      await host.watch.close();
      await pumpEventQueue();
      expect(forwarder.problem, isNull);
    });

    test('after a reconnect a server already running is forwarded again, '
        'at the address it had', () async {
      await connect([]);
      await host.sweep(['00000000:0BB9 0', _vite]); // 3001 taken → 3002
      expect(host.serves.single, contains('--tcp 3002 '));

      forwarder.stop();
      expect(host.cancelled, hasLength(2), reason: 'the watch and the serve');

      final again = _FakeHost();
      forwarder.start(again);
      again.watch.add('1000');
      await again.sweep([_vite]); // 3002 is free again, and 3001 now too
      expect(again.serves, ['tailscale serve --tcp 3002 tcp://localhost:3000']);
    });
  });

  test('two sessions on one host forward a server once', () async {
    const box = HostProfile(
      id: 'box',
      label: 'box',
      host: 'a.tail1.ts.net',
      username: 'me',
      forwardPorts: true,
    );
    final manager = SessionManager();
    final first = manager.open(box);
    final second = manager.open(box);
    final firstHost = _FakeHost();
    final secondHost = _FakeHost();
    first.forwarder.start(firstHost);
    second.forwarder.start(secondHost);

    for (final host in [firstHost, secondHost]) {
      host.watch.add('1000');
      await host.sweep([]);
    }
    await firstHost.sweep([_vite]);
    await secondHost.sweep([_vite]);

    expect(firstHost.serves, hasLength(1));
    expect(secondHost.serves, isEmpty);

    // The tab that forwarded it closes: the other one takes over.
    await manager.close(first.id);
    await secondHost.sweep([_vite]);
    expect(secondHost.serves, hasLength(1));
  });
}
