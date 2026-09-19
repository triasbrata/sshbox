import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/data/known_host_store.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/files/file_browser.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/isolate_transport.dart';
import 'package:sshbox/src/session/terminal_session.dart';

/// Drives [IsolateTransport]'s wire with a session that is this file's rather
/// than SSH's, so everything the protocol has to carry can be checked without
/// a host: the terminal both ways, a command's output, a channel's bytes, a
/// remote port's connections, the file browser's listings and failures, a
/// transfer's progress and its cancel, and the calls that come back the other
/// way for a credential and a host key.
///
/// The isolate is real, which is the whole point: everything asserted here
/// had to cross a port to be asserted.
void main() {
  test('carries a session over the wire, both ways', () async {
    final asked = <String>[];
    final transport = IsolateTransport(
      knownHosts: _NoKnownHosts(),
      entryPoint: fakeSessionIsolate,
      onAuthBanner: asked.add,
    );

    final session = await transport.connect(
      host: _host,
      secrets: _Secrets({'sshbox.password.probe': 'hunter2'}),
      columns: 80,
      rows: 24,
      environment: const {'LC_TEST': 'yes'},
      beforeShell: (connection) async {
        // Runs while the far side is still connecting, and reaches back into
        // it: the port it opens has to work before there is a session.
        final port = await connection.listen('127.0.0.1', 0);
        return {'LC_PORT': '${port.port}'};
      },
    );
    addTearDown(session.dispose);

    expect(session.status.value, SessionStatus.connected);

    final said = <String>[];
    session.output.listen(said.add);

    // The credential was read here and used there; the environment and the
    // port opened by `beforeShell` came back the same way.
    await _settle();
    expect(said.join(), contains('secret=hunter2'));
    expect(said.join(), contains('LC_TEST=yes'));
    expect(said.join(), contains('LC_PORT=4242'));
    expect(asked, ['visit https://example.test/auth']);

    // Keystrokes out, echo back.
    session.send('hello');
    await _settle();
    expect(said.join(), contains('>hello'));

    // A command's output, a line at a time.
    expect(
      await (session as CommandCapable).run('lines').toList(),
      ['one', 'two', 'three'],
    );

    // A channel's bytes, both ways.
    final channel = await (session as ChannelCapable).open('echo');
    final heard = channel.output.map(utf8.decode).take(1).toList();
    channel.write(Uint8List.fromList(utf8.encode('ping')));
    expect(await heard, ['PING']);
    channel.close();

    // A terminal channel, likewise, its size carried across as well.
    final terminal = await (session as TerminalChannelCapable).openTerminal(
      'tui',
      columns: 100,
      rows: 30,
    );
    final drawn = terminal.output.map(utf8.decode).take(1).toList();
    terminal.write(Uint8List.fromList(utf8.encode('key')));
    expect(await drawn, ['tui 100x30: key']);
    terminal.close();

    // A forwarded connection, likewise, through a sink.
    final tunnel = await (session as ForwardCapable).forward('db', 5432);
    final back = tunnel.output.map(utf8.decode).take(1).toList();
    tunnel.input.add(utf8.encode('query'));
    expect(await back, ['QUERY']);
    await tunnel.input.close();

    // A remote port and the connection that arrives on it.
    final port = await (session as ForwardCapable).listen('127.0.0.1', 0);
    expect(port.port, 4242);
    final arrived = await port.connections.first;
    expect(await arrived.output.map(utf8.decode).first, 'knock');
    port.close();
  });

  test('carries a file browser, its failures and its transfers', () async {
    final session = await _connect();
    addTearDown(session.dispose);
    final browser = (session as FileBrowseCapable).openFileBrowser();

    // Data classes cross whole, DateTime and enum and all.
    final listed = await browser.list('/home');
    expect(listed.map((entry) => entry.name), ['bin', 'notes.txt']);
    expect(listed.first.kind, RemoteEntryKind.directory);
    expect(listed.last.size, 12);
    expect(listed.last.modified, DateTime.utc(2026, 9, 16));

    // A failure crosses as itself, so `on FileBrowserException` and its
    // fault still work on this side.
    await expectLater(
      browser.stat('/missing'),
      throwsA(
        isA<FileBrowserException>()
            .having((e) => e.fault, 'fault', FileBrowserFault.notFound),
      ),
    );

    // Progress arrives as it happens and the call ends when the work does.
    final progress = <(int, int)>[];
    await browser.download(
      '/home/notes.txt',
      '/tmp/notes.txt',
      onProgress: (received, total) => progress.add((received, total)),
    );
    expect(progress, [(4, 12), (8, 12), (12, 12)]);

    // A stretch of a file, as a pane's record is read from its end.
    var end = 0;
    await browser.download(
      '/home/notes.txt',
      '/tmp/notes.txt',
      offset: 3,
      length: 7,
      onProgress: (_, total) => end = total,
    );
    expect(end, 10);

    // Cancel stops it part way and raises the cancelled failure here.
    final stop = Completer<void>();
    final cancelled = browser.download(
      '/home/slow',
      '/tmp/slow',
      onProgress: (received, _) {
        if (received >= 4 && !stop.isCompleted) stop.complete();
      },
      cancel: stop.future,
    );
    await expectLater(
      cancelled,
      throwsA(
        isA<FileBrowserException>()
            .having((e) => e.fault, 'fault', FileBrowserFault.cancelled),
      ),
    );

    await browser.close();
  });

  test('the far side does the work, not this isolate', () async {
    final session = await _connect();
    addTearDown(session.dispose);

    // The fake burns half a second of CPU before it answers, which is what a
    // transfer's decryption and framing did on the UI isolate. Before the
    // transport moved, that half second was this isolate's and every frame
    // in it was missed. The gap meter below is what a frame would have
    // waited.
    final gaps = <int>[];
    final clock = Stopwatch()..start();
    var last = 0;
    final meter = Timer.periodic(const Duration(milliseconds: 1), (_) {
      final now = clock.elapsedMicroseconds;
      gaps.add(now - last);
      last = now;
    });

    final answer = await (session as CommandCapable).run('burn 500').toList();
    meter.cancel();

    expect(answer, ['burnt']);
    expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(450));
    gaps.sort();
    // Generous: this runs on a loaded machine. The point is the difference
    // between tens of milliseconds and the five hundred the work took.
    expect(gaps.last, lessThan(100000));
  });

  test('an isolate that dies takes the session down with it', () async {
    final session = await _connect();
    expect(session.status.value, SessionStatus.connected);

    // `die` makes the far side throw where nothing catches it, which kills
    // the isolate: a connection that goes away without saying goodbye.
    unawaited((session as CommandCapable).run('die').toList().catchError(
          (Object _) => <String>[],
        ));

    await _until(() => session.status.value != SessionStatus.connected);
    expect(session.status.value, SessionStatus.closed);

    // Everything asked of it afterwards fails rather than waiting for ever.
    await expectLater(
      (session as ChannelCapable).open('echo'),
      throwsA(isA<SshSessionException>()),
    );
    await session.dispose();
  });
}

