import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../data/host_repository.dart';
import '../data/known_host_store.dart';
import '../data/secret_store.dart';
import '../files/file_browser.dart';
import '../models/host_profile.dart';
import 'dartssh2_transport.dart';
import 'isolate_wire.dart';
import 'terminal_session.dart';

/// The SSH transport, run on an isolate of its own.
///
/// dartssh2 is pure Dart: every packet on a connection is decrypted and
/// framed by whichever isolate holds the client. Holding it on the UI isolate
/// put that work between the app and its next frame, and the pacing that kept
/// the frames coming capped a transfer at what the device could decrypt in a
/// slice of one frame, times the frame rate — about 1.6 MB/s on the tablet in
/// debug and 3.5 in AOT, whatever the link could do. There is no slice to
/// dial that fixes that; the work has to leave the isolate the frame is on.
///
/// So a session's whole [SSHClient] lives on a worker isolate: the socket,
/// the cipher, the framing, SFTP and both ends of every transfer's file
/// copy. What crosses back is what the app actually looks at — the terminal's
/// text, a listing, a progress count, a forwarded connection's bytes — and a
/// download crosses nothing at all, because the local file is written there.
///
/// A cipher's state is one running thing every channel on a connection
/// shares, which is why nothing smaller than the whole client can move: one
/// isolate per connection, and the jump hosts in front of it go with it.
///
/// Two things cannot move, because they need Flutter plugins or the user:
/// reading a credential and ruling on a host key. Those are called back here
/// over the wire — a handful of messages while connecting, none afterwards.
///
/// This is a drop-in for [Dartssh2Transport] behind [SessionTransport], and
/// it runs that class unchanged on the far side.
class IsolateTransport implements SessionTransport {
  IsolateTransport({
    KnownHostStore? knownHosts,
    this.confirmHostKey,
    this.onAuthBanner,
    this.entryPoint = runSessionIsolate,
  }) : _knownHosts = knownHosts ?? KnownHostStore();

  /// What the session's isolate runs. Only a test brings another, to put a
  /// stand-in session behind the same wire.
  @visibleForTesting
  final void Function(SendPort toProxy) entryPoint;

  final KnownHostStore _knownHosts;

  /// Asked when a host's key is not the one pinned for it. It shows a dialog,
  /// so it stays here and the isolate asks for the ruling.
  final Future<bool> Function(HostKeyCheck check)? confirmHostKey;

  final void Function(String banner)? onAuthBanner;

  /// Where a remark about the connection goes — that a host answered at its
  /// alternative address rather than its saved one.
  ///
  /// Static because every connection in the app has one of these, made in
  /// three places (a session, a port forward, a database tunnel), and the one
  /// thing on screen that can speak for all of them is the tab shell, which
  /// sets this the way it sets `portForwards.onNotice`.
  // ponytail: one global sink; a callback per transport if a caller ever
  // needs its own wording.
  static void Function(String message)? onNotice;

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
    final session =
        _ProxySession(_knownHosts, confirmHostKey, onAuthBanner, entryPoint);
    await session.start(
      host: host,
      secrets: secrets,
      columns: columns,
      rows: rows,
      shell: shell,
      environment: environment,
      beforeShell: beforeShell,
    );
    return session;
  }
}

/// Makes the transport the isolate runs. Only a test brings its own; the app
/// always gets SSH.
typedef IsolateTransportMaker = SessionTransport Function({
  required KnownHostStore knownHosts,
  required Future<bool> Function(HostKeyCheck check)? confirmHostKey,
  required void Function(String banner)? onAuthBanner,
  required void Function(String message)? onNotice,
  required Future<List<HostProfile>> Function()? loadHosts,
});

/// A session isolate's entry point: everything below here runs off the UI
/// isolate, with [toProxy] the way back to the [IsolateTransport] that
/// spawned it.
///
/// [transport] is a test's stand-in, made on this side because a closure
/// cannot be spawned with.
void runSessionIsolate(
  SendPort toProxy, {
  IsolateTransportMaker? transport,
}) =>
    _Server(toProxy, transport ?? _ssh).start();

