import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../data/host_repository.dart';
import '../data/known_host_store.dart';
import '../data/secret_store.dart';
import '../files/file_browser.dart';
import '../files/sftp_file_browser.dart';
import '../models/host_profile.dart';
import 'terminal_session.dart';

/// The SSH implementation of [SessionTransport].
///
/// `dartssh2` is imported here and in `files/sftp_file_browser.dart`, and
/// nowhere else. Both are SSH implementations of an interface the rest of the
/// app is written against, which is what makes a future mosh transport — or a
/// daemon behind a port forward — a drop-in rather than a rewrite.
class Dartssh2Transport implements SessionTransport {
  Dartssh2Transport({
    KnownHostStore? knownHosts,
    this.confirmHostKey,
    this.onAuthBanner,
  }) : _knownHosts = knownHosts ?? KnownHostStore();

  final KnownHostStore _knownHosts;

  /// Asked when a host's key is not the one pinned for it — the first
  /// connect, or a key that has changed — so the user decides rather than
  /// the app trusting a stranger silently. Left out, such a key is refused.
  final Future<bool> Function(HostKeyCheck check)? confirmHostKey;

  /// Text the server sent during authentication. Tailscale SSH puts its
  /// "visit this URL" check in here.
  final void Function(String banner)? onAuthBanner;

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
    final session = _Dartssh2Session(_knownHosts, confirmHostKey, onAuthBanner)
      .._environment = environment;
    await session._open(
      host: host,
      secrets: secrets,
      columns: columns,
      rows: rows,
      shell: shell,
      beforeShell: beforeShell,
    );
    return session;
  }
}

/// The jump hosts [host] is reached through, from [hosts], the one dialled
/// directly first. Empty when [host] has none.
@visibleForTesting
List<HostProfile> jumpChain(HostProfile host, List<HostProfile> hosts) {
  final chain = <HostProfile>[];
  var hop = host;
  while (hop.jumpHostId.isNotEmpty) {
    final jump = hosts.where((saved) => saved.id == hop.jumpHostId).firstOrNull;
    if (jump == null) {
      throw SshSessionException(
        'The jump host of ${hop.displayName} was deleted. Edit it and pick '
        'another.',
      );
    }
    if (jump.id == host.id || chain.any((seen) => seen.id == jump.id)) {
      throw SshSessionException(
        'The jump hosts go round in a loop at ${jump.displayName}. Edit one '
        'of them and pick another.',
      );
    }
    chain.insert(0, jump);
    hop = jump;
  }
  return chain;
}