Future<TerminalSession> _connect() => IsolateTransport(
      knownHosts: _NoKnownHosts(),
      entryPoint: fakeSessionIsolate,
    ).connect(
      host: _host,
      secrets: _Secrets(const {}),
      columns: 80,
      rows: 24,
    );

const _host = HostProfile(
  id: 'probe',
  label: 'fake',
  host: '127.0.0.1',
  port: 22,
  username: 'nobody',
);

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
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

/// Nothing is pinned and nothing asks: the fake never offers a host key.
class _NoKnownHosts extends KnownHostStore {
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

// ---------------------------------------------------------------------------
// Everything below runs on the session's isolate.
// ---------------------------------------------------------------------------

/// The isolate the tests drive: the wire and the server are the app's, the
/// session behind them is this file's. Top-level because an isolate is
/// spawned with a function, never with a closure.
void fakeSessionIsolate(SendPort toProxy) => runSessionIsolate(
      toProxy,
      transport: ({
        required knownHosts,
        required confirmHostKey,
        required onAuthBanner,
        required onNotice,
        required loadHosts,
      }) =>
          _FakeTransport(onAuthBanner),
    );

class _FakeTransport implements SessionTransport {
  _FakeTransport(this._banner);

  final void Function(String banner)? _banner;

  @override
  Future<TerminalSession> connect({
    required HostProfile host,
    required SecretStore secrets,
    required int columns,
    required int rows,
    bool shell = true,
    Map<String, String> environment = const {},
    Future<Map<String, String>> Function(ForwardCapable host)? beforeShell,
  }) async {
    final session = _FakeSession();
    _banner?.call('visit https://example.test/auth');
    final secret = await secrets.read('sshbox.password.probe');
    final extra = await beforeShell?.call(session) ?? const {};
    session.start({...environment, ...extra}, secret);
    return session;
  }
}

class _FakeSession
    implements
        TerminalSession,
        FileUploadCapable,
        FileBrowseCapable,
        CommandCapable,
        ChannelCapable,
        TerminalChannelCapable,
        ForwardCapable {
  final _output = StreamController<String>.broadcast();
  final _status = ValueNotifier(SessionStatus.connecting);

  void start(Map<String, String> environment, String? secret) {
    _status.value = SessionStatus.connected;
    scheduleMicrotask(() {
      _output.add('secret=$secret\n');
      for (final MapEntry(:key, :value) in environment.entries) {
        _output.add('$key=$value\n');
      }
    });
  }

  @override
  Stream<String> get output => _output.stream;

  @override
  ValueListenable<SessionStatus> get status => _status;

  @override
  String? get failure => null;

  @override
  void send(String data) => _output.add('>$data');

  @override
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) {}