SessionTransport _ssh({
  required KnownHostStore knownHosts,
  required Future<bool> Function(HostKeyCheck check)? confirmHostKey,
  required void Function(String banner)? onAuthBanner,
  required void Function(String message)? onNotice,
  required Future<List<HostProfile>> Function()? loadHosts,
}) =>
    Dartssh2Transport(
      knownHosts: knownHosts,
      confirmHostKey: confirmHostKey,
      onAuthBanner: onAuthBanner,
      onNotice: onNotice,
      loadHosts: loadHosts,
    );

// ---------------------------------------------------------------------------
// The isolate's side.
// ---------------------------------------------------------------------------

class _Server {
  _Server(this._toProxy, this._make);

  final SendPort _toProxy;
  final IsolateTransportMaker _make;

  late final IsolateWire _wire = IsolateWire(_serve);

  /// Terminal output, status changes and sign-in banners, in the order they
  /// happened. Buffered until the proxy listens, which it does before it asks
  /// for a connection, so a banner sent during authentication is not missed.
  final _events = StreamController<Object?>();

  TerminalSession? _session;
  StreamSubscription<String>? _outputs;

  /// The connection while it is being made, before there is a session to hold
  /// it: `beforeShell` opens the notification port on it.
  ForwardCapable? _connecting;

  final _browsers = <int, FileBrowser>{};

  /// Open channels — a command's, a forwarded connection's — by a number of
  /// this side's own. Even, where the proxy's own numbering is odd, so the
  /// two never collide in a message.
  final _channels = <int, Object>{};

  /// What each channel has sent, from the moment it opened: see [_hold].
  final _caught = <int, StreamController<Uint8List>>{};
  var _nextChannel = 0;

  final _listeners = <int, RemotePort>{};
  final _arrivals = <int, StreamController<int>>{};

  void start() {
    _wire.listen();
    _wire.bind(_toProxy);
    _toProxy.send(_wire.inbox.sendPort);
  }

  FutureOr<Object?> _serve(String method, List<Object?> args, int id) async {
    switch (method) {
      case 'events':
        return _events.stream;
      case 'connect':
        return _connect(args);
      case 'send':
        _live().send(args[0]! as String);
        return null;
      case 'resize':
        _live().resize(
          args[0]! as int,
          args[1]! as int,
          args[2]! as int,
          args[3]! as int,
        );
        return null;
      case 'dispose':
        await _dispose();
        return null;

      case 'run':
        return (_live() as CommandCapable)
            .run(args[0]! as String, pty: args[1]! as bool);

      case 'openChannel':
        return _hold(await (_live() as ChannelCapable).open(args[0]! as String));
      case 'openTerminal':
        return _hold(
          await (_live() as TerminalChannelCapable).openTerminal(
            args[0]! as String,
            columns: args[1]! as int,
            rows: args[2]! as int,
          ),
        );
      case 'forward':
        return _hold(
          await _forwards().forward(args[0]! as String, args[1]! as int),
        );
      case 'channelOut':
        return _channelOut(args[0]! as int);
      case 'channelIn':
        return _channelIn(args[0]! as int, args[1]! as Uint8List);
      case 'channelEnd':
        await _channelEnd(args[0]! as int);
        return null;

      case 'listen':
        return _listen(args[0]! as int, args[1]! as String, args[2]! as int);
      case 'arrivals':
        return (_arrivals[args[0]! as int] ??= StreamController<int>()).stream;
      case 'listenClose':
        _listeners.remove(args[0]! as int)?.close();
        await _arrivals.remove(args[0]! as int)?.close();
        return null;

      case 'browser':
        _browsers[args[0]! as int] =
            (_live() as FileBrowseCapable).openFileBrowser();
        return null;
      case 'fb':
        return _file(args[0]! as int, args[1]! as String, args.sublist(2));
      case 'fbMoving':
        return _moving(args[0]! as int, args[1]! as String, args.sublist(2));
      case 'uploadToTmp':
        return _uploadToTmp(args[0]! as String, args[1]! as String);
    }
    throw SshSessionException('The session isolate has no "$method".');
  }

