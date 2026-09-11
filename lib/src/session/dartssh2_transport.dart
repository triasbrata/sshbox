import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
    this.onHostKeyPinned,
    this.onAuthBanner,
  }) : _knownHosts = knownHosts ?? KnownHostStore();

  final KnownHostStore _knownHosts;

  /// Fires when a host key is pinned for the very first time, so the UI can
  /// say so out loud instead of trusting a stranger silently.
  final void Function(String fingerprint)? onHostKeyPinned;

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
  }) async {
    final session =
        _Dartssh2Session(_knownHosts, onHostKeyPinned, onAuthBanner);
    await session._open(
      host: host,
      secrets: secrets,
      columns: columns,
      rows: rows,
      shell: shell,
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
        ChannelCapable {
  _Dartssh2Session(
    this._knownHosts,
    this._onHostKeyPinned,
    this._onAuthBannerReceived,
  );

  final KnownHostStore _knownHosts;
  final void Function(String fingerprint)? _onHostKeyPinned;
  final void Function(String banner)? _onAuthBannerReceived;

  final _output = StreamController<String>.broadcast();
  final _status = ValueNotifier(SessionStatus.connecting);
  final _subscriptions = <StreamSubscription<Object?>>[];

  SSHClient? _client;

  /// The jump hosts [_client] is tunnelled through, first dialled first.
  final _jumps = <SSHClient>[];
  SSHSession? _shell;
  String? _failure;
  bool _disposed = false;

  /// Set when we reject the server's key, so the generic handshake failure
  /// that follows can be reported as the security event it actually is.
  bool _hostKeyRejected = false;

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
        () => SSHSocket.connect(
          hop.host,
          hop.port,
          timeout: const Duration(seconds: 15),
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

      if (!shell) {
        // What opening a shell would otherwise wait out, and fail on.
        await _client!.authenticated;
        unawaited(
          _client!.done.catchError((Object _) {}).whenComplete(_markClosed),
        );
        _status.value = SessionStatus.connected;
        return;
      }

      _shell = await _client!.shell(
        pty: SSHPtyConfig(
          width: columns,
          height: rows,
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
    );
  }

  /// Servers can send text during authentication. Tailscale SSH uses it to
  /// hand over the URL a user has to visit before the session is allowed, so
  /// this is where that link surfaces.
  void _onAuthBanner(String banner) {
    _onAuthBannerReceived?.call(banner);
  }

  Future<bool> _verifyHostKey(HostProfile host, String fingerprint) async {
    final verdict = await _knownHosts.verify(
      host: host.host,
      port: host.port,
      fingerprint: fingerprint,
    );

    switch (verdict) {
      case HostKeyVerdict.matched:
        return true;
      case HostKeyVerdict.trustedOnFirstUse:
        _onHostKeyPinned?.call(fingerprint);
        return true;
      case HostKeyVerdict.changed:
        _hostKeyRejected = true;
        return false;
    }
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

  /// An exec channel with no pty, closed with `destroy` for the same reason
  /// [run]'s is.
  @override
  Future<CommandChannel> open(String command) async {
    final client = _client;
    if (client == null || _status.value != SessionStatus.connected) {
      throw const SshSessionException('Not connected.');
    }
    final session = await client.execute(command);
    return (
      output: session.stdout,
      write: session.write,
      close: session.channel.destroy,
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
  }) async {
    final client = _client;
    if (client == null || _status.value != SessionStatus.connected) {
      throw const SshSessionException('Not connected.');
    }

    final source = File(localPath);
    final total = await source.length();
    final remotePath = _remotePathFor(fileName);

    final sftp = await client.sftp();
    try {
      final remote = await sftp.open(
        remotePath,
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate,
      );
      final handle = await source.open();

      try {
        // dartssh2 offers no streaming write, so we chunk by hand against the
        // file offset. Reading a whole video into memory first is not
        // something a phone forgives.
        const chunkSize = 256 * 1024;
        var offset = 0;
        while (offset < total) {
          final chunk = await handle.read(chunkSize);
          if (chunk.isEmpty) break;
          await remote.writeBytes(chunk, offset: offset);
          offset += chunk.length;
          onProgress?.call(offset, total);
        }
      } finally {
        await handle.close();
        await remote.close();
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
    if (_hostKeyRejected) {
      return 'Host key changed since the last connection. This can mean the '
          'server was rebuilt — or that something is intercepting the '
          'connection. Forget the pinned key only if you know why it changed.';
    }
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