class _Dartssh2Session
    implements
        TerminalSession,
        FileUploadCapable,
        FileBrowseCapable,
        CommandCapable,
        ChannelCapable,
        ForwardCapable {
  _Dartssh2Session(
    this._knownHosts,
    this._confirmHostKey,
    this._onAuthBannerReceived,
  );

  final KnownHostStore _knownHosts;
  final Future<bool> Function(HostKeyCheck check)? _confirmHostKey;
  final void Function(String banner)? _onAuthBannerReceived;

  final _output = StreamController<String>.broadcast();
  final _status = ValueNotifier(SessionStatus.connecting);
  final _subscriptions = <StreamSubscription<Object?>>[];

  SSHClient? _client;

  /// The jump hosts [_client] is tunnelled through, first dialled first.
  final _jumps = <SSHClient>[];
  SSHSession? _shell;

  /// Sent with the shell and with each command [open] starts: see
  /// [SessionTransport.connect]. Emptied once the host has refused it.
  Map<String, String> _environment = const {};
  String? _failure;
  bool _disposed = false;

  /// Set when we reject the server's key, so the generic handshake failure
  /// that follows can be reported as the security event it actually is.
  String? _hostKeyRefused;

  @override
  Stream<String> get output => _output.stream;

  @override
  ValueListenable<SessionStatus> get status => _status;

  @override
  String? get failure => _failure;

  Future<void> _open({
    required HostProfile host,
    required SecretStore secrets,
    required int columns,
    required int rows,
    required bool shell,
    Future<Map<String, String>> Function(ForwardCapable host)? beforeShell,
  }) async {
    // The host being signed in to, so a failure on a jump host says so.
    var hop = host;
    try {
      final chain = [
        if (host.jumpHostId.isNotEmpty)
          ...jumpChain(host, await HostRepository(secrets).load()),
        host,
      ];

      hop = chain.first;
      var client = await _login(
        hop,
        secrets,
        () async => _PacedSocket(
          await SSHSocket.connect(
            hop.host,
            hop.port,
            timeout: const Duration(seconds: 15),
          ),
        ),
      );
      for (final next in chain.skip(1)) {
        final jump = client;
        _jumps.add(jump);
        await jump.authenticated;
        hop = next;
        client = await _login(
          next,
          secrets,
          () => jump
              .forwardLocal(next.host, next.port)
              .timeout(const Duration(seconds: 15)),
        );
      }
      _client = client;
      // What opening a shell would otherwise wait out, and fail on.
      await client.authenticated;
      if (beforeShell != null) {
        _environment = {..._environment, ...await beforeShell(this)};
      }

      if (!shell) {
        unawaited(
          _client!.done.catchError((Object _) {}).whenComplete(_markClosed),
        );
        _status.value = SessionStatus.connected;
        return;
      }

      _shell = await _withEnvironment(
        (environment) => _client!.shell(
          pty: SSHPtyConfig(width: columns, height: rows),
          environment: environment,
        ),
      );

      // One decoder bound per stream. Multi-byte runes are routinely split
      // across TCP reads, so decoding each chunk independently would corrupt
      // any non-ASCII output. `bind` keeps the decoder's carry-over state.
      const decoder = Utf8Decoder(allowMalformed: true);
      _subscriptions.add(decoder.bind(_shell!.stdout).listen(_emit));
      _subscriptions.add(decoder.bind(_shell!.stderr).listen(_emit));

      unawaited(_shell!.done.whenComplete(_markClosed));

      _status.value = SessionStatus.connected;
    } catch (error) {
      final problem = _describe(error);
      _failure = hop == host ? problem : 'Through ${hop.displayName}: $problem';
      await _teardown();
      _status.value = SessionStatus.failed;
      throw SshSessionException(_failure!);
    }
  }

  /// Signs in to [host] over the connection [dial] opens: straight to it, or
  /// through the jump host before it. Its credentials are read before
  /// dialling, so a host with nothing stored fails without a connection
  /// left open.
  Future<SSHClient> _login(
    HostProfile host,
    SecretStore secrets,
    Future<SSHSocket> Function() dial,
  ) async {
    final identities = await _loadIdentities(host, secrets);
    final password = await _loadPassword(host, secrets);
    final isTailscale = host.authMethod == SshAuthMethod.tailscale;

    return SSHClient(
      await dial(),
      username: host.username,
      identities: identities,
      // Offer nothing for Tailscale SSH. dartssh2 always appends `none` as
      // the last method to try, so with no others configured that is the
      // only one attempted — which is what tailscaled expects. Anything else
      // would be tried first and rejected before we ever got there.
      onPasswordRequest: isTailscale ? null : () => password,
      onUserauthBanner: _onAuthBanner,
      // The check is completed in a browser by a human, so the usual auth
      // deadline is far too short.
      authTimeout: isTailscale ? const Duration(minutes: 5) : null,
      onVerifyHostKey: (type, fingerprint) =>
          _verifyHostKey(host, utf8.decode(fingerprint)),
      // OpenSSH's own order. dartssh2 puts AES-GCM first, and pointycastle's
      // GCM runs about 1.3 MB/s, some 30 times slower than ChaCha20 or
      // AES-CTR, all of it on the UI isolate: a 70 MB download held it for
      // a minute and Android called the app not responding.
      algorithms: const SSHAlgorithms(
        cipher: [
          SSHCipherType.chacha20poly1305,
          SSHCipherType.aes128ctr,
          SSHCipherType.aes256ctr,
          SSHCipherType.aes128gcm,
          SSHCipherType.aes256gcm,
        ],
      ),
    );
  }

  /// Servers can send text during authentication. Tailscale SSH uses it to
  /// hand over the URL a user has to visit before the session is allowed, so
  /// this is where that link surfaces.
  void _onAuthBanner(String banner) {
    _onAuthBannerReceived?.call(banner);
  }

  /// Runs before authentication, so a refused key costs no credential.
  Future<bool> _verifyHostKey(HostProfile host, String fingerprint) async {
    if (await _knownHosts.trust(host, fingerprint, _confirmHostKey)) {
      return true;
    }
    _hostKeyRefused = await _knownHosts.pinnedKey(host.host, host.port) == null
        ? 'The host key was not trusted, so nothing was sent to the host.'
        : 'Host key changed since the last connection. This can mean the '
            'server was rebuilt — or that something is intercepting the '
            'connection. Replace the pinned key only if you know why it '
            'changed.';
    return false;
  }

  /// Read once, up front, so a host with nothing stored fails immediately.
  ///
  /// Handing back an empty string from `onPasswordRequest` instead makes the
  /// server prompt again and again until the auth timeout — the UI just spins
  /// for a minute and then gives a vague error.
  Future<String> _loadPassword(HostProfile host, SecretStore secrets) async {
    if (host.authMethod != SshAuthMethod.password) return '';

    final password = await secrets.read(SecretKeys.password(host.id));
    if (password == null || password.isEmpty) {
      throw const SshSessionException(
        'No password saved for this host. Edit it and enter one.',
      );
    }
    return password;
  }

  Future<List<SSHKeyPair>> _loadIdentities(
    HostProfile host,
    SecretStore secrets,
  ) async {
    if (host.authMethod != SshAuthMethod.privateKey) return const [];

    final pem = await secrets.read(SecretKeys.privateKey(host.id));
    if (pem == null || pem.trim().isEmpty) {
      throw const SshSessionException(
        'This host is set to key authentication but no private key is stored.',
      );
    }

    final passphrase = await secrets.read(SecretKeys.passphrase(host.id));
    return SSHKeyPair.fromPem(pem, passphrase);
  }

  /// Starts a session channel with [_environment], or without it once the
  /// host has refused it. sshd takes only the names its `AcceptEnv` lists,
  /// and dartssh2 fails the whole channel over a refused one where `ssh(1)`
  /// carries on, so the channel is started again without them, and the rest
  /// of this connection stops asking.
  Future<SSHSession> _withEnvironment(
    Future<SSHSession> Function(Map<String, String>? environment) start,
  ) async {
    if (_environment.isEmpty) return start(null);
    try {
      return await start(_environment);
    } on SSHChannelRequestError {
      _environment = const {};
      return start(null);
    }
  }

  void _emit(String data) {
    if (_output.isClosed) return;
    _output.add(data);
  }

  void _markClosed() {
    if (_disposed || _status.value == SessionStatus.failed) return;
    _status.value = SessionStatus.closed;
  }

  @override
  void send(String data) {
    final shell = _shell;
    if (shell == null || _status.value != SessionStatus.connected) return;
    shell.write(Uint8List.fromList(utf8.encode(data)));
  }

  @override
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) {
    final shell = _shell;
    if (shell == null || _status.value != SessionStatus.connected) return;
    // A zero dimension makes dartssh2 throw; a mid-rotation layout pass can
    // legitimately report one.
    if (columns <= 0 || rows <= 0) return;
    shell.resizeTerminal(columns, rows, pixelWidth, pixelHeight);
  }

  @override
  FileBrowser openFileBrowser() {
    final client = _client;
    if (client == null || _status.value != SessionStatus.connected) {
      throw const SshSessionException('Not connected.');
    }
    return SftpFileBrowser(client);
  }

  /// One exec channel per command, on the connection the shell already holds.
  @override
  Stream<String> run(String command, {bool pty = false}) async* {
    final client = _client;
    if (client == null || _status.value != SessionStatus.connected) {
      throw const SshSessionException('Not connected.');
    }
    final session = await client.execute(
      command,
      pty: pty ? const SSHPtyConfig() : null,
    );
    try {
      const decoder = Utf8Decoder(allowMalformed: true);
      yield* const LineSplitter().bind(decoder.bind(session.stdout));
    } finally {
      // Reached on cancellation too. `destroy` rather than `close`: dartssh2's
      // close only sends EOF and waits for the far end to finish, which a
      // command that never reads its stdin never does. Destroying sends the
      // close outright, and sshd hangs up what it was running.
      session.channel.destroy();
    }
  }

  /// An exec channel with no pty, and the environment the shell would have
  /// had, closed with `destroy` for the same reason [run]'s is.
  @override
  Future<CommandChannel> open(String command) async {
    final client = _client;
    if (client == null || _status.value != SessionStatus.connected) {
      throw const SshSessionException('Not connected.');
    }
    final session = await _withEnvironment(
      (environment) => client.execute(command, environment: environment),
    );
    return (
      output: session.stdout,
      write: session.write,
      close: session.channel.destroy,
    );
  }

  /// A direct-tcpip channel on the connection the shell holds — through the
  /// jump hosts too, when there are some, as the shell is.
  @override
  Future<Tunnel> forward(String host, int port) async {
    final client = _client;
    if (client == null || _status.value != SessionStatus.connected) {
      throw const SshSessionException('Not connected.');
    }
    try {
      final channel = await client.forwardLocal(host, port);
      return (output: channel.stream, input: channel.sink);
    } on SSHChannelOpenError catch (error) {
      throw SshSessionException(error.description);
    }
  }

  /// A tcpip-forward on the connection the shell holds. Its channels come
  /// only from the port asked for, or the one the host picked for port 0:
  /// dartssh2 refuses any other.
  ///
  /// While connecting too: a shell's notification port is asked for before
  /// the shell starts — see [SessionTransport.connect]'s `beforeShell`.
  @override
  Future<RemotePort> listen(String host, int port) async {
    final client = _client;
    if (client == null || _status.value == SessionStatus.closed) {
      throw const SshSessionException('Not connected.');
    }
    final forward = await client.forwardRemote(host: host, port: port);
    if (forward == null) {
      throw const SshSessionException(
        'The host refused to open it: the port may be in use, below 1024 '
        'without root, or port forwarding is off in its sshd.',
      );
    }
    return (
      port: forward.port,
      connections: forward.connections.map(
        (channel) => (output: channel.stream, input: channel.sink),
      ),
      // Not forward.close, which leaves its cancel failing unhandled once the
      // connection has gone — and a connection going cancels it anyway.
      close: () => client.cancelForwardRemote(forward).ignore(),
    );
  }

  /// Everything lands in `/tmp`, named after the file the user picked.
  ///
  /// The name is scrubbed down to a safe character set: it arrives from
  /// Android's picker and would otherwise be free to contain path separators
  /// or shell metacharacters, both of which end badly when the result is
  /// pasted into a command line.
  static String _remotePathFor(String fileName) {
    final base = fileName.split('/').last.split(r'\').last;
    final safe = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return '/tmp/${safe.isEmpty ? 'upload' : safe}';
  }

  @override
  Future<String> uploadToTmp({
    required String localPath,
    required String fileName,
    void Function(int sent, int total)? onProgress,
    Future<void>? cancel,
  }) async {
    final client = _client;
    if (client == null || _status.value != SessionStatus.connected) {
      throw const SshSessionException('Not connected.');
    }

    var remotePath = _remotePathFor(fileName);

    final sftp = await client.sftp();
    try {
      // Exclusive, and 0600 before the bytes go in (see
      // [SftpFileBrowser.sendFile]): /tmp is shared, so a link planted under
      // the name would aim this write at another file, and whatever is left
      // readable there every login on the host can read. An earlier upload of
      // ours under the name is replaced; someone else's, which we cannot
      // remove, makes way for a name nobody can guess.
      Future<SftpFile> create(String path) => sftp.open(
            path,
            mode: SftpFileOpenMode.create |
                SftpFileOpenMode.exclusive |
                SftpFileOpenMode.write,
          );
      SftpFile remote;
      try {
        await sftp.remove(remotePath).catchError((Object _) {});
        remote = await create(remotePath);
      } on SftpStatusError {
        remotePath = '/tmp/${SftpFileBrowser.randomName()}-'
            '${remotePath.substring('/tmp/'.length)}';
        remote = await create(remotePath);
      }
      try {
        await SftpFileBrowser.sendFile(
          remote,
          localPath,
          onProgress: onProgress,
          cancel: cancel,
        );
      } catch (_) {
        // Ours, made just now, and in a sticky /tmp nobody else can have
        // swapped it since: half a file is no use to anyone.
        await sftp.remove(remotePath).catchError((Object _) {});
        rethrow;
      }
    } finally {
      sftp.close();
    }

    return remotePath;
  }

  Future<void> _teardown() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _shell?.close();
    _client?.close();
    for (final jump in _jumps) {
      jump.close();
    }
    _jumps.clear();
    _shell = null;
    _client = null;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _teardown();
    await _output.close();
    if (_status.value != SessionStatus.failed) {
      _status.value = SessionStatus.closed;
    }
    _status.dispose();
  }

  String _describe(Object error) {
    final refused = _hostKeyRefused;
    if (refused != null) return refused;
    if (error is SshSessionException) return error.message;
    if (error is SSHAuthFailError) {
      return 'Authentication rejected. Check the username and credentials.';
    }
    if (error is SSHAuthAbortError) {
      return 'Authentication was aborted by the server.';
    }
    if (error is SSHKeyDecryptError) {
      return 'Could not decrypt the private key — the passphrase looks wrong.';
    }
    if (error is SSHKeyDecodeError) {
      return 'Could not read the private key. It must be an OpenSSH or PEM key.';
    }
    if (error is SSHChannelOpenError) {
      return 'The jump host cannot reach this host: ${error.description}';
    }
    if (error is TimeoutException) {
      return 'Timed out reaching the host.';
    }
    if (error is SocketException) {
      return 'Cannot reach the host: ${error.message}';
    }
    return error.toString();
  }
}