  Future<SessionStatus> _connect(List<Object?> args) async {
    final host = args[0]! as HostProfile;
    final wantsBeforeShell = args[5]! as bool;
    final secrets = _WireSecrets(_wire);
    final transport = _make(
      knownHosts: _WireKnownHosts(_wire),
      confirmHostKey: (check) async => await _wire.call('trust', [
            check.host,
            check.fingerprint,
          ]) as bool,
      onAuthBanner: (banner) => _emit(('banner', banner)),
      onNotice: (message) => _emit(('notice', message)),
      loadHosts: () async =>
          (await _wire.call('hosts', const []) as List).cast<HostProfile>(),
    );

    final session = await transport.connect(
      host: host,
      secrets: secrets,
      columns: args[1]! as int,
      rows: args[2]! as int,
      shell: args[3]! as bool,
      environment: (args[4]! as Map).cast<String, String>(),
      beforeShell: wantsBeforeShell
          ? (connection) async {
              _connecting = connection;
              try {
                final given = await _wire.call('beforeShell', const []);
                return (given! as Map).cast<String, String>();
              } finally {
                _connecting = null;
              }
            }
          : null,
    );

    _session = session;
    _outputs = session.output.listen((text) => _emit(('output', text)));
    // Only changes from here: the status this returns is the one the proxy
    // starts from, so nothing has to race the reply to set it.
    session.status.addListener(() {
      final failure = session.failure;
      if (failure != null) _emit(('failure', failure));
      _emit(('status', session.status.value));
    });
    return session.status.value;
  }

  TerminalSession _live() {
    final session = _session;
    if (session == null) throw const SshSessionException('Not connected.');
    return session;
  }

  ForwardCapable _forwards() {
    final connecting = _connecting;
    if (connecting != null) return connecting;
    return _live() as ForwardCapable;
  }

  void _emit(Object? event) {
    if (_events.isClosed) return;
    _events.add(event);
  }

  /// Files a channel and starts catching what comes out of it at once.
  ///
  /// The proxy asks for those bytes in a second call, a port round trip
  /// later. Whatever the host sent in between — tmux's opening banner, on a
  /// control-mode channel — would be gone by then, so it is caught here: a
  /// controller with nobody listening keeps its events, and once the proxy is
  /// listening its pauses reach the channel through the same controller.
  int _hold(Object channel) {
    final key = _nextChannel += 2;
    _channels[key] = channel;
    final source =
        channel is Tunnel ? channel.output : (channel as CommandChannel).output;
    final caught = StreamController<Uint8List>();
    _caught[key] = caught;
    caught.addStream(source).whenComplete(() {
      if (!caught.isClosed) caught.close();
    });
    return key;
  }

  /// A channel's bytes, as they are rather than as a [TransferableTypedData].
  ///
  /// Transferring would neuter the buffer dartssh2 handed over, which is its
  /// own and may still be a view on something it keeps. Copying 32 KB costs a
  /// few microseconds against the hundreds this change took off the frame,
  /// and the one path that moves real volume — a file transfer — no longer
  /// crosses at all, the local file being written on this side.
  Stream<Object?> _channelOut(int key) {
    final caught = _caught[key];
    if (caught == null) {
      throw const SshSessionException('That channel is closed.');
    }
    return caught.stream;
  }

  Object? _channelIn(int key, Uint8List data) {
    final held = _channels[key];
    if (held is Tunnel) {
      held.input.add(data);
    } else if (held is CommandChannel) {
      held.write(data);
    }
    return null;
  }

