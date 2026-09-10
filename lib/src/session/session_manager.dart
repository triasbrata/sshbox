import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:xterm2/xterm.dart';

import '../data/secret_store.dart';
import '../files/file_browser.dart';
import '../models/host_profile.dart';
import 'dartssh2_transport.dart';
import 'terminal_session.dart';

/// A local file waiting to go to the host — from the picker, or handed to us
/// by another app through the share sheet.
typedef SharedFile = ({String path, String name});

/// One terminal that outlives the widget showing it.
///
/// The [Terminal] holds the scrollback, so it must be owned here rather than
/// inside a `State`. Creating it in the page meant navigating back disposed it
/// and threw the session away — which is precisely what "return me to my
/// session" has to avoid.
class LiveSession extends ChangeNotifier {
  LiveSession({required this.host}) {
    // Wired up front, not at connect time: the view reports its size during
    // the first layout, which happens before the shell exists.
    _wireTerminal();
  }

  final HostProfile host;

  /// 10k lines: enough to scroll back through a build log, small enough not to
  /// strain a phone's memory.
  final Terminal terminal = Terminal(maxLines: 10000);

  /// Set by the page while it is on screen, so armed key-bar modifiers can be
  /// folded into outgoing keystrokes. Lives here as a hook rather than a
  /// dependency so this layer never has to import UI code.
  String Function(String data)? outputTransform;

  TerminalSession? _session;
  StreamSubscription<String>? _outputSubscription;
  String? _error;
  String? _remoteTitle;
  bool _connecting = false;
  bool _wired = false;
  bool _disposed = false;
  (int columns, int rows) _size = (80, 24);

  /// Teardown is asynchronous but [dispose] is not, so every notify has to be
  /// guarded — otherwise closing a session throws "used after being disposed"
  /// once the pending disconnect finishes.
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// Text the server sent during authentication, if any.
  String? _authBanner;

  /// A link pulled out of that text. Tailscale SSH uses this to make the user
  /// prove who they are in a browser before letting the session through.
  Uri? _authUrl;

  static final _urlPattern = RegExp(r'https?://\S+');

  bool get connecting => _connecting;
  String? get error => _error;
  String? get authBanner => _authBanner;
  Uri? get authUrl => _authUrl;

  /// Pulls the first link out of an authentication banner.
  ///
  /// Tailscale SSH's check arrives as prose with a URL in the middle of it,
  /// so there is no structure to rely on beyond finding the link.
  static Uri? extractAuthUrl(String banner) {
    final match = _urlPattern.firstMatch(banner);
    if (match == null) return null;
    // Trailing punctuation is common when the URL ends a sentence.
    final raw = match.group(0)!.replaceAll(RegExp(r'[.,;:)\]]+$'), '');
    return Uri.tryParse(raw);
  }

  void _onAuthBanner(String banner) {
    _authBanner = banner.trim();
    _authUrl = extractAuthUrl(banner);
    _notify();
  }
  String? get remoteTitle => _remoteTitle;
  String get title => _remoteTitle ?? host.displayName;

  /// True only while a shell is actually attached — what the host list uses to
  /// decide between "resume" and "connect".
  bool get isConnected =>
      _session?.status.value == SessionStatus.connected;

  void _wireTerminal() {
    if (_wired) return;
    _wired = true;

    terminal.onTitleChange = (title) {
      _remoteTitle = title;
      _notify();
    };

    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      _size = (width, height);
      _session?.resize(width, height, pixelWidth, pixelHeight);
    };

