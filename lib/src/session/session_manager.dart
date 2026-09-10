import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:xterm2/xterm.dart';

import '../data/secret_store.dart';
import '../files/file_browser.dart';
import '../models/host_profile.dart';
import 'dartssh2_transport.dart';
import 'tailnet_forwarder.dart';
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
  LiveSession({
    required this._host,
    bool Function(int port)? forwardedElsewhere,
  }) {
    forwarder = TailnetForwarder(
      onChanged: _notify,
      forwardedElsewhere: forwardedElsewhere,
    );
    // Wired up front, not at connect time: the view reports its size during
    // the first layout, which happens before the shell exists.
    _wireTerminal();
  }

  HostProfile _host;

  HostProfile get host => _host;

  /// Replaced when the saved profile changes while this session is open —
  /// see [SessionManager.updateHost].
  set host(HostProfile value) {
    _host = value;
    _syncForwarding();
    _notify();
  }

  /// Puts servers started in this session on the tailnet, when the host is
  /// set to. Outlives reconnects, so a server keeps its address across a
  /// dropped connection.
  late final TailnetForwarder forwarder;

  /// Forwarding follows the host's switch while connected, so turning it off
  /// takes the ports off the tailnet now rather than at the next connect.
  void _syncForwarding() {
    final session = _session;
    if (host.forwardPorts && isConnected && session is CommandCapable) {
      forwarder.start(session as CommandCapable);
    } else {
      forwarder.stop();
    }
  }

  /// Names this session among the others on the same host — a host can have
  /// several shells open at once, so its own id cannot tell their tabs apart.
  final int id = _nextId++;
  static int _nextId = 0;

  /// 10k lines: enough to scroll back through a build log, small enough not to
  /// strain a phone's memory.
  ///
  /// Every key a hardware keyboard sends is turned into bytes by this input
  /// handler, which makes it the one place to change what a key means. The
  /// kitty handler goes first so a program that has switched that protocol on
  /// still gets the protocol's own encoding.
  final Terminal terminal = Terminal(
    maxLines: 10000,
    inputHandler: const CascadeInputHandler([
      KittyKeyboardInputHandler(),
      _ShiftEnterInputHandler(),
      defaultInputHandler,
    ]),
  );

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

  /// True once the shell has gone — closed by the far end, dropped, or never
  /// reached — as opposed to not having been asked for yet. A new tab is not
  /// connecting for the one frame before its page asks, and must not flash a
  /// reconnect button in that frame.
  bool get ended =>
      !isConnected && !_connecting && (_session != null || _error != null);

  final List<String> _openFiles = [];

  /// Absolute paths of the files opened from the drawer, in tab order. They
  /// are read over this session, so they cannot outlive it — closing the
  /// shell takes its file tabs with it.
  List<String> get openFiles => List.unmodifiable(_openFiles);

  /// Opening a file already on the strip is a no-op: it selects the tab that
  /// is already there rather than stacking a second copy of the same file.
  void openFile(String path) {
    if (_openFiles.contains(path)) return;
    _openFiles.add(path);
    _notify();
  }

  void closeFile(String path) {
    if (_openFiles.remove(path)) _notify();
  }

  /// A file tab's name: the host, then the file.
  String fileTabTitle(String path) =>
      '${host.displayName} > ${path.split('/').last}';

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
      _syncForwarding();
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
    _syncForwarding();
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

  FileBrowser? _fileBrowser;

  /// The browser every file tab on this session reads through.
  ///
  /// Shared rather than one per tab: the tabs are all reading the same host
  /// over the same shell, and a browser per tab is a channel per tab sitting
  /// idle on the server. It is closed with the session, and dropped on a
  /// reconnect because it is bound to the client that went away.
  FileBrowser get fileBrowser => _fileBrowser ??= openFileBrowser();

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
    forwarder.stop();
    final session = _session;
    _session = null;
    final browser = _fileBrowser;
    _fileBrowser = null;
    await browser?.close();
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

/// What a tab shows: the shell on a host, or a file opened over that shell.
enum TabKind { terminal, file }

/// Registry of open terminals, keyed by session id. A host can have any number
/// of them: each tap in the host list opens another.
///
/// This is also where "take me back to my session" is decided, in one place,
/// so a notification tap and a shared file land on the same terminal.
///
/// Sessions live only as long as the app process. If Android kills the app
/// there is nothing to return to, and the next open is a fresh connection —
/// keeping a backgrounded connection alive for long needs a foreground
/// service, and on iOS is not possible at all.
class SessionManager extends ChangeNotifier {
  /// Insertion-ordered, and that order is the tab order.
  final Map<int, LiveSession> _sessions = {};

  /// The session the user is in: the one whose tab is showing, or the last
  /// one shown while the host list is up. What a file shared from another app
  /// is sent to.
  LiveSession? _active;

  LiveSession? get active => _active;