  Future<void> _channelEnd(int key) async {
    final held = _channels.remove(key);
    if (held is Tunnel) await held.input.close();
    if (held is CommandChannel) held.close();
    final caught = _caught.remove(key);
    if (caught != null && !caught.isClosed) await caught.close();
  }

  Future<int> _listen(int key, String host, int port) async {
    final opened = await _forwards().listen(host, port);
    _listeners[key] = opened;
    final arrivals = _arrivals[key] ??= StreamController<int>();
    opened.connections.listen(
      (tunnel) {
        if (arrivals.isClosed) return;
        arrivals.add(_hold(tunnel));
      },
      onDone: () {
        if (!arrivals.isClosed) arrivals.close();
      },
    );
    return opened.port;
  }

  FileBrowser _browser(int key) {
    final browser = _browsers[key];
    if (browser == null) {
      throw const FileBrowserException(
        'The file browser was closed.',
        fault: FileBrowserFault.disconnected,
      );
    }
    return browser;
  }

  Future<Object?> _file(int key, String method, List<Object?> a) async {
    final browser = _browser(key);
    switch (method) {
      case 'resolveHome':
        return browser.resolveHome();
      case 'list':
        return browser.list(a[0]! as String);
      case 'stat':
        return browser.stat(a[0]! as String);
      case 'readText':
        return browser.readText(a[0]! as String, maxBytes: a[1]! as int);
      case 'writeText':
        return browser.writeText(
          a[0]! as String,
          a[1]! as String,
          expected: a[2] as FileStamp?,
        );
      case 'rename':
        await browser.rename(a[0]! as String, a[1]! as String);
        return null;
      case 'delete':
        await browser.delete(a[0]! as String, recursive: a[1]! as bool);
        return null;
      case 'makeDirectory':
        await browser.makeDirectory(a[0]! as String);
        return null;
      case 'sudoReadText':
        return (browser as SudoCapable).sudoReadText(
          a[0]! as String,
          password: a[1] as String?,
          maxBytes: a[2]! as int,
        );
      case 'sudoWriteText':
        return (browser as SudoCapable).sudoWriteText(
          a[0]! as String,
          a[1]! as String,
          password: a[2] as String?,
          expected: a[3] as FileStamp?,
        );
      case 'close':
        _browsers.remove(key);
        await browser.close();
        return null;
    }
    throw SshSessionException('The file browser has no "$method".');
  }

  /// The calls that move bytes or arrive a piece at a time, each as one
  /// stream: progress goes over as it happens, the listener cancelling is the
  /// cancel the transfer watches for, and the end of the stream is the end of
  /// the work. One wire stream carries what would otherwise be a call, a
  /// progress channel and a cancel channel.
  Stream<Object?> _moving(int key, String method, List<Object?> a) {
    final browser = _browser(key);
    switch (method) {
      case 'upload':
        return _progressed(
          (onProgress, cancel) async => browser.upload(
            a[0]! as String,
            a[1]! as String,
            replace: a[2]! as bool,
            onProgress: onProgress,
            cancel: cancel,
          ),
        );
      case 'download':
        return _progressed(
          (onProgress, cancel) async => browser.download(
            a[0]! as String,
            a[1]! as String,
            onProgress: onProgress,
            cancel: cancel,
          ),
        );
      case 'search':
        return (browser as FileSearchCapable).search(
          root: a[0]! as String,
          query: a[1]! as String,
        );
    }
    throw SshSessionException('The file browser has no "$method".');
  }

  Stream<Object?> _uploadToTmp(String localPath, String fileName) =>
      _progressed(
        (onProgress, cancel) => (_live() as FileUploadCapable).uploadToTmp(
          localPath: localPath,
          fileName: fileName,
          onProgress: onProgress,
          cancel: cancel,
        ),
      );