  @override
  Stream<String> run(String command, {bool pty = false}) async* {
    if (command == 'lines') {
      yield* Stream.fromIterable(['one', 'two', 'three']);
      return;
    }
    if (command.startsWith('burn ')) {
      final spin = Stopwatch()..start();
      final until = int.parse(command.split(' ').last);
      // Deliberately synchronous: an event loop given no chance to run, which
      // is what a packet being decrypted and framed is.
      while (spin.elapsedMilliseconds < until) {}
      yield 'burnt';
      return;
    }
    if (command == 'die') {
      Isolate.current.kill(priority: Isolate.immediate);
    }
  }

  @override
  Future<CommandChannel> open(String command) async {
    final back = StreamController<Uint8List>();
    return (
      output: back.stream,
      write: (Uint8List data) =>
          back.add(Uint8List.fromList(utf8.encode(utf8.decode(data).toUpperCase()))),
      close: back.close,
    );
  }

  @override
  Future<CommandChannel> openTerminal(
    String command, {
    int columns = 120,
    int rows = 40,
  }) async {
    final back = StreamController<Uint8List>();
    return (
      output: back.stream,
      write: (Uint8List data) => back.add(
        Uint8List.fromList(
          utf8.encode('$command ${columns}x$rows: ${utf8.decode(data)}'),
        ),
      ),
      close: back.close,
    );
  }

  @override
  Future<Tunnel> forward(String host, int port) async {
    final back = StreamController<Uint8List>();
    return (
      output: back.stream,
      input: _Upper(back),
    );
  }

  @override
  Future<RemotePort> listen(String host, int port) async {
    final knocks = StreamController<Tunnel>();
    scheduleMicrotask(() {
      final one = StreamController<Uint8List>();
      knocks.add((output: one.stream, input: _Upper(one)));
      one.add(Uint8List.fromList(utf8.encode('knock')));
    });
    return (port: 4242, connections: knocks.stream, close: knocks.close);
  }

  @override
  FileBrowser openFileBrowser() => _FakeBrowser();

  @override
  Future<String> uploadToTmp({
    required String localPath,
    required String fileName,
    void Function(int sent, int total)? onProgress,
    Future<void>? cancel,
  }) async {
    onProgress?.call(1, 1);
    return '/tmp/$fileName';
  }

  @override
  Future<void> dispose() async {
    await _output.close();
    _status.dispose();
  }
}

/// A sink that hands back what it is given, shouted.
class _Upper implements StreamSink<List<int>> {
  _Upper(this._back);

  final StreamController<Uint8List> _back;
  final _done = Completer<void>();

  @override
  void add(List<int> data) => _back.add(
        Uint8List.fromList(utf8.encode(utf8.decode(data).toUpperCase())),
      );

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
    await _back.close();
  }

  @override
  Future<void> get done => _done.future;
}

class _FakeBrowser implements FileBrowser {
  @override
  Future<List<RemoteEntry>> list(String path) async => [
        const RemoteEntry(
          name: 'bin',
          path: '/home/bin',
          kind: RemoteEntryKind.directory,
        ),
        RemoteEntry(
          name: 'notes.txt',
          path: '/home/notes.txt',
          kind: RemoteEntryKind.file,
          size: 12,
          modified: DateTime.utc(2026, 9, 16),
        ),
      ];

  @override
  Future<RemoteEntryKind?> stat(String path) async => throw const
      FileBrowserException('Not there.', fault: FileBrowserFault.notFound);

  @override
  Future<void> download(
    String path,
    String localPath, {
    int offset = 0,
    int? length,
    void Function(int received, int total)? onProgress,
    Future<void>? cancel,
  }) async {
    var stopped = false;
    unawaited(cancel?.then((_) => stopped = true));
    for (var received = 4; received <= 12; received += 4) {
      if (stopped) throw FileBrowserException.cancelled;
      // Where a stretch would end, so a test sees that both crossed.
      onProgress?.call(received, offset + (length ?? 12));
      if (path == '/home/slow') {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    if (stopped) throw FileBrowserException.cancelled;
  }

  @override
  Future<void> close() async {}

  @override
  Future<String> resolveHome() async => '/home';

  @override
  Future<void> delete(String path, {bool recursive = false}) async {}

  @override
  Future<void> makeDirectory(String path) async {}

  @override
  Future<RemoteText> readText(
    String path, {
    int maxBytes = FileBrowser.defaultReadLimit,
  }) async =>
      (text: 'hello', stamp: (modified: null, size: 5));

  @override
  Future<void> rename(String from, String to) async {}

  @override
  Future<void> upload(
    String localPath,
    String path, {
    bool replace = false,
    void Function(int sent, int total)? onProgress,
    Future<void>? cancel,
  }) async {}

  @override
  Future<FileStamp> writeText(
    String path,
    String content, {
    FileStamp? expected,
  }) async =>
      (modified: null, size: content.length);
}