  /// Which tab is showing: a session id, or null for the pinned host list.
  int? _activeId;
  TabKind _activeKind = TabKind.terminal;

  /// Which file, when the showing tab is a file tab.
  String? _activePath;

  List<LiveSession> get sessions => List.unmodifiable(_sessions.values);

  int? get activeId => _activeId;

  /// Which kind of tab is showing. Meaningless while [activeId] is null.
  TabKind get activeKind => _activeKind;

  /// The file the showing tab holds, when [activeKind] is [TabKind.file].
  String? get activePath => _activePath;

  /// null selects the pinned host list.
  void select(int? id, {TabKind kind = TabKind.terminal, String? path}) {
    if (_activeId == id && _activeKind == kind && _activePath == path) {
      return;
    }
    _activeId = id;
    _activeKind = kind;
    _activePath = kind == TabKind.file ? path : null;
    // Going back to the host list leaves the last session standing as the
    // active one: a file shared from another app still has somewhere to go.
    if (id != null) _active = _sessions[id];
    notifyListeners();
  }

  /// Opens a file picked in the drawer as a tab of its own, and shows it.
  /// Picking a file that already has a tab just goes back to it.
  void openFile(int id, String path) {
    final session = _sessions[id];
    if (session == null) return;
    session.openFile(path);
    select(id, kind: TabKind.file, path: path);
  }

  /// Closing a file tab lands on the shell it was opened from — the session
  /// itself keeps running.
  void closeFile(int id, String path) {
    final session = _sessions[id];
    if (session == null) return;
    session.closeFile(path);
    if (_activeId == id &&
        _activeKind == TabKind.file &&
        _activePath == path) {
      select(id);
    }
  }

  int get liveCount => _sessions.values.where((s) => s.isConnected).length;

  /// Every session open on this host, in tab order.
  List<LiveSession> sessionsFor(String hostId) =>
      _sessions.values.where((s) => s.host.id == hostId).toList();

  /// Opens another terminal on this host, whatever it already has open, and
  /// shows it.
  LiveSession open(HostProfile host) {
    late final LiveSession created;
    created = LiveSession(
      host: host,
      forwardedElsewhere: (port) => sessionsFor(created.host.id)
          .any((s) => s != created && s.forwarder.isForwarding(port)),
    );
    created.addListener(notifyListeners);
    _sessions[created.id] = created;
    _active = created;
    _activeId = created.id;
    _activeKind = TabKind.terminal;
    _activePath = null;
    notifyListeners();
    return created;
  }

  /// Takes the user back to a terminal on this host — the one they were last
  /// in, else its newest — and opens one only when it has none.
  LiveSession openOrCreate(HostProfile host) {
    final existing = _active?.host.id == host.id
        ? _active
        : sessionsFor(host.id).lastOrNull;
    if (existing == null) return open(host);
    select(existing.id);
    return existing;
  }

  Future<void> close(int id) async {
    final ids = _sessions.keys.toList();
    final index = ids.indexOf(id);
    final session = _sessions.remove(id);
    if (session == null) return;
    session.removeListener(notifyListeners);
    session.dispose();

    // Closing the tab you are looking at lands on its left-hand neighbour,
    // falling back to the host list — the same move every tabbed UI makes.
    if (_activeId == id) {
      _activeId = index > 0 ? ids[index - 1] : null;
      _activeKind = TabKind.terminal;
      _activePath = null;
    }
    if (identical(_active, session)) {
      _active = _activeId == null ? null : _sessions[_activeId];
    }
    notifyListeners();
  }

  /// Hands an edited profile to every session open on its host, so their
  /// tab names, next reconnects and file tree roots follow the edit instead
  /// of the profile as it was when each tab opened.
  void updateHost(HostProfile host) {
    for (final session in sessionsFor(host.id)) {
      session.host = host;
    }
  }

  /// Closes every session on this host — what deleting the host needs.
  Future<void> closeHost(String hostId) async {
    for (final session in sessionsFor(hostId)) {
      await close(session.id);
    }
  }

  Future<void> closeAll() async {
    for (final id in _sessions.keys.toList()) {
      await close(id);
    }
  }
}

/// Sends Shift+Enter from a hardware keyboard as ESC CR — Alt+Enter.
///
/// A terminal has no byte of its own for Shift+Enter, and xterm2 sends the
/// same CR as for Enter, so Claude Code submits a message you meant to break
/// onto a new line. ESC CR is what it reads as "new line, don't send", as do
/// zsh and fish — and what Claude Code's own `/terminal-setup` binds
/// Shift+Enter to in terminals that lack it.
class _ShiftEnterInputHandler implements TerminalInputHandler {
  const _ShiftEnterInputHandler();

  @override
  String? call(TerminalKeyboardEvent event) {
    if (event.type == TerminalKeyEventType.release) return null;
    if (event.key != TerminalKey.enter || !event.shift) return null;
    if (event.ctrl || event.alt || event.superKey) return null;
    return '\x1b\r';
  }
}