  /// [work] as a stream of `(moved, total)` records, ending with whatever it
  /// answered with when that is not null — the remote path, for an upload
  /// into `/tmp`.
  static Stream<Object?> _progressed(
    Future<Object?> Function(
      void Function(int moved, int total) onProgress,
      Future<void> cancel,
    ) work,
  ) {
    final cancelled = Completer<void>();
    late StreamController<Object?> out;
    out = StreamController<Object?>(
      onListen: () async {
        try {
          final answer = await work(
            (moved, total) {
              if (!out.isClosed) out.add((moved, total));
            },
            cancelled.future,
          );
          if (answer != null && !out.isClosed) out.add(answer);
        } catch (error) {
          if (!out.isClosed) out.addError(error);
        }
        if (!out.isClosed) await out.close();
      },
      onCancel: () {
        if (!cancelled.isCompleted) cancelled.complete();
      },
    );
    return out.stream;
  }

  Future<void> _dispose() async {
    for (final listener in _listeners.values) {
      listener.close();
    }
    _listeners.clear();
    for (final arrivals in _arrivals.values) {
      await arrivals.close();
    }
    _arrivals.clear();
    for (final browser in _browsers.values) {
      await browser.close().catchError((Object _) {});
    }
    _browsers.clear();
    _channels.clear();
    for (final caught in _caught.values) {
      if (!caught.isClosed) await caught.close();
    }
    _caught.clear();
    await _outputs?.cancel();
    await _session?.dispose();
    _session = null;
    await _events.close();
  }
}

/// The credentials, read by the isolate that cannot reach the key store —
/// [SecretStore] is a Flutter plugin, and plugins live where the UI is.
class _WireSecrets implements SecretStore {
  _WireSecrets(this._wire);

  final IsolateWire _wire;

  @override
  Future<String?> read(String key) async =>
      await _wire.call('secret', [key]) as String?;

  @override
  Future<void> write(String key, String? value) async =>
      throw UnsupportedError('A session isolate never writes a secret.');

  @override
  Future<void> purgeHost(String hostId) async =>
      throw UnsupportedError('A session isolate never writes a secret.');
}

/// The pinned host keys, likewise: reading them needs shared preferences and
/// pinning a new one needs the user, so both are asked for.
class _WireKnownHosts extends KnownHostStore {
  _WireKnownHosts(this._wire);

  final IsolateWire _wire;

  @override
  Future<bool> trust(
    HostProfile host,
    String address,
    String fingerprint,
    Future<bool> Function(HostKeyCheck check)? confirm,
  ) async =>
      // The far side runs the whole of it, dialog and pinning together: the
      // question and the answer are one round trip rather than three.
      await _wire.call('trust', [host, address, fingerprint]) as bool;

  @override
  Future<String?> pinnedKey(String host, int port) async =>
      await _wire.call('pinned', [host, port]) as String?;
}

// ---------------------------------------------------------------------------
// The UI isolate's side.
// ---------------------------------------------------------------------------