/// The socket a connection is dialled on, handing dartssh2 what arrives no
/// more than [_piece] at a time, each piece in an event-loop turn of its own.
///
/// dartssh2 decrypts and frames all a socket hands it in one go, on the UI
/// isolate, and a transfer keeps half a megabyte in flight: a read that
/// brought much of it held every frame back until it was through, up to
/// 16 ms on a desktop in JIT, 24 ms in AOT, and several times that on the
/// tablet. A piece at a time is 2 to 4 ms there, and the transfer is no
/// slower for it: see tool/transfer_bench.dart. The hosts behind a jump host
/// are reached through this one socket, so pacing it paces them too.
class _PacedSocket implements SSHSocket {
  _PacedSocket(this._socket);

  final SSHSocket _socket;

  /// One full SSH packet, the most a host sends in one.
  static const _piece = 32 * 1024;

  @override
  late final Stream<Uint8List> stream = _pace(_socket.stream);

  static Stream<Uint8List> _pace(Stream<Uint8List> source) async* {
    await for (final data in source) {
      for (var at = 0; at < data.length; at += _piece) {
        // Between the pieces of one read; the next read is a turn of its own.
        if (at > 0) await Future<void>.delayed(Duration.zero);
        yield Uint8List.sublistView(data, at, min(at + _piece, data.length));
      }
    }
  }

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
