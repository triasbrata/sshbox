import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm2/xterm.dart';

import '../data/secret_store.dart';
import '../files/file_browser.dart';
import '../session/session_manager.dart';
import 'ctrl_click.dart';
import 'file_browser_page.dart';
import 'key_bar.dart';
import 'magic_key.dart';
import 'terminal_link.dart';
import 'terminal_text_input.dart';
import 'tmux_panes.dart';

/// Shows a [LiveSession]. Deliberately owns nothing that must survive
/// navigation — the terminal, its scrollback and the SSH connection all belong
/// to the session, so leaving this page keeps them alive and coming back
/// re-attaches to the same shell.
class TerminalPage extends StatefulWidget {
  const TerminalPage({
    super.key,
    required this.session,
    required this.secrets,
    required this.onOpenFile,
    required this.onSaveFileRoot,
  });

  final LiveSession session;
  final SecretStore secrets;

  /// Opens a file picked in the drawer as a tab of its own, next to this one.
  final void Function(String path) onOpenFile;

  /// Writes the file tree's root into this host's saved config.
  final Future<void> Function(String root) onSaveFileRoot;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  final _keyBar = KeyBarController();
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// What the file browser is allowed to do to this shell. Owned here so the
  /// "follow" switch survives the drawer being torn down and rebuilt.
  late final _terminalLink = TerminalLink(
    typePath: _typePath,
    changeDirectory: _cdTo,
  );

  /// Every terminal on screen, by the [Terminal] it shows — the shell's, or
  /// each tmux pane's — so what acts on all of them can reach each: a key
  /// sent letting go of a selection, Ctrl coming down underlining links.
  final _views = <Terminal, GlobalKey<_PaneViewState>>{};
  bool _ctrlShown = false;

  Iterable<_PaneViewState> get _paneViews =>
      _views.values.map((key) => key.currentState).nonNulls;

  bool _uploading = false;
  double? _uploadProgress;

  /// Kept for the width of a tablet session rather than per visit, because the
  /// drawer holding it is rebuilt every time it opens and reconnecting SFTP on
  /// each open would be felt.
  FileBrowser? _browser;

  /// Where the drawer's tree was last rooted and which folders were open in
  /// it, so reopening it does not fold the tree shut and throw the user back
  /// to the host's root.
  String? _browseRoot;
  Set<String> _browseExpanded = const {};

  /// And how far down it was scrolled, kept with the root it was scrolled
  /// under: a drawer sent to open at another folder starts at the top of it,
  /// not at an offset measured in a different tree.
  ({String? root, double offset}) _browseScroll = (root: null, offset: 0);

  LiveSession get _session => widget.session;

  /// Forwards and problems already announced, so each gets one snack bar.
  /// Held by identity: a server that restarts is a new forward, and says so.
  final _announced = <Object>{};