class _ProxySession
    implements
        TerminalSession,
        FileUploadCapable,
        FileBrowseCapable,
        CommandCapable,
        ChannelCapable,
        TerminalChannelCapable,
        ForwardCapable {
  _ProxySession(
    this._knownHosts,
    this._confirmHostKey,
    this._onAuthBanner,
    this._entryPoint,
  );

  final KnownHostStore _knownHosts;
  final Future<bool> Function(HostKeyCheck check)? _confirmHostKey;
  final void Function(String banner)? _onAuthBanner;
  final void Function(SendPort toProxy) _entryPoint;

  late final IsolateWire _wire = IsolateWire(_serve);
  Isolate? _isolate;
  ReceivePort? _obituary;
  StreamSubscription<Object?>? _events;

  final _output = StreamController<String>.broadcast();
  final _status = ValueNotifier(SessionStatus.connecting);
  String? _failure;
  var _disposed = false;

  SecretStore? _secrets;
  Future<Map<String, String>> Function(ForwardCapable host)? _beforeShell;

  /// Odd, where the isolate's own channel numbering is even.
  var _nextKey = -1;
  int get _key => _nextKey += 2;

  @override
  Stream<String> get output => _output.stream;

  @override
  ValueListenable<SessionStatus> get status => _status;

  @override
  String? get failure => _failure;

  Future<void> start({
    required HostProfile host,
    required SecretStore secrets,
    required int columns,
    required int rows,
    required bool shell,
    required Map<String, String> environment,
    Future<Map<String, String>> Function(ForwardCapable host)? beforeShell,
  }) async {
    _secrets = secrets;
    _beforeShell = beforeShell;
    _wire.listen();

    final obituary = _obituary = ReceivePort();
    // An isolate that has gone — killed, or out of memory — is a connection
    // dropped, and everything waiting on it has to hear about it rather than
    // wait for ever. An uncaught error comes down the same port as a pair of
    // strings and is not a death: `errorsAreFatal` is off, so the isolate
    // carries on, exactly as the UI isolate does when dartssh2 throws where
    // nothing was waiting.
    obituary.listen((message) {
      if (message is List) {
        // Said out loud in a debug build only: an isolate that swallows its
        // errors is the worst thing to be handed at three in the morning.
        assert(() {
          debugPrint('session isolate: ${message.first}');
          return true;
        }());
        return;
      }
      _gone();
    });
    _isolate = await Isolate.spawn(
      _entryPoint,
      _wire.inbox.sendPort,
      onExit: obituary.sendPort,
      onError: obituary.sendPort,
      debugName: 'ssh ${host.displayName}',
      errorsAreFatal: false,
    );

    // The connection going away ends this stream with that failure. It is
    // already told through the status, so there is nothing to raise here.
    _events = _wire.stream('events', const []).listen(
      _onEvent,
      onError: (Object _) {},
    );

    try {
      _status.value = await _wire.call('connect', [
        host,
        columns,
        rows,
        shell,
        environment,
        beforeShell != null,
      ]) as SessionStatus;
    } catch (error) {
      _failure ??= '$error';
      _status.value = SessionStatus.failed;
      await _stop();
      throw error is SshSessionException
          ? error
          : SshSessionException('$error');
    }
  }

  /// What the isolate asks of this side: the two things it cannot do, and the
  /// callback that runs while it is connecting.
  FutureOr<Object?> _serve(String method, List<Object?> args, int id) {
    switch (method) {
      case 'secret':
        return _secrets!.read(args[0]! as String);
      case 'hosts':
        return HostRepository(_secrets!).load();
      case 'pinned':
        return _knownHosts.pinnedKey(args[0]! as String, args[1]! as int);
      case 'trust':
        return _knownHosts.trust(
          args[0]! as HostProfile,
          args[1]! as String,
          args[2]! as String,
          _confirmHostKey,
        );
      case 'beforeShell':
        return _beforeShell!(this);
    }
    throw SshSessionException('The session proxy has no "$method".');
  }

  void _onEvent(Object? event) {
    if (_disposed) return;
    switch (event) {
      case ('output', final String text):
        if (!_output.isClosed) _output.add(text);
      case ('status', final SessionStatus status):
        _status.value = status;
      case ('failure', final String problem):
        _failure = problem;
      case ('banner', final String text):
        _onAuthBanner?.call(text);
      case ('notice', final String text):
        IsolateTransport.onNotice?.call(text);
    }
  }

  void _gone() {
    _wire.die(const SshSessionException('The connection went away.'));
    if (_disposed) return;
    if (_status.value == SessionStatus.connected) {
      _status.value = SessionStatus.closed;
    }
  }

  @override
  void send(String data) {
    if (_status.value != SessionStatus.connected) return;
    _wire.call('send', [data]).ignore();
  }

  @override
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) {
    if (_status.value != SessionStatus.connected) return;
    if (columns <= 0 || rows <= 0) return;
    _wire.call('resize', [columns, rows, pixelWidth, pixelHeight]).ignore();
  }

  @override
  Stream<String> run(String command, {bool pty = false}) =>
      _wire.stream('run', [command, pty]).cast<String>();

  @override
  Future<CommandChannel> open(String command) async {
    final key = await _wire.call('openChannel', [command]) as int;
    return (
      output: _wire.stream('channelOut', [key]).cast<Uint8List>(),
      write: (Uint8List data) => _wire.call('channelIn', [key, data]).ignore(),
      close: () => _wire.call('channelEnd', [key]).ignore(),
    );
  }

  @override
  Future<CommandChannel> openTerminal(
    String command, {
    int columns = 120,
    int rows = 40,
  }) async {
    final key =
        await _wire.call('openTerminal', [command, columns, rows]) as int;
    return (
      output: _wire.stream('channelOut', [key]).cast<Uint8List>(),
      write: (Uint8List data) => _wire.call('channelIn', [key, data]).ignore(),
      close: () => _wire.call('channelEnd', [key]).ignore(),
    );
  }

  @override
  Future<Tunnel> forward(String host, int port) async {
    final key = await _wire.call('forward', [host, port]) as int;
    return _tunnel(key);
  }

  Tunnel _tunnel(int key) => (
        output: _wire.stream('channelOut', [key]).cast<Uint8List>(),
        input: _ChannelSink(_wire, key),
      );

  @override
  Future<RemotePort> listen(String host, int port) async {
    final key = _key;
    final opened = await _wire.call('listen', [key, host, port]) as int;
    return (
      port: opened,
      connections:
          _wire.stream('arrivals', [key]).map((id) => _tunnel(id! as int)),
      close: () => _wire.call('listenClose', [key]).ignore(),
    );
  }

  @override
  FileBrowser openFileBrowser() {
    if (_status.value != SessionStatus.connected) {
      throw const SshSessionException('Not connected.');
    }
    return _ProxyBrowser(_wire, _key);
  }

  @override
  Future<String> uploadToTmp({
    required String localPath,
    required String fileName,
    void Function(int sent, int total)? onProgress,
    Future<void>? cancel,
  }) async {
    if (_status.value != SessionStatus.connected) {
      throw const SshSessionException('Not connected.');
    }
    final path = await _moved(
      _wire.stream('uploadToTmp', [localPath, fileName]),
      onProgress,
      cancel,
    );
    return path! as String;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _wire
          .call('dispose', const [])
          .timeout(const Duration(seconds: 5));
    } on Object {
      // A connection already gone, or an isolate that will not answer: it is
      // killed below either way.
    }
    await _stop();
    await _output.close();
    if (_status.value != SessionStatus.failed) {
      _status.value = SessionStatus.closed;
    }
    _status.dispose();
  }

  Future<void> _stop() async {
    await _events?.cancel();
    _events = null;
    _wire.die(const SshSessionException('The session was closed.'));
    _obituary?.close();
    _obituary = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }
}

