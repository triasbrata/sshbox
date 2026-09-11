import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:xterm2/xterm.dart';

import '../data/secret_store.dart';
import '../files/file_browser.dart';
import '../models/host_profile.dart';
import 'dartssh2_transport.dart';
import 'tailnet_forwarder.dart';
import 'terminal_session.dart';
import 'tmux.dart';

/// A local file waiting to go to the host — from the picker, or handed to us
/// by another app through the share sheet.
typedef SharedFile = ({String path, String name});

/// What a session's terminal is running on the host, as
/// [LiveSession.foreground] reads it: whether the shell itself has the
/// terminal — sitting at a prompt rather than running something — the name of
/// whatever does (`claude`, `vim`, or the shell's own), and that program's
/// working directory.
typedef Foreground = ({bool shellInForeground, String program, String cwd});

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
    this._transport,
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

  /// What [connect] opens the shell with, when a test hands one in. Otherwise
  /// each attempt makes its own SSH transport, carrying that attempt's host
  /// key and banner callbacks.
  final SessionTransport? _transport;

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
  /// strain a phone's memory. Every tmux pane gets the same.
  ///
  /// Every key a hardware keyboard sends is turned into bytes by this input
  /// handler, which makes it the one place to change what a key means. The
  /// kitty handler goes first so a program that has switched that protocol on
  /// still gets the protocol's own encoding.
  static Terminal _newTerminal() => Terminal(
    maxLines: 10000,
    inputHandler: const CascadeInputHandler([
      KittyKeyboardInputHandler(),
      _ShiftEnterInputHandler(),
      defaultInputHandler,
    ]),
  );

  /// The shell's terminal, and in tmux mode the one shown until tmux is up.
  final Terminal _terminal = _newTerminal();

  /// The terminal keystrokes go to: the shell's, or in tmux mode the focused
  /// pane's. What the key bar, the magic key and the upload all act on.
  Terminal get terminal => _tmux?.focused?.terminal ?? _terminal;

  /// This tab's tmux session, while one is attached — see [HostProfile.useTmux].
  TmuxSession? get tmux => _tmux;
  TmuxSession? _tmux;

  /// What the tmux session is called on the host. Made once per tab and kept
  /// across reconnects, which is what brings a dropped connection back to the
  /// same panes. Random rather than [id], which restarts with the app: a new
  /// tab must not land in a session left behind by an earlier run, or by
  /// another device.
  late final tmuxName =
      'sshbox-${_random.nextInt(1 << 32).toRadixString(36)}';
  static final _random = math.Random();

  /// Why this host's tmux could not be used, for the page to say once.
  String? _tmuxProblem;

  /// Hands the reason over and forgets it, so it is said once per connect.
  String? takeTmuxProblem() {
    final problem = _tmuxProblem;
    _tmuxProblem = null;
    return problem;
  }

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

  final List<WebTab> _webTabs = [];

  /// The web pages opened from links in this session, in tab order. They sit
  /// beside its shell and close with it, but need nothing of its connection
  /// — the phone fetches them itself — so a reconnect leaves them open.
  List<WebTab> get webTabs => List.unmodifiable(_webTabs);

  /// A link already showing in one of this session's tabs returns that tab
  /// rather than opening a second, as a file does.
  WebTab openWeb(Uri url) {
    final open = _webTabs.where((tab) => tab.url == url).firstOrNull;
    if (open != null) return open;
    final tab = WebTab._(url);
    _webTabs.add(tab);
    _notify();
    return tab;
  }

  void closeWeb(WebTab tab) {
    if (_webTabs.remove(tab)) _notify();
  }

  /// Where a web tab's page has got to, as its view reports it, so the strip
  /// names the tab after it.
  void updateWeb(WebTab tab, {required Uri url, String? title}) {
    if (tab._url == url && tab._title == title) return;
    tab
      .._url = url
      .._title = title;
    _notify();
  }

  /// The host's own name for itself, cut at the first dot: what a default
  /// bash `\h` or zsh `%m` prompt shows, so `DESKTOP-L2EPDPG` where the host
  /// list says "WSL via tailnet". Asked for when the connection comes up
  /// rather than when a tab is drawn, so a file opened straight away already
  /// has it. Forgotten with the connection: an edited profile's next one may
  /// reach another machine.
  String? _hostname;

  /// A file tab's host: the machine's own name once it has said it, and the
  /// host list's until then, or for good on a host that cannot say.
  String get fileTabHost => _hostname ?? host.displayName;

  /// A file tab's name: [fileTabHost], then the file.
  String fileTabTitle(String path) =>
      '$fileTabHost · ${RemotePath.basename(path)}';

  void _wireTerminal() {
    if (_wired) return;
    _wired = true;

    _terminal.onTitleChange = (title) {
      _remoteTitle = title;
      _notify();
    };

    _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      _size = (width, height);
      _session?.resize(width, height, pixelWidth, pixelHeight);
    };

    _terminal.onOutput = (data) {
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
      final transport = _transport ??
          Dartssh2Transport(
            onHostKeyPinned: onHostKeyPinned,
            onAuthBanner: _onAuthBanner,
          );
      Future<TerminalSession> open({required bool shell}) => transport.connect(
        host: host,
        secrets: secrets,
        columns: _size.$1,
        rows: _size.$2,
        shell: shell,
      );

      var session = await open(shell: !host.useTmux);
      if (host.useTmux && !await _attachTmux(session)) {
        // The plain shell the host would have had without the switch.
        await session.dispose();
        session = await open(shell: true);
      }

      _outputSubscription = session.output.listen(_terminal.write);
      session.status.addListener(_onStatusChanged);
      _session = session;
      _syncForwarding();
      unawaited(_fetchHostname());
    } on SshSessionException catch (error) {
      _error = error.message;
    } catch (error) {
      _error = error.toString();
    } finally {
      _connecting = false;
      _notify();
    }
  }

  /// Starts this tab's tmux session on the connection [session] holds, and
  /// says why not when it cannot.
  Future<bool> _attachTmux(TerminalSession session) async {
    final TmuxSession tmux;
    try {
      final host = session as ChannelCapable;
      tmux = TmuxSession(
        name: tmuxName,
        channel: await host.open(TmuxSession.command(tmuxName)),
        newTerminal: _newTerminal,
        transform: (data) => outputTransform?.call(data) ?? data,
        onChanged: _notify,
        onEnded: _onTmuxEnded,
        size: _size,
      );
    } catch (error) {
      _tmuxProblem = '$error';
      return false;
    }
    // A host that neither starts tmux nor says why must not leave the tab
    // spinning.
    final attached = await tmux.attached.timeout(
      const Duration(seconds: 20),
      onTimeout: () => false,
    );
    if (attached) {
      _tmux = tmux;
      return true;
    }
    tmux.dispose();
    _tmuxProblem = tmux.problem ?? 'tmux did not answer.';
    return false;
  }

  /// tmux ending is this tab's shell ending, however it came about — the last
  /// pane exited, the session was killed elsewhere, the connection dropped —
  /// and it ends the way a plain shell does: the panes keep their last
  /// screen, and the tab offers to reconnect.
  void _onTmuxEnded() => unawaited(_session?.dispose());

  void _onStatusChanged() {
    _syncForwarding();
    final status = _session?.status.value;
    if (status == SessionStatus.closed) {
      _terminal.write('\r\n\x1b[2m[session closed]\x1b[0m\r\n');
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
  /// escape sequences. In tmux mode, to the focused pane.
  void sendRaw(String data) {
    final tmux = _tmux;
    if (tmux != null) {
      tmux.send(data);
    } else {
      _session?.send(data);
    }
  }

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

  /// This session's login shell on the host, once [foreground] has found it.
  /// Forgotten with the connection: the next one starts another shell.
  int? _shellPid;

  /// What this session's terminal is running on the host, and where. Null
  /// when the host cannot say: not Linux, or no way to run a command beside
  /// the shell.
  ///
  /// One exec channel on the connection the shell already holds, reading
  /// `/proc`. The shell is found by `SSH_CONNECTION` — the client's address
  /// and port as the host saw them, which no two open connections share — as
  /// the oldest process with a terminal that carries this connection's value
  /// while its parent does not. sshd and tailscaled put it only in what they
  /// start, and everything else on the connection, this command included,
  /// comes after the shell. Not a marker of our own sent with the shell:
  /// dartssh2 fails the shell outright when sshd refuses an environment
  /// variable, and Tailscale SSH drops them unless the tailnet policy lists
  /// them.
  ///
  /// The terminal's foreground process group is then whatever the user is
  /// looking at, and its cwd is where a relative path it printed starts from:
  /// Claude Code's project, not wherever the shell was when it started it.
  ///
  /// In tmux mode, tmux answers instead, for the focused pane.
  ///
  /// ponytail: the shell's own terminal only. Inside a tmux or screen started
  /// by hand the pane is on a terminal of its own, and this reports the
  /// multiplexer's client.
  Future<Foreground?> foreground() async {
    final tmux = _tmux;
    if (tmux != null) return isConnected ? tmux.foreground() : null;
    final session = _session;
    if (session is! CommandCapable || !isConnected) return null;
    // Through `sh`, because the login shell may be fish.
    final script = _foregroundScript.replaceAll("'", r"'\''");
    try {
      final lines = await (session as CommandCapable)
          .run("sh -c '$script' sh ${_shellPid ?? ''}")
          .toList();
      // Anything else is the login shell's own chatter.
      final fields = lines
          .firstWhere((line) => line.startsWith('sshbox\t'), orElse: () => '')
          .split('\t');
      if (fields.length != 5) return null;
      _shellPid = int.tryParse(fields[1]);
      return (
        shellInForeground: fields[2] == '1',
        program: fields[3],
        cwd: fields[4],
      );
    } catch (_) {
      // A dropped connection is announced elsewhere; here it only means the
      // host cannot say.
      return null;
    }
  }

  /// Asks the host for [_hostname], on an exec channel beside the shell the
  /// way [foreground] asks. tmux mode asks the same way: it is the same
  /// machine.
  ///
  /// `uname -n` rather than `hostname -s`: it is the name `\h` and `%m` are
  /// cut from, every Unix has it, and it never waits on DNS the way an older
  /// `hostname -s` does. A host without it, Windows say, prints nothing on
  /// stdout and keeps the host list's name.
  Future<void> _fetchHostname() async {
    final session = _session;
    if (session is! CommandCapable) return;
    try {
      final lines = await (session as CommandCapable).run('uname -n').toList();
      // The last line: anything before it is the login shell's own chatter.
      final name = lines
          .lastWhere((line) => line.trim().isNotEmpty, orElse: () => '')
          .trim()
          .split('.')
          .first;
      // A reconnect since asking has its own answer coming.
      if (name.isEmpty || !identical(_session, session)) return;
      _hostname = name;
      _notify();
    } catch (_) {
      // Only a tab's name rides on it, and that has its fallback.
    }
  }

  /// Finds the shell as [foreground] describes, unless its pid comes in `$1`,
  /// and prints one line: `sshbox`, the pid, 1 when the terminal's foreground
  /// group (field 8 of `/proc/<pid>/stat`) is the shell's own (field 5), that
  /// group's program name, and its cwd — or the shell's, when the program's
  /// cannot be read. Prints nothing where there is no `/proc` to read.
  static const _foregroundScript = r'''
[ -n "$SSH_CONNECTION" ] || exit
shells() {
  for e in $(grep -lsF "SSH_CONNECTION=$SSH_CONNECTION" /proc/[0-9]*/environ); do
    s=$(cat "${e%/environ}/stat" 2>/dev/null) || continue
    set -- ${s##*) }
    [ "$5" = 0 ] || grep -qsF "SSH_CONNECTION=$SSH_CONNECTION" "/proc/$2/environ" ||
      echo "${20} ${e%/environ}"
  done
}
p=/proc/$1
[ -n "$1" ] && [ -r "$p/stat" ] || p=$(shells | sort -n | head -n 1 | cut -d " " -f 2)
[ -n "$p" ] || exit
s=$(cat "$p/stat")
set -- ${s##*) }
f=/proc/$6
[ "$6" = "$3" ] && t=1 || t=0
d=$(readlink "$f/cwd" || readlink "$p/cwd")
printf "sshbox\t%s\t%s\t%s\t%s\n" "${p#/proc/}" "$t" "$(cat "$f/comm" 2>/dev/null)" "$d"''';

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

  /// [kill] ends the tmux session too — closing the tab. A reconnect leaves
  /// it running, to come back to.
  Future<void> _teardown({bool kill = false}) async {
    forwarder.stop();
    final tmux = _tmux;
    _tmux = null;
    if (kill) await tmux?.kill();
    tmux?.dispose();
    final session = _session;
    _session = null;
    _shellPid = null;
    _hostname = null;
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
    _terminal.write('\x1b[2J\x1b[H');
    await connect(secrets: secrets, onHostKeyPinned: onHostKeyPinned);
  }

  @override
  void dispose() {
    // Flag first: teardown continues after this method returns, and anything
    // it triggers must not touch a disposed notifier.
    _disposed = true;
    unawaited(_teardown(kill: true));
    _terminal.dispose();
    super.dispose();
  }
}

/// What a tab shows: the shell on a host, a file opened over that shell, or
/// a web page a link in it opened.
enum TabKind { terminal, file, web }

/// A web page in a tab beside the shell whose link opened it.
class WebTab {
  WebTab._(this._url);

  /// Names the tab for as long as it is open. Its address cannot: that
  /// changes with every link followed on the page.
  final int id = _nextId++;
  static int _nextId = 0;

  Uri _url;
  String? _title;

  /// Where the page is now: the link it opened at, until it moves on.
  Uri get url => _url;

  /// What the tab is called: the page's own title once it has loaded one,
  /// and until then the host it is on — what a browser's tab shows while a
  /// page loads.
  String get title {
    final title = _title?.trim() ?? '';
    if (title.isNotEmpty) return title;
    return _url.host.isNotEmpty ? _url.host : '$_url';
  }
}

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

  /// Which page, when the showing tab is a web tab.
  WebTab? _activeWeb;

  List<LiveSession> get sessions => List.unmodifiable(_sessions.values);

  int? get activeId => _activeId;

  /// Which kind of tab is showing. Meaningless while [activeId] is null.
  TabKind get activeKind => _activeKind;

  /// The file the showing tab holds, when [activeKind] is [TabKind.file].
  String? get activePath => _activePath;

  /// The page the showing tab holds, when [activeKind] is [TabKind.web].
  WebTab? get activeWeb => _activeWeb;

  int? _activeLine;

  /// The line a search result asked the showing file tab to open at. Dropped
  /// when another tab is shown, so coming back does not move the cursor.
  int? get activeLine => _activeLine;

  /// null selects the pinned host list.
  void select(
    int? id, {
    TabKind kind = TabKind.terminal,
    String? path,
    WebTab? web,
  }) {
    if (_activeId == id &&
        _activeKind == kind &&
        _activePath == path &&
        _activeWeb == web) {
      return;
    }
    _activeId = id;
    _activeKind = kind;
    _activePath = kind == TabKind.file ? path : null;
    _activeWeb = kind == TabKind.web ? web : null;
    _activeLine = null;
    // Going back to the host list leaves the last session standing as the
    // active one: a file shared from another app still has somewhere to go.
    if (id != null) _active = _sessions[id];
    notifyListeners();
  }

  /// Opens a file picked in the drawer as a tab of its own, and shows it.
  /// Picking a file that already has a tab just goes back to it. [line] is
  /// where a search result found what was asked for.
  void openFile(int id, String path, {int? line}) {
    final session = _sessions[id];
    if (session == null) return;
    session.openFile(path);
    select(id, kind: TabKind.file, path: path);
    if (line != null) {
      _activeLine = line;
      notifyListeners();
    }
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

  /// Opens a link as a web page in a tab beside the session's shell, and
  /// shows it. A link already open there just goes back to its tab.
  void openWeb(int id, Uri url) {
    final session = _sessions[id];
    if (session == null) return;
    select(id, kind: TabKind.web, web: session.openWeb(url));
  }

  /// Closing a web tab lands on the shell whose link opened it.
  void closeWeb(int id, WebTab web) {
    final session = _sessions[id];
    if (session == null) return;
    session.closeWeb(web);
    if (_activeWeb == web) select(id);
  }

  int get liveCount => _sessions.values.where((s) => s.isConnected).length;

  /// Every session open on this host, in tab order.
  List<LiveSession> sessionsFor(String hostId) =>
      _sessions.values.where((s) => s.host.id == hostId).toList();

  /// Opens another terminal on this host, whatever it already has open, and
  /// shows it. [transport] is a test's, as [LiveSession] takes one.
  LiveSession open(HostProfile host, {SessionTransport? transport}) {
    late final LiveSession created;
    created = LiveSession(
      host: host,
      forwardedElsewhere: (port) => sessionsFor(created.host.id)
          .any((s) => s != created && s.forwarder.isForwarding(port)),
      transport: transport,
    );
    created.addListener(notifyListeners);
    _sessions[created.id] = created;
    _active = created;
    _activeId = created.id;
    _activeKind = TabKind.terminal;
    _activePath = null;
    _activeWeb = null;
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
      _activeWeb = null;
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