  @override
  void initState() {
    super.initState();

    // Only meaningful while this page is on screen, so it is installed and
    // removed with the widget rather than held by the session.
    _session.outputTransform = _outgoing;
    _session.addListener(_onSessionChanged);
    _keyBar.addListener(_syncCtrl);
    HardwareKeyboard.instance.addHandler(_onHardwareKey);

    // Connect after first layout so the PTY opens at the real on-screen size.
    // A no-op when we are returning to a session that is already connected.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _session.connect(
        secrets: widget.secrets,
        onHostKeyPinned: _reportPinnedKey,
      );
      // Files queued before this page existed. Connecting to an already-live
      // session is a no-op and notifies nothing, so the drain cannot rely on
      // the listener alone.
      unawaited(_drainShared());
    });
  }

  void _onSessionChanged() {
    if (!mounted) return;
    // A browser is carried by the connection that made it, so when the session
    // goes, so does the browser and anything opened through it. Holding on
    // would leave the pane showing a file nothing can save.
    if (!_session.isConnected && _browser != null) {
      _browser!.close();
      _browser = null;
      // Forgotten with the connection, so the first tree after logging in
      // again opens where the host's config says rather than where the last
      // session wandered off to.
      _browseRoot = null;
      _browseExpanded = const {};
      _browseScroll = (root: null, offset: 0);
    }
    setState(() {});
    _announceForwards();
    final tmuxProblem = _session.takeTmuxProblem();
    if (tmuxProblem != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Not using tmux: $tmuxProblem')),
      );
    }
    // A file shared from another app may have been queued before this page
    // existed, or before the shell came up. Either way the session notifies,
    // and this is where it lands.
    unawaited(_drainShared());
  }

  /// Says so when a server lands on the tailnet, or cannot, with a way
  /// straight to it — whichever tab is showing, because the moment it lands
  /// is when the address is wanted.
  void _announceForwards() {
    final messenger = ScaffoldMessenger.of(context);
    final forwarder = _session.forwarder;
    for (final forward in forwarder.forwards) {
      final address = forward.address;
      if (address == null && forward.error == null) continue;
      if (!_announced.add(forward)) continue;
      messenger.showSnackBar(
        address != null
            ? SnackBar(
                duration: const Duration(seconds: 8),
                content: Text('Port ${forward.port} is on $address'),
                action: SnackBarAction(
                  label: 'Open',
                  onPressed: () =>
                      openUrl(context, Uri.parse('http://$address')),
                ),
              )
            : SnackBar(
                content: Text(
                  'Port ${forward.port} not forwarded: ${forward.error}',
                ),
              ),
      );
    }
    final problem = forwarder.problem;
    if (problem != null && _announced.add(problem)) {
      messenger.showSnackBar(
        SnackBar(content: Text('Not forwarding ports: $problem')),
      );
    }
  }

  /// Uploads anything handed to the session from outside the terminal page.
  Future<void> _drainShared() async {
    if (_uploading || !_session.isConnected || !_session.hasPendingUploads) {
      return;
    }
    // Opening a session replaces this page with a fresh one; only whichever is
    // actually on screen takes the queue, so the progress bar is visible and
    // no file is uploaded twice.
    if (ModalRoute.of(context)?.isCurrent != true) return;
    for (final file in _session.takePendingUploads()) {
      await _upload(file);
    }
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    if (_session.outputTransform == _outgoing) {
      _session.outputTransform = null;
    }
    _keyBar.dispose();
    _terminalLink.dispose();
    // Ours to close: the drawer and the editor pane are handed this rather
    // than owning it.
    _browser?.close();
    // The session itself is intentionally left running.
    super.dispose();
  }

  /// Typing, from either keyboard, on its way out: armed key-bar modifiers are
  /// folded in, and a selection is let go, since a key sent means you are done
  /// reading it.
  String _outgoing(String data) {
    _letGo();
    return _keyBar.applyModifiers(data);
  }

  /// The same for the keys the bar, the pad and the magic key send.
  void _send(String data) {
    _letGo();
    _session.sendRaw(data);
  }

  void _letGo() {
    for (final view in _paneViews) {
      view.selection.clearSelection();
    }
  }

  void _reportPinnedKey(String fingerprint) {
    if (mounted) reportPinnedKey(context, fingerprint);
  }

  Future<void> _reconnect() => _session.reconnect(
        secrets: widget.secrets,
        onHostKeyPinned: _reportPinnedKey,
      );

  /// Opens the remote filesystem as a native listing.
  ///
  /// The browser is built here and handed over; the page it goes to closes it
  /// when the user leaves. Which transport is behind it is decided by
  /// [LiveSession.openFileBrowser] and is not this page's business.
  /// The listing is a drawer on every size.
  ///
  /// Tapping outside it puts you back in the terminal in one gesture, from
  /// however deep in the tree you had wandered — which a full screen of its
  /// own could not do.
  Future<void> _openFiles() async {
    setState(() => _browser ??= _session.openFileBrowser());
    _scaffoldKey.currentState?.openEndDrawer();
  }

  Widget _buildFilesDrawer() {
    final browser = _browser;
    if (browser == null) return const Drawer(child: SizedBox.shrink());

    return Drawer(
      // Wider than Material's 304dp default, because every row here is a path
      // and the default truncates most of them — but never so wide on a phone
      // that there is no terminal left to tap back onto.
      width: math.min(360, MediaQuery.sizeOf(context).width * 0.85),
      child: FileBrowserPage(
        browser: browser,
        title: _session.host.displayName,
        initialRoot: _browseRoot ?? _session.host.fileRoot,
        initialExpanded: _browseExpanded,
        initialScrollOffset:
            _browseScroll.root == _browseRoot ? _browseScroll.offset : 0,
        ownsBrowser: false,
        onRootChanged: (root) => _browseRoot = root,
        onExpandedChanged: (expanded) => _browseExpanded = expanded,
        onScrollChanged: (offset) =>
            _browseScroll = (root: _browseRoot, offset: offset),
        onSaveRoot: widget.onSaveFileRoot,
        terminal: _terminalLink,
        onClose: _closeFilesDrawer,
        onFileSelected: _openFileTab,
      ),
    );
  }

  void _closeFilesDrawer() => _scaffoldKey.currentState?.closeEndDrawer();

  /// A picked file becomes a tab of its own, beside this session's — the same
  /// answer on every size, so there is one place a file is ever opened.
  void _openFileTab(String path) {
    _closeFilesDrawer();
    widget.onOpenFile(path);
  }

  /// Whether a tap now is a Ctrl+tap: CTRL latched on the bar, or held on a
  /// hardware keyboard — which covers a mouse click with Ctrl too.
  bool get _ctrl => _keyBar.ctrl || HardwareKeyboard.instance.isControlPressed;

  /// Only watches. The key still goes wherever it was going.
  bool _onHardwareKey(KeyEvent _) {
    _syncCtrl();
    return false;
  }

  /// Underlines every link on every terminal on screen while Ctrl is down,
  /// and takes them away when it lifts or is used up.
  void _syncCtrl() {
    final ctrl = _ctrl;
    if (!mounted || ctrl == _ctrlShown) return;
    _ctrlShown = ctrl;
    final color = Theme.of(context).colorScheme.primary;
    for (final view in _paneViews) {
      view.showLinks(ctrl: ctrl, color: color);
    }
  }

  /// With Ctrl, opens the link under the tap and types nothing; without, asks
  /// for the keyboard back, the way a tap always has.
  void _onTerminalTap(_PaneViewState view, CellOffset cell) {
    if (!_ctrl) {
      view.requestKeyboard();
      return;
    }
    // Used up by the tap, link or not, the way a key uses it up.
    if (_keyBar.ctrl) _keyBar.toggleCtrl();
    final link = linkAt(view.widget.terminal.buffer, cell);
    if (link != null) unawaited(_openLink(link));
  }

  /// A URL goes to the browser, a folder becomes the files drawer's root, and
  /// a file opens in a tab the way one picked in the drawer does.
  ///
  /// A relative path starts from the program that printed it, the terminal's
  /// foreground process on the host, and from home when the host cannot say.
  ///
  /// ponytail: the line number is read and dropped; the editor cannot open at
  /// a line yet.
  Future<void> _openLink(LinkCandidate link) async {
    final target = link.target;
    if (link.kind == LinkKind.url) {
      final url = Uri.tryParse(target);
      if (url != null) await openUrl(context, url);
      return;
    }
    if (!_session.isConnected || !_session.canBrowseFiles) return;

    final messenger = ScaffoldMessenger.of(context);
    final browser = _session.fileBrowser;
    final relative = !target.startsWith('/') && !target.startsWith('~');
    try {
      final cwd = relative ? (await _session.foreground())?.cwd : null;
      final path = RemotePath.normalize(
        cwd != null
            ? RemotePath.join(cwd, target)
            : RemotePath.resolve(
                target,
                target.startsWith('/') ? '/' : await browser.resolveHome(),
              ),
      );
      final kind = await browser.stat(path);
      if (!mounted) return;
      switch (kind) {
        case RemoteEntryKind.directory:
          _browseRoot = path;
          await _openFiles();
        case RemoteEntryKind.file:
          _openFileTab(path);
        case RemoteEntryKind.other || RemoteEntryKind.symlink:
          messenger.showSnackBar(
            SnackBar(content: Text('Not a file or a folder: $path')),
          );
        case null:
          // A bare name only counted if it was there, so a miss on one is
          // nothing under the tap.
          if (link.kind == LinkKind.name) return;
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                relative && cwd == null
                    ? 'Not found: $path\nTaken from home: the host did not '
                          'say where the terminal is.'
                    : 'Not found: $path',
              ),
            ),
          );
      }
    } on FileBrowserException catch (error) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  /// Wraps a path so the shell sees exactly these characters.
  ///
  /// A path picked out of a listing can hold spaces, or anything else the
  /// shell would act on rather than pass along.
  static String _shellQuote(String path) =>
      RegExp(r'^[A-Za-z0-9._/-]+$').hasMatch(path)
          ? path
          : "'${path.replaceAll("'", r"'\''")}'";

  /// Puts a path at the prompt, ready for a command to be written around it.
  void _typePath(String path) => _session.sendRaw('${_shellQuote(path)} ');

  /// Sends the shell to a directory — the one way anything does, so every
  /// `cd` is checked here.
  ///
  /// The newline is what separates this from [_typePath]: it runs something.
  /// With a program in the foreground, that something is the program's input
  /// — `cd` sent to Claude Code is a message to it — so the host is asked
  /// first, and anything short of "the shell is at its prompt" types nothing
  /// and says why. A shell already there types nothing either: opening a
  /// folder and shutting it again is two taps on one place.
  ///
  /// In a tab set to use tmux, tmux answers for the focused pane, and the
  /// `cd` goes there.
  ///
  /// ponytail: inside a tmux started by hand the probe sees tmux, not the
  /// pane's shell, so every `cd` is refused as "tmux is running".
  Future<void> _cdTo(String path) async {
    final messenger = ScaffoldMessenger.of(context);
    // Replacing rather than queueing: following, every folder tapped on the
    // way down to a file can be refused, and each would wait its turn.
    void refuse(String why) => messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(why)));

    var slow = false;
    final now = await _session.foreground().timeout(
      const Duration(milliseconds: 1500),
      onTimeout: () {
        slow = true;
        return null;
      },
    );
    if (now == null) {
      refuse(slow
          ? 'No answer from the host in time — not moving the shell'
          : 'The host cannot say what the shell is running — not moving it');
    } else if (!now.shellInForeground) {
      refuse('${now.program} is running — not moving the shell');
    } else if (now.cwd != path) {
      _session.sendRaw('cd ${_shellQuote(path)}\n');
    }
  }

  /// Pick a file, send it to `/tmp` on the host, then type the remote path at
  /// the prompt — so the next thing you write is a command that uses it.
  Future<void> _attachFile() async {
    final file = await FilePicker.pickFile();
    final localPath = file?.path;
    // Something picked from a cloud provider has no filesystem path, and so
    // nothing for SFTP to read.
    if (file == null || localPath == null) return;
    await _upload((path: localPath, name: file.name));
  }

  /// The one upload path: the paperclip and the share sheet both end here, so
  /// progress, the typed remote path and the error message cannot drift apart.
  Future<void> _upload(SharedFile file) async {
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _uploading = true);

    try {
      final remotePath = await _session.uploadToTmp(
        localPath: file.path,
        fileName: file.name,
        onProgress: (sent, total) {
          if (!mounted || total == 0) return;
          setState(() => _uploadProgress = sent / total);
        },
      );

      // A trailing space so the path is ready to be followed by arguments.
      _session.sendRaw('$remotePath ');

      messenger.showSnackBar(
        SnackBar(content: Text('Uploaded to $remotePath')),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Upload failed: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _uploading = false;
          _uploadProgress = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      endDrawer: _buildFilesDrawer(),
      // Never by edge swipe: the terminal owns horizontal gestures, and having
      // the file list slide over the shell mid-command would be maddening.
      endDrawerEnableOpenDragGesture: false,
      // No app bar: the tab strip above already names the session, and the
      // page's two buttons ride in the key bar, where the thumb already is.
      body: _buildBody(),
      // In the Scaffold's own slot rather than the body so it rides above the
      // soft keyboard and the button below floats clear of it.
      bottomNavigationBar: TerminalKeyBar(
        controller: _keyBar,
        terminal: _session.terminal,
        onEmit: _send,
        showKeys: _session.isConnected,
        leading: [
          IconButton(
            tooltip: 'Browse files',
            onPressed: (_session.isConnected && _session.canBrowseFiles)
                ? _openFiles
                : null,
            icon: const Icon(Icons.folder_outlined),
          ),
          IconButton(
            tooltip: 'Upload a file to /tmp',
            onPressed: (_session.isConnected &&
                    _session.canUploadFiles &&
                    !_uploading)
                ? _attachFile
                : null,
            icon: const Icon(Icons.attach_file),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final error = _session.error;
    if (error != null && !_session.isConnected) {
      return _ConnectionError(message: error, onRetry: _reconnect);
    }

    final tmux = _session.tmux;
    final shown = tmux == null
        ? {_session.terminal}
        : {for (final pane in tmux.panes) pane.terminal};
    _views.removeWhere((terminal, _) => !shown.contains(terminal));

    return Stack(
      children: [
        if (tmux == null)
          _paneView(_session.terminal, focused: true, padding: _padding)
        else
          TmuxPaneLayout(
            tmux: tmux,
            textStyle: _textStyle,
            padding: _padding,
            // Touching a pane is what focuses it, and the session sends the
            // bar's keys to the focused pane, so every pane sends through it.
            pane: (pane, focused) =>
                _paneView(pane.terminal, focused: focused, autoResize: false),
          ),
        if (_session.connecting)
          ColoredBox(
            color: Colors.black54,
            child: Center(
              child: _session.authUrl == null
                  ? const CircularProgressIndicator()
                  : _AuthCheckPrompt(url: _session.authUrl!),
            ),
          ),
        // Along the terminal's bottom edge, just above the key bar, rather
        // than in the bar's slot: growing the slot would shrink the terminal,
        // and resize the shell once when an upload starts and again when it
        // ends.
        if (_uploading)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: LinearProgressIndicator(value: _uploadProgress),
          ),
        // In the body rather than the Scaffold's button slot so it can be
        // parked anywhere, and so its ring is free to open over the terminal.
        if (_session.isConnected)
          Positioned.fill(
            child: MagicKey(
              terminal: _session.terminal,
              onEmit: _send,
            ),
          ),
      ],
    );
  }

  Widget _paneView(
    Terminal terminal, {
    required bool focused,
    bool autoResize = true,
    EdgeInsets? padding,
  }) => _PaneView(
    key: _views.putIfAbsent(terminal, GlobalKey.new),
    terminal: terminal,
    onEmit: _send,
    onTap: _onTerminalTap,
    focused: focused,
    autoResize: autoResize,
    padding: padding,
  );
}

const _padding = EdgeInsets.all(6);

/// What every terminal on the page draws with. tmux's panes are laid out in
/// cells of it, so it is one value rather than one per view.
const _textStyle = TerminalStyle(fontSize: 13);

/// One terminal on the page, and what makes it usable by touch: the soft
/// keyboard's input, the swipe pad, and xterm2's view. A plain session shows
/// one; tmux shows one per pane, each with its own focus, scroll position and
/// selection.
class _PaneView extends StatefulWidget {
  const _PaneView({
    super.key,
    required this.terminal,
    required this.onEmit,
    required this.onTap,
    required this.focused,
    this.autoResize = true,
    this.padding,
  });

  final Terminal terminal;
  final void Function(String data) onEmit;
  final void Function(_PaneViewState view, CellOffset cell) onTap;

  /// Whether keystrokes go here. Only such a view takes focus, and with it
  /// the soft keyboard.
  final bool focused;

  /// False for a tmux pane: tmux sizes its terminal, not the view.
  final bool autoResize;

  final EdgeInsets? padding;

  @override
  State<_PaneView> createState() => _PaneViewState();
}

class _PaneViewState extends State<_PaneView> {
  /// Shared with the terminal view below it, which is what holds focus.
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();
  final _inputKey = GlobalKey<TerminalTextInputState>();
  final _viewKey = GlobalKey<TerminalViewState>();

  /// Shared by the terminal view, which paints the selection, and the pad,
  /// which makes it by touch. It also carries the underlines Ctrl puts under
  /// every link, and keeps a Ctrl+tap from a program that reads the mouse.
  final selection = TerminalController();
  List<TerminalUnderline> _underlines = const [];

  @override
  void initState() {
    super.initState();
    // A pane born focused — tmux focuses the one a split makes — takes focus
    // from the pane that had it, which autofocus alone would leave alone.
    WidgetsBinding.instance.addPostFrameCallback((_) => _followFocus());
  }

  @override
  void didUpdateWidget(_PaneView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.focused) _followFocus();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _scrollController.dispose();
    // Takes the underlines with it.
    selection.dispose();
    super.dispose();
  }

  /// Typing goes wherever Flutter's focus is, and the key bar wherever
  /// tmux's is: the two are kept on the same pane.
  void _followFocus() {
    if (mounted && widget.focused && !_focusNode.hasFocus) {
      _focusNode.requestFocus();
    }
  }

  void requestKeyboard() => _inputKey.currentState?.requestKeyboard();

  /// Typing anywhere in the scrollback should snap back to the prompt.
  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    position.jumpTo(position.maxScrollExtent);
  }

  /// Underlines every link on screen, or takes them away.
  ///
  /// ponytail: scanned once, as Ctrl goes down. Output that arrives while it
  /// is held is not underlined until it comes down again, though a Ctrl+tap
  /// on it still opens it — the tap reads the line afresh.
  void showLinks({required bool ctrl, required Color color}) {
    // A program reading the mouse would otherwise take the tap as a click.
    selection.setSuspendPointerInput(ctrl);
    for (final underline in _underlines) {
      underline.dispose();
    }
    _underlines = const [];

    final view = _viewKey.currentState;
    if (!ctrl || view == null) return;
    final render = view.renderTerminal;
    _underlines = underlineLinks(
      selection,
      widget.terminal.buffer,
      from: render.getCellOffset(Offset.zero).y,
      to: render.getCellOffset(render.size.bottomLeft(Offset.zero)).y,
      color: color,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Two wrappers, because they take different things: the input owns the
    // keyboard connection, the pad owns the swipe. The pad sits inside so
    // its gestures land on the terminal itself — it claims only long presses
    // and double taps, so a plain tap still falls through to xterm2 below and
    // asks for the keyboard back, and a plain drag scrolls the scrollback.
    // Only while a hold has text selected does it take every touch, until
    // the selection goes.
    return TerminalTextInput(
      key: _inputKey,
      terminal: widget.terminal,
      focusNode: _focusNode,
      onInput: _scrollToBottom,
      child: SwipeKeyPad(
        terminal: widget.terminal,
        controller: selection,
        onEmit: widget.onEmit,
        child: TerminalView(
          widget.terminal,
          key: _viewKey,
          controller: selection,
          focusNode: _focusNode,
          scrollController: _scrollController,
          autofocus: widget.focused,
          autoResize: widget.autoResize,
          // The soft keyboard belongs to TerminalTextInput; xterm2 keeps
          // hardware keys, shortcuts and mouse selection.
          hardwareKeyboardOnly: true,
          // Tapping a terminal that already has focus is how you ask for the
          // keyboard back, and focus alone will not raise it.
          onTapUp: (_, cell) => widget.onTap(this, cell),
          padding: widget.padding,
          textStyle: _textStyle,
        ),
      ),
    );
  }
}

/// Says out loud that a host key was trusted on first sight, rather than
/// trusting a stranger silently. Shared by everything that connects a
/// session: this page, and the reconnect on a tab whose shell has ended.
void reportPinnedKey(BuildContext context, String fingerprint) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 6),
      content: Text('Pinned new host key\n$fingerprint'),
    ),
  );
}