/// A transfer's progress stream, watched to its end.
///
/// [cancel] completing cancels the subscription, which is what tells the
/// isolate to stop: the failure it raises there is on a stream nobody is
/// listening to any more, so the cancelled error is raised here instead.
Future<Object?> _moved(
  Stream<Object?> moving,
  void Function(int moved, int total)? onProgress,
  Future<void>? cancel,
) async {
  final done = Completer<Object?>();
  Object? last;
  var stopped = false;
  late StreamSubscription<Object?> watching;
  watching = moving.listen(
    (item) {
      if (item is (int, int)) {
        onProgress?.call(item.$1, item.$2);
      } else {
        last = item;
      }
    },
    onError: (Object error) {
      if (!done.isCompleted) done.completeError(error);
    },
    onDone: () {
      if (done.isCompleted) return;
      if (stopped) {
        done.completeError(FileBrowserException.cancelled);
      } else {
        done.complete(last);
      }
    },
    cancelOnError: true,
  );
  unawaited(
    cancel?.then((_) async {
      if (done.isCompleted) return;
      stopped = true;
      await watching.cancel();
      if (!done.isCompleted) done.completeError(FileBrowserException.cancelled);
    }),
  );
  return done.future;
}

/// The writing end of a channel on the other isolate.
class _ChannelSink implements StreamSink<List<int>> {
  _ChannelSink(this._wire, this._key);