    terminal.onOutput = (data) {
      final transformed = outputTransform?.call(data) ?? data;
      _session?.send(transformed);
    };
  }

  /// Connects if there is no live shell. Calling this on an already-connected
  /// session is a no-op, so a notification tap can route here unconditionally.
  Future<void> connect({
    required SecretStore secrets,
    void Function(String fingerprint)? onHostKeyPinned,
    (int columns, int rows)? size,
  }) async {
    if (isConnected || _connecting) return;

    _wireTerminal();
    if (size != null) _size = size;

    _connecting = true;
    _error = null;
    _authBanner = null;
    _authUrl = null;
    _notify();

    try {
      final transport = Dartssh2Transport(
        onHostKeyPinned: onHostKeyPinned,
        onAuthBanner: _onAuthBanner,
      );
      final session = await transport.connect(
        host: host,
        secrets: secrets,
        columns: _size.$1,
        rows: _size.$2,
      );

      _outputSubscription = session.output.listen(terminal.write);
      session.status.addListener(_onStatusChanged);
      _session = session;
    } on SshSessionException catch (error) {
      _error = error.message;
    } catch (error) {
      _error = error.toString();
    } finally {
      _connecting = false;
      _notify();
    }
  }

  void _onStatusChanged() {
    final status = _session?.status.value;
    if (status == SessionStatus.closed) {
      terminal.write('\r\n\x1b[2m[session closed]\x1b[0m\r\n');
    } else if (status == SessionStatus.failed) {
      _error = _session?.failure;
    }
    _notify();
  }

  void resize(int columns, int rows, int pixelWidth, int pixelHeight) {
    _size = (columns, rows);
    _session?.resize(columns, rows, pixelWidth, pixelHeight);
  }

  /// Bypasses [outputTransform] — key bar entries are already complete
  /// escape sequences.
  void sendRaw(String data) => _session?.send(data);

  /// Whether this session's transport can move files at all.
  bool get canUploadFiles => _session is FileUploadCapable;

  /// Whether this session can tunnel a remote port to the device.
  bool get canForwardPorts => _session is PortForwardCapable;

  /// Whether this session's transport exposes a browsable filesystem.
  bool get canBrowseFiles => _session is FileBrowseCapable;

  /// Opens a file browser on this session. The caller closes it.
  FileBrowser openFileBrowser() {
    final session = _session;
    if (session is! FileBrowseCapable) {
      throw const SshSessionException('This session cannot browse files.');
    }
    final browsable = session as FileBrowseCapable;
    return browsable.openFileBrowser();
  }

  /// Tunnels [remoteHost]:[remotePort] to a loopback port on the device.
  Future<LocalPortForward> forwardLocalPort({
    required String remoteHost,
    required int remotePort,
  }) async {
    final session = _session;
    if (session is! PortForwardCapable) {
      throw const SshSessionException('This session cannot forward ports.');
    }
    final forwarder = session as PortForwardCapable;
    return forwarder.forwardLocalPort(
      remoteHost: remoteHost,
      remotePort: remotePort,
    );
  }

  /// Files handed to this session from outside the terminal page, waiting for
  /// the page to be on screen and the shell to be up.
  ///
  /// A share can arrive while the app is dead, so the file has to wait
  /// somewhere that outlives the widget — same reason the terminal does.
  final List<SharedFile> _pendingUploads = [];

  bool get hasPendingUploads => _pendingUploads.isNotEmpty;

  void queueUploads(Iterable<SharedFile> files) {
    if (files.isEmpty) return;
    _pendingUploads.addAll(files);
    _notify();
  }

  /// Hands the queue over and empties it, so a redraw cannot upload twice.
  List<SharedFile> takePendingUploads() {
    final taken = List<SharedFile>.of(_pendingUploads);
    _pendingUploads.clear();
    return taken;
  }

  /// Uploads into `/tmp` on the remote host and returns the path to type.
  Future<String> uploadToTmp({
    required String localPath,
    required String fileName,
    void Function(int sent, int total)? onProgress,
  }) async {
    final session = _session;
    // `is!` already rules out null. The explicit cast that follows is what
    // pins the static type down: promoting a nullable field to an unrelated
    // interface leaves the analyzer describing it as one half or the other.
    if (session is! FileUploadCapable) {
      throw const SshSessionException('This session cannot transfer files.');
    }
    final uploader = session as FileUploadCapable;
    return uploader.uploadToTmp(
      localPath: localPath,
      fileName: fileName,
      onProgress: onProgress,
    );
  }

  Future<void> _teardown() async {
    final session = _session;
    _session = null;
    await _outputSubscription?.cancel();
    _outputSubscription = null;
    session?.status.removeListener(_onStatusChanged);
    await session?.dispose();
  }

  Future<void> disconnect() async {
    await _teardown();
    _notify();
  }

  Future<void> reconnect({
    required SecretStore secrets,
    void Function(String fingerprint)? onHostKeyPinned,
  }) async {
    await disconnect();
    terminal.write('\x1b[2J\x1b[H');
    await connect(secrets: secrets, onHostKeyPinned: onHostKeyPinned);
  }

  @override
  void dispose() {
    // Flag first: teardown continues after this method returns, and anything
    // it triggers must not touch a disposed notifier.
    _disposed = true;
    unawaited(_teardown());
    terminal.dispose();
    super.dispose();
  }
}

/// Registry of open terminals, keyed by host id.
///
/// This is where "take me back to my session, or start a new one" is decided,
/// in one place, so a notification tap and a tap in the host list follow the
/// exact same rule.
///
/// Sessions live only as long as the app process. If Android kills the app
/// there is nothing to return to, and the next open is a fresh connection —
/// keeping a backgrounded connection alive for long needs a foreground
/// service, and on iOS is not possible at all.
class SessionManager extends ChangeNotifier {
  final Map<String, LiveSession> _sessions = {};

  LiveSession? _active;

  /// The session the user is in — the last one opened. What a file shared
  /// from another app is sent to.
  LiveSession? get active => _active;

  List<LiveSession> get sessions => List.unmodifiable(_sessions.values);

  int get liveCount => _sessions.values.where((s) => s.isConnected).length;

  LiveSession? find(String hostId) => _sessions[hostId];

  bool hasSession(String hostId) => _sessions.containsKey(hostId);

  bool isConnected(String hostId) => _sessions[hostId]?.isConnected ?? false;

  /// Returns the existing terminal for this host, or opens a new one.
  LiveSession openOrCreate(HostProfile host) {
    final existing = _sessions[host.id];
    if (existing != null) {
      _active = existing;
      return existing;
    }

    final created = LiveSession(host: host);
    _active = created;
    created.addListener(notifyListeners);
    _sessions[host.id] = created;
    notifyListeners();
    return created;
  }

  Future<void> close(String hostId) async {
    final session = _sessions.remove(hostId);
    if (session == null) return;
    if (identical(_active, session)) _active = null;
    session.removeListener(notifyListeners);
    session.dispose();
    notifyListeners();
  }

  Future<void> closeAll() async {
    for (final hostId in _sessions.keys.toList()) {
      await close(hostId);
    }
  }
}