/// Opens a link without leaving the app: a web page in a Custom Tab, which
/// the phone's default browser draws over this app with its own engine,
/// cookies and sign-ins, and Back returns from. Every link the app opens goes
/// through here — a Ctrl+tap, a forwarded port, a sign-in check.
///
/// A browser that cannot draw a Custom Tab takes the link as a page of its
/// own instead; a `mailto:` or `tel:` goes wherever the phone sends it. When
/// nothing takes it the user is told, rather than left tapping a dead link.
///
/// [context] is only read at the end, if it is still mounted: a snack bar's
/// Open can outlive the page that showed it.
Future<void> openUrl(BuildContext context, Uri url) async {
  final web = url.isScheme('http') || url.isScheme('https');
  for (final mode in [
    if (web) LaunchMode.inAppBrowserView,
    web ? LaunchMode.externalApplication : LaunchMode.platformDefault,
  ]) {
    try {
      if (await launchUrl(url, mode: mode)) return;
    } on PlatformException {
      // How Android says no app took it, rather than returning false.
    }
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('No app can open $url')),
    );
  }
}

/// Shown while a server is waiting for the user to prove who they are
/// somewhere else — Tailscale SSH's check, for instance.
///
/// The connection is still open behind this; finishing in the browser is what
/// releases it, so there is nothing to submit here.
class _AuthCheckPrompt extends StatelessWidget {
  const _AuthCheckPrompt({required this.url});

  final Uri url;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.verified_user_outlined,
              size: 40, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text(
            'This host wants you to sign in',
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Open the link, sign in, and this session continues on its own. '
            'Later sessions will not ask again until the check expires.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () => openUrl(context, url),
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open link'),
          ),
          const SizedBox(height: 12),
          SelectableText(
            url.toString(),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionError extends StatelessWidget {
  const _ConnectionError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.link_off, size: 40, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}