  final IsolateWire _wire;
  final int _key;
  final _done = Completer<void>();

  @override
  void add(List<int> data) {
    if (_done.isCompleted) return;
    _wire.call('channelIn', [
      _key,
      data is Uint8List ? data : Uint8List.fromList(data),
    ]).ignore();
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) =>
      stream.forEach(add);

  @override
  Future<void> close() async {
    if (_done.isCompleted) return _done.future;
    _done.complete();
    await _wire.call('channelEnd', [_key]).catchError((Object _) => null);
  }

  @override
  Future<void> get done => _done.future;
}

class _ProxyBrowser implements FileBrowser, FileSearchCapable, SudoCapable {
  _ProxyBrowser(this._wire, this._key) {
    _opened = _wire.call('browser', [_key]);
  }

  final IsolateWire _wire;
  final int _key;

  /// The browser is made over there while this one is handed back here —
  /// [FileBrowser] is opened synchronously, so the first call waits instead.
  late final Future<Object?> _opened;

  Future<Object?> _call(String method, [List<Object?> args = const []]) async {
    await _opened;
    return _wire.call('fb', [_key, method, ...args]);
  }

  Stream<Object?> _moving(String method, List<Object?> args) async* {
    await _opened;
    yield* _wire.stream('fbMoving', [_key, method, ...args]);
  }

  @override
  Future<String> resolveHome() async => await _call('resolveHome') as String;

  @override
  Future<List<RemoteEntry>> list(String path) async =>
      (await _call('list', [path]) as List).cast<RemoteEntry>();

  @override
  Future<RemoteEntryKind?> stat(String path) async =>
      await _call('stat', [path]) as RemoteEntryKind?;

  @override
  Future<RemoteText> readText(
    String path, {
    int maxBytes = FileBrowser.defaultReadLimit,
  }) async =>
      await _call('readText', [path, maxBytes]) as RemoteText;

  @override
  Future<FileStamp> writeText(
    String path,
    String content, {
    FileStamp? expected,
  }) async =>
      await _call('writeText', [path, content, expected]) as FileStamp;

  @override
  Future<void> rename(String from, String to) async =>
      _call('rename', [from, to]);

  @override
  Future<void> delete(String path, {bool recursive = false}) async =>
      _call('delete', [path, recursive]);

  @override
  Future<void> makeDirectory(String path) async =>
      _call('makeDirectory', [path]);

  @override
  Future<void> upload(
    String localPath,
    String path, {
    bool replace = false,
    void Function(int sent, int total)? onProgress,
    Future<void>? cancel,
  }) =>
      _moved(
        _moving('upload', [localPath, path, replace]),
        onProgress,
        cancel,
      );

  @override
  Future<void> download(
    String path,
    String localPath, {
    void Function(int received, int total)? onProgress,
    Future<void>? cancel,
  }) =>
      _moved(_moving('download', [path, localPath]), onProgress, cancel);

  @override
  Stream<SearchHit> search({required String root, required String query}) =>
      _moving('search', [root, query]).cast<SearchHit>();

  @override
  Future<RemoteText> sudoReadText(
    String path, {
    String? password,
    int maxBytes = FileBrowser.defaultReadLimit,
  }) async =>
      await _call('sudoReadText', [path, password, maxBytes]) as RemoteText;

  @override
  Future<FileStamp> sudoWriteText(
    String path,
    String content, {
    String? password,
    FileStamp? expected,
  }) async =>
      await _call('sudoWriteText', [path, content, password, expected])
          as FileStamp;

  @override
  Future<void> close() async {
    try {
      await _call('close');
    } on Object {
      // A session already gone takes its browsers with it.
    }
  }
}
