import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm2/xterm.dart';

import '../chat/claude_chat.dart';
import '../data/host_repository.dart';
import '../data/known_host_store.dart';
import '../data/secret_store.dart';
import '../db/db_session.dart';
import '../files/file_browser.dart';
import '../models/host_profile.dart';
import '../models/os_info.dart';
import '../notifications/direct_notify.dart';
import '../notifications/notify_key.dart';
import '../git/git_diff.dart';
import '../git/git_repo.dart';
import 'isolate_transport.dart';
import 'tailnet_forwarder.dart';
import 'terminal_session.dart';
import 'tmux.dart';

/// A local file waiting to go to the host — from the picker, or handed to us
/// by another app through the share sheet.
typedef SharedFile = ({String path, String name});

/// Makes the transport one connect goes through, handed that attempt's host
/// key question and sign-in banner hook: SSH's own, unless a test brings a
/// stand-in.
typedef TransportMaker = SessionTransport Function(
  Future<bool> Function(HostKeyCheck check)? confirmHostKey,
  void Function(String banner) onAuthBanner,
);

/// Posts a notification that opens [hostId] when tapped, as a push does:
/// `NotificationGateway.showForHost`.
typedef ShowNotification = Future<void> Function({
  required String hostId,
  required String title,
  required String body,
});

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
    this._notifyKeys,
    this._onNotify,
    String? tmuxName,
    bool restored = false,
  }) : tmuxName = tmuxName ?? _newTmuxName(),
       _autoConnect = restored,
       _checkTmux = restored {
    forwarder = TailnetForwarder(
      onChanged: _notify,
      forwardedElsewhere: forwardedElsewhere,
    );
    // Wired up front, not at connect time: the view reports its size during
    // the first layout, which happens before the shell exists.
    _wireTerminal();
  }

  HostProfile _host;

  /// Makes what [connect] opens the shell with, when a test hands one in.
  /// Otherwise each attempt makes its own SSH transport. Either way it
  /// carries that attempt's host key and banner callbacks.
  final TransportMaker? _transport;

  /// The relay keys, one per host, read at every connect: see
  /// [SessionManager.notifyKeys].
  final NotifyKeys? _notifyKeys;

  /// Shows what a host sent down this session's connection: see
  /// [SessionManager.onNotify].
  final ShowNotification? _onNotify;

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
  /// still gets the protocol's own encoding, and a key's release goes only to
  /// a program that asked for it: see [_ReleaseOnlyIfAsked].
  static Terminal _newTerminal() => Terminal(
    maxLines: 10000,
    inputHandler: const _ReleaseOnlyIfAsked(
      CascadeInputHandler([
        KittyKeyboardInputHandler(),
        _ShiftEnterInputHandler(),
        defaultInputHandler,
      ]),
    ),
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
  /// same panes, and saved with the tab, which brings it back after the app
  /// restarts: see [SessionManager.restoreTabs]. Random rather than [id],
  /// which restarts with the app: a new tab must not land in a session left
  /// behind by an earlier run, or by another device.
  final String tmuxName;
  static final _random = math.Random();
  static String _newTmuxName() =>
      'sshbox-${_random.nextInt(1 << 32).toRadixString(36)}';

  /// What a saved tmux name must look like to be used: it goes into a
  /// command on the host.
  static final tmuxNamePattern = RegExp(r'^sshbox-[0-9a-z]+$');

  /// Brought back from an earlier run and not connected since: see
  /// [takeAutoConnect].
  bool _autoConnect;

  /// Whether the next connect asks the host if [tmuxName] is still there
  /// before attaching, which would otherwise make a new one: a tab brought
  /// back from an earlier run, until it has connected.
  bool _checkTmux;

  bool _tmuxGone = false;

  /// This tab's tmux session is no longer on the host: it restarted, or the
  /// session was ended there. [startNewTmux] makes a new one instead.
  bool get tmuxGone => _tmuxGone;

  /// True once, for a tab brought back from an earlier run that has not
  /// connected since: what makes it connect the first time it shows.
  bool takeAutoConnect() {
    final auto = _autoConnect;
    _autoConnect = false;
    return auto;
  }

  /// Gives up on the tmux session that went: the next connect makes a new one
  /// under the same name.
  void startNewTmux() {
    _checkTmux = false;
    _tmuxGone = false;
  }

  /// Files that were open over this session when the app last went away,
  /// opened again once it connects: a file tab reads through the connection.
  final List<String> _restoredFiles = [];

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

  /// Where the transport hands over what the server said.
  void _onAuthBanner(String banner) {
    _authBanner = banner.trim();
    _authUrl = extractAuthUrl(banner);
    _notify();
  }

  String? get remoteTitle => _remoteTitle;
  String get title => _remoteTitle ?? host.displayName;

  /// True only while a shell is actually attached — what the host list uses to
  /// decide between "resume" and "connect".
  bool get isConnected => _session?.status.value == SessionStatus.connected;

  /// True once the shell has gone — closed by the far end, dropped, never
  /// reached, or given up on — as opposed to not having been asked for yet.
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

  bool _chatOpen = false;

  /// Whether this session has a chat tab beside its shell. At most one: it is
  /// this host's one conversation, not a document there can be several of.
  bool get chatOpen => _chatOpen;

  /// Whether Claude can be run beside the shell at all — a transport that
  /// carries only a terminal, as mosh does, cannot.
  bool get canChat => _session is ChannelCapable;

  /// The connection whose Claude Code passed [chatRefusal]. Asked once a
  /// connection, since a version does not change under a session unless it
  /// is upgraded — and a refusal is not kept, so after an upgrade the next
  /// tap asks again without a reconnect.
  Object? _claudeFitOn;

  /// Why chat cannot open on this host — no Claude Code, or one older than
  /// [ClaudeChat.minimumVersion] — or null when it can.
  Future<String?> chatRefusal() async {
    final session = _session;
    if (session is! ChannelCapable || !isConnected) return 'Not connected.';
    if (identical(_claudeFitOn, session)) return null;
    final String output;
    try {
      final channel = await (session as ChannelCapable).open(
        ClaudeChat.versionCommand(),
      );
      try {
        output = await utf8.decoder
            .bind(channel.output)
            .join()
            .timeout(const Duration(seconds: 20));
      } finally {
        channel.close();
      }
    } catch (error) {
      return 'Could not ask the host which Claude Code it has: $error';
    }
    final why = ClaudeChat.versionRefusal(output);
    if (why == null) _claudeFitOn = session;
    return why;
  }

  ClaudeChat? _chat;

  /// The conversation the chat tab shows, made the first time it is asked
  /// for and kept until the tab closes.
  ///
  /// It outlives a reconnect: the process on the host dies with the
  /// connection, but what was said is here, and its [ClaudeChat.restart]
  /// resumes the same conversation on the new one by its id.
  ClaudeChat get chat => _chat ??= ClaudeChat(
    open: (command) async {
      final session = _session;
      if (session is! ChannelCapable || !isConnected) {
        throw const SshSessionException('Not connected.');
      }
      return (session as ChannelCapable).open(command);
    },
    // A terminal of its own on the host, for typing into a running session
    // through `claude attach`, which will not run without one.
    openTerminal: (command) async {
      final session = _session;
      if (session is! TerminalChannelCapable || !isConnected) {
        throw const SshSessionException('Not connected.');
      }
      return (session as TerminalChannelCapable).openTerminal(command);
    },
    cwd: host.fileRoot.trim().isEmpty ? null : host.fileRoot,
  );

  void openChat() {
    if (_chatOpen) return;
    _chatOpen = true;
    _notify();
  }

  /// Closing the tab takes the conversation with it: the process on the host
  /// is ended, and what was said goes with it, as a shell's tab does.
  void closeChat() {
    if (!_chatOpen) return;
    _chatOpen = false;
    _chat?.dispose();
    _chat = null;
    _notify();
  }

  bool _gitOpen = false;

  /// Whether this session has a git tab beside its shell. At most one, as the
  /// chat is: it is this host's repositories, and the picker inside it is how
  /// you move between them.
  bool get gitOpen => _gitOpen;

  /// Whether git can be run beside the shell at all. A transport that carries
  /// only a terminal cannot, and the key bar's button is dead there.
  bool get canGit => _session is CommandCapable;

  GitRepos? _repos;

  /// The repositories the git tab shows, found the first time it is asked for
  /// and kept until the tab closes. Rooted at the host's file tree root when
  /// it has one, so a host that opens in `~/projects` looks for repositories
  /// there rather than across the whole home.
  GitRepos get repos => _repos ??= GitRepos(
    run: (command) {
      final session = _session;
      if (session is! CommandCapable || !isConnected) {
        throw const SshSessionException('Not connected.');
      }
      return (session as CommandCapable).run(command);
    },
    start: host.fileRoot.trim().isEmpty
        ? GitRepos.loginHome
        : host.fileRoot.trim(),
  );

  void openGit() {
    if (_gitOpen) return;
    _gitOpen = true;
    _notify();
  }

  void closeGit() {
    if (!_gitOpen) return;
    _gitOpen = false;
    _repos?.dispose();
    _repos = null;
    _notify();
  }

  final List<GitDiff> _diffs = [];

  /// The diffs opened from this session's git panel, in tab order. Each is a
  /// file tab of its own holding what git printed; the panel keeps the lists,
  /// and a diff outlives the panel that opened it, since it runs its own
  /// command over this session rather than through the panel.
  List<GitDiff> get diffs => List.unmodifiable(_diffs);

  /// Opening a diff already on the strip goes back to its tab rather than
  /// stacking a second copy, the way opening a file does.
  void openDiff(GitDiff diff) {
    if (_diffs.any((open) => open.key == diff.key)) return;
    _diffs.add(diff);
    _notify();
  }

  void closeDiff(String key) {
    final before = _diffs.length;
    _diffs.removeWhere((open) => open.key == key);
    if (_diffs.length != before) _notify();
  }

  final List<WebTab> _webTabs = [];

  /// The web pages opened from links in this session, in tab order. They sit
  /// beside its shell and close with it, but need nothing of its connection
  /// — the phone fetches them itself — so a reconnect leaves them open.
  List<WebTab> get webTabs => List.unmodifiable(_webTabs);

  /// A link already showing in one of this session's tabs returns that tab
  /// rather than opening a second, as a file does.
  ///
  /// The session's own sign-in link, opened while it waits at that sign-in,
  /// is the sign-in prompt's Open link, in the connect sheet or on the
  /// shell's page. Its tab closes once the session is through, and whoever
  /// was still on it lands back in the shell they were signing in for.
  WebTab openWeb(Uri url) {
    final open = _webTabs.where((tab) => tab.url == url).firstOrNull;
    if (open != null) return open;
    final tab = WebTab._(url).._signIn = _connecting && url == _authUrl;
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

  /// A diff tab's name, the same way: [fileTabHost], then what the diff calls
  /// itself — "main.dart · diff". A key with no diff left can only be a tab
  /// on its way out.
  String diffTabTitle(String key) {
    final diff = _diffs.where((open) => open.key == key).firstOrNull;
    return '$fileTabHost · ${diff?.title ?? 'diff'}';
  }

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

  /// Bumped by every connect and by [abandon], so a connect that comes
  /// through after it was given up on lets its connection go rather than
  /// taking over the tab.
  int _attempt = 0;

  /// Connects if there is no live shell, and does nothing while one is up or
  /// on its way.
  Future<void> connect({
    required SecretStore secrets,
    Future<bool> Function(HostKeyCheck check)? confirmHostKey,
    (int columns, int rows)? size,
  }) async {
    if (isConnected || _connecting) return;
    _autoConnect = false;

    _wireTerminal();
    if (size != null) _size = size;

    final attempt = ++_attempt;
    bool current() => attempt == _attempt && !_disposed;
    _connecting = true;
    _error = null;
    _authBanner = null;
    _authUrl = null;
    _notify();

    try {
      // A banner for an attempt given up on is not this one's sign-in.
      void banner(String text) {
        if (current()) _onAuthBanner(text);
      }

      final transport =
          _transport?.call(confirmHostKey, banner) ??
          IsolateTransport(
            confirmHostKey: confirmHostKey,
            onAuthBanner: banner,
          );
      // The key this host's servers sign a push to the relay with, and the
      // host a tap opens, for a script on the host to read rather than anyone
      // copying them over by hand; never the FCM token. A host's first
      // connect registers its key while SSH signs in, and the shell waits a
      // little more for it at most: a relay out of reach leaves it to the
      // next connect, and this one goes without. `LC_` because sshd takes
      // only the names its AcceptEnv lists, and Debian, Ubuntu and macOS ship
      // `AcceptEnv LANG LC_*`: how iTerm2's `LC_TERMINAL` gets through. The
      // direct way's two join them from [_openNotifyPort].
      final key = _notifyKeys?.forConnect(host.id);
      Future<Map<String, String>> environment(ForwardCapable connection) async {
        final value = await key?.timeout(
          const Duration(seconds: 3),
          onTimeout: () => null,
        );
        return {
          if (value != null) ...{
            'LC_SSHBOX_KEY': value,
            'LC_SSHBOX_HOST_ID': host.id,
          },
          if (_onNotify != null) ...await _openNotifyPort(connection),
        };
      }

      // What the shell is opened at, to be put right once it is up.
      var opened = _size;
      Future<TerminalSession> open({required bool shell}) {
        opened = _size;
        return transport.connect(
          host: host,
          secrets: secrets,
          columns: _size.$1,
          rows: _size.$2,
          shell: shell,
          beforeShell: environment,
        );
      }

      var session = await open(shell: !host.useTmux);
      if (host.useTmux && _checkTmux && await _tmuxMissing(session)) {
        await session.dispose();
        if (current()) {
          _tmuxGone = true;
          _error =
              'The tmux session $tmuxName is no longer on '
              '${host.displayName}: the host restarted, or the session was '
              'ended there.';
        }
        return;
      }
      final tmux = host.useTmux ? await _attachTmux(session) : null;
      if (host.useTmux && tmux == null) {
        // The plain shell the host would have had without the switch.
        await session.dispose();
        session = await open(shell: true);
      }

      if (!current()) {
        // Given up on while it connected, so nothing will ever show it. A
        // tab that has closed takes its tmux session with it, as closing a
        // tab always does; one still open keeps it for its next reconnect.
        if (_disposed) await tmux?.kill();
        tmux?.dispose();
        await session.dispose();
        return;
      }

      _tmux = tmux;
      _checkTmux = false;
      _tmuxGone = false;
      for (final path in _restoredFiles) {
        if (!_openFiles.contains(path)) _openFiles.add(path);
      }
      _restoredFiles.clear();
      _outputSubscription = session.output.listen(_terminal.write);
      session.status.addListener(_onStatusChanged);
      _session = session;
      // A page laid out while this waited — at a sign-in, beside its web
      // tab — had no shell yet to tell its size to.
      if (_size != opened) session.resize(_size.$1, _size.$2, 0, 0);
      // Through the sign-in: its page has done its work.
      _webTabs.removeWhere((tab) => tab._signIn);
      _syncForwarding();
      unawaited(_fetchHostname());
      unawaited(_saveOs(secrets));
    } on SshSessionException catch (error) {
      if (current()) _error = error.message;
    } catch (error) {
      if (current()) _error = error.toString();
    } finally {
      if (current()) {
        _connecting = false;
        _notify();
      }
    }
  }

  /// Asks the host for a port on its loopback that comes down this
  /// connection, for a server to notify the phone straight through it with
  /// no FCM: see [DirectNotify]. What it returns joins the shell's
  /// variables. A host that will not — `AllowTcpForwarding no`, or anything
  /// else — leaves this connection without them, and nothing is said.
  ///
  /// Asked for on every connection that opens a shell or tmux, before it
  /// does, and gone with that connection: the host stops listening when it
  /// ends, and no channel comes after.
  Future<Map<String, String>> _openNotifyPort(ForwardCapable connection) async {
    final show = _onNotify!;
    try {
      // The shell waits on this, so a host that never answers must not
      // hold it up.
      final port = await connection
          .listen('127.0.0.1', 0)
          .timeout(const Duration(seconds: 10));
      final direct = DirectNotify(
        (title, body) => show(hostId: host.id, title: title, body: body),
      );
      // A caller that hangs up before its answer is nobody's problem.
      port.connections.listen((tunnel) => direct.serve(tunnel).ignore());
      return direct.environment(port.port);
    } catch (_) {
      return const {};
    }
  }

  /// Starts this tab's tmux session on the connection [session] holds, and
  /// says why not when it cannot.
  Future<TmuxSession?> _attachTmux(TerminalSession session) async {
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
        record: _host.recordPanes,
      );
    } catch (error) {
      _tmuxProblem = '$error';
      return null;
    }
    // A host that neither starts tmux nor says why must not leave the tab
    // spinning.
    final attached = await tmux.attached.timeout(
      const Duration(seconds: 20),
      onTimeout: () => false,
    );
    if (attached) return tmux;
    tmux.dispose();
    _tmuxProblem = tmux.problem ?? 'tmux did not answer.';
    return null;
  }

  /// Whether this tab's tmux session is gone from the host, asked before a
  /// tab brought back from an earlier run attaches: attaching would make a
  /// new one. A host that cannot say counts as still having it, and the
  /// attach says what is wrong.
  Future<bool> _tmuxMissing(TerminalSession session) async {
    if (session is! CommandCapable) return false;
    try {
      final lines = await (session as CommandCapable)
          .run(TmuxSession.exists(tmuxName))
          .toList();
      final last = lines.lastWhere(
        (line) => line.trim().isNotEmpty,
        orElse: () => '',
      );
      return last.trim() == 'no';
    } catch (_) {
      return false;
    }
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
  /// comes after the shell. Not a marker of our own sent with the shell: a
  /// host may refuse the variables sent with it, as sshd does any its
  /// AcceptEnv does not list, and Tailscale SSH any its tailnet policy does
  /// not.
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

  /// Asks the host what it runs and saves that on its profile for the host
  /// list, on every connect: an edited address may reach another machine.
  /// Silent: the connection never waits on it, and a failure is no answer.
  Future<void> _saveOs(SecretStore secrets) async {
    final session = _session;
    if (session is! CommandCapable) return;
    try {
      final os = await OsInfo.detect((session as CommandCapable).run);
      if (os != null && await HostRepository(secrets).saveOs(host.id, os)) {
        _notify();
      }
    } catch (_) {
      // The host list keeps what it had.
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

  /// Shares handed to this session from outside the terminal page, waiting for
  /// the page to be on screen and the shell to be up: each a [SharedFile] to
  /// upload, or a [String] to paste at the prompt.
  ///
  /// A share can arrive while the app is dead, so it has to wait somewhere
  /// that outlives the widget — same reason the terminal does.
  final List<Object> _pendingUploads = [];

  bool get hasPendingUploads => _pendingUploads.isNotEmpty;

  void queueUploads(Iterable<Object> shares) {
    if (shares.isEmpty) return;
    _pendingUploads.addAll(shares);
    _notify();
  }

  /// Hands the queue over and empties it, so a redraw cannot upload twice.
  List<Object> takePendingUploads() {
    final taken = List<Object>.of(_pendingUploads);
    _pendingUploads.clear();
    return taken;
  }

  /// Uploads into `/tmp` on the remote host and returns the path to type.
  Future<String> uploadToTmp({
    required String localPath,
    required String fileName,
    void Function(int sent, int total)? onProgress,
    Future<void>? cancel,
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
      cancel: cancel,
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
    Future<bool> Function(HostKeyCheck check)? confirmHostKey,
  }) async {
    await disconnect();
    _terminal.write('\x1b[2J\x1b[H');
    await connect(secrets: secrets, confirmHostKey: confirmHostKey);
  }

  /// Gives up on the connect under way — what closing its sheet does. A host
  /// key it was asking about has been refused by then, and a connection it
  /// still makes is let go when it comes. The tab, if it has one, is left
  /// ended, offering to reconnect.
  void abandon() {
    if (!_connecting) return;
    _attempt++;
    _connecting = false;
    _error = 'Connection cancelled.';
    _notify();
  }

  @override
  void dispose() {
    // Flag first: teardown continues after this method returns, and anything
    // it triggers must not touch a disposed notifier.
    _disposed = true;
    unawaited(_teardown(kill: true));
    _chat?.dispose();
    _chat = null;
    // Not only the git tab's: the panel also opens in the terminal's drawer,
    // which never closes them.
    _repos?.dispose();
    _repos = null;
    _terminal.dispose();
    super.dispose();
  }
}

/// What a tab shows: the shell on a host, a file opened over that shell, or
/// a web page a link in it opened.
enum TabKind { terminal, chat, git, diff, file, web }

/// A web page in a tab beside the shell whose link opened it.
class WebTab {
  WebTab._(this._url);

  /// Names the tab for as long as it is open. Its address cannot: that
  /// changes with every link followed on the page.
  final int id = _nextId++;
  static int _nextId = 0;

  Uri _url;
  String? _title;

  /// Opened by the session's sign-in — see [LiveSession.openWeb].
  bool _signIn = false;

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

/// A database open in a tab of its own — see `DbBrowserPage`. It keeps its
/// own connection, so it hangs off no session, and its tab comes after every
/// session's.
class DbTab {
  DbTab._(this.db, this.title);

  /// Names the tab for as long as it is open.
  final int id = _nextId++;
  static int _nextId = 0;

  final DbConnection db;

  /// What the tab is called: the database's name, or its kind and host.
  final String title;
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
  SessionManager({this.notifyKeys, this.onNotify});

  /// The relay keys, one per host: what each connection hands its host as
  /// `LC_SSHBOX_KEY`, what a host's edit page copies and what Settings
  /// resets. Null where push is not wired, as in most tests, and then no
  /// connection hands one.
  final NotifyKeys? notifyKeys;

  /// Shows a notification a host sent straight down one of its connections
  /// — see [DirectNotify] — as a push is shown, a tap opening the host.
  /// Null, and no connection offers the host that way.
  final ShowNotification? onNotify;

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

  /// Databases open in tabs of their own, after every session's: see
  /// [openDb].
  final List<DbTab> _dbTabs = [];

  List<DbTab> get dbTabs => List.unmodifiable(_dbTabs);

  /// The database whose tab is showing. [activeId] is null then, as for the
  /// host list: a database's tab hangs off no session.
  DbTab? _activeDb;

  DbTab? get activeDb => _activeDb;

  /// Whether the Transfers tab is on the strip, after every other: see
  /// [showTransfers]. Not saved with the tabs: what it lists ends with the
  /// app.
  bool _transfersTab = false;

  bool get transfersTab => _transfersTab;

  /// Whether the Transfers tab is the one showing. [activeId] is null then,
  /// as for the host list.
  bool _transfersActive = false;

  bool get transfersActive => _transfersActive;

  /// null selects the pinned host list, or with [db], that database's tab,
  /// or with [transfers], the Transfers tab.
  void select(
    int? id, {
    TabKind kind = TabKind.terminal,
    String? path,
    WebTab? web,
    DbTab? db,
    bool transfers = false,
  }) {
    final showTransfers = id == null && db == null && transfers;
    if (_activeId == id &&
        _activeKind == kind &&
        _activePath == path &&
        _activeWeb == web &&
        _activeDb == db &&
        _transfersActive == showTransfers) {
      return;
    }
    _activeId = id;
    _activeKind = kind;
    // A diff tab is named by its key the way a file tab is named by its path:
    // one session can have several of either, and this is what tells them
    // apart on the strip.
    _activePath = kind == TabKind.file || kind == TabKind.diff ? path : null;
    _activeWeb = kind == TabKind.web ? web : null;
    _activeDb = id == null ? db : null;
    _transfersActive = showTransfers;
    if (showTransfers) _transfersTab = true;
    _activeLine = null;
    // Going back to the host list leaves the last session standing as the
    // active one: a file shared from another app still has somewhere to go.
    if (id != null) _active = _sessions[id];
    notifyListeners();
  }

  /// Opens [db] in a tab of its own, named [title], after every session's,
  /// and shows it. A database already open just goes back to its tab.
  void openDb(DbConnection db, String title) {
    var tab = _dbTabs.where((tab) => tab.db.id == db.id).firstOrNull;
    if (tab == null) _dbTabs.add(tab = DbTab._(db, title));
    select(null, db: tab);
  }

  /// Closes a database's tab, which lets its connection go. The one showing
  /// lands on its left-hand neighbour: the database before it, else the last
  /// session's shell, else the host list.
  void closeDb(DbTab tab) {
    final index = _dbTabs.indexOf(tab);
    if (index < 0) return;
    _dbTabs.removeAt(index);
    if (_activeDb != tab) {
      notifyListeners();
    } else if (index > 0) {
      select(null, db: _dbTabs[index - 1]);
    } else {
      select(_sessions.keys.lastOrNull);
    }
  }

  /// Puts the Transfers tab on the strip, after every other, and with
  /// [select], shows it.
  void showTransfers({bool select = false}) {
    if (select) {
      this.select(null, transfers: true);
    } else if (!_transfersTab) {
      _transfersTab = true;
      notifyListeners();
    }
  }

  /// Takes the Transfers tab off the strip; what it lists carries on. The
  /// one showing lands on its left-hand neighbour: the last database, else
  /// the last session's shell, else the host list.
  void closeTransfers() {
    if (!_transfersTab) return;
    _transfersTab = false;
    final db = _dbTabs.lastOrNull;
    if (!_transfersActive) {
      notifyListeners();
    } else if (db != null) {
      select(null, db: db);
    } else {
      select(_sessions.keys.lastOrNull);
    }
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
    if (_activeId == id && _activeKind == TabKind.file && _activePath == path) {
      select(id);
    }
  }

  /// Opens this session's chat with Claude in a tab beside its shell, and
  /// shows it. Asking again goes back to the tab already there.
  void openChat(int id) {
    final session = _sessions[id];
    if (session == null) return;
    session.openChat();
    select(id, kind: TabKind.chat);
  }

  /// Closing the chat tab lands on the shell it sits beside, and ends the
  /// Claude running for it.
  void closeChat(int id) {
    final session = _sessions[id];
    if (session == null) return;
    session.closeChat();
    if (_activeId == id && _activeKind == TabKind.chat) select(id);
  }

  /// Opens this session's git panel in a tab beside its shell, and shows it.
  /// Asking again goes back to the tab already there.
  void openGit(int id) {
    final session = _sessions[id];
    if (session == null) return;
    session.openGit();
    select(id, kind: TabKind.git);
  }

  /// Opens a diff from this session's git panel in a file tab of its own, and
  /// shows it. The same diff asked for again goes back to the tab it is in.
  void openDiff(int id, GitDiff diff) {
    final session = _sessions[id];
    if (session == null) return;
    session.openDiff(diff);
    select(id, kind: TabKind.diff, path: diff.key);
  }

  /// Closing a diff lands on the shell it was opened beside; the git panel,
  /// wherever it is, is untouched.
  void closeDiff(int id, String key) {
    final session = _sessions[id];
    if (session == null) return;
    session.closeDiff(key);
    if (_activeId == id && _activeKind == TabKind.diff && _activePath == key) {
      select(id);
    }
  }

  /// Closing the git tab lands on the shell it sits beside, and lets go of
  /// the repositories it found.
  void closeGit(int id) {
    final session = _sessions[id];
    if (session == null) return;
    session.closeGit();
    if (_activeId == id && _activeKind == TabKind.git) select(id);
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

  /// Passes a session's change on to the tabs. A web tab the session closed
  /// itself — a sign-in's, once the session is through it — lands on its
  /// shell, as closing one by hand does, not on the host list.
  void _onSessionChanged() {
    final web = _activeWeb;
    if (web != null && _active?.webTabs.contains(web) == false) {
      select(_activeId);
    } else {
      notifyListeners();
    }
  }

  int get liveCount => _sessions.values.where((s) => s.isConnected).length;

  /// Every session open on this host, in tab order.
  List<LiveSession> sessionsFor(String hostId) =>
      _sessions.values.where((s) => s.host.id == hostId).toList();

  /// Another terminal on this host, with no tab yet: the connect sheet
  /// connects it, and [add] gives it one once it is up, or once its sign-in
  /// has gone to a web tab beside it. [transport] is a test's, as
  /// [LiveSession] takes one.
  ///
  /// [tmuxName] and [restored] bring back a tab saved by an earlier run: see
  /// [restoreTabs].
  LiveSession create(
    HostProfile host, {
    TransportMaker? transport,
    String? tmuxName,
    bool restored = false,
  }) {
    late final LiveSession created;
    created = LiveSession(
      host: host,
      forwardedElsewhere: (port) =>
          sessionsFor(created.host.id)
              .any((s) => s != created && s.forwarder.isForwarding(port)),
      transport: transport,
      notifyKeys: notifyKeys,
      onNotify: onNotify,
      tmuxName: tmuxName,
      restored: restored,
    );
    return created;
  }

  /// Gives [session] its tab, at the end of the strip, and shows it.
  void add(LiveSession session) {
    session.addListener(_onSessionChanged);
    _sessions[session.id] = session;
    _active = session;
    _activeId = session.id;
    _activeKind = TabKind.terminal;
    _activePath = null;
    _activeWeb = null;
    _activeDb = null;
    _transfersActive = false;
    notifyListeners();
  }

  /// [create] and [add] at once: a tab before its shell is up, which only a
  /// test wants.
  @visibleForTesting
  LiveSession open(HostProfile host, {TransportMaker? transport}) {
    final session = create(host, transport: transport);
    add(session);
    return session;
  }

  /// Takes the user back to a terminal on this host — the one they were last
  /// in, else its newest — and shows it. Null when it has none: a new one
  /// connects in its sheet first.
  LiveSession? resume(String hostId) {
    final existing = _active?.host.id == hostId
        ? _active
        : sessionsFor(hostId).lastOrNull;
    if (existing != null) select(existing.id);
    return existing;
  }

  Future<void> close(int id) async {
    final ids = _sessions.keys.toList();
    final index = ids.indexOf(id);
    final session = _sessions.remove(id);
    if (session == null) return;
    session.removeListener(_onSessionChanged);
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

  /// Where the open tabs are saved as they change: see [restoreTabs].
  static const _savedKey = 'sshbox.tabs.v1';

  /// Whether tab changes are saved: from the end of [restoreTabs], so what it
  /// brings back is not written over first, until [shutdown].
  bool _saving = false;

  /// What was last written, so an unchanged list is not written again.
  String? _saved;

  @override
  void notifyListeners() {
    super.notifyListeners();
    _save();
  }

  /// The open tabs as they are saved: what finds each again, and nothing
  /// secret. Each terminal's host and tmux name, its files, and its web
  /// pages by address alone; then the databases, by id.
  void _save() {
    if (!_saving) return;
    final json = jsonEncode({
      'sessions': [
        for (final session in _sessions.values)
          {
            'hostId': session.host.id,
            'tmux': session.tmuxName,
            // Whether the chat tab was on the strip, never what was said in
            // it: the conversation lives in the Claude the host ran, and that
            // went when the app did.
            if (session._chatOpen) 'chat': true,
            // The same for the git tab: which repositories there are, and
            // which was picked, are found again on the host it asks.
            if (session._gitOpen) 'git': true,
            'files': [...session._restoredFiles, ...session._openFiles],
            'web': [
              for (final web in session._webTabs)
                if (!web._signIn) ?_savedUrl(web.url),
            ],
          },
      ],
      'databases': [for (final tab in _dbTabs) tab.db.id],
    });
    if (json == _saved) return;
    _saved = json;
    unawaited(
      SharedPreferences.getInstance().then(
        (prefs) => prefs.setString(_savedKey, json),
      ),
    );
  }

  /// A web page's address as it is saved: without credentials, query or
  /// fragment, which can carry a token, and never a Tailscale sign-in, whose
  /// link works once.
  static String? _savedUrl(Uri url) =>
      (url.isScheme('http') || url.isScheme('https')) &&
          url.host != 'login.tailscale.com'
      ? Uri(
          scheme: url.scheme,
          host: url.host,
          port: url.hasPort ? url.port : null,
          path: url.path,
        ).toString()
      : null;

  /// Brings back the tabs open when the app last went away, as a browser
  /// does, and saves them from then on as they change. Each terminal comes
  /// back unconnected, under its old tmux name, and connects the first time
  /// its tab shows; its files come back once it has. A tab whose host or
  /// database has been deleted since does not come back. [transport] is a
  /// test's, as [create] takes one.
  Future<void> restoreTabs({
    required List<HostProfile> hosts,
    required List<DbConnection> databases,
    TransportMaker? transport,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final saved = jsonDecode(
        prefs.getString(_savedKey) ?? '{}',
      ) as Map<String, dynamic>;
      for (final tab in saved['sessions'] as List? ?? const []) {
        if (tab is! Map<String, dynamic>) continue;
        final host = hosts
            .where((host) => host.id == tab['hostId'])
            .firstOrNull;
        if (host == null) continue;
        final tmux = tab['tmux'];
        final session = create(
          host,
          transport: transport,
          tmuxName: tmux is String && LiveSession.tmuxNamePattern.hasMatch(tmux)
              ? tmux
              : null,
          restored: true,
        );
        session._chatOpen = tab['chat'] == true;
        session._gitOpen = tab['git'] == true;
        session._restoredFiles.addAll(
          (tab['files'] as List? ?? const []).whereType<String>(),
        );
        for (final url
            in (tab['web'] as List? ?? const []).whereType<String>()) {
          final uri = Uri.tryParse(url);
          if (uri != null && _savedUrl(uri) != null) session.openWeb(uri);
        }
        session.addListener(_onSessionChanged);
        _sessions[session.id] = session;
      }
      for (final id in saved['databases'] as List? ?? const []) {
        final db = databases.where((db) => db.id == id).firstOrNull;
        if (db == null || _dbTabs.any((tab) => tab.db.id == id)) continue;
        final host = hosts.where((host) => host.id == db.hostId).firstOrNull;
        _dbTabs.add(DbTab._(db, db.displayName(host)));
      }
    } catch (_) {
      // A corrupt list costs its tabs, not the app's start.
    }
    _saving = true;
    notifyListeners();
  }

  /// What the app going away does: every connection is let go, and every
  /// tmux session left running on its host for its tab to come back to, as
  /// the tabs were last saved. Only a tab's own close ends its tmux session.
  Future<void> shutdown() async {
    _saving = false;
    for (final session in _sessions.values.toList()) {
      await session.disconnect();
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

/// Keeps a key's release to itself unless the program asked for releases,
/// which it does with kitty's flag 2, "report event types".
///
/// xterm2's kitty handler encodes a release whenever the protocol is on, and
/// without flag 2 it has nothing to mark it with, so the release went out as
/// the press all over again. Claude Code pushes flags 1 and 4 (`ESC [>5u`),
/// so one hardware Ctrl+T reached it twice, and Shift+Enter made two new
/// lines. The key bar was never affected, since it sends bytes rather than
/// presses and releases. Every other handler already drops releases.
class _ReleaseOnlyIfAsked implements TerminalInputHandler {
  const _ReleaseOnlyIfAsked(this._keys);

  final TerminalInputHandler _keys;

  static const _reportEventTypes = 0x02;

  @override
  String? call(TerminalKeyboardEvent event) {
    if (event.type == TerminalKeyEventType.release &&
        event.state.kittyKeyboardMode & _reportEventTypes == 0) {
      return null;
    }
    return _keys(event);
  }
}
